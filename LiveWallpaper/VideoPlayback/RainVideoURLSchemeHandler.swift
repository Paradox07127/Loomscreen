import Foundation
@preconcurrency import WebKit
import UniformTypeIdentifiers

/// Serves the current video through a WKWebView custom scheme so the generated
/// WebGL rain page can sample it as a CORS-approved `<video>` texture.
final class RainVideoURLSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    static let scheme = "livewallpaper-rain-video"
    static let host = "current"
    static let currentVideoURL = URL(string: "\(scheme)://\(host)/video")!
    nonisolated static let responseChunkSize = 128 * 1024

    private var activeVideoURL: URL?
    private var activeTasks: [ObjectIdentifier: RainVideoActiveTask] = [:]

    var videoURL: URL? {
        get { activeVideoURL }
        set {
            if activeVideoURL != newValue {
                cancelAllActiveTasks()
            }
            activeVideoURL = newValue
        }
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
              requestURL.host?.lowercased() == Self.host,
              requestURL.path == "/video" else {
            urlSchemeTask.didFailWithError(Self.makeError(.badURL, "Invalid rain video URL"))
            return
        }

        guard let fileURL = activeVideoURL else {
            urlSchemeTask.didFailWithError(Self.makeError(.notConnectedToInternet, "No active video"))
            return
        }

        let mime = Self.mimeType(for: fileURL)
        let rangeHeader = urlSchemeTask.request.value(forHTTPHeaderField: "Range")
        let delivery = RainVideoSchemeDelivery(urlSchemeTask)
        let taskID = ObjectIdentifier(urlSchemeTask as AnyObject)

        activeTasks[taskID]?.cancel()

        let worker = Task.detached(priority: .userInitiated) { [weak self, fileURL, mime, rangeHeader, requestURL, delivery, taskID] in
            do {
                let fileSize = try Self.fileSize(for: fileURL)
                let range = Self.byteRange(from: rangeHeader, totalLength: fileSize)
                let statusCode = range == nil ? 200 : 206
                let contentLength = range?.length ?? fileSize

                var headers = [
                    "Content-Type": mime,
                    "Content-Length": "\(contentLength)",
                    "Accept-Ranges": "bytes",
                    "Access-Control-Allow-Origin": "*",
                    "Access-Control-Allow-Methods": "GET, HEAD, OPTIONS",
                    "Access-Control-Allow-Headers": "Range"
                ]
                if let range {
                    headers["Content-Range"] = "bytes \(range.start)-\(range.end)/\(fileSize)"
                }

                let response = HTTPURLResponse(
                    url: requestURL,
                    statusCode: statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: headers
                ) ?? URLResponse(
                    url: requestURL,
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
                Logger.warning("RainVideoScheme: \(fileURL.lastPathComponent) - \(error.localizedDescription)", category: .screenManager)
                await delivery.fail(with: error)
            }

            _ = await MainActor.run {
                self?.activeTasks.removeValue(forKey: taskID)
            }
        }

        activeTasks[taskID] = RainVideoActiveTask(worker: worker, delivery: delivery)
        if delivery.hasTerminated {
            activeTasks.removeValue(forKey: taskID)
        }
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

    private struct ByteRange: Sendable {
        let start: Int
        let end: Int
        var length: Int { end - start + 1 }
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
        to delivery: RainVideoSchemeDelivery,
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

    nonisolated private static func mimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if let utType = UTType(filenameExtension: ext), let mime = utType.preferredMIMEType {
            return mime
        }
        switch ext {
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "webm": return "video/webm"
        case "mkv": return "video/x-matroska"
        default: return "application/octet-stream"
        }
    }

    nonisolated static func makeError(_ code: URLError.Code, _ message: String? = nil) -> NSError {
        var info: [String: Any] = [:]
        if let message { info[NSLocalizedDescriptionKey] = message }
        return NSError(domain: NSURLErrorDomain, code: code.rawValue, userInfo: info)
    }
}

private struct RainVideoActiveTask {
    let worker: Task<Void, Never>
    let delivery: RainVideoSchemeDelivery

    @MainActor
    func cancel() {
        delivery.markStopped()
        worker.cancel()
    }
}

private final class RainVideoSchemeDelivery: @unchecked Sendable {
    private let task: any WKURLSchemeTask
    @MainActor private var isLive = true

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
    func deliver(chunk: Data) {
        guard isLive else { return }
        task.didReceive(chunk)
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
