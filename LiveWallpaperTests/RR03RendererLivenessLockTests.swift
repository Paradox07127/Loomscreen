#if !LITE_BUILD
import CoreGraphics
import CryptoKit
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import MetalKit
import Testing
@testable import LiveWallpaper

@MainActor
@Suite("RR-03 renderer liveness lock", .serialized)
struct RR03RendererLivenessLockTests {
    @Test("Static renderer settles on demand and repeated frames keep the same hash")
    func staticRendererSettlesWithStableHash() async throws {
        let fixture = try RR03LivenessFixture.make(propertyControlled: false)
        defer { fixture.cleanup() }
        let stack = try Self.makeRenderer(fixture)
        let renderer = stack.renderer
        defer { renderer.cleanup() }

        try await stack.load()

        #expect(renderer.needsContinuousFrames == false)
        #expect(stack.surface.mtkView.isPaused)
        #expect(stack.surface.mtkView.enableSetNeedsDisplay)
        let first = try #require(renderer.outputTexture)
        let firstHash = try Self.textureSHA256(first)
        renderer.executor.synchronizeFrameCompletion = true
        let second = try renderer.renderCurrentFrame(inputs: renderer.makeFrameInputs())
        let secondHash = try Self.textureSHA256(second)
        #expect(firstHash == secondHash)
    }

    @Test("A property patch redraws a settled scene immediately without leaving it live")
    func propertyPatchRedrawsThenSettles() async throws {
        let fixture = try RR03LivenessFixture.make(propertyControlled: true)
        defer { fixture.cleanup() }
        let stack = try Self.makeRenderer(fixture)
        let renderer = stack.renderer
        defer { renderer.cleanup() }

        try await stack.load()
        let visibleHash = try Self.textureSHA256(try #require(renderer.outputTexture))
        renderer.executor.synchronizeFrameCompletion = true
        let patch = WPEScenePropertyPatch(
            bindingsByProperty: renderer.scenePropertyBindings,
            oldValues: ["show": .bool(true)],
            newValues: ["show": .bool(false)]
        )

        #expect(renderer.applyScenePropertyPatch(patch))
        let hiddenHash = try Self.textureSHA256(try #require(renderer.outputTexture))
        #expect(hiddenHash != visibleHash)
        #expect(renderer.needsContinuousFrames == false)
        #expect(stack.surface.mtkView.isPaused)
        #expect(stack.surface.mtkView.enableSetNeedsDisplay)
    }

    @Test("Pointer capture re-arms a settled renderer and disabling it settles again")
    func pointerCaptureRearmsAndSettles() async throws {
        let fixture = try RR03LivenessFixture.make(propertyControlled: false)
        defer { fixture.cleanup() }
        let stack = try Self.makeRenderer(fixture)
        let renderer = stack.renderer
        defer { renderer.cleanup() }

        try await stack.load()
        #expect(stack.surface.mtkView.isPaused)

        renderer.setClickCaptureEnabled(true)
        #expect(renderer.needsContinuousFrames)
        #expect(stack.surface.mtkView.isPaused == false)
        #expect(stack.surface.mtkView.enableSetNeedsDisplay == false)

        renderer.setClickCaptureEnabled(false)
        #expect(renderer.needsContinuousFrames == false)
        #expect(stack.surface.mtkView.isPaused)
        #expect(stack.surface.mtkView.enableSetNeedsDisplay)
    }

    private static func makeRenderer(_ fixture: RR03LivenessFixture) throws -> RR03RendererStack {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let surface = WPERenderSurface(frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: device)
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            projectManifestRootURL: fixture.root,
            dependencyMounts: [],
            surfaceControl: surface,
            mailbox: surface.mailbox,
            presentLayer: WPEPresentLayer(layer: surface.metalLayer),
            drawableSize: surface.metalLayer.drawableSize,
            device: device,
            pointerSampler: .fixed(SIMD2<Double>(0.5, 0.5))
        )
        return RR03RendererStack(renderer: renderer, surface: surface, actor: WPEDisplayRenderActor(backing: .main))
    }

    private static func textureSHA256(_ texture: MTLTexture) throws -> String {
        try #require(texture.pixelFormat == .rgba8Unorm || texture.pixelFormat == .rgba8Unorm_srgb)
        let bytesPerRow = texture.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        texture.getBytes(
            &bytes,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height),
            mipmapLevel: 0
        )
        return SHA256.hash(data: Data(bytes))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

@MainActor
private struct RR03RendererStack {
    let renderer: WPEMetalSceneRenderer
    let surface: WPERenderSurface
    let actor: WPEDisplayRenderActor

    func load() async throws {
        await actor.adopt(WPERendererHandoff(renderer: renderer).renderer)
        try await actor.load()
    }
}

private struct RR03LivenessFixture {
    let root: URL
    let descriptor: SceneDescriptor

    static func make(propertyControlled: Bool) throws -> Self {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rr03-liveness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let visible: Any = propertyControlled
            ? ["user": "show", "value": true]
            : true
        let scene = try JSONSerialization.data(withJSONObject: [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 64, "auto": true]],
            "objects": [[
                "id": "solid",
                "name": "Solid",
                "type": "image",
                "image": "models/util/solidlayer.json",
                "color": "1 0 0",
                "alpha": 1,
                "visible": visible,
            ]],
        ], options: [.sortedKeys])
        try scene.write(to: root.appendingPathComponent("scene.json"))
        let project = try JSONSerialization.data(withJSONObject: [
            "workshopid": "rr03-fixture",
            "type": "scene",
            "file": "scene.json",
            "general": [
                "properties": [
                    "show": ["type": "bool", "value": true],
                ],
            ],
        ], options: [.sortedKeys])
        try project.write(to: root.appendingPathComponent("project.json"))
        return Self(
            root: root,
            descriptor: SceneDescriptor(
                workshopID: "rr03-fixture",
                cacheRelativePath: "wpe-cache/rr03-fixture",
                entryFile: "scene.json",
                capabilityTier: .imageOnly
            )
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
#endif
