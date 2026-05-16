import Foundation
import Testing
import WebKit
@testable import LiveWallpaper

@Suite("WebGL rain wallpaper")
struct WebGLRainWallpaperTests {
    @Test("HTMLSource stores WebGL rain video metadata and round-trips")
    func htmlSourceRoundTrip() throws {
        let bookmark = Data([0x01, 0x02, 0x03])
        let source = HTMLSource.webGLRainVideo(bookmarkData: bookmark)

        #expect(source.displayName == "WebGL rain glass")
        #expect(source.iconName == "drop.fill")
        #expect(source.diagnosticSignature == "webgl-rain-video:" + bookmark.base64EncodedString())

        let encoded = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(HTMLSource.self, from: encoded)

        #expect(decoded == source)
    }

    @Test("Generated template embeds the active video and rain renderer")
    func templateContainsVideoAndRenderer() {
        let videoURL = "livewallpaper-rain-video://current/video"
        let html = WebGLRainHTMLTemplate.html(videoURL: videoURL)

        #expect(html.contains(videoURL))
        #expect(html.contains("getContext('webgl'"))
        #expect(html.contains("function Raindrops"))
        #expect(html.contains("function RainRenderer"))
        #expect(html.contains("Codrops RainEffect"))
        #expect(html.contains("dropAlphaDataURL"))
        #expect(html.contains("dropColorDataURL"))
        #expect(html.contains("createDrop"))
        #expect(html.contains("updateDroplets"))
        #expect(html.contains("collisionRadius"))
        #expect(html.contains("u_waterMap"))
        #expect(html.contains("u_textureBg"))
        #expect(html.contains("u_textureFg"))
        #expect(!html.contains("TODO"))
    }

    @Test(
        "Bundled Codrops rain textures are available",
        .enabled(if: WebGLRainAssets.rootURL != nil)
    )
    func bundledRainTexturesPresent() throws {
        let rootURL = try #require(WebGLRainAssets.rootURL)

        for fileName in WebGLRainAssets.expectedFiles {
            let fileURL = rootURL.appendingPathComponent(fileName, isDirectory: false)
            #expect(FileManager.default.fileExists(atPath: fileURL.path))
        }
    }

    @Test("WebGL rain HTML wallpaper keeps the source video available for fallback")
    func screenConfigurationPreservesVideoFallback() {
        let bookmark = Data([0xCA, 0xFE])
        var configuration = ScreenConfiguration(screenID: 9, videoBookmarkData: bookmark)
        let source = HTMLSource.webGLRainVideo(bookmarkData: bookmark)

        configuration.setHTMLWallpaper(source: source, config: ScreenManager.webGLRainHTMLConfig)

        #expect(configuration.activeWallpaper == .html(source: source, config: ScreenManager.webGLRainHTMLConfig))
        #expect(configuration.preferredVideoBookmarkData == bookmark)
        let restored = configuration.activateSavedVideoWallpaper()
        #expect(restored)
        #expect(configuration.activeWallpaper == .video(bookmarkData: bookmark))
    }

    @Test("Transient rain renderer does not overwrite the user's saved HTML wallpaper")
    func transientRainPreservesSavedHTMLWallpaper() {
        let videoBookmark = Data([0x10, 0x20])
        let savedHTMLSource = HTMLSource.url(URL(string: "https://example.com/wallpaper")!)
        let savedHTMLConfig = HTMLConfig(allowJavaScript: false, blockTrackers: false)
        var configuration = ScreenConfiguration(screenID: 10, videoBookmarkData: videoBookmark)

        configuration.setHTMLWallpaper(source: savedHTMLSource, config: savedHTMLConfig)
        let restoredInitialVideo = configuration.activateSavedVideoWallpaper()
        #expect(restoredInitialVideo)

        configuration.setTransientWebGLRainWallpaper(
            bookmarkData: videoBookmark,
            config: ScreenManager.webGLRainHTMLConfig
        )
        #expect(configuration.savedHTMLSource == savedHTMLSource)
        #expect(configuration.savedHTMLConfig == savedHTMLConfig)

        let restoredVideo = configuration.activateSavedVideoWallpaper()
        #expect(restoredVideo)
        #expect(configuration.savedHTMLSource == savedHTMLSource)

        let restoredHTML = configuration.activateSavedHTMLWallpaper()
        #expect(restoredHTML)
        #expect(configuration.activeWallpaper == .html(source: savedHTMLSource, config: savedHTMLConfig))
    }

    @Test("Decoded transient rain renderer is not backfilled as saved HTML")
    func decodedTransientRainDoesNotBecomeSavedHTMLWallpaper() throws {
        let videoBookmark = Data([0x33, 0x44])
        var configuration = ScreenConfiguration(screenID: 11, videoBookmarkData: videoBookmark)
        configuration.setTransientWebGLRainWallpaper(
            bookmarkData: videoBookmark,
            config: ScreenManager.webGLRainHTMLConfig
        )

        let encoded = try JSONEncoder().encode(configuration)
        var decoded = try JSONDecoder().decode(ScreenConfiguration.self, from: encoded)

        #expect(decoded.savedHTMLSource == nil)
        let restoredHTML = decoded.activateSavedHTMLWallpaper()
        #expect(!restoredHTML)
    }
}

@Suite("RainVideoURLSchemeHandler")
@MainActor
struct RainVideoURLSchemeHandlerTests {
    @Test("Range request streams bytes from the active video")
    func rangeRequestStreamsActiveVideo() async throws {
        let payload = Data("0123456789".utf8)
        let fileURL = try makeTemporaryVideo(payload: payload)
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let handler = RainVideoURLSchemeHandler()
        handler.videoURL = fileURL

        var request = URLRequest(url: RainVideoURLSchemeHandler.currentVideoURL)
        request.setValue("bytes=2-5", forHTTPHeaderField: "Range")
        let task = RainFakeURLSchemeTask(request: request)

        handler.webView(WKWebView(), start: task)
        try await waitUntil(timeout: .seconds(2)) { task.didFinishCalled || task.failedError != nil }
        handler.webView(WKWebView(), stop: task)

        let received = task.receivedData.reduce(into: Data()) { $0.append($1) }
        #expect(task.failedError == nil)
        #expect((task.receivedResponse as? HTTPURLResponse)?.statusCode == 206)
        #expect(received == payload.subdata(in: 2..<6))
    }

    @Test("Requests are rejected after the active video is cleared")
    func clearedVideoRejectsRequests() {
        let handler = RainVideoURLSchemeHandler()
        handler.videoURL = nil

        let task = RainFakeURLSchemeTask(request: URLRequest(url: RainVideoURLSchemeHandler.currentVideoURL))
        handler.webView(WKWebView(), start: task)

        #expect(task.failedError != nil)
    }

    private func makeTemporaryVideo(payload: Data) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LWRainVideo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fileURL = folder.appendingPathComponent("clip.mp4")
        try payload.write(to: fileURL)
        return fileURL
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

private final class RainFakeURLSchemeTask: NSObject, WKURLSchemeTask, @unchecked Sendable {
    let request: URLRequest
    private(set) var receivedResponse: URLResponse?
    private(set) var receivedData: [Data] = []
    private(set) var didFinishCalled = false
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
