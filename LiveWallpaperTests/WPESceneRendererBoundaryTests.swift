import AppKit
import CoreGraphics
import ImageIO
import Metal
import MetalKit
import Testing
import UniformTypeIdentifiers
@testable import LiveWallpaper

@MainActor
@Suite("WPE scene renderer boundary")
struct WPESceneRendererBoundaryTests {
    @Test("SceneWallpaperSession forwards lifecycle to a type-erased renderer")
    func sessionForwardsLifecycleToTypeErasedRenderer() async throws {
        let renderer = FakeSceneRenderer()
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 64, height: 64),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        let session = SceneWallpaperSession(window: window, renderer: renderer)

        session.startLoadIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        session.setThrottled(true)
        session.applyPerformanceProfile(.suspended)
        await session.reload()

        #expect(renderer.loadCallCount == 2)
        #expect(renderer.lastThrottle == true)
        #expect(renderer.lastProfile == .suspended)
        #expect(session.sceneRenderer === renderer)
    }

    @Test("Ambient builder uses the Metal renderer for scene wallpapers")
    func ambientBuilderUsesMetalRenderer() async throws {
        _ = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try SceneFixture.cacheBackedSolidColorScene()
        defer { fixture.cleanup() }

        let session = try #require(AmbientWallpaperSessionBuilder().makeSceneSession(
            descriptor: fixture.descriptor,
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            applicationSupportRootURL: fixture.root
        ))
        defer { session.cleanup() }

        #expect(session.sceneRenderer is WPEMetalSceneRenderer)
        #expect(session.sceneRenderer?.nsView is MTKView)
        try await waitForSessionLoad(session)
    }

    private func waitForSessionLoad(_ session: SceneWallpaperSession) async throws {
        for _ in 0..<50 {
            if session.sceneRenderer?.hasPresentedFrame == true {
                return
            }
            if let error = session.loadError {
                throw error
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(
            domain: "WPESceneRendererBoundaryTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for scene renderer load"]
        )
    }
}

@MainActor
private final class FakeSceneRenderer: WPESceneRenderer {
    let view = NSView(frame: .zero)
    var loadCallCount = 0
    var lastThrottle: Bool?
    var lastProfile: WallpaperPerformanceProfile?
    var onProgress: (@MainActor (String) -> Void)?
    var loadDiagnostics: SceneLoadDiagnostic?
    var renderGraph: WPERenderGraph?
    var renderPipeline: WPEPreparedRenderPipeline?
    var hasPresentedFrame = false
    var resolutionDiagnostics = WPEResolutionDiagnosticsSnapshot(events: [])
    var previewSnapshot: NSImage?
    var nsView: NSView { view }

    func load() async throws {
        loadCallCount += 1
        hasPresentedFrame = true
    }

    func reload() async throws {
        try await load()
    }

    func setThrottled(_ throttled: Bool) {
        lastThrottle = throttled
    }

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        lastProfile = profile
    }

    func cleanup() {}
}

private struct SceneFixture {
    let root: URL
    let descriptor: SceneDescriptor

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    static func cacheBackedSolidColorScene() throws -> SceneFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPESceneBuilderBoundary-\(UUID().uuidString)", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("wpe-cache/test", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let scene = """
        {
          "camera": { "center": "0 0 0" },
          "general": { "orthogonalprojection": { "width": 64, "height": 64, "auto": true } },
          "objects": [{
            "id": "solid",
            "name": "Solid",
            "type": "image",
            "image": "models/util/solidlayer.json",
            "color": "1 0 0",
            "alpha": 1
          }]
        }
        """
        try Data(scene.utf8).write(to: cacheRoot.appendingPathComponent("scene.json"))
        return SceneFixture(
            root: root,
            descriptor: SceneDescriptor(
                workshopID: UUID().uuidString,
                cacheRelativePath: "wpe-cache/test",
                entryFile: "scene.json",
                capabilityTier: .imageOnly
            )
        )
    }
}
