#if !LITE_BUILD
import Foundation
@preconcurrency import WebKit
import UniformTypeIdentifiers

/// Serves the embedded `wpe-webgl-runtime.bundle/` over `wpe-runtime://host/...`
/// so the JS runtime is loaded as same-origin web content (subresources
/// inherit the document origin and pass CORS), and a CSP can pin
/// `script-src 'self'` to this scheme alone.
final class WPERuntimeSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    nonisolated static let scheme = "wpe-runtime"
    nonisolated static let host = "host"
    nonisolated static let indexPath = "index.html"

    private static let bundleRoot: URL? = Bundle.main.url(
        forResource: "wpe-webgl-runtime",
        withExtension: "bundle"
    )

    private var activeTasks: [ObjectIdentifier: WPESchemeTaskDelivery] = [:]

    var hasBundle: Bool { Self.bundleRoot != nil }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let delivery = WPESchemeTaskDelivery(urlSchemeTask)
        let taskID = ObjectIdentifier(urlSchemeTask as AnyObject)
        activeTasks[taskID] = delivery

        guard (urlSchemeTask.request.httpMethod ?? "GET").uppercased() == "GET" else {
            delivery.fail(with: Self.makeError(.badURL, "Only GET is supported"))
            activeTasks.removeValue(forKey: taskID)
            return
        }

        guard let url = urlSchemeTask.request.url else {
            delivery.fail(with: Self.makeError(.badURL))
            activeTasks.removeValue(forKey: taskID)
            return
        }

        guard url.host?.lowercased() == Self.host else {
            delivery.fail(with: Self.makeError(.badURL, "Host mismatch"))
            activeTasks.removeValue(forKey: taskID)
            return
        }

        guard let bundleRoot = Self.bundleRoot else {
            delivery.fail(with: Self.makeError(
                .resourceUnavailable,
                "wpe-webgl-runtime.bundle is missing from the app bundle"
            ))
            activeTasks.removeValue(forKey: taskID)
            return
        }

        let fileURL: URL
        do {
            fileURL = try Self.resolvedFileURL(for: url, inside: bundleRoot)
        } catch {
            delivery.fail(with: error)
            activeTasks.removeValue(forKey: taskID)
            return
        }

        Task.detached(priority: .userInitiated) { [weak self, delivery, fileURL, url, taskID] in
            do {
                let data = try Data(contentsOf: fileURL)
                let mime = Self.mimeType(for: fileURL)
                let headers = [
                    "Content-Type": mime,
                    "Content-Length": "\(data.count)",
                    "Access-Control-Allow-Origin": "*"
                ]
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: headers
                ) ?? URLResponse(
                    url: url,
                    mimeType: mime,
                    expectedContentLength: data.count,
                    textEncodingName: nil
                )
                await delivery.deliver(response: response)
                await delivery.deliver(chunk: data)
                await delivery.finish()
            } catch {
                await delivery.fail(with: error)
            }
            _ = await MainActor.run { self?.activeTasks.removeValue(forKey: taskID) }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        let taskID = ObjectIdentifier(urlSchemeTask as AnyObject)
        activeTasks.removeValue(forKey: taskID)?.markStopped()
    }

    nonisolated static func resolvedFileURL(for requestURL: URL, inside root: URL) throws -> URL {
        let rootURL = root.standardizedFileURL.resolvingSymlinksInPath()
        let rawPath = requestURL.path.removingPercentEncoding ?? requestURL.path
        let trimmed = rawPath.hasPrefix("/") ? String(rawPath.dropFirst()) : rawPath
        let relativePath = trimmed.isEmpty ? Self.indexPath : trimmed
        let candidate = rootURL
            .appendingPathComponent(relativePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let rootPath = normalizedPath(rootURL.path(percentEncoded: false))
        let candidatePath = normalizedPath(candidate.path(percentEncoded: false))
        guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else {
            throw makeError(.noPermissionsToReadFile, "Path escapes runtime bundle")
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

    nonisolated private static func mimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if let utType = UTType(filenameExtension: ext), let mime = utType.preferredMIMEType {
            return mime
        }
        switch ext {
        case "js", "mjs":  return "application/javascript"
        case "wasm":       return "application/wasm"
        case "json":       return "application/json"
        case "map":        return "application/json"
        case "html", "htm": return "text/html"
        case "css":        return "text/css"
        default:           return "application/octet-stream"
        }
    }

    nonisolated static func makeError(_ code: URLError.Code, _ message: String? = nil) -> NSError {
        var info: [String: Any] = [:]
        if let message { info[NSLocalizedDescriptionKey] = message }
        return NSError(domain: NSURLErrorDomain, code: code.rawValue, userInfo: info)
    }
}

/// Bridges the detached worker back to the main-thread `WKURLSchemeTask`.
/// Once `markStopped()` is called every subsequent delivery is dropped.
final class WPESchemeTaskDelivery: @unchecked Sendable {
    private let task: any WKURLSchemeTask
    @MainActor private var isLive: Bool = true

    init(_ task: any WKURLSchemeTask) {
        self.task = task
    }

    @MainActor var hasTerminated: Bool { !isLive }

    @MainActor func markStopped() {
        isLive = false
    }

    @MainActor func deliver(response: URLResponse) {
        guard isLive else { return }
        task.didReceive(response)
    }

    @MainActor func deliver(chunk data: Data) {
        guard isLive else { return }
        task.didReceive(data)
    }

    @MainActor func finish() {
        guard isLive else { return }
        isLive = false
        task.didFinish()
    }

    @MainActor func fail(with error: any Error) {
        guard isLive else { return }
        isLive = false
        task.didFailWithError(error)
    }
}
#endif
