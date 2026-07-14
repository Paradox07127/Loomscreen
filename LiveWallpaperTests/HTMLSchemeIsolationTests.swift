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

    @Test("Package backend serves a scene.pkg entry's exact bytes")
    func packageBackendServesEntryBytes() async throws {
        let handler = FolderURLSchemeHandler()
        let folder = makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let jsBytes = Data("console.log('pkg-entry')".utf8)
        let pkgURL = folder.appendingPathComponent("scene.pkg")
        try Self.makePackageData(entries: [
            ("index.html", Data("<html>pkg</html>".utf8)),
            ("app.js", jsBytes)
        ]).write(to: pkgURL)

        let backing = try Self.packageBacking(at: pkgURL)
        handler.folderURL = folder
        handler.setPackageBacking(backing)

        var request = URLRequest(url: URL(string: "livewallpaper://wallpaper/app.js")!)
        request.mainDocumentURL = URL(string: "livewallpaper://wallpaper/index.html?n=\(handler.currentSessionNonce ?? "")")
        let task = FakeURLSchemeTask(request: request)
        handler.webView(WKWebView(), start: task)
        try await waitUntil(timeout: .seconds(2)) { task.didFinishCalled || task.failedError != nil }

        #expect(task.failedError == nil)
        #expect(task.didFinishCalled)
        #expect(task.receivedData.reduce(Data(), +) == jsBytes)
        let http = task.receivedResponse as? HTTPURLResponse
        #expect(http?.value(forHTTPHeaderField: "Content-Type")?.contains("javascript") == true)
        #expect(http?.value(forHTTPHeaderField: "Content-Length") == "\(jsBytes.count)")
    }

    @Test("Package backend honours a Range request against an entry slice")
    func packageBackendHonoursRange() async throws {
        let handler = FolderURLSchemeHandler()
        let folder = makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let full = Data((0..<200).map { UInt8($0 & 0xff) })
        let pkgURL = folder.appendingPathComponent("scene.pkg")
        try Self.makePackageData(entries: [
            ("index.html", Data("<html></html>".utf8)),
            ("clip.bin", full)
        ]).write(to: pkgURL)

        handler.folderURL = folder
        handler.setPackageBacking(try Self.packageBacking(at: pkgURL))

        var request = URLRequest(url: URL(string: "livewallpaper://wallpaper/clip.bin")!)
        request.mainDocumentURL = URL(string: "livewallpaper://wallpaper/index.html?n=\(handler.currentSessionNonce ?? "")")
        request.setValue("bytes=10-19", forHTTPHeaderField: "Range")
        let task = FakeURLSchemeTask(request: request)
        handler.webView(WKWebView(), start: task)
        try await waitUntil(timeout: .seconds(2)) { task.didFinishCalled || task.failedError != nil }

        #expect(task.failedError == nil)
        #expect(task.receivedData.reduce(Data(), +) == full[10...19])
        let http = task.receivedResponse as? HTTPURLResponse
        #expect(http?.statusCode == 206)
        #expect(http?.value(forHTTPHeaderField: "Content-Range") == "bytes 10-19/200")
    }

    @Test("Loose files win over same-named package entries (no plain-folder regression)")
    func packageBackendPrefersLooseFileOverPackageEntry() async throws {
        let handler = FolderURLSchemeHandler()
        let folder = makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        // Both a loose index.html and a package index.html exist; the loose one
        // must win so an ordinary HTML folder next to a scene.pkg is unaffected.
        let looseBytes = Data("<html>loose-wins</html>".utf8)
        try looseBytes.write(to: folder.appendingPathComponent("index.html"))
        let pkgURL = folder.appendingPathComponent("scene.pkg")
        try Self.makePackageData(entries: [
            ("index.html", Data("<html>packaged</html>".utf8))
        ]).write(to: pkgURL)

        handler.folderURL = folder
        handler.setPackageBacking(try Self.packageBacking(at: pkgURL))

        let url = URL(string: "livewallpaper://wallpaper/index.html?n=\(handler.currentSessionNonce ?? "")")!
        let task = FakeURLSchemeTask(request: URLRequest(url: url))
        handler.webView(WKWebView(), start: task)
        try await waitUntil(timeout: .seconds(2)) { task.didFinishCalled || task.failedError != nil }

        #expect(task.failedError == nil)
        #expect(task.receivedData.reduce(Data(), +) == looseBytes)
    }

    @Test("Package backend falls back to a loose sibling for non-package files")
    func packageBackendFallsBackToLooseFile() async throws {
        let handler = FolderURLSchemeHandler()
        let folder = makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let pkgURL = folder.appendingPathComponent("scene.pkg")
        try Self.makePackageData(entries: [
            ("index.html", Data("<html></html>".utf8))
        ]).write(to: pkgURL)
        let looseBytes = Data("{\"loose\":true}".utf8)
        try looseBytes.write(to: folder.appendingPathComponent("project.json"))

        handler.folderURL = folder
        handler.setPackageBacking(try Self.packageBacking(at: pkgURL))

        var request = URLRequest(url: URL(string: "livewallpaper://wallpaper/project.json")!)
        request.mainDocumentURL = URL(string: "livewallpaper://wallpaper/index.html?n=\(handler.currentSessionNonce ?? "")")
        let task = FakeURLSchemeTask(request: request)
        handler.webView(WKWebView(), start: task)
        try await waitUntil(timeout: .seconds(2)) { task.didFinishCalled || task.failedError != nil }

        #expect(task.failedError == nil)
        #expect(task.receivedData.reduce(Data(), +) == looseBytes)
    }

    // MARK: - helpers

    private static func packageBacking(at pkgURL: URL) throws -> FolderURLSchemeHandler.PackageBacking {
        let handle = try FileHandle(forReadingFrom: pkgURL)
        defer { try? handle.close() }
        let package = try WallpaperEnginePackage.parseIndex(streamingFrom: handle)
        return FolderURLSchemeHandler.PackageBacking(url: pkgURL, package: package)
    }

    /// Builds a minimal `scene.pkg` blob (`PKGV0022` header) in the same layout
    /// the real parser reads: `[magicLen|magic][count]({nameLen|name|off|size})*[payload]`.
    static func makePackageData(entries: [(name: String, bytes: Data)]) -> Data {
        var payload = Data()
        var resolved: [(name: String, offset: UInt32, size: UInt32)] = []
        for entry in entries {
            resolved.append((entry.name, UInt32(payload.count), UInt32(entry.bytes.count)))
            payload.append(entry.bytes)
        }

        var data = Data()
        func appendU32(_ value: UInt32) {
            data.append(UInt8(value & 0xff))
            data.append(UInt8((value >> 8) & 0xff))
            data.append(UInt8((value >> 16) & 0xff))
            data.append(UInt8((value >> 24) & 0xff))
        }
        let magic = Array("PKGV0022".utf8)
        appendU32(UInt32(magic.count))
        data.append(contentsOf: magic)
        appendU32(UInt32(resolved.count))
        for entry in resolved {
            let nameBytes = Array(entry.name.utf8)
            appendU32(UInt32(nameBytes.count))
            data.append(contentsOf: nameBytes)
            appendU32(entry.offset)
            appendU32(entry.size)
        }
        data.append(payload)
        return data
    }

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

@Suite("HTMLWallpaperView navigation policy")
struct HTMLWallpaperNavigationPolicyTests {

    private func makeReadRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LWNavPolicy-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("Remote source rejects file:// navigation")
    func remoteSourceRejectsFileURL() {
        let target = URL(fileURLWithPath: "/etc/passwd")
        let decision = HTMLWallpaperView.navigationDecision(
            for: target,
            navigationType: .other,
            currentURL: URL(string: "https://example.com/"),
            allowMouseInteraction: false,
            localReadAccessRoot: nil
        )
        #expect(decision == .cancel)
    }

    @Test("Remote source rejects scripted cross-origin navigation")
    func remoteSourceRejectsCrossOriginNavigation() {
        let source = URL(string: "https://trusted.example/wallpaper")!
        let decision = HTMLWallpaperView.navigationDecision(
            for: URL(string: "https://attacker.example/payload")!,
            navigationType: .other,
            currentURL: source,
            allowMouseInteraction: false,
            localReadAccessRoot: nil,
            remoteSourceOrigin: source
        )
        #expect(decision == .cancel)
    }

    @Test("Remote source allows same-origin navigation with an implicit default port")
    func remoteSourceAllowsSameOriginNavigation() {
        let source = URL(string: "https://trusted.example:443/wallpaper")!
        let decision = HTMLWallpaperView.navigationDecision(
            for: URL(string: "https://trusted.example/redirected")!,
            navigationType: .other,
            currentURL: source,
            allowMouseInteraction: false,
            localReadAccessRoot: nil,
            remoteSourceOrigin: source
        )
        #expect(decision == .allow)
    }

    @Test("Remote source rejects navigation to a different effective port")
    func remoteSourceRejectsDifferentPort() {
        let source = URL(string: "https://trusted.example/wallpaper")!
        let decision = HTMLWallpaperView.navigationDecision(
            for: URL(string: "https://trusted.example:8443/payload")!,
            navigationType: .other,
            currentURL: source,
            allowMouseInteraction: false,
            localReadAccessRoot: nil,
            remoteSourceOrigin: source
        )
        #expect(decision == .cancel)
    }

    @Test("Remote source trust stays pinned after current URL changes")
    func remoteSourceTrustDoesNotFollowCurrentURL() {
        let source = URL(string: "https://trusted.example/wallpaper")!
        let attacker = URL(string: "https://attacker.example/landing")!
        let decision = HTMLWallpaperView.navigationDecision(
            for: URL(string: "https://attacker.example/next")!,
            navigationType: .reload,
            currentURL: attacker,
            allowMouseInteraction: false,
            localReadAccessRoot: nil,
            remoteSourceOrigin: source
        )
        #expect(decision == .cancel)
    }

    @Test("Inline source rejects file:// navigation")
    func inlineSourceRejectsFileURL() {
        let target = URL(fileURLWithPath: "/private/var/db/secret")
        let decision = HTMLWallpaperView.navigationDecision(
            for: target,
            navigationType: .other,
            currentURL: nil,
            allowMouseInteraction: false,
            localReadAccessRoot: nil
        )
        #expect(decision == .cancel)
    }

    @Test("Local file source allows sibling file inside read root")
    func localSourceAllowsSiblingFile() {
        let root = makeReadRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sibling = root.appendingPathComponent("asset.css")
        let decision = HTMLWallpaperView.navigationDecision(
            for: sibling,
            navigationType: .other,
            currentURL: root.appendingPathComponent("index.html"),
            allowMouseInteraction: false,
            localReadAccessRoot: root
        )
        #expect(decision == .allow)
    }

    @Test("Local file source rejects parent traversal outside read root")
    func localSourceRejectsParentTraversal() {
        let root = makeReadRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let escape = root.deletingLastPathComponent().appendingPathComponent("../etc/passwd")
        let decision = HTMLWallpaperView.navigationDecision(
            for: escape,
            navigationType: .other,
            currentURL: root.appendingPathComponent("index.html"),
            allowMouseInteraction: false,
            localReadAccessRoot: root
        )
        #expect(decision == .cancel)
    }

    @Test("Folder source rejects file URL outside granted folder")
    func folderSourceRejectsExternalFile() {
        let root = makeReadRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = URL(fileURLWithPath: "/tmp/some-other-file.png")
        let decision = HTMLWallpaperView.navigationDecision(
            for: outside,
            navigationType: .other,
            currentURL: URL(string: "livewallpaper://wallpaper/index.html?n=abc"),
            allowMouseInteraction: false,
            localReadAccessRoot: root
        )
        #expect(decision == .cancel)
    }

    @Test("Folder scheme navigation is always allowed")
    func folderSchemeNavigationAllowed() {
        let target = URL(string: "livewallpaper://wallpaper/sub/index.html?n=abc")!
        let decision = HTMLWallpaperView.navigationDecision(
            for: target,
            navigationType: .other,
            currentURL: target,
            allowMouseInteraction: false,
            localReadAccessRoot: URL(fileURLWithPath: "/tmp/wp")
        )
        #expect(decision == .allow)
    }

    @Test("Link activation with mouse disabled cancels everything")
    func linkActivationCancelsWithoutMouseInteraction() {
        let target = URL(string: "https://example.com/click")!
        let decision = HTMLWallpaperView.navigationDecision(
            for: target,
            navigationType: .linkActivated,
            currentURL: URL(string: "https://example.com/"),
            allowMouseInteraction: false,
            localReadAccessRoot: nil
        )
        #expect(decision == .cancel)
    }

    @Test("Link activation opens cross-origin remote URL externally")
    func linkActivationOpensCrossOriginExternally() {
        let target = URL(string: "https://other.example/")!
        let decision = HTMLWallpaperView.navigationDecision(
            for: target,
            navigationType: .linkActivated,
            currentURL: URL(string: "https://example.com/"),
            allowMouseInteraction: true,
            localReadAccessRoot: nil
        )
        #expect(decision == .openExternally(target))
    }

    @Test("Link activation on remote page rejects file:// click")
    func linkActivationOnRemoteRejectsFile() {
        let decision = HTMLWallpaperView.navigationDecision(
            for: URL(fileURLWithPath: "/etc/passwd"),
            navigationType: .linkActivated,
            currentURL: URL(string: "https://example.com/"),
            allowMouseInteraction: true,
            localReadAccessRoot: nil
        )
        #expect(decision == .cancel)
    }

    @Test("Form submission is always cancelled")
    func formSubmissionCancelled() {
        let decision = HTMLWallpaperView.navigationDecision(
            for: URL(string: "https://example.com/submit")!,
            navigationType: .formSubmitted,
            currentURL: URL(string: "https://example.com/"),
            allowMouseInteraction: true,
            localReadAccessRoot: nil
        )
        #expect(decision == .cancel)
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
