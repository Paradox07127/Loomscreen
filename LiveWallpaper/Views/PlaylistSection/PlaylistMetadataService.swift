import Foundation
@preconcurrency import AVFoundation
import LiveWallpaperCore

/// Resolves bookmark → URL → AVURLAsset metadata (resolution + duration + folder).
actor PlaylistMetadataService {
    static let shared = PlaylistMetadataService()

    private var cache: [String: PlaylistRowMetadata] = [:]
    private var inFlight: [String: Task<PlaylistRowMetadata, Never>] = [:]
    private let cacheLimit = 256

    private init() {}

    /// Cancellation is cooperative: a caller's parent-task cancellation drops
    /// their wait but does not invalidate the shared in-flight computation.
    func metadata(for bookmark: Data) async -> PlaylistRowMetadata {
        let key = cacheKey(for: bookmark)
        if let cached = cache[key] { return cached }
        if let pending = inFlight[key] { return await pending.value }

        let task = Task<PlaylistRowMetadata, Never> {
            await PlaylistMetadataService.loadMetadata(for: bookmark)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight.removeValue(forKey: key)
        if result != .empty {
            storeInCache(result, for: key)
        }
        return result
    }

    func invalidate(_ bookmark: Data) {
        cache.removeValue(forKey: cacheKey(for: bookmark))
    }

    private func storeInCache(_ value: PlaylistRowMetadata, for key: String) {
        if cache.count >= cacheLimit {
            if let victim = cache.keys.randomElement() {
                cache.removeValue(forKey: victim)
            }
        }
        cache[key] = value
    }

    private func cacheKey(for bookmark: Data) -> String {
        bookmark.base64EncodedString()
    }

    // MARK: - Loader

    private static func loadMetadata(for bookmark: Data) async -> PlaylistRowMetadata {
        let resolverResult = SecurityScopedBookmarkResolver.shared.resolve(
            bookmark,
            target: .transient
        )
        guard case .success(let resolved) = resolverResult else {
            return .empty
        }
        let url = resolved.url
        let folder = url.deletingLastPathComponent().lastPathComponent

        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        let asset = AVURLAsset(url: url)
        async let durationLoad: CMTime? = {
            try? await asset.load(.duration)
        }()
        async let resolutionLoad: CGSize? = await Self.loadResolution(from: asset)

        let durationTime = await durationLoad
        let resolution = await resolutionLoad
        let seconds = durationTime.flatMap { time -> TimeInterval? in
            let raw = CMTimeGetSeconds(time)
            return raw.isFinite && raw > 0 ? raw : nil
        }

        return PlaylistRowMetadata(
            resolution: resolution,
            duration: seconds,
            folder: folder
        )
    }

    private static func loadResolution(from asset: AVURLAsset) async -> CGSize? {
        guard let tracks = try? await asset.loadTracks(withMediaType: .video),
              let track = tracks.first
        else { return nil }
        guard let size = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform)
        else { return nil }
        let transformed = size.applying(transform)
        return CGSize(width: abs(transformed.width), height: abs(transformed.height))
    }
}
