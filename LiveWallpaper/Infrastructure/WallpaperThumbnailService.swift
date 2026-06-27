import AppKit
@preconcurrency import AVFoundation
import WebKit

/// Shared thumbnail provider for video / HTML wallpapers.
///
/// - Videos: first-frame poster via `AVAssetImageGenerator`.
/// - HTML:   single-shot offscreen `WKWebView.takeSnapshot` after the page
///           hits `didFinish` (or a small fallback timeout).
///
/// Cached in-memory by a stable string key so the BookmarkCard grid and
/// the HTML inspector preview share one rendering pass per source.
@MainActor
final class WallpaperThumbnailService {
    static let shared = WallpaperThumbnailService()

    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 256
        // ~64 MB ceiling. With 480x270 RGBA thumbnails costing ~0.5 MB
        // each, the count cap alone could pin ~125 MB worst case; the
        // byte cap kicks in earlier and lets NSCache evict under memory
        // pressure.
        c.totalCostLimit = 64 * 1024 * 1024
        return c
    }()

    /// Dedup: re-entering for the same key returns the same task, not a parallel snapshot.
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    /// Held strong until snapshot completion — WKWebView fails silently if released mid-load.
    private var pendingWebViews: [String: PendingHTMLSnapshot] = [:]

    private init() {}

    func cachedThumbnail(forKey key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    func videoPosterImage(for url: URL, cacheKey: String) async -> NSImage? {
        if let cached = cachedThumbnail(forKey: cacheKey) { return cached }
        if let inFlight = inFlight[cacheKey] { return await inFlight.value }

        let task = Task<NSImage?, Never> { [cache] in
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }

            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 270)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

            do {
                let (cgImage, _) = try await generator.image(at: .zero)
                let size = NSSize(width: cgImage.width, height: cgImage.height)
                let image = NSImage(cgImage: cgImage, size: size)
                cache.setObject(image, forKey: cacheKey as NSString, cost: Self.estimatedCost(of: cgImage))
                return image
            } catch {
                return nil
            }
        }

        inFlight[cacheKey] = task
        let result = await task.value
        inFlight.removeValue(forKey: cacheKey)
        return result
    }

    /// width × height × 4 (RGBA) — drives `NSCache.totalCostLimit` so the cache
    /// stays bounded in MB, not just object count.
    private static func estimatedCost(of image: CGImage) -> Int {
        image.width * image.height * 4
    }

    func htmlSnapshotImage(
        for url: URL,
        cacheKey: String,
        targetSize: CGSize = CGSize(width: 480, height: 270),
        timeout: TimeInterval = 6
    ) async -> NSImage? {
        if let cached = cachedThumbnail(forKey: cacheKey) { return cached }
        if let inFlight = inFlight[cacheKey] { return await inFlight.value }

        let task = Task<NSImage?, Never> { @MainActor [weak self] in
            guard let self else { return nil }
            return await self.captureHTMLSnapshot(
                url: url,
                cacheKey: cacheKey,
                targetSize: targetSize,
                timeout: timeout
            )
        }

        inFlight[cacheKey] = task
        let result = await task.value
        inFlight.removeValue(forKey: cacheKey)
        return result
    }

    func invalidate(cacheKey: String) {
        cache.removeObject(forKey: cacheKey as NSString)
    }

    // MARK: - HTML snapshot internals

    private func captureHTMLSnapshot(
        url: URL,
        cacheKey: String,
        targetSize: CGSize,
        timeout: TimeInterval
    ) async -> NSImage? {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = false
        let webView = WKWebView(
            frame: CGRect(origin: .zero, size: targetSize),
            configuration: config
        )

        let pending = PendingHTMLSnapshot(webView: webView)
        pendingWebViews[cacheKey] = pending
        webView.navigationDelegate = pending

        let didStart = url.isFileURL ? url.startAccessingSecurityScopedResource() : false
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }

        let timeoutTask = Task<Void, Never> { [weak pending] in
            try? await Task.sleep(for: .seconds(timeout))
            pending?.complete(reason: .timeout)
        }

        let didLoad = await pending.waitForLoadOutcome()
        timeoutTask.cancel()

        if didLoad {
            try? await Task.sleep(for: .milliseconds(250))
        }

        let snapshotConfig = WKSnapshotConfiguration()
        snapshotConfig.rect = CGRect(origin: .zero, size: targetSize)
        snapshotConfig.afterScreenUpdates = true

        let image: NSImage? = await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: snapshotConfig) { image, _ in
                continuation.resume(returning: image)
            }
        }

        webView.stopLoading()
        pendingWebViews.removeValue(forKey: cacheKey)

        if let image, didLoad {
            cache.setObject(image, forKey: cacheKey as NSString, cost: Self.estimatedCost(of: image))
            return image
        }
        return nil
    }

    /// width × height × 4 (RGBA) — the WebKit snapshot path only exposes an `NSImage`.
    private static func estimatedCost(of image: NSImage) -> Int {
        let pixels = image.representations
            .compactMap { $0 as? NSBitmapImageRep }
            .map { $0.pixelsWide * $0.pixelsHigh }
            .max()
            ?? Int(image.size.width * image.size.height)
        return pixels * 4
    }
}

/// Bridges `WKWebView` `didFinish`/`didFail` callbacks to an async awaiter via a continuation.
@MainActor
private final class PendingHTMLSnapshot: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private var continuation: CheckedContinuation<Bool, Never>?
    private var finished = false

    enum CompletionReason {
        case success
        case failure
        case timeout
    }

    init(webView: WKWebView) {
        self.webView = webView
    }

    func waitForLoadOutcome() async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func complete(reason: CompletionReason) {
        guard !finished else { return }
        finished = true
        continuation?.resume(returning: reason == .success)
        continuation = nil
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak self] in self?.complete(reason: .success) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self] in self?.complete(reason: .failure) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self] in self?.complete(reason: .failure) }
    }
}
