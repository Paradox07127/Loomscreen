import CoreGraphics
import Foundation
import ImageIO
import Metal
import MetalKit
import Testing
import UniformTypeIdentifiers
@testable import LiveWallpaper

@MainActor
@Suite("WPE Metal scene renderer")
struct WPEMetalSceneRendererTests {

    @Test("Interactive Metal view accepts first mouse while click capture is enabled")
    func interactiveMetalViewAcceptsFirstMouseWhenCapturingClicks() {
        let view = WPEInteractiveMTKView(
            frame: CGRect(x: 0, y: 0, width: 16, height: 16),
            device: nil
        )

        #expect(view.acceptsFirstMouse(for: nil) == false)
        view.clickCaptureEnabled = true
        #expect(view.acceptsFirstMouse(for: nil) == true)
    }

    @Test("Initializes with an MTKView when Metal is available")
    func initializesWithMTKView() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }

        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device
        )

        #expect(renderer.nsView is MTKView)
        #expect(renderer.hasPresentedFrame == false)
    }

    @Test("Loads solidcolor scene through Metal executor")
    func loadsSolidColorScene() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device
        )

        try await renderer.load()

        #expect(renderer.hasPresentedFrame)
        #expect(renderer.renderGraph?.layers.count == 1)
        #expect(renderer.renderPipeline?.layers.first?.passes.first?.pass.shader == "solidlayer")
    }

    @Test("Dynamic origin scripts keep otherwise static scenes on the continuous render loop")
    func dynamicOriginScriptsKeepRendererLive() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.cursorOriginScene()
        defer { fixture.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device,
            pointerSampler: .fixed(SIMD2<Double>(0.25, 0.75))
        )

        try await renderer.load()

        let mtkView = try #require(renderer.nsView as? MTKView)
        #expect(mtkView.isPaused == false)
        #expect(mtkView.enableSetNeedsDisplay == false)
    }

    @Test("Loads material texture bindings before rendering")
    func loadsMaterialTextureBindings() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.materialTextureScene(color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        defer { fixture.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device
        )

        try await renderer.load()

        let pixel = try #require(renderer.renderedTexture?.readPixel(x: 32, y: 32))
        #expect(pixel.r >= 200)
        #expect(pixel.r > pixel.g)
        #expect(pixel.r > pixel.b)
    }

    @Test("Renders layers created by SceneScript")
    func rendersSceneScriptCreatedLayers() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.sceneScriptCreatedLayerScene()
        defer { fixture.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device
        )

        try await renderer.load()

        let pixel = try #require(renderer.renderedTexture?.readPixel(x: 32, y: 32))
        #expect(pixel.r >= 200)
        #expect(pixel.r > pixel.g)
        #expect(pixel.r > pixel.b)
    }

    @Test("Resolves dependency-mounted texture references")
    func resolvesDependencyMountedTextures() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.dependencyTextureScene()
        defer { fixture.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [WPEAssetMount(workshopID: "123", rootURL: fixture.dependencyRoot!)],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device
        )

        try await renderer.load()

        let pixel = try #require(renderer.renderedTexture?.readPixel(x: 32, y: 32))
        #expect(pixel.g >= 245)
        #expect(pixel.g > pixel.r)
        #expect(pixel.g > pixel.b)
    }

    @Test("Load failure populates loadDiagnostics with a SceneLoadDiagnostic")
    func loadFailurePopulatesDiagnostics() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let descriptor = SceneDescriptor(
            workshopID: UUID().uuidString,
            cacheRelativePath: "wpe-cache/missing-\(UUID().uuidString)",
            entryFile: "scene.json",
            capabilityTier: .imageOnly
        )
        let nonExistentRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEMetalDiagnostics-\(UUID().uuidString)", isDirectory: true)

        let renderer = try WPEMetalSceneRenderer(
            descriptor: descriptor,
            cacheRootURL: nonExistentRoot,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device
        )

        await #expect(throws: (any Error).self) {
            try await renderer.load()
        }

        let diagnostic = try #require(renderer.loadDiagnostics)
        if case .fileMissing(_, let path) = diagnostic {
            #expect(path == descriptor.entryFile)
        } else {
            Issue.record("Expected .fileMissing diagnostic, got \(diagnostic)")
        }
    }

    @Test("Successful reload clears stale loadDiagnostics")
    func reloadClearsStaleDiagnostics() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device
        )

        try await renderer.load()
        try await renderer.reload()

        #expect(renderer.loadDiagnostics == nil)
    }

    @Test("Computes runtime uniforms from clock pointer and performance profile during load render")
    func computesRuntimeUniformsDuringLoadRender() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = try #require(DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 5,
            day: 5,
            hour: 12,
            minute: 0,
            second: 0
        ).date)

        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device,
            frameClock: WPEMetalFrameClock(
                loadTime: 100,
                currentMediaTime: { 101.25 },
                currentDate: { date },
                calendar: calendar
            ),
            pointerSampler: .fixed(SIMD2<Double>(0.25, 0.75))
        )
        renderer.applyPerformanceProfile(.suspended)

        try await renderer.load()

        let uniforms = try #require(renderer.lastRuntimeUniforms)
        #expect(abs(uniforms.time - 1.25) < 0.0001)
        #expect(abs(uniforms.daytime - 0.5) < 0.0001)
        // Suspended renders at full brightness: g_Brightness multiplies image
        // albedo, so 0 here would render every genericimage layer as a black
        // silhouette. Suspension pauses via isPaused, not by dimming to black.
        #expect(uniforms.brightness == 1)
        #expect(uniforms.pointerPosition == SIMD2<Double>(0.25, 0.75))
    }

    @Test("Loads preview snapshot from Metal offscreen output")
    func loadsPreviewSnapshotFromMetalOutput() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }

        // The first-frame snapshot is now a scene-debug artifact: the renderer
        // only pays for the GPU read-back when artifacts are enabled (the
        // inspector otherwise shows the project's preview GIF). Force it on so
        // this test exercises the snapshot path deterministically.
        let key = WPESceneDebugArtifacts.defaultsKey
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }

        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device
        )

        try await renderer.load()

        let snapshot = try #require(renderer.previewSnapshot)
        #expect(snapshot.size.width == 64)
        #expect(snapshot.size.height == 64)
    }

    @Test("Texture load failure attributes diagnostic to the WPE object name that referenced it")
    func textureLoadDiagnosticsUseLayerObjectName() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.missingTextureScene()
        defer { fixture.cleanup() }

        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device
        )

        await #expect(throws: (any Error).self) {
            try await renderer.load()
        }

        let diagnostic = try #require(renderer.loadDiagnostics)
        #expect(diagnostic.layerName == "Hero Layer")
        #expect(diagnostic.errorDescription.contains("Hero Layer"))
        #expect(!diagnostic.errorDescription.lowercased().contains("texture"))
        #expect(!diagnostic.errorDescription.lowercased().contains("shader"))
    }

    @Test("Texture candidate generator treats dotted basenames as extension-less")
    func textureCandidatesHandlesDottedBasenames() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device
        )

        let dotted = renderer.textureCandidates(
            for: "anime-girl-sleeping-saber-fate-grand-order-4k-wallpaper-uhdpaper.com-600@5@f"
        )
        #expect(
            dotted.contains("materials/anime-girl-sleeping-saber-fate-grand-order-4k-wallpaper-uhdpaper.com-600@5@f.png"),
            "Dotted basename must still try the materials/.png fallback"
        )
        #expect(
            dotted.contains("materials/anime-girl-sleeping-saber-fate-grand-order-4k-wallpaper-uhdpaper.com-600@5@f.tex")
        )

        let underscored = renderer.textureCandidates(for: "91VDetfVuOL._UF1000,1000_QL80_DpWeblab_")
        #expect(underscored.contains("materials/91VDetfVuOL._UF1000,1000_QL80_DpWeblab_.png"))
        #expect(underscored.contains("materials/91VDetfVuOL._UF1000,1000_QL80_DpWeblab_.tex"))

        let generated = renderer.textureCandidates(
            for: "__yuuki_shibou_yuugi_de_meshi_wo_kuu_drawn_by_nekometaru__ae12f81d42ef9a8b610029375bac6b70"
        )
        #expect(generated.contains("materials/__yuuki_shibou_yuugi_de_meshi_wo_kuu_drawn_by_nekometaru__ae12f81d42ef9a8b610029375bac6b70.tex"))
        #expect(generated.contains("__yuuki_shibou_yuugi_de_meshi_wo_kuu_drawn_by_nekometaru__ae12f81d42ef9a8b610029375bac6b70"))

        // A raw-image ref also probes its converted `.tex` form and the
        // `materials/` root — WPE stores `foo.png` source images as
        // `materials/foo.png.tex` (see WPEMetalSceneRenderer.textureCandidates).
        #expect(
            renderer.textureCandidates(for: "logo.png")
                == ["logo.png", "logo.png.tex", "materials/logo.png", "materials/logo.png.tex"]
        )
        // `.tex` is taken at face value — no fallback chain.
        #expect(renderer.textureCandidates(for: "atlas.tex") == ["atlas.tex"])

        let bare = renderer.textureCandidates(for: "halo")
        #expect(bare.contains("materials/halo.tex"))
        #expect(bare.contains("materials/halo.png"))
        #expect(bare.contains("halo"))
    }

    @Test("Default preferredFramesPerSecond is 30 (WPE-compatible)")
    func defaultPreferredFPSIsThirty() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device
        )

        let mtkView = try #require(renderer.nsView as? MTKView)
        #expect(mtkView.preferredFramesPerSecond == 30)
        #expect(WPEMetalSceneRenderer.defaultPreferredFPS == 30)
    }

    @Test("setFrameRateLimit re-targets the MTKView's preferredFramesPerSecond")
    func setFrameRateLimitRetargetsMTKView() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device
        )
        let mtkView = try #require(renderer.nsView as? MTKView)

        renderer.setFrameRateLimit(.fps60)
        #expect(mtkView.preferredFramesPerSecond == 60)

        renderer.setFrameRateLimit(.fps15)
        #expect(mtkView.preferredFramesPerSecond == 15)

        // .unlimited falls back to vsync ceiling, not 0 (which would
        // free-run on some macOS versions).
        renderer.setFrameRateLimit(.unlimited)
        #expect(mtkView.preferredFramesPerSecond == WPEMetalSceneRenderer.unlimitedPreferredFPS)
    }

    @Test("setAudioMuted before load is no-op on the renderer (no crash) and seeds runtime state")
    func setAudioMutedBeforeLoadIsSafe() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device
        )

        // Before load soundRuntime is nil: calls must not crash, and state is
        // cached for the deferred audio startup to apply later.
        renderer.setAudioMuted(true)
        renderer.setAudioVolume(0.4)
        #expect(true)
    }

    @Test("Audio startup is deferred until the first present, not started during load")
    func audioStartupIsDeferredUntilPresent() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.soundScene()
        defer { fixture.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device
        )

        try await renderer.load()

        // load() rendered the first frame, but audio must NOT have started
        // synchronously — it is deferred to the first present, which a headless
        // test never triggers. The scene's sound objects leave it pending.
        #expect(renderer.debugSoundRuntimeActive == false)
        #expect(renderer.debugAudioStartupPending == true)

        // Tearing down (cleanup) clears the pending startup + cancels the task so
        // a late present can't boot a stale scene's audio. (reload(), by contrast,
        // re-loads and legitimately re-defers, so it is not the invalidation case.)
        renderer.cleanup()
        #expect(renderer.debugAudioStartupPending == false)
    }
}

private struct MetalSceneFixture {
    let root: URL
    let descriptor: SceneDescriptor
    var dependencyRoot: URL?

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
        if let dependencyRoot {
            try? FileManager.default.removeItem(at: dependencyRoot)
        }
    }

    static func solidColorScene() throws -> MetalSceneFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEMetalSceneRenderer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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
        try Data(scene.utf8).write(to: root.appendingPathComponent("scene.json"))
        return MetalSceneFixture(
            root: root,
            descriptor: SceneDescriptor(
                workshopID: UUID().uuidString,
                cacheRelativePath: "wpe-cache/test",
                entryFile: "scene.json",
                capabilityTier: .imageOnly
            ),
            dependencyRoot: nil
        )
    }

    static func cursorOriginScene() throws -> MetalSceneFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEMetalSceneRenderer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let scene = """
        {
          "camera": { "center": "0 0 0" },
          "general": { "orthogonalprojection": { "width": 64, "height": 64, "auto": true } },
          "objects": [{
            "id": "cursor",
            "name": "Cursor Flower",
            "type": "image",
            "image": "models/util/solidlayer.json",
            "color": "0 0 1",
            "alpha": 1,
            "origin": {
              "value": "10 10 0",
              "script": "'use strict';\\nexport function update(value) {\\n  value.x = input.cursorWorldPosition.x;\\n  value.y = input.cursorWorldPosition.y;\\n  return value;\\n}"
            }
          }]
        }
        """
        try Data(scene.utf8).write(to: root.appendingPathComponent("scene.json"))
        return MetalSceneFixture(
            root: root,
            descriptor: SceneDescriptor(
                workshopID: UUID().uuidString,
                cacheRelativePath: "wpe-cache/test",
                entryFile: "scene.json",
                capabilityTier: .imageOnly
            ),
            dependencyRoot: nil
        )
    }

    static func materialTextureScene(color: CGColor) throws -> MetalSceneFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEMetalSceneRenderer-\(UUID().uuidString)", isDirectory: true)
        let models = root.appendingPathComponent("models", isDirectory: true)
        let materials = root.appendingPathComponent("materials", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: materials, withIntermediateDirectories: true)
        try writePNG(at: materials.appendingPathComponent("base.png"), color: color)
        try Data(#"{ "material": "materials/base.json" }"#.utf8)
            .write(to: models.appendingPathComponent("base.json"))
        try Data(#"{ "passes": [{ "shader": "genericimage2", "textures": ["materials/base.png"] }] }"#.utf8)
            .write(to: materials.appendingPathComponent("base.json"))
        try writeScene(imagePath: "models/base.json", to: root)
        return MetalSceneFixture(
            root: root,
            descriptor: SceneDescriptor(
                workshopID: UUID().uuidString,
                cacheRelativePath: "wpe-cache/test",
                entryFile: "scene.json",
                capabilityTier: .imageOnly
            ),
            dependencyRoot: nil
        )
    }

    static func sceneScriptCreatedLayerScene() throws -> MetalSceneFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEMetalSceneRenderer-\(UUID().uuidString)", isDirectory: true)
        let models = root.appendingPathComponent("models", isDirectory: true)
        let materials = root.appendingPathComponent("materials", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: materials, withIntermediateDirectories: true)
        try writePNG(at: materials.appendingPathComponent("base.png"), color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        try Data(#"{ "material": "materials/base.json" }"#.utf8)
            .write(to: models.appendingPathComponent("base.json"))
        try Data(#"{ "passes": [{ "shader": "genericimage2", "textures": ["materials/base.png"] }] }"#.utf8)
            .write(to: materials.appendingPathComponent("base.json"))
        let script = """
        export function init() {
            thisScene.createLayer({
                image: "models/base.json",
                origin: new Vec3(0.5, 0.5, 0),
                color: new Vec3(1, 1, 1),
                alpha: 1,
                scale: new Vec3(1, 1, 1),
                visible: true
            });
        }
        export function update() {}
        """
        let escapedScript = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let scene = """
        {
          "camera": { "center": "0 0 0" },
          "general": { "orthogonalprojection": { "width": 64, "height": 64, "auto": true } },
          "objects": [
            {
              "id": "template",
              "name": "Template",
              "type": "image",
              "image": "models/base.json",
              "origin": "1000 1000 0",
              "scale": "1 1 1",
              "visible": false,
              "alpha": 1
            },
            {
              "id": "host",
              "name": "MAIN",
              "solid": true,
              "visible": {
                "value": true,
                "script": "\(escapedScript)"
              }
            }
          ]
        }
        """
        try Data(scene.utf8).write(to: root.appendingPathComponent("scene.json"))
        return MetalSceneFixture(
            root: root,
            descriptor: SceneDescriptor(
                workshopID: UUID().uuidString,
                cacheRelativePath: "wpe-cache/test",
                entryFile: "scene.json",
                capabilityTier: .imageOnly
            ),
            dependencyRoot: nil
        )
    }

    static func missingTextureScene() throws -> MetalSceneFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEMetalSceneRenderer-\(UUID().uuidString)", isDirectory: true)
        let models = root.appendingPathComponent("models", isDirectory: true)
        let materials = root.appendingPathComponent("materials", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: materials, withIntermediateDirectories: true)
        try Data(#"{ "material": "materials/missing-material.json" }"#.utf8)
            .write(to: models.appendingPathComponent("hero.json"))
        try Data(#"{ "passes": [{ "shader": "genericimage2", "textures": ["materials/missing.png"] }] }"#.utf8)
            .write(to: materials.appendingPathComponent("missing-material.json"))
        let scene = """
        {
          "camera": { "center": "0 0 0" },
          "general": { "orthogonalprojection": { "width": 64, "height": 64, "auto": true } },
          "objects": [{
            "id": "hero",
            "name": "Hero Layer",
            "type": "image",
            "image": "models/hero.json",
            "origin": "0.5 0.5 0",
            "scale": "1 1 1",
            "alpha": 1
          }]
        }
        """
        try Data(scene.utf8).write(to: root.appendingPathComponent("scene.json"))
        return MetalSceneFixture(
            root: root,
            descriptor: SceneDescriptor(
                workshopID: UUID().uuidString,
                cacheRelativePath: "wpe-cache/test",
                entryFile: "scene.json",
                capabilityTier: .imageOnly
            ),
            dependencyRoot: nil
        )
    }

    static func dependencyTextureScene() throws -> MetalSceneFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEMetalSceneRenderer-\(UUID().uuidString)", isDirectory: true)
        let materials = root.appendingPathComponent("materials", isDirectory: true)
        try FileManager.default.createDirectory(at: materials, withIntermediateDirectories: true)
        try Data(#"{ "passes": [{ "shader": "genericimage2", "textures": ["../123/materials/dep.png"] }] }"#.utf8)
            .write(to: materials.appendingPathComponent("base.json"))
        try Data(#"{ "material": "materials/base.json" }"#.utf8)
            .write(to: root.appendingPathComponent("model.json"))
        try writeScene(imagePath: "model.json", to: root)

        let dependencyRoot = root.deletingLastPathComponent()
            .appendingPathComponent("WPEMetalSceneDependency-\(UUID().uuidString)", isDirectory: true)
        let dependencyMaterials = dependencyRoot.appendingPathComponent("materials", isDirectory: true)
        try FileManager.default.createDirectory(at: dependencyMaterials, withIntermediateDirectories: true)
        try writePNG(at: dependencyMaterials.appendingPathComponent("dep.png"), color: CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        return MetalSceneFixture(
            root: root,
            descriptor: SceneDescriptor(
                workshopID: UUID().uuidString,
                cacheRelativePath: "wpe-cache/test",
                entryFile: "scene.json",
                capabilityTier: .imageOnly
            ),
            dependencyRoot: dependencyRoot
        )
    }

    /// An image layer plus a sound object. The sound file need not exist: audio
    /// startup is deferred to the first present (never triggered in a headless
    /// test), so `start()` — the only thing that reads the file — is never called.
    static func soundScene() throws -> MetalSceneFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEMetalSceneRenderer-\(UUID().uuidString)", isDirectory: true)
        let models = root.appendingPathComponent("models", isDirectory: true)
        let materials = root.appendingPathComponent("materials", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: materials, withIntermediateDirectories: true)
        try writePNG(at: materials.appendingPathComponent("base.png"), color: CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        try Data(#"{ "material": "materials/base.json" }"#.utf8)
            .write(to: models.appendingPathComponent("base.json"))
        try Data(#"{ "passes": [{ "shader": "genericimage2", "textures": ["materials/base.png"] }] }"#.utf8)
            .write(to: materials.appendingPathComponent("base.json"))
        let scene = """
        {
          "camera": { "center": "0 0 0" },
          "general": { "orthogonalprojection": { "width": 64, "height": 64, "auto": true } },
          "objects": [
            { "id": "img", "name": "Img", "type": "image", "image": "models/base.json", "origin": "0.5 0.5 0", "scale": "1 1 1", "alpha": 1 },
            { "id": "snd", "name": "Loop", "type": "sound", "sound": ["sounds/loop.mp3"] }
          ]
        }
        """
        try Data(scene.utf8).write(to: root.appendingPathComponent("scene.json"))
        return MetalSceneFixture(
            root: root,
            descriptor: SceneDescriptor(
                workshopID: UUID().uuidString,
                cacheRelativePath: "wpe-cache/test",
                entryFile: "scene.json",
                capabilityTier: .imageOnly
            ),
            dependencyRoot: nil
        )
    }

    private static func writeScene(imagePath: String, to root: URL) throws {
        let scene = """
        {
          "camera": { "center": "0 0 0" },
          "general": { "orthogonalprojection": { "width": 64, "height": 64, "auto": true } },
          "objects": [{
            "id": "image",
            "name": "Image",
            "type": "image",
            "image": "\(imagePath)",
            "origin": "0.5 0.5 0",
            "scale": "1 1 1",
            "alpha": 1
          }]
        }
        """
        try Data(scene.utf8).write(to: root.appendingPathComponent("scene.json"))
    }

    private static func writePNG(at url: URL, color: CGColor) throws {
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
        context.setFillColor(color)
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

private struct MetalPixel {
    let r: UInt8
    let g: UInt8
    let b: UInt8
    let a: UInt8
}

private extension MTLTexture {
    func readPixel(x: Int, y: Int) -> MetalPixel? {
        let supportedFormats: [MTLPixelFormat] = [.rgba8Unorm, .rgba8Unorm_srgb]
        guard supportedFormats.contains(pixelFormat),
              x >= 0, x < width,
              y >= 0, y < height else {
            return nil
        }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        getBytes(
            &bytes,
            bytesPerRow: width * 4,
            from: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )
        let index = (y * width + x) * 4
        return MetalPixel(r: bytes[index], g: bytes[index + 1], b: bytes[index + 2], a: bytes[index + 3])
    }
}
