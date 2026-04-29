import Foundation
import WebKit
import UniformTypeIdentifiers

/// Serves files from a security-scoped folder under a custom `livewallpaper://`
/// scheme so WKWebView treats them as same-origin web content. file:// loads
/// of Vite/webpack ES-module bundles fail because `<script type="module">`
/// + `crossorigin` triggers CORS rejection that file:// cannot satisfy; this
/// handler avoids the issue entirely.
/// `@unchecked Sendable` because WebKit invokes the protocol methods on the
/// main thread (documented behaviour) and `folderURL` is only ever read /
/// written from the main thread by `HTMLWallpaperView`.
final class FolderURLSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    static let scheme = "livewallpaper"
    static let host = "wallpaper"

    /// Updated each time `HTMLWallpaperView.loadSource(.folder)` swaps content.
    var folderURL: URL?

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        handle(urlSchemeTask)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        // Reads are synchronous; nothing to cancel.
    }

    private func handle(_ urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(Self.error(.badURL))
            return
        }
        guard let folderURL else {
            urlSchemeTask.didFailWithError(Self.error(.notConnectedToInternet, "No active folder"))
            return
        }

        // Strip leading "/" then resolve relative to the folder.
        let path = url.path.removingPercentEncoding ?? url.path
        let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let fileURL = folderURL.appendingPathComponent(relative)

        guard fileURL.path.hasPrefix(folderURL.path) else {
            // Reject path traversal (`/../foo`).
            urlSchemeTask.didFailWithError(Self.error(.noPermissionsToReadFile, "Path escapes folder"))
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let mime = Self.mimeType(for: fileURL)
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": mime,
                    "Content-Length": "\(data.count)",
                    // Same-origin for everything served under this scheme.
                    "Access-Control-Allow-Origin": "*"
                ]
            ) ?? URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil) as URLResponse
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            Logger.warning("FolderScheme: \(fileURL.lastPathComponent) — \(error.localizedDescription)", category: .screenManager)
            urlSchemeTask.didFailWithError(error)
        }
    }

    // MARK: - Helpers

    nonisolated private static func mimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if let utType = UTType(filenameExtension: ext), let mime = utType.preferredMIMEType {
            return mime
        }
        // Fallbacks for things UTType sometimes misses.
        switch ext {
        case "js", "mjs": return "application/javascript"
        case "wasm":      return "application/wasm"
        case "json":      return "application/json"
        case "atlas":     return "text/plain"
        case "skel":      return "application/octet-stream"
        default:          return "application/octet-stream"
        }
    }

    nonisolated private static func error(_ code: URLError.Code, _ message: String? = nil) -> NSError {
        var info: [String: Any] = [:]
        if let message { info[NSLocalizedDescriptionKey] = message }
        return NSError(domain: NSURLErrorDomain, code: code.rawValue, userInfo: info)
    }
}
