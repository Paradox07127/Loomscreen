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
        #expect(session.sceneController == nil)
    }

    @Test("SpriteKit controller conforms to WPESceneRenderer without losing SKView access")
    func spriteKitControllerConformsToRendererBoundary() throws {
        let fixture = try SceneFixture.singlePNGScene()
        defer { fixture.cleanup() }
        let controller = SceneRenderingController(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            frame: CGRect(x: 0, y: 0, width: 100, height: 100)
        )

        let renderer: WPESceneRenderer = controller

        #expect(renderer.nsView === controller.view)
        #expect(controller.view.frame.size == CGSize(width: 100, height: 100))
    }

    @Test("Ambient builder uses Metal as the default scene backend")
    func ambientBuilderUsesMetalDefaultBackend() async throws {
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
        #expect(session.sceneController == nil)
        try await waitForSessionLoad(session)
    }

    @Test("Ambient builder can explicitly use the SpriteKit fallback backend")
    func ambientBuilderCanUseSpriteKitFallbackBackend() async throws {
        let fixture = try SceneFixture.cacheBackedPNGScene()
        defer { fixture.cleanup() }

        let session = try #require(AmbientWallpaperSessionBuilder().makeSceneSession(
            descriptor: fixture.descriptor,
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            rendererBackend: .spriteKit,
            applicationSupportRootURL: fixture.root
        ))
        defer { session.cleanup() }

        let renderer = try #require(session.sceneRenderer)
        let controller = try #require(session.sceneController)
        #expect(renderer === controller)
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

    static func singlePNGScene() throws -> SceneFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPESceneRendererBoundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{ "camera": { "center": "0 0 0" }, "general": { "orthogonalprojection": { "width": 64, "height": 64, "auto": true } }, "objects": [] }"#.utf8)
            .write(to: root.appendingPathComponent("scene.json"))
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

    static func cacheBackedPNGScene() throws -> SceneFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPESceneBuilderBoundary-\(UUID().uuidString)", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("wpe-cache/test", isDirectory: true)
        let materialsRoot = cacheRoot.appendingPathComponent("materials", isDirectory: true)
        try FileManager.default.createDirectory(at: materialsRoot, withIntermediateDirectories: true)
        try writePNG(at: materialsRoot.appendingPathComponent("a.png"))
        let scene = """
        {
          "camera": { "center": "0 0 0" },
          "general": { "orthogonalprojection": { "width": 64, "height": 64, "auto": true } },
          "objects": [{
            "id": "image",
            "name": "Image",
            "type": "image",
            "image": "materials/a.png",
            "origin": "0.5 0.5 0",
            "scale": "1 1 1",
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

    private static func writePNG(at url: URL) throws {
        guard let context = CGContext(
            data: nil,
            width: 8,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "fixture", code: -1)
        }
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
              ) else {
            throw NSError(domain: "fixture", code: -2)
        }
        CGImageDestinationAddImage(destination, image, nil)
        if !CGImageDestinationFinalize(destination) {
            throw NSError(domain: "fixture", code: -3)
        }
    }
}
