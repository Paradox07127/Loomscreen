import Foundation
@preconcurrency import WebKit
import UniformTypeIdentifiers

/// Serves files from a security-scoped folder under a custom `livewallpaper://`
/// scheme so WKWebView treats them as same-origin web content. file:// loads
/// of Vite/webpack ES-module bundles fail because `<script type="module">`
/// + `crossorigin` triggers CORS rejection that file:// cannot satisfy; this
/// handler avoids the issue entirely.
///
/// Top-level navigations must include the per-session `?n=<nonce>` query
/// parameter so a stale `livewallpaper://wallpaper/...` URL retained by a
/// previous folder cannot be replayed against the active folder. Subresource
/// requests inherit security from the enclosing document, so they don't
/// need the nonce; WebKit only routes them here while the parent document
/// loaded with the matching nonce.
///
/// `@unchecked Sendable` because WebKit invokes the protocol methods on the
/// main thread (documented behaviour) and all mutable state is read / written
/// from the main thread by `HTMLWallpaperView`.
final class FolderURLSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    nonisolated static let scheme = "livewallpaper"
    nonisolated static let host = "wallpaper"
    nonisolated static let responseChunkSize = 64 * 1024

    /// CSP applied to every response served from this handler. v2 baseline
    /// from `docs/2026-05-28-steam-workshop-integration-plan.md` (Phase 4).
    ///
    /// Hard wins kept regardless of audit outcome:
    /// - `frame-src 'none'` blocks clickjacking and nested document attacks.
    /// - `object-src 'none'` denies plugins / `<embed>` / Flash.
    /// - `form-action 'none'` denies `<form>` exfiltration submits.
    /// - `base-uri 'none'` denies `<base href>` redirect attacks.
    ///
    /// Compatibility allowances (validated by the Phase 0 step 10 audit):
    /// - `unsafe-inline` / `unsafe-eval` are required by the legitimate WPE
    ///   web project corpus (inline `<script>` and dynamic property eval).
    /// - `connect-src https:` allows outbound HTTPS so weather / clock / news
    ///   widgets keep working. Residual risk (exfiltration) is documented in
    ///   the threat model — the HTML wallpaper path registers no Swift
    ///   bridge, so JS has no access to local files, Keychain, or app state.
    nonisolated static let contentSecurityPolicy: String = [
        "default-src 'self' 'unsafe-inline' 'unsafe-eval' data: blob: livewallpaper:;",
        "connect-src 'self' https: livewallpaper: data: blob:;",
        "img-src 'self' https: data: blob: livewallpaper:;",
        "media-src 'self' https: data: blob: livewallpaper:;",
        "font-src 'self' https: data: livewallpaper:;",
        "frame-src 'none';",
        "object-src 'none';",
        "base-uri 'none';",
        "form-action 'none';"
    ].joined(separator: " ")

    /// Per-handler CSP override. Tests inject one of the candidate policies
    /// in `Report-Only` mode (via `CSPCompatibilityAuditTests`) so the
    /// wallpaper runs unimpeded while the browser still emits
    /// `securitypolicyviolation` events for the test corpus. `nil` (the
    /// default) keeps the production enforced policy from
    /// `contentSecurityPolicy`.
    var cspOverride: ContentSecurityPolicyOverride?

    /// Directives + disposition held together so callers can't swap one field
    /// but forget the other.
    struct ContentSecurityPolicyOverride: Sendable, Equatable {
        enum Disposition: Sendable, Equatable {
            case enforced
            case reportOnly
        }
        let directives: String
        let disposition: Disposition

        var headerName: String {
            switch disposition {
            case .enforced:   return "Content-Security-Policy"
            case .reportOnly: return "Content-Security-Policy-Report-Only"
            }
        }
    }

    private var activeFolderURL: URL?
    private var sessionNonce: String?
    private var activeTasks: [ObjectIdentifier: ActiveTask] = [:]

    /// Optional in-place package backend. When set, a request that the folder
    /// does NOT have as a loose file is resolved against the parsed `scene.pkg`
    /// table-of-contents (entries are contiguous, uncompressed byte slices).
    /// Loose files always win, so an ordinary HTML folder next to a `scene.pkg`
    /// keeps its plain-folder behaviour; the package only serves the packaged
    /// payload (index + bundle). Set/cleared together with `folderURL`; changing
    /// the folder always clears it.
    private var activePackageBacking: PackageBacking?

    struct PackageBacking: Sendable {
        let url: URL
        let package: WallpaperEnginePackage
    }
    /// Filenames already reported as missing for the current folder session.
    /// Wallpaper Engine projects routinely reference voiceline / sprite
    /// resources that were never packaged (the author shipped placeholders),
    /// and the HTML side retries them on every loop tick. Logging each retry
    /// at warning level spams the console; we log once and stay quiet after.
    private var reportedMissingResources: Set<String> = []
    /// Same dedupe pattern for Ogg → mp3/m4a substitutions — logged once per
    /// requested filename per session so the user can see the workaround
    /// happened without the console drowning in repeat entries.
    private var reportedOggSubstitutions: Set<String> = []

    /// Updated each time `HTMLWallpaperView.loadSource(.folder)` swaps content.
    /// Setting `nil` (or any different folder) immediately cancels in-flight
    /// scheme requests so a stale detached worker cannot keep streaming the
    /// previous folder after the security scope is gone.
    var folderURL: URL? {
        get { activeFolderURL }
        set {
            if activeFolderURL != newValue {
                cancelAllActiveTasks()
                reportedMissingResources.removeAll()
                reportedOggSubstitutions.removeAll()
            }
            activeFolderURL = newValue
            // A folder swap invalidates any prior package backend; the caller
            // re-supplies one via `setPackageBacking(_:)` right after.
            activePackageBacking = nil
            sessionNonce = newValue == nil ? nil : UUID().uuidString
        }
    }

    /// Supplies (or clears) the in-place package backend for the current folder
    /// session. Must be called *after* assigning `folderURL` (which resets it),
    /// and does not regenerate the session nonce.
    func setPackageBacking(_ backing: PackageBacking?) {
        activePackageBacking = backing
    }

    /// Nonce produced for the current `folderURL` session. `HTMLWallpaperView`
    /// embeds it as `?n=<nonce>` on the top-level URL it asks WebKit to load.
    var currentSessionNonce: String? {
        sessionNonce
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(Self.makeError(.badURL))
            return
        }

        do {
            try validateRequest(urlSchemeTask.request, url: url)
        } catch {
            urlSchemeTask.didFailWithError(error)
            return
        }

        guard activeFolderURL != nil else {
            urlSchemeTask.didFailWithError(Self.makeError(.notConnectedToInternet, "No active folder"))
            return
        }

        // Resolve the loose candidate first (rejects path traversal). A loose
        // file — when it actually exists — wins, preserving plain-folder
        // semantics for ordinary HTML folders that merely happen to sit next to
        // a `scene.pkg`. Only paths the folder does NOT have loose fall back to
        // an in-place package entry (that's the packaged web payload).
        let primaryURL: URL
        do {
            primaryURL = try Self.resolvedFileURL(for: url, inside: activeFolderURL!)
        } catch {
            urlSchemeTask.didFailWithError(error)
            return
        }

        let source: ByteSource
        let mime: String
        if Self.isRegularFile(primaryURL) {
            source = .file(primaryURL)
            mime = Self.mimeType(for: primaryURL)
        } else if let fallback = Self.oggFallbackURL(for: primaryURL) {
            if !reportedOggSubstitutions.contains(primaryURL.lastPathComponent) {
                reportedOggSubstitutions.insert(primaryURL.lastPathComponent)
                Logger.info(
                    "FolderScheme: serving \(fallback.lastPathComponent) for \(primaryURL.lastPathComponent) (macOS WebKit Ogg/Opus decoder workaround)",
                    category: .screenManager
                )
            }
            source = .file(fallback)
            mime = Self.mimeType(for: fallback)
        } else if let resolved = packageByteSource(for: url) {
            source = resolved.source
            mime = resolved.mime
        } else {
            // Nothing loose, nothing in the package: serve the loose candidate
            // so the worker emits the existing 404 + missing-resource log.
            source = .file(primaryURL)
            mime = Self.mimeType(for: primaryURL)
        }

        let rangeHeader = urlSchemeTask.request.value(forHTTPHeaderField: "Range")
        let delivery = SchemeTaskDelivery(urlSchemeTask)
        let taskID = ObjectIdentifier(urlSchemeTask as AnyObject)
        // Snapshot the CSP for this request on the main thread so the detached
        // worker can attach it without crossing actor boundaries to read the
        // mutable `cspOverride` property.
        let cspHeader: (name: String, value: String) = {
            if let override = cspOverride {
                return (override.headerName, override.directives)
            }
            return ("Content-Security-Policy", Self.contentSecurityPolicy)
        }()

        activeTasks[taskID]?.cancel()

        let worker = Task.detached(priority: .userInitiated) { [weak self, source, mime, rangeHeader, url, delivery, taskID, cspHeader] in
            do {
                let totalLength = try Self.totalLength(of: source)
                let range = Self.byteRange(from: rangeHeader, totalLength: totalLength)
                let statusCode = range == nil ? 200 : 206
                let contentLength = range?.length ?? totalLength

                var headers = [
                    "Content-Type": mime,
                    "Content-Length": "\(contentLength)",
                    "Accept-Ranges": "bytes",
                    cspHeader.name: cspHeader.value
                ]
                // Range-served audio / video subresources need ACAO so the
                // page can `<audio>`/`<video>` them across nested iframes;
                // the previous unconditional `*` also opened every text /
                // JSON response to cross-origin reads, which we don't want.
                // CSP `default-src 'self'` already gates same-origin
                // fetches without needing ACAO on those responses.
                if Self.requiresMediaCORSExposure(for: mime) {
                    headers["Access-Control-Allow-Origin"] = "*"
                }
                if let range {
                    headers["Content-Range"] = "bytes \(range.start)-\(range.end)/\(totalLength)"
                }

                let response = HTTPURLResponse(
                    url: url,
                    statusCode: statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: headers
                ) ?? URLResponse(
                    url: url,
                    mimeType: mime,
                    expectedContentLength: contentLength,
                    textEncodingName: nil
                )

                await delivery.deliver(response: response)
                try await Self.stream(
                    source,
                    to: delivery,
                    offset: range?.start ?? 0,
                    length: contentLength
                )
                await delivery.finish()
            } catch is CancellationError {
                await delivery.fail(with: Self.makeError(.cancelled, "Request cancelled"))
            } catch {
                let isMissingFile = (error as NSError).domain == NSCocoaErrorDomain
                    && ((error as NSError).code == NSFileReadNoSuchFileError
                        || (error as NSError).code == NSFileNoSuchFileError)
                if isMissingFile, case .file(let fileURL) = source {
                    await self?.logMissingResource(fileURL: fileURL, requestURL: url)
                } else {
                    Logger.warning("FolderScheme: \(source.lastComponent) — \(error.localizedDescription)", category: .screenManager)
                }
                await delivery.fail(with: error)
            }

            _ = await MainActor.run {
                self?.activeTasks.removeValue(forKey: taskID)
            }
        }

        activeTasks[taskID] = ActiveTask(worker: worker, delivery: delivery)
        if delivery.hasTerminated {
            activeTasks.removeValue(forKey: taskID)
        }
    }

    /// Resolves a request to an in-place `scene.pkg` entry when a package
    /// backend is active. Returns `nil` (→ loose-folder fallback) when there is
    /// no package, the path is unsafe, or the entry isn't in the package. Path
    /// safety is enforced by `canonicalLookupName` (rejects leading `/` / `..`).
    private func packageByteSource(for url: URL) -> (source: ByteSource, mime: String)? {
        guard let backing = activePackageBacking else { return nil }
        let requestPath = url.path.removingPercentEncoding ?? url.path
        let relativePath = requestPath.hasPrefix("/") ? String(requestPath.dropFirst()) : requestPath
        guard let lookup = WallpaperEnginePackage.canonicalLookupName(relativePath) else { return nil }

        if let entry = backing.package.entry(named: lookup) {
            return (Self.packageSource(for: entry, in: backing), Self.mimeType(forEntryName: entry.name))
        }
        // Ogg-family substitution, mirroring the loose-folder workaround but
        // resolved against the package's in-memory table of contents.
        if let fallback = Self.packageOggFallbackEntry(for: lookup, in: backing.package) {
            let requested = (lookup as NSString).lastPathComponent
            if !reportedOggSubstitutions.contains(requested) {
                reportedOggSubstitutions.insert(requested)
                Logger.info(
                    "FolderScheme: serving \(fallback.name) for \(requested) from package (macOS WebKit Ogg/Opus decoder workaround)",
                    category: .screenManager
                )
            }
            return (Self.packageSource(for: fallback, in: backing), Self.mimeType(forEntryName: fallback.name))
        }
        return nil
    }

    nonisolated private static func packageSource(
        for entry: WallpaperEnginePackage.Entry,
        in backing: PackageBacking
    ) -> ByteSource {
        .packageEntry(
            packageURL: backing.url,
            absoluteStart: backing.package.dataStart + entry.dataOffset,
            size: entry.dataSize
        )
    }

    nonisolated private static func packageOggFallbackEntry(
        for lookup: String,
        in package: WallpaperEnginePackage
    ) -> WallpaperEnginePackage.Entry? {
        let ext = (lookup as NSString).pathExtension.lowercased()
        guard ext == "ogg" || ext == "oga" || ext == "opus" else { return nil }
        let base = (lookup as NSString).deletingPathExtension
        for candidateExt in oggFallbackExtensions {
            if let entry = package.entry(named: "\(base).\(candidateExt)") {
                return entry
            }
        }
        return nil
    }

    /// Diagnostic log for the "file not found" branch. Logging only
    /// `lastPathComponent` can't distinguish a truly-missing asset from our
    /// path resolution dropping a subfolder, so we also log the request path,
    /// resolved fs path, an existence check, a parent-dir peek (surfaces a
    /// near-miss filename), and an OGG/Opus codec hint (users mistake a flaky
    /// WebKit decoder for a missing file). One entry per filename per session.
    @MainActor
    private func logMissingResource(fileURL: URL, requestURL: URL) {
        guard reportedMissingResources.insert(fileURL.lastPathComponent).inserted else { return }

        let fm = FileManager.default
        let exists = fm.fileExists(atPath: fileURL.path)
        let parent = fileURL.deletingLastPathComponent()
        var siblingPreview = ""
        if let entries = try? fm.contentsOfDirectory(atPath: parent.path) {
            let sorted = entries.sorted()
            let head = sorted.prefix(10)
            let extra = sorted.count > 10 ? " (+\(sorted.count - 10) more)" : ""
            siblingPreview = head.isEmpty
                ? " | parentEmpty"
                : " | parent=[\(head.joined(separator: ", "))]\(extra)"
        } else {
            siblingPreview = " | parentUnreadable"
        }

        let codecHint: String
        switch fileURL.pathExtension.lowercased() {
        case "ogg", "oga", "opus":
            codecHint = " | hint=Ogg/Opus has historically poor WebKit support on macOS — convert to .mp3 / .aac if 404 persists"
        case "webm":
            codecHint = " | hint=WebM audio/video has limited WebKit support on macOS"
        default:
            codecHint = ""
        }

        Logger.info(
            """
            FolderScheme 404: \(fileURL.lastPathComponent) \
            requested=\(requestURL.path) \
            resolved=\(fileURL.path) \
            onDisk=\(exists)\(siblingPreview)\(codecHint)
            """,
            category: .screenManager
        )
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        let taskID = ObjectIdentifier(urlSchemeTask as AnyObject)
        guard let entry = activeTasks.removeValue(forKey: taskID) else { return }
        entry.cancel()
    }

    private func cancelAllActiveTasks() {
        let entries = activeTasks
        activeTasks.removeAll()
        for entry in entries.values {
            entry.cancel()
        }
    }

    // MARK: - Validation

    private func validateRequest(_ request: URLRequest, url: URL) throws {
        guard url.host?.lowercased() == Self.host else {
            throw Self.makeError(.badURL, "Host mismatch")
        }
        guard activeFolderURL != nil else {
            throw Self.makeError(.notConnectedToInternet, "No active folder")
        }

        let isTopLevel = request.mainDocumentURL == nil || request.mainDocumentURL == url
        if isTopLevel, !topLevelNonceIsValid(for: url) {
            throw Self.makeError(.badURL, "Invalid folder session nonce")
        }
    }

    private func topLevelNonceIsValid(for url: URL) -> Bool {
        guard let sessionNonce,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems,
              items.count == 1,
              items[0].name == "n",
              items[0].value == sessionNonce else {
            return false
        }
        return true
    }

    // MARK: - Helpers

    /// macOS WebKit's Ogg/Vorbis/Opus decoder has well-known issues that
    /// don't reproduce in Chrome / Firefox (which bundle their own ffmpeg):
    /// playback stalls on granulepos jumps, multi-stream Ogg goes silent,
    /// and pre-macOS-14 there is no Opus support at all. Additionally,
    /// Wallpaper Engine authors frequently hardcode `.ogg` in their JS but
    /// ship only `.mp3` in the published package.
    ///
    /// Both cases collapse to the same fix: when an Ogg-family URL is
    /// requested, prefer a same-name sibling in a reliably-supported
    /// container if one exists. Returns `nil` when no substitution applies.
    nonisolated private static let oggFallbackExtensions: [String] = ["mp3", "m4a", "aac", "wav", "flac"]

    nonisolated static func oggFallbackURL(for primary: URL) -> URL? {
        let ext = primary.pathExtension.lowercased()
        guard ext == "ogg" || ext == "oga" || ext == "opus" else { return nil }
        let parent = primary.deletingLastPathComponent()
        let baseName = primary.deletingPathExtension().lastPathComponent
        let fm = FileManager.default
        for candidateExt in oggFallbackExtensions {
            let candidate = parent.appendingPathComponent("\(baseName).\(candidateExt)")
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    nonisolated static func resolvedFileURL(for requestURL: URL, inside folderURL: URL) throws -> URL {
        let rootURL = folderURL.standardizedFileURL.resolvingSymlinksInPath()
        let requestPath = requestURL.path.removingPercentEncoding ?? requestURL.path
        let relativePath = requestPath.hasPrefix("/") ? String(requestPath.dropFirst()) : requestPath
        let candidate = rootURL
            .appendingPathComponent(relativePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        let rootPath = normalizedPath(rootURL.path(percentEncoded: false))
        let candidatePath = normalizedPath(candidate.path(percentEncoded: false))

        guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else {
            throw Self.makeError(.noPermissionsToReadFile, "Path escapes folder")
        }

        return candidate
    }

    nonisolated private static func normalizedPath(_ path: String) -> String {
        var normalized = path
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    nonisolated private static func fileSize(for url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw Self.makeError(.cannotOpenFile, "Requested resource is not a regular file")
        }
        guard let fileSize = values.fileSize else {
            throw Self.makeError(.cannotOpenFile, "Missing file size")
        }
        return fileSize
    }

    nonisolated private static func streamFile(
        _ url: URL,
        to delivery: SchemeTaskDelivery,
        offset: Int,
        length: Int
    ) async throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        if offset > 0 {
            try handle.seek(toOffset: UInt64(offset))
        }

        var bytesRemaining = length
        while bytesRemaining > 0 {
            try Task.checkCancellation()
            let chunkLimit = min(responseChunkSize, bytesRemaining)
            let chunk = try handle.read(upToCount: chunkLimit) ?? Data()
            guard !chunk.isEmpty else { break }
            bytesRemaining -= chunk.count
            await delivery.deliver(chunk: chunk)
        }
    }

    nonisolated private static func totalLength(of source: ByteSource) throws -> Int {
        switch source {
        case .file(let url):
            return try fileSize(for: url)
        case .packageEntry(_, _, let size):
            guard let length = Int(exactly: size) else {
                throw makeError(.cannotOpenFile, "Package entry exceeds addressable size")
            }
            return length
        }
    }

    nonisolated private static func stream(
        _ source: ByteSource,
        to delivery: SchemeTaskDelivery,
        offset: Int,
        length: Int
    ) async throws {
        switch source {
        case .file(let url):
            try await streamFile(url, to: delivery, offset: offset, length: length)
        case .packageEntry(let packageURL, let absoluteStart, _):
            try await streamPackageEntry(
                packageURL: packageURL,
                absoluteStart: absoluteStart,
                to: delivery,
                offset: offset,
                length: length
            )
        }
    }

    /// Streams a slice of a `scene.pkg` entry. Each task opens its **own** file
    /// handle (entries are contiguous, uncompressed byte ranges) so concurrent
    /// subresource requests never contend on a shared seek offset.
    nonisolated private static func streamPackageEntry(
        packageURL: URL,
        absoluteStart: UInt64,
        to delivery: SchemeTaskDelivery,
        offset: Int,
        length: Int
    ) async throws {
        let handle = try FileHandle(forReadingFrom: packageURL)
        defer { try? handle.close() }

        try handle.seek(toOffset: absoluteStart + UInt64(max(0, offset)))

        var bytesRemaining = length
        while bytesRemaining > 0 {
            try Task.checkCancellation()
            let chunkLimit = min(responseChunkSize, bytesRemaining)
            let chunk = try handle.read(upToCount: chunkLimit) ?? Data()
            guard !chunk.isEmpty else { break }
            bytesRemaining -= chunk.count
            await delivery.deliver(chunk: chunk)
        }
        // A package entry has a known exact size; a short read means a truncated
        // or corrupt package, not EOF — surface it instead of a silent success.
        if bytesRemaining > 0 {
            throw makeError(.cannotParseResponse, "Package entry truncated by \(bytesRemaining) bytes")
        }
    }

    nonisolated private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }

    private struct ByteRange: Sendable {
        let start: Int
        let end: Int
        var length: Int { end - start + 1 }
    }

    nonisolated private static func byteRange(from header: String?, totalLength: Int) -> ByteRange? {
        guard totalLength > 0,
              let header,
              header.lowercased().hasPrefix("bytes="),
              !header.contains(",") else { return nil }

        let spec = String(header.dropFirst("bytes=".count))
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }

        if parts[0].isEmpty {
            guard let suffixLength = Int(parts[1]), suffixLength > 0 else { return nil }
            let length = min(suffixLength, totalLength)
            let start = totalLength - length
            return ByteRange(start: start, end: totalLength - 1)
        }

        guard let start = Int(parts[0]), start >= 0, start < totalLength else { return nil }

        let end: Int
        if parts[1].isEmpty {
            end = totalLength - 1
        } else if let parsed = Int(parts[1]), parsed >= start {
            end = min(parsed, totalLength - 1)
        } else {
            return nil
        }

        return ByteRange(start: start, end: end)
    }

    nonisolated private static func mimeType(for url: URL) -> String {
        mimeType(forPathExtension: url.pathExtension)
    }

    nonisolated private static func mimeType(forEntryName name: String) -> String {
        mimeType(forPathExtension: (name as NSString).pathExtension)
    }

    nonisolated private static func mimeType(forPathExtension rawExtension: String) -> String {
        let ext = rawExtension.lowercased()
        if let utType = UTType(filenameExtension: ext), let mime = utType.preferredMIMEType {
            return mime
        }
        switch ext {
        case "js", "mjs": return "application/javascript"
        case "wasm":      return "application/wasm"
        case "json":      return "application/json"
        case "ogg":       return "audio/ogg"
        case "oga":       return "audio/ogg"
        case "opus":      return "audio/ogg"
        case "mp3":       return "audio/mpeg"
        case "m4a":       return "audio/mp4"
        case "wav":       return "audio/wav"
        case "flac":      return "audio/flac"
        case "webm":      return "audio/webm"
        case "atlas":     return "text/plain"
        case "skel":      return "application/octet-stream"
        default:          return "application/octet-stream"
        }
    }

    /// Whether the response needs `Access-Control-Allow-Origin: *` to be
    /// useful. Range-served media (audio/video) historically needed it on the
    /// `wpe-asset://` scheme so cross-origin `<audio>` / `<video>` could
    /// play; we mirror that here to avoid regressing existing local WE
    /// projects. Plain HTML / JS / JSON / CSS / images stay same-origin —
    /// the page's own document is on `livewallpaper://wallpaper`, so the
    /// `'self'` directive in CSP covers their needs without ACAO.
    nonisolated static func requiresMediaCORSExposure(for mime: String) -> Bool {
        mime.hasPrefix("audio/") || mime.hasPrefix("video/")
    }

    nonisolated static func makeError(_ code: URLError.Code, _ message: String? = nil) -> NSError {
        var info: [String: Any] = [:]
        if let message { info[NSLocalizedDescriptionKey] = message }
        return NSError(domain: NSURLErrorDomain, code: code.rawValue, userInfo: info)
    }
}

// MARK: - Internal Types

/// Where a resolved request's bytes come from: a loose file on disk, or a
/// contiguous slice of an in-place `scene.pkg`.
private enum ByteSource: Sendable {
    case file(URL)
    case packageEntry(packageURL: URL, absoluteStart: UInt64, size: UInt64)

    var lastComponent: String {
        switch self {
        case .file(let url):
            return url.lastPathComponent
        case .packageEntry(let packageURL, _, _):
            return "\(packageURL.lastPathComponent)#entry"
        }
    }
}

private struct ActiveTask {
    let worker: Task<Void, Never>
    let delivery: SchemeTaskDelivery

    @MainActor
    func cancel() {
        delivery.markStopped()
        worker.cancel()
    }
}

/// Bridges the detached worker back to the main-thread `WKURLSchemeTask`.
/// Once `markStopped()` is called every subsequent delivery is dropped, so a
/// late chunk can never reach an invalidated task.
private final class SchemeTaskDelivery: @unchecked Sendable {
    private let task: any WKURLSchemeTask
    @MainActor private var isLive: Bool = true

    init(_ task: any WKURLSchemeTask) {
        self.task = task
    }

    @MainActor
    var hasTerminated: Bool { !isLive }

    @MainActor
    func markStopped() {
        isLive = false
    }

    @MainActor
    func deliver(response: URLResponse) {
        guard isLive else { return }
        task.didReceive(response)
    }

    @MainActor
    func deliver(chunk data: Data) {
        guard isLive else { return }
        task.didReceive(data)
    }

    @MainActor
    func finish() {
        guard isLive else { return }
        isLive = false
        task.didFinish()
    }

    @MainActor
    func fail(with error: Error) {
        guard isLive else { return }
        isLive = false
        task.didFailWithError(error)
    }
}
