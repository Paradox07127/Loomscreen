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
    nonisolated static let responseChunkSize = 64 * 1024

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

        let fileURL: URL
        do {
            fileURL = try Self.resolvedFileURL(for: url, inside: folderURL)
        } catch {
            urlSchemeTask.didFailWithError(error)
            return
        }

        do {
            let mime = Self.mimeType(for: fileURL)
            let fileSize = try Self.fileSize(for: fileURL)
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": mime,
                    "Content-Length": "\(fileSize)",
                    // Same-origin for everything served under this scheme.
                    "Access-Control-Allow-Origin": "*"
                ]
            ) ?? URLResponse(url: url, mimeType: mime, expectedContentLength: fileSize, textEncodingName: nil) as URLResponse
            urlSchemeTask.didReceive(response)
            try Self.sendFile(fileURL, to: urlSchemeTask)
            urlSchemeTask.didFinish()
        } catch {
            Logger.warning("FolderScheme: \(fileURL.lastPathComponent) — \(error.localizedDescription)", category: .screenManager)
            urlSchemeTask.didFailWithError(error)
        }
    }

    // MARK: - Helpers

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
            throw Self.error(.noPermissionsToReadFile, "Path escapes folder")
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
            throw Self.error(.cannotOpenFile, "Requested resource is not a regular file")
        }
        guard let fileSize = values.fileSize else {
            throw Self.error(.cannotOpenFile, "Missing file size")
        }
        return fileSize
    }

    nonisolated private static func sendFile(_ url: URL, to urlSchemeTask: any WKURLSchemeTask) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }

        while true {
            let chunk = try handle.read(upToCount: responseChunkSize) ?? Data()
            guard !chunk.isEmpty else { break }
            urlSchemeTask.didReceive(chunk)
        }
    }

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
