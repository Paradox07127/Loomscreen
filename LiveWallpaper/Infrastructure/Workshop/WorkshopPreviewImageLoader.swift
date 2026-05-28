#if !LITE_BUILD && DIRECT_DISTRIBUTION
import AppKit
import Foundation

/// Fetches Workshop preview images under the same allow-list invariants the
/// metadata service applies to the canonical URL. The shipping
/// `SwiftUI.AsyncImage` cannot satisfy the plan's CDN policy because it
/// follows 3xx redirects without re-running the host allow-list, has no
/// `image/*` content-type check, has no byte cap, and reuses the system
/// cookie store.
///
/// Cache lives in-memory for the app's lifetime; URLs are immutable Steam
/// CDN assets so a small cap is enough. Disk caching is intentionally out of
/// scope for v1.
@MainActor
final class WorkshopPreviewImageLoader {

    static let shared = WorkshopPreviewImageLoader()

    /// Plan-specified cap (Phase 1 / Phase 5 "Cap downloaded preview byte
    /// size at 8 MiB; cancel and discard if exceeded").
    static let maxBytes = 8 * 1024 * 1024

    private var cache: [URL: NSImage] = [:]
    private var inflight: [URL: Task<NSImage?, Never>] = [:]
    private let session: URLSession
    private let delegate: RedirectGuardDelegate

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        let delegate = RedirectGuardDelegate()
        self.delegate = delegate
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    /// Returns the cached image, or kicks off (and awaits) a fetch.
    /// Returns `nil` if any allow-list / content-type / size check fails —
    /// callers fall back to a placeholder.
    func load(_ url: URL) async -> NSImage? {
        if let cached = cache[url] { return cached }
        if let task = inflight[url] { return await task.value }
        let task = Task { @MainActor [weak self] in
            await self?.performLoad(url)
        }
        inflight[url] = task
        let result = await task.value
        inflight.removeValue(forKey: url)
        if let result {
            cache[url] = result
        }
        return result
    }

    private func performLoad(_ url: URL) async -> NSImage? {
        // Initial URL is filtered by `SteamWorkshopMetadataService` before
        // we ever see it — re-run anyway as a defense in depth.
        if case .rejected = WorkshopCDNHostAllowList.evaluate(url.absoluteString) {
            return nil
        }
        var request = URLRequest(url: url)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return nil
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return nil
        }
        if let mime = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
           !mime.hasPrefix("image/") {
            return nil
        }
        guard data.count <= Self.maxBytes else {
            return nil
        }
        return NSImage(data: data)
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
