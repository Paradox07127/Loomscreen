#if !LITE_BUILD
import Foundation
@preconcurrency import WebKit
import UniformTypeIdentifiers

/// Serves per-scene assets over `wpe-asset://scene/<nonce>/<relative-path>`.
///
/// Phase 1 lays the URL contract + nonce gating; Phase 4 will plug in a
/// `WPEAssetProvider` backed by `WPETexDecoder` + `WPEMultiRootResourceResolver`.
/// Until then every request fails with 404 so the JS side can exercise its
/// error paths against a wired-but-empty handler.
protocol WPEAssetProvider: AnyObject, Sendable {
    /// Returns the bytes + MIME for `relativePath` inside the active scene's
    /// asset roots. `nil` => 404. Errors raised here are surfaced as 5xx.
    func data(for relativePath: String) async throws -> WPEAssetResponse?
}

struct WPEAssetResponse: Sendable {
    var bytes: Data
    var mimeType: String
    var cacheControl: String?
}

final class WPEAssetSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    nonisolated static let scheme = "wpe-asset"
    nonisolated static let host = "scene"

    private var activeTasks: [ObjectIdentifier: WPESchemeTaskDelivery] = [:]
    private var activeNonce: String?
    private weak var provider: (any WPEAssetProvider)?

    /// Updated whenever the renderer loads a new scene. Setting `nil`
    /// cancels in-flight requests so a stale URL retained by a previous
    /// scene cannot replay against the active session.
    func setActive(nonce: String?, provider: (any WPEAssetProvider)?) {
        if activeNonce != nonce {
            cancelAll()
        }
        activeNonce = nonce
        self.provider = provider
    }

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

        let parsed: ParsedAssetRequest
        do {
            parsed = try parseRequest(url: url)
        } catch {
            delivery.fail(with: error)
            activeTasks.removeValue(forKey: taskID)
            return
        }

        guard let provider else {
            delivery.fail(with: Self.makeError(
                .resourceUnavailable,
                "No active asset provider for scene \(parsed.nonce)"
            ))
            activeTasks.removeValue(forKey: taskID)
            return
        }

        let rangeHeader = urlSchemeTask.request.value(forHTTPHeaderField: "Range")

        Task.detached(priority: .userInitiated) { [weak self, delivery, parsed, provider, url, taskID, rangeHeader] in
            do {
                guard let response = try await provider.data(for: parsed.relativePath) else {
                    await delivery.fail(with: Self.makeError(
                        .fileDoesNotExist,
                        "Missing asset: \(parsed.relativePath)"
                    ))
                    _ = await MainActor.run { self?.activeTasks.removeValue(forKey: taskID) }
                    return
                }
                let totalLength = response.bytes.count
                let range = Self.byteRange(from: rangeHeader, totalLength: totalLength)
                let statusCode = range == nil ? 200 : 206
                let contentLength = range?.length ?? totalLength

                var headers = [
                    "Content-Type": response.mimeType,
                    "Content-Length": "\(contentLength)",
                    "Accept-Ranges": "bytes",
                    // `<video>` elements use `crossOrigin = "anonymous"` so
                    // their decoded frames are non-tainted and uploadable to
                    // WebGL. Without this header the texImage2D upload fails.
                    "Access-Control-Allow-Origin": "*"
                ]
                if let cacheControl = response.cacheControl {
                    headers["Cache-Control"] = cacheControl
                }
                if let range {
                    headers["Content-Range"] = "bytes \(range.start)-\(range.end)/\(totalLength)"
                }
                let httpResponse = HTTPURLResponse(
                    url: url,
                    statusCode: statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: headers
                ) ?? URLResponse(
                    url: url,
                    mimeType: response.mimeType,
                    expectedContentLength: contentLength,
                    textEncodingName: nil
                )
                await delivery.deliver(response: httpResponse)
                if let range {
                    await delivery.deliver(chunk: response.bytes.subdata(in: range.start..<(range.end + 1)))
                } else {
                    await delivery.deliver(chunk: response.bytes)
                }
                await delivery.finish()
            } catch {
                await delivery.fail(with: error)
            }
            _ = await MainActor.run { self?.activeTasks.removeValue(forKey: taskID) }
        }
    }

    private struct ByteRange: Sendable {
        let start: Int
        let end: Int
        var length: Int { end - start + 1 }
    }

    // Mirrors FolderURLSchemeHandler.byteRange. Supports `bytes=N-M`,
    // `bytes=N-` (open-ended), `bytes=-N` (suffix). Single range only.
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
            return ByteRange(start: totalLength - length, end: totalLength - 1)
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

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        let taskID = ObjectIdentifier(urlSchemeTask as AnyObject)
        activeTasks.removeValue(forKey: taskID)?.markStopped()
    }

    private func cancelAll() {
        let snapshot = activeTasks
        activeTasks.removeAll()
        for entry in snapshot.values {
            entry.markStopped()
        }
    }

    // MARK: - Parsing

    private struct ParsedAssetRequest: Sendable {
        let nonce: String
        let relativePath: String
    }

    private func parseRequest(url: URL) throws -> ParsedAssetRequest {
        guard url.host?.lowercased() == Self.host else {
            throw Self.makeError(.badURL, "Host mismatch")
        }
        guard let activeNonce, !activeNonce.isEmpty else {
            throw Self.makeError(.notConnectedToInternet, "No active scene session")
        }
        let rawPath = url.path.removingPercentEncoding ?? url.path
        let trimmed = rawPath.hasPrefix("/") ? String(rawPath.dropFirst()) : rawPath
        let parts = trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else {
            throw Self.makeError(.badURL, "URL must be wpe-asset://scene/<nonce>/<path>")
        }
        let nonce = String(parts[0])
        guard nonce == activeNonce else {
            throw Self.makeError(.badURL, "Stale or invalid scene nonce")
        }
        let relativePath = String(parts[1])
        let pathParts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.hasPrefix("\\"),
              !relativePath.contains("\0"),
              !relativePath.contains("\\"),
              !pathParts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw Self.makeError(.noPermissionsToReadFile, "Path escape attempt")
        }
        return ParsedAssetRequest(nonce: nonce, relativePath: relativePath)
    }

    nonisolated static func makeError(_ code: URLError.Code, _ message: String? = nil) -> NSError {
        var info: [String: Any] = [:]
        if let message { info[NSLocalizedDescriptionKey] = message }
        return NSError(domain: NSURLErrorDomain, code: code.rawValue, userInfo: info)
    }
}
#endif
