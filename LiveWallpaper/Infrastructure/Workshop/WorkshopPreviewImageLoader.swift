#if !LITE_BUILD && DIRECT_DISTRIBUTION
import AppKit
import Foundation

/// Fetches Workshop preview images under the CDN allow-list invariants. Unlike
/// `SwiftUI.AsyncImage`, it re-runs the host allow-list on every redirect,
/// requires an `image/*` content type, caps the transfer, and uses an ephemeral
/// cookieless session. Cache lives for the app's lifetime (CDN assets immutable).
@MainActor
final class WorkshopPreviewImageLoader {

    static let shared = WorkshopPreviewImageLoader()

    // Kept in sync with `WorkshopAnimatedGIF.maxBytes`. Workshop animated GIF
    // previews routinely exceed 8 MiB; an 8 MiB transfer cap aborted them
    // mid-stream and the card fell back to a blank placeholder.
    nonisolated static let maxBytes = 32 * 1024 * 1024

    private var cache: [URL: NSImage] = [:]
    private var assetCache: [URL: WorkshopPreviewAsset] = [:]
    private var assetInflight: [URL: Task<WorkshopPreviewAsset?, Never>] = [:]
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        // `URLSession` retains its delegate, so no stored reference is needed.
        self.session = URLSession(configuration: config, delegate: RedirectGuardDelegate(), delegateQueue: nil)
    }

    /// Returns `nil` if any allow-list / content-type / size check fails —
    /// callers fall back to a placeholder.
    func load(_ url: URL) async -> NSImage? {
        if let cached = cache[url] { return cached }
        // Route through `loadAsset` so the poster goes through the same byte /
        // frame-count / decoded-pixel caps (paste-flow thumbnails included).
        guard let asset = await loadAsset(url) else { return nil }
        let image = Self.nsImage(from: asset.posterFrame)
        cache[url] = image
        return image
    }

    /// Like `load`, but returns a decoded asset distinguishing a still image
    /// from a bounded animation so callers can drive frame-stepped
    /// (hover-to-play) playback.
    func loadAsset(_ url: URL) async -> WorkshopPreviewAsset? {
        if let cached = assetCache[url] { return cached }
        if let task = assetInflight[url] { return await task.value }
        let task = Task { @MainActor [weak self] in
            await self?.performAssetLoad(url)
        }
        assetInflight[url] = task
        let result = await task.value
        assetInflight.removeValue(forKey: url)
        if let result {
            assetCache[url] = result
        }
        return result
    }

    private static func nsImage(from image: CGImage) -> NSImage {
        NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    private func performAssetLoad(_ url: URL) async -> WorkshopPreviewAsset? {
        let session = session
        guard let data = await Self.fetchData(url, session: session) else { return nil }
        // Decode off the main actor — the CGImageSource work is CPU-bound.
        return await Task.detached(priority: .userInitiated) {
            WorkshopAnimatedGIF.make(from: data)
        }.value
    }

    /// Streams the body so an oversized response is aborted mid-flight rather
    /// than buffered whole. Re-runs the allow-list (defense in depth) and
    /// requires a 200 + `image/*` content type.
    private nonisolated static func fetchData(_ url: URL, session: URLSession) async -> Data? {
        guard case .allowed(let canonicalURL) = WorkshopCDNHostAllowList.evaluate(url.absoluteString) else {
            return nil
        }
        var request = URLRequest(url: canonicalURL)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            return nil
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let mime = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
              mime.hasPrefix("image/"),
              http.expectedContentLength <= Int64(maxBytes) else {
            return nil
        }

        var data = Data()
        if http.expectedContentLength > 0 {
            data.reserveCapacity(Int(http.expectedContentLength))
        }
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxBytes { return nil }
            }
        } catch {
            return nil
        }
        return data
    }
}

/// `URLSessionTaskDelegate` that re-runs `WorkshopCDNHostAllowList` against
/// every redirect target before letting `URLSession` follow. Anything that
/// fails the allow-list cancels the request.
private final class RedirectGuardDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url else {
            completionHandler(nil)
            return
        }
        switch WorkshopCDNHostAllowList.evaluate(url.absoluteString) {
        case .allowed:
            completionHandler(request)
        case .rejected:
            completionHandler(nil)
        }
    }
}
#endif
