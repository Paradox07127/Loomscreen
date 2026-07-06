import AVFoundation
import CryptoKit
import Foundation
import LiveWallpaperCore

/// Transcodes Ogg Vorbis/Opus → AAC (`.m4a`), cached, so WPE web wallpapers whose
/// audio WKWebView decodes unreliably (raw `.ogg` plays silently / stalls on
/// macOS) get a format it can. `AVAudioFile` does the in-process decode (no
/// third-party lib); wired into the `livewallpaper://` handler's existing
/// substitution path.
///
/// Concurrency (the subtle part): WK media loaders issue overlapping range
/// requests for one URL, so callers coalesce onto a single transcode and all see
/// the same result. Each wait is bounded by `deadline`, after which the key is
/// poisoned (→ serve the raw ogg) so a pathological decoder hang — which can't be
/// interrupted mid-`read` — can't stall the wallpaper. Callers must already hold
/// the security scope for `oggURL` (the handler does).
final class OggAudioTranscoder: @unchecked Sendable {
    static let shared = OggAudioTranscoder()

    private let cacheDirectory: URL
    // Concurrent so one file's (rare) un-interruptible decode hang can't
    // head-of-line block — or falsely poison — every other Ogg.
    private let queue = DispatchQueue(label: "com.livewallpaper.ogg-transcode", attributes: .concurrent)
    private let lock = NSLock()
    private enum Outcome { case ready(URL); case unavailable }
    /// Memoized per-key result. `.unavailable` poisons a file that failed or hung
    /// so it isn't retried (and its caller never waits again).
    private var memo: [String: Outcome] = [:]
    /// In-flight transcodes, so concurrent callers coalesce onto one job.
    private var pending: [String: DispatchGroup] = [:]
    /// Generous vs the observed <1s real-file cost; bounds the caller's wait and
    /// the decode loop when a file is slow, not just hung.
    private let deadline: TimeInterval = 6

    /// Disk ceiling for the transcode cache. Unlike `WPEVideoTextureDiskCache`
    /// there's no per-workshopID orphan GC — sources here aren't attributable
    /// to a scene, so a flat mtime-LRU cap is the whole reclamation story.
    private static let maxCacheBytes: UInt64 = 256 * 1024 * 1024  // 256 MiB

    private init() {
        let caches = (try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        cacheDirectory = caches.appendingPathComponent("OggTranscode", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        queue.async { [self] in enforceSizeLimit() }
    }

    static func isOggFamily(_ url: URL) -> Bool {
        ["ogg", "oga", "opus"].contains(url.pathExtension.lowercased())
    }

    /// Cached AAC `.m4a` for `oggURL`, transcoding on first call. Returns nil on
    /// failure or timeout — the caller then serves the raw ogg, i.e. no
    /// regression vs today. Concurrent callers for the same file see one
    /// consistent result.
    func transcodedM4A(forOgg oggURL: URL) -> URL? {
        guard Self.isOggFamily(oggURL), let key = cacheKey(for: oggURL) else { return nil }
        let destination = cacheDirectory.appendingPathComponent(key).appendingPathExtension("m4a")

        lock.lock()
        switch memo[key] {
        case .ready(let url): lock.unlock(); return url
        case .unavailable:    lock.unlock(); return nil   // poisoned this session — never serve, even if a late .m4a lands
        case nil:             break
        }
        // Disk cache from a prior session wins — but only after the poison check
        // above, so a stale/late file can't bypass an in-session poison.
        if FileManager.default.fileExists(atPath: destination.path) {
            memo[key] = .ready(destination)
            lock.unlock()
            return destination
        }
        if let group = pending[key] {
            // Coalesce: wait (bounded) for the in-flight transcode so concurrent
            // range requests for the same URL all serve the same representation.
            lock.unlock()
            if group.wait(timeout: .now() + deadline) == .success {
                return readyURL(forKey: key)
            }
            return arbitrateAfterTimeout(forKey: key)
        }
        let group = DispatchGroup()
        group.enter()
        pending[key] = group
        lock.unlock()

        queue.async { [self] in
            let produced = transcode(oggURL, to: destination)
            lock.lock()
            if case .unavailable = memo[key] {
                // A caller already timed out and poisoned this key — honor it and
                // drop the late artifact so it can't resurface as a cache hit.
                if let produced { try? FileManager.default.removeItem(at: produced) }
            } else {
                memo[key] = produced.map(Outcome.ready) ?? .unavailable
            }
            pending[key] = nil
            group.leave()
            lock.unlock()
            if produced != nil { enforceSizeLimit() }
        }

        guard group.wait(timeout: .now() + deadline) == .success else {
            return arbitrateAfterTimeout(forKey: key)
        }
        return readyURL(forKey: key)
    }

    /// After a caller's bounded wait elapses, converge every caller for this key:
    /// honor whatever the background job already committed, else poison (so the
    /// session stays consistent on the raw ogg, and the job honors that poison).
    /// Used by both the creator and the coalesced-waiter timeout paths so they
    /// can't diverge into mixed AAC/ogg representations for one URL.
    private func arbitrateAfterTimeout(forKey key: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        switch memo[key] {
        case .ready(let url): return url
        case .unavailable:    return nil
        case nil:             memo[key] = .unavailable; return nil
        }
    }

    private func readyURL(forKey key: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        if case .ready(let url) = memo[key] { return url }
        return nil
    }

    private func transcode(_ source: URL, to destination: URL) -> URL? {
        let partial = destination.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)
        do {
            let input = try AVAudioFile(forReading: source)
            let format = input.processingFormat
            let total = input.length
            guard total > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else {
                return nil
            }
            var written: AVAudioFramePosition = 0
            // Inner scope so the writer is finalized (flushed + closed) before the move.
            do {
                let output = try AVAudioFile(
                    forWriting: partial,
                    settings: [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: format.sampleRate,
                        AVNumberOfChannelsKey: format.channelCount
                    ]
                )
                let started = ProcessInfo.processInfo.systemUptime
                var reachedEnd = false
                // `AVAudioFile.read` THROWS at end-of-stream (Ogg `length` is only
                // an estimate, so an exact frame count can't be read). Treat that
                // throw as completion once audio has been decoded; a throw before
                // any frames is a genuine decode failure (→ caught below, no cache).
                // A `write` failure still propagates as a real error.
                while !reachedEnd {
                    if ProcessInfo.processInfo.systemUptime - started > deadline { throw TranscodeError.timedOut }
                    try autoreleasepool {
                        do {
                            try input.read(into: buffer, frameCount: buffer.frameCapacity)
                        } catch {
                            reachedEnd = true
                            return
                        }
                        if buffer.frameLength == 0 {
                            reachedEnd = true
                            return
                        }
                        try output.write(from: buffer)
                        written += AVAudioFramePosition(buffer.frameLength)
                    }
                }
                // A clean decode reads ~100% of the (slightly over-estimated)
                // length; far fewer frames means `read` threw mid-stream rather
                // than at EOF, so reject it instead of caching a truncated file.
                guard Double(written) >= Double(total) * 0.9 else { throw TranscodeError.truncated }
            }
            try FileManager.default.moveItem(at: partial, to: destination)
            Logger.info(
                "Ogg→AAC transcoded \(source.lastPathComponent) (\(written)/\(total) frames)",
                category: .screenManager
            )
            return destination
        } catch {
            try? FileManager.default.removeItem(at: partial)
            Logger.notice(
                "Ogg→AAC transcode skipped for \(source.lastPathComponent): \(error.localizedDescription)",
                category: .screenManager
            )
            return nil
        }
    }

    private func cacheKey(for url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize else { return nil }
        let stamp = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        let seed = "\(url.path)|\(size)|\(stamp)"
        let digest = SHA256.hash(data: Data(seed.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Evicts the least-recently-modified `.m4a`s until the directory is back
    /// under `maxCacheBytes`. Runs off the caller's path (init / after a
    /// background transcode completes) so it never adds latency to playback.
    private func enforceSizeLimit() {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var files: [(url: URL, size: UInt64, modified: Date)] = []
        var total: UInt64 = 0
        for url in children {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            let size = UInt64(max(0, values.fileSize ?? 0))
            let modified = values.contentModificationDate ?? .distantPast
            if url.pathExtension == "partial" {
                // Fresh `.partial` belongs to a possibly-running transcode; a
                // stale one is an orphan from a killed process. Either way it
                // never counts against the budget.
                if modified < Date(timeIntervalSinceNow: -3600) {
                    try? fm.removeItem(at: url)
                }
                continue
            }
            guard url.pathExtension == "m4a" else { continue }
            total += size
            files.append((url, size, modified))
        }
        guard total > Self.maxCacheBytes else { return }

        for file in files.sorted(by: { $0.modified < $1.modified }) {
            if total <= Self.maxCacheBytes { break }
            let key = file.url.deletingPathExtension().lastPathComponent
            // Check-and-delete atomically with the caller's disk-hit promotion
            // (which also runs under `lock`): clear the memo and unlink while
            // holding it so a concurrent request can't re-promote the path
            // between our check and the delete. Evicting a `.ready` entry is
            // fine — the next request simply re-transcodes.
            lock.lock()
            if pending[key] != nil {
                lock.unlock()
                continue
            }
            let previous = memo[key]
            memo[key] = nil
            let removed = (try? fm.removeItem(at: file.url)) != nil
            if !removed { memo[key] = previous }
            lock.unlock()
            if removed { total -= file.size }
        }
    }

    private enum TranscodeError: Error { case timedOut, truncated }
}
