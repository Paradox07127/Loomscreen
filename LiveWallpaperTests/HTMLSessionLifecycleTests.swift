import Testing
import Foundation
import WebKit
@testable import LiveWallpaper

/// Validates the FolderURLSchemeHandler runtime contract: byte-range responses,
/// stop-after-start cancellation, and folder-swap teardown. Complements the
/// existing isolation/nonce tests by exercising the response side of the loop
/// instead of just the validation side.
@Suite("FolderURLSchemeHandler session lifecycle")
@MainActor
struct FolderURLSchemeHandlerLifecycleTests {

    @Test("Range request returns 206 with Content-Range header and trimmed payload")
    func rangeRequestReturns206() async throws {
        let folder = makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let payload = Data((0..<2048).map { UInt8($0 % 256) })
        let asset = folder.appendingPathComponent("blob.bin")
        try payload.write(to: asset)

        let handler = FolderURLSchemeHandler()
        handler.folderURL = folder

        let request = subresourceRequest(
            url: "livewallpaper://wallpaper/blob.bin",
            mainDocument: "livewallpaper://wallpaper/index.html?n=\(handler.currentSessionNonce ?? "")",
            range: "bytes=0-99"
        )
        let task = FakeURLSchemeTask(request: request)

        handler.webView(WKWebView(), start: task)
        try await waitUntilTaskCompletes(task)

        let response = try #require(task.receivedResponse as? HTTPURLResponse)
        #expect(response.statusCode == 206)
        #expect(response.value(forHTTPHeaderField: "Content-Range") == "bytes 0-99/2048")
        #expect(response.value(forHTTPHeaderField: "Accept-Ranges") == "bytes")
        #expect(task.totalReceivedBytes == 100)
    }

    @Test("Suffix range bytes=-N returns the trailing N bytes")
    func suffixRangeReturnsTrailingBytes() async throws {
        let folder = makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let payload = Data((0..<512).map { UInt8($0 % 256) })
        let asset = folder.appendingPathComponent("trail.bin")
        try payload.write(to: asset)

        let handler = FolderURLSchemeHandler()
        handler.folderURL = folder

        let request = subresourceRequest(
            url: "livewallpaper://wallpaper/trail.bin",
            mainDocument: "livewallpaper://wallpaper/index.html?n=\(handler.currentSessionNonce ?? "")",
            range: "bytes=-64"
        )
        let task = FakeURLSchemeTask(request: request)

        handler.webView(WKWebView(), start: task)
        try await waitUntilTaskCompletes(task)

        let response = try #require(task.receivedResponse as? HTTPURLResponse)
        #expect(response.statusCode == 206)
        #expect(response.value(forHTTPHeaderField: "Content-Range") == "bytes 448-511/512")
        #expect(task.totalReceivedBytes == 64)
    }

    @Test("Plain GET without Range returns 200 + full payload")
    func plainRequestReturns200WithFullPayload() async throws {
        let folder = makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let payload = Data("hello world".utf8)
        let asset = folder.appendingPathComponent("hello.txt")
        try payload.write(to: asset)

        let handler = FolderURLSchemeHandler()
        handler.folderURL = folder

        let request = subresourceRequest(
            url: "livewallpaper://wallpaper/hello.txt",
            mainDocument: "livewallpaper://wallpaper/index.html?n=\(handler.currentSessionNonce ?? "")"
        )
        let task = FakeURLSchemeTask(request: request)

        handler.webView(WKWebView(), start: task)
        try await waitUntilTaskCompletes(task)

        let response = try #require(task.receivedResponse as? HTTPURLResponse)
        #expect(response.statusCode == 200)
        #expect(response.value(forHTTPHeaderField: "Content-Range") == nil)
        #expect(task.totalReceivedBytes == payload.count)
    }

    @Test("Stop after start prevents finish from firing")
    func stopAfterStartCancelsDelivery() async throws {
        let folder = makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let payload = Data(repeating: 0xAB, count: 1 * 1024 * 1024)
        let asset = folder.appendingPathComponent("large.bin")
        try payload.write(to: asset)

        let handler = FolderURLSchemeHandler()
        handler.folderURL = folder

        let request = subresourceRequest(
            url: "livewallpaper://wallpaper/large.bin",
            mainDocument: "livewallpaper://wallpaper/index.html?n=\(handler.currentSessionNonce ?? "")"
        )
        let task = FakeURLSchemeTask(request: request)

        handler.webView(WKWebView(), start: task)
        handler.webView(WKWebView(), stop: task)

        try await Task.sleep(for: .milliseconds(50))
        #expect(!task.didFinishCalled)
    }

    @Test("Reassigning folderURL cancels in-flight workers from the previous folder")
    func reassigningFolderCancelsInFlightWorkers() async throws {
        let firstFolder = makeTemporaryFolder()
        let secondFolder = makeTemporaryFolder()
        defer {
            try? FileManager.default.removeItem(at: firstFolder)
            try? FileManager.default.removeItem(at: secondFolder)
        }

        let payload = Data(repeating: 0x55, count: 512 * 1024)
        try payload.write(to: firstFolder.appendingPathComponent("big.bin"))

        let handler = FolderURLSchemeHandler()
        handler.folderURL = firstFolder
        let firstNonce = handler.currentSessionNonce ?? ""

        let request = subresourceRequest(
            url: "livewallpaper://wallpaper/big.bin",
            mainDocument: "livewallpaper://wallpaper/index.html?n=\(firstNonce)"
        )
        let task = FakeURLSchemeTask(request: request)

        handler.webView(WKWebView(), start: task)
        handler.folderURL = secondFolder

        try await Task.sleep(for: .milliseconds(50))
        #expect(!task.didFinishCalled)
        #expect(handler.currentSessionNonce != firstNonce)
    }

    @Test("Path traversal escapes the folder root and fails")
    func pathTraversalIsRejected() async throws {
        let folder = makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("ok".utf8).write(to: folder.appendingPathComponent("ok.txt"))

        let handler = FolderURLSchemeHandler()
        handler.folderURL = folder

        let request = subresourceRequest(
            url: "livewallpaper://wallpaper/../../../etc/passwd",
            mainDocument: "livewallpaper://wallpaper/index.html?n=\(handler.currentSessionNonce ?? "")"
        )
        let task = FakeURLSchemeTask(request: request)

        handler.webView(WKWebView(), start: task)
        try await waitUntilTaskFails(task)

        #expect(task.failedError != nil)
        #expect(task.didFinishCalled == false)
    }

    // MARK: - Helpers

    private func makeTemporaryFolder() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LWLifecycle-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func subresourceRequest(
        url: String,
        mainDocument: String,
        range: String? = nil
    ) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.mainDocumentURL = URL(string: mainDocument)
        if let range {
            request.setValue(range, forHTTPHeaderField: "Range")
        }
        return request
    }

    private func waitUntilTaskCompletes(
        _ task: FakeURLSchemeTask,
        timeout: Duration = .seconds(2)
    ) async throws {
        try await waitUntil(timeout: timeout) {
            task.didFinishCalled || task.failedError != nil
        }
        if task.failedError != nil {
            Issue.record("Expected success but task failed: \(task.failedError!)")
        }
    }

    private func waitUntilTaskFails(
        _ task: FakeURLSchemeTask,
        timeout: Duration = .seconds(2)
    ) async throws {
        try await waitUntil(timeout: timeout) {
            task.failedError != nil
        }
    }

    private func waitUntil(
        timeout: Duration,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@Suite("HTML wallpaper runtime scripts")
struct HTMLWallpaperRuntimeScriptTests {
    @Test("Physical-pixel script can hot-patch loaded pages")
    func physicalPixelScriptHotPatchesLoadedPages() {
        let script = HTMLWallpaperRuntimeScript.physicalPixelState(enabled: true, backingScale: 2)

        #expect(script.contains("__liveWallpaperPhysicalPixelLayout"))
        #expect(script.contains("get: function () { return 1; }"))
        #expect(script.contains("dispatchEvent(new Event('resize'))"))
    }

    @Test("Wallpaper Engine general properties script sends fps")
    func wallpaperEngineGeneralPropertiesScriptSendsFPS() {
        let script = HTMLWallpaperRuntimeScript.wallpaperEngineGeneralProperties(fps: 1)

        #expect(script.contains("applyGeneralProperties"))
        #expect(script.contains("\"fps\":1"))
    }
}

@Suite("HTML wallpaper compatibility policy")
struct HTMLWallpaperCompatibilityPolicyTests {
    @Test("Wallpaper Engine folders keep physical-pixel layout during hot config updates")
    func wallpaperEngineFolderKeepsPhysicalPixelLayout() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LWCompatibility-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        try Data("<html></html>".utf8).write(to: folder.appendingPathComponent("index.html"))
        try Data("{}".utf8).write(to: folder.appendingPathComponent("project.json"))
        let bookmark = try folder.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        var updated = HTMLConfig.default
        updated.customCSS = "html { background: black; }"

        let result = HTMLWallpaperCompatibilityPolicy.runtimeConfig(
            source: .folder(bookmarkData: bookmark, indexFileName: "index.html"),
            config: updated,
            trustedOrigins: Set<TrustedHTMLOrigin>()
        )

        #expect(result.config.physicalPixelLayout)
        #expect(result.enabledPhysicalPixelLayout)
        #expect(result.config.customCSS == updated.customCSS)
    }
}

/// Local fake — duplicating the type from `HTMLSchemeIsolationTests` keeps each
/// suite self-contained and avoids cross-file coupling between unrelated tests.
private final class FakeURLSchemeTask: NSObject, WKURLSchemeTask, @unchecked Sendable {
    let request: URLRequest
    private let lock = NSLock()
    private var _receivedResponse: URLResponse?
    private var _receivedData: [Data] = []
    private var _didFinishCalled = false
    private var _failedError: Error?

    init(request: URLRequest) {
        self.request = request
    }

    var receivedResponse: URLResponse? {
        lock.lock(); defer { lock.unlock() }
        return _receivedResponse
    }

    var totalReceivedBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return _receivedData.reduce(0) { $0 + $1.count }
    }

    var didFinishCalled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _didFinishCalled
    }

    var failedError: Error? {
        lock.lock(); defer { lock.unlock() }
        return _failedError
    }

    func didReceive(_ response: URLResponse) {
        lock.lock(); defer { lock.unlock() }
        _receivedResponse = response
    }

    func didReceive(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        _receivedData.append(data)
    }

    func didFinish() {
        lock.lock(); defer { lock.unlock() }
        _didFinishCalled = true
    }

    func didFailWithError(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        _failedError = error
    }
}
