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

    private var activeFolderURL: URL?
    private var sessionNonce: String?
    private var activeTasks: [ObjectIdentifier: ActiveTask] = [:]
    /// Filenames already reported as missing for the current folder session.
    /// Wallpaper Engine projects routinely reference voiceline / sprite
    /// resources that were never packaged (the author shipped placeholders),
    /// and the HTML side retries them on every loop tick. Logging each retry
    /// at warning level spams the console; we log once and stay quiet after.
    private var reportedMissingResources: Set<String> = []

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
            }
            activeFolderURL = newValue
            sessionNonce = newValue == nil ? nil : UUID().uuidString
        }
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

        guard let folderURL = activeFolderURL else {
            urlSchemeTask.didFailWithError(Self.makeError(.notConnectedToInternet, "No active folder"))
            return
        }

        let fileURL: URL
        do {
            fileURL = try Self.resolvedFileURL(for: url, inside: folderURL)
        } catch {
            urlSchemeTask.didFailWithError(error)
            return
        }

        let mime = Self.mimeType(for: fileURL)
        let rangeHeader = urlSchemeTask.request.value(forHTTPHeaderField: "Range")
        let delivery = SchemeTaskDelivery(urlSchemeTask)
        let taskID = ObjectIdentifier(urlSchemeTask as AnyObject)

        activeTasks[taskID]?.cancel()

        let worker = Task.detached(priority: .userInitiated) { [weak self, fileURL, mime, rangeHeader, url, delivery, taskID] in
            do {
                let fileSize = try Self.fileSize(for: fileURL)
                let range = Self.byteRange(from: rangeHeader, totalLength: fileSize)
                let statusCode = range == nil ? 200 : 206
                let contentLength = range?.length ?? fileSize

                var headers = [
                    "Content-Type": mime,
                    "Content-Length": "\(contentLength)",
                    "Accept-Ranges": "bytes",
                    "Access-Control-Allow-Origin": "*"
                ]
                if let range {
                    headers["Content-Range"] = "bytes \(range.start)-\(range.end)/\(fileSize)"
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
                try await Self.streamFile(
                    fileURL,
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
                if isMissingFile {
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        if self.reportedMissingResources.insert(fileURL.lastPathComponent).inserted {
                            Logger.info("FolderScheme: \(fileURL.lastPathComponent) not found in project (HTML 404 — wallpaper content issue, not app)", category: .screenManager)
                        }
                    }
                } else {
                    Logger.warning("FolderScheme: \(fileURL.lastPathComponent) — \(error.localizedDescription)", category: .screenManager)
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

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        let taskID = ObjectIdentifier(urlSchemeTask as AnyObject)
        guard let entry = activeTasks.removeValue(forKey: taskID) else { return }
        entry.cancel()
    }

    /// Cancels every in-flight scheme worker.
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
        let ext = url.pathExtension.lowercased()
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

    nonisolated static func makeError(_ code: URLError.Code, _ message: String? = nil) -> NSError {
        var info: [String: Any] = [:]
        if let message { info[NSLocalizedDescriptionKey] = message }
        return NSError(domain: NSURLErrorDomain, code: code.rawValue, userInfo: info)
    }
}

// MARK: - Internal Types

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
