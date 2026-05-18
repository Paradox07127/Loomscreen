import Testing
import Foundation
import WebKit
@testable import LiveWallpaper

/// Verifies the C1 (HTML local-file isolation) and H2 (async/range scheme
/// handler) hardening from Week 1 of the product-pivot plan.
@Suite("FolderURLSchemeHandler isolation regressions")
@MainActor
struct FolderURLSchemeHandlerIsolationTests {

    @Test("Clearing folderURL also rotates the session nonce")
    func clearingFolderURLDropsNonce() {
        let handler = FolderURLSchemeHandler()
        let folder = makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        handler.folderURL = folder
        let firstNonce = handler.currentSessionNonce
        #expect(firstNonce != nil)

        handler.folderURL = nil
        #expect(handler.currentSessionNonce == nil)

        handler.folderURL = folder
        #expect(handler.currentSessionNonce != firstNonce)
    }

    @Test("Top-level requests are rejected once the folder is cleared")
    func staleTopLevelRequestRejected() {
        let handler = FolderURLSchemeHandler()
        let folder = makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        try? "<!doctype html><title>x</title>".write(
            to: folder.appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )

        handler.folderURL = folder
        let nonce = handler.currentSessionNonce ?? ""
        let request = URLRequest(url: URL(string: "livewallpaper://wallpaper/index.html?n=\(nonce)")!)

        let live = FakeURLSchemeTask(request: request)
        handler.webView(WKWebView(), start: live)
        handler.webView(WKWebView(), stop: live)
        #expect(live.failedError == nil)

        handler.folderURL = nil
        let stale = FakeURLSchemeTask(request: request)
        handler.webView(WKWebView(), start: stale)
        #expect(stale.failedError != nil)
    }

    @Test("Top-level requests with a wrong nonce are rejected")
    func wrongNonceRejected() {
        let handler = FolderURLSchemeHandler()
        let folder = makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        handler.folderURL = folder
        let request = URLRequest(url: URL(string: "livewallpaper://wallpaper/index.html?n=NOT-THE-NONCE")!)
        let task = FakeURLSchemeTask(request: request)
        handler.webView(WKWebView(), start: task)

        #expect(task.failedError != nil)
    }

    @Test("Top-level requests without any query are rejected")
    func missingNonceRejected() {
        let handler = FolderURLSchemeHandler()
        let folder = makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        handler.folderURL = folder
        let request = URLRequest(url: URL(string: "livewallpaper://wallpaper/index.html")!)
        let task = FakeURLSchemeTask(request: request)
        handler.webView(WKWebView(), start: task)

        #expect(task.failedError != nil)
    }

    @Test("Wrong host is rejected even when folder is active")
    func wrongHostRejected() {
        let handler = FolderURLSchemeHandler()
        let folder = makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        handler.folderURL = folder
        let nonce = handler.currentSessionNonce ?? ""
        let request = URLRequest(url: URL(string: "livewallpaper://other-host/index.html?n=\(nonce)")!)
        let task = FakeURLSchemeTask(request: request)
        handler.webView(WKWebView(), start: task)

        #expect(task.failedError != nil)
    }

    @Test("Subresource requests bypass the nonce check (scheme + host already gated)")
    func subresourceWithoutNonceAllowed() async throws {
        let handler = FolderURLSchemeHandler()
        let folder = makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let payload = Data("console.log('ok')".utf8)
        try payload.write(to: folder.appendingPathComponent("app.js"))

        handler.folderURL = folder

        let mainDocURL = URL(string: "livewallpaper://wallpaper/index.html?n=\(handler.currentSessionNonce ?? "")")!
        var request = URLRequest(url: URL(string: "livewallpaper://wallpaper/app.js")!)
        request.mainDocumentURL = mainDocURL

        let task = FakeURLSchemeTask(request: request)
        handler.webView(WKWebView(), start: task)

        try await waitUntil(timeout: .seconds(2)) { task.didFinishCalled || task.failedError != nil }
        handler.webView(WKWebView(), stop: task)

        #expect(task.failedError == nil)
        #expect(task.didFinishCalled)
    }

    // MARK: - helpers

    private func makeTemporaryFolder() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LWSchemeTest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
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

@Suite("HTMLWallpaperView source-isolation contract")
@MainActor
struct HTMLWallpaperViewSourceIsolationTests {

    @Test("Switching from .folder to .url clears folderURL and rotates nonce")
    func switchingToRemoteClearsFolder() {
        let view = HTMLWallpaperView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LWView-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? "<!doctype html><title>z</title>".write(
            to: folder.appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        guard let bookmark = ResourceUtilities.createBookmark(for: folder) else {
            Issue.record("Bookmark creation failed in test environment")
            return
        }
        view.loadSource(.folder(bookmarkData: bookmark, indexFileName: "index.html"))
        #expect(view.folderHandlerSnapshot.folderURL != nil)

        view.loadSource(.url(URL(string: "https://example.com")!))
        #expect(view.folderHandlerSnapshot.folderURL == nil)
        #expect(view.folderHandlerSnapshot.currentSessionNonce == nil)
    }
}

// MARK: - Test helpers

private final class FakeURLSchemeTask: NSObject, WKURLSchemeTask, @unchecked Sendable {
    let request: URLRequest
    private(set) var receivedResponse: URLResponse?
    private(set) var receivedData: [Data] = []
    private(set) var didFinishCalled: Bool = false
    private(set) var failedError: Error?

    init(request: URLRequest) {
        self.request = request
    }

    func didReceive(_ response: URLResponse) {
        receivedResponse = response
    }

    func didReceive(_ data: Data) {
        receivedData.append(data)
    }

    func didFinish() {
        didFinishCalled = true
    }

    func didFailWithError(_ error: Error) {
        failedError = error
    }
}

extension HTMLWallpaperView {
    /// Test-only window into the scheme handler so the isolation contract is
    /// observable without relying on private state.
    @MainActor
    var folderHandlerSnapshot: (folderURL: URL?, currentSessionNonce: String?) {
        let mirror = Mirror(reflecting: self)
        guard let handler = mirror.children.first(where: { $0.label == "folderHandler" })?.value as? FolderURLSchemeHandler else {
            return (nil, nil)
        }
        return (handler.folderURL, handler.currentSessionNonce)
    }
}
