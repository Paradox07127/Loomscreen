import CoreGraphics
import Foundation
import ImageIO
import SpriteKit
import Testing
import UniformTypeIdentifiers
@testable import LiveWallpaper

@Suite("SceneRenderingController")
@MainActor
struct SceneRenderingControllerTests {

    @Test("Successful image-only load mounts an SKScene with one sprite per layer")
    func loadImageOnlyMountsSprites() async throws {
        let fixture = try makeFixture(layers: ["a.png", "b.png"])
        defer { fixture.cleanup() }

        let controller = SceneRenderingController(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.cacheRoot,
            frame: CGRect(x: 0, y: 0, width: 200, height: 200)
        )
        try await controller.load()

        let scene = controller.view.scene
        #expect(scene != nil)
        #expect(scene?.children.count == 2)
    }

    @Test("Throttle drops preferredFramesPerSecond to 1 fps")
    func throttleDropsFrameRate() async throws {
        let fixture = try makeFixture(layers: ["a.png"])
        defer { fixture.cleanup() }

        let controller = SceneRenderingController(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.cacheRoot,
            frame: CGRect(x: 0, y: 0, width: 200, height: 200)
        )
        try await controller.load()

        controller.setThrottled(true)
        #expect(controller.view.preferredFramesPerSecond == SceneRenderingController.throttledPreferredFPS)

        controller.setThrottled(false)
        #expect(controller.view.preferredFramesPerSecond == SceneRenderingController.defaultPreferredFPS)
    }

    @Test("Suspended profile pauses the SKScene")
    func suspendedProfilePausesScene() async throws {
        let fixture = try makeFixture(layers: ["a.png"])
        defer { fixture.cleanup() }

        let controller = SceneRenderingController(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.cacheRoot,
            frame: CGRect(x: 0, y: 0, width: 200, height: 200)
        )
        try await controller.load()

        controller.applyPerformanceProfile(.suspended)
        #expect(controller.view.scene?.isPaused == true)

        controller.applyPerformanceProfile(.quality)
        #expect(controller.view.scene?.isPaused == false)
    }

    @Test("Empty cache directory throws entryFileMissing")
    func missingEntryFileThrows() async throws {
        let fixture = try makeFixture(layers: [], includeSceneJSON: false)
        defer { fixture.cleanup() }

        let controller = SceneRenderingController(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.cacheRoot,
            frame: CGRect(x: 0, y: 0, width: 200, height: 200)
        )

        await #expect(throws: SceneRenderingError.self) {
            try await controller.load()
        }
    }

    @Test("Entry file with .. traversal is rejected before any I/O")
    func entryFileTraversalRejected() async throws {
        let fixture = try makeFixture(layers: ["a.png"])
        defer { fixture.cleanup() }

        let descriptor = SceneDescriptor(
            workshopID: fixture.descriptor.workshopID,
            cacheRelativePath: fixture.descriptor.cacheRelativePath,
            entryFile: "../scene.json",
            capabilityTier: .imageOnly
        )
        let controller = SceneRenderingController(
            descriptor: descriptor,
            cacheRootURL: fixture.cacheRoot,
            frame: CGRect(x: 0, y: 0, width: 200, height: 200)
        )

        await #expect(throws: SceneRenderingError.self) {
            try await controller.load()
        }
    }

    @Test("Scene with no resolvable layers throws noRenderableObjects")
    func noResolvableLayersThrows() async throws {
        // Cache contains scene.json but every declared layer references a
        // missing path — controller must throw rather than mount an empty
        // SKScene that the user would interpret as a hung load.
        let fixture = try makeFixture(layers: [], declaredLayers: ["materials/missing.png"])
        defer { fixture.cleanup() }

        let controller = SceneRenderingController(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.cacheRoot,
            frame: CGRect(x: 0, y: 0, width: 200, height: 200)
        )

        await #expect(throws: SceneRenderingError.self) {
            try await controller.load()
        }
    }

    @Test("Scene renderer does not attach ad-hoc SpriteKit actions for WPE shader effects")
    func shaderEffectsDoNotAttachSpriteKitFallbackActions() async throws {
        let fixture = try makeFixture(
            layers: ["a.png"],
            textFiles: [
                "effects/shake/effect.json": """
                {
                    "passes": [{
                        "material": "materials/effects/shake.json"
                    }]
                }
                """,
                "materials/effects/shake.json": """
                {
                    "passes": [{
                        "shader": "effects/shake"
                    }]
                }
                """
            ],
            objectOverrides: [
                """
                {
                    "id": "layer-0",
                    "name": "Layer 0",
                    "type": "image",
                    "image": "materials/a.png",
                    "origin": "0.5 0.5 0",
                    "scale": "1 1 1",
                    "alpha": 1,
                    "effects": [{
                        "id": 1,
                        "name": "Shake",
                        "file": "effects/shake/effect.json",
                        "visible": true,
                        "passes": [{
                            "constantshadervalues": {
                                "speed": 0.59,
                                "strength": 0.133
                            }
                        }]
                    }]
                }
                """
            ]
        )
        defer { fixture.cleanup() }

        let controller = SceneRenderingController(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.cacheRoot,
            frame: CGRect(x: 0, y: 0, width: 200, height: 200)
        )
        try await controller.load()

        let sprite = try #require(controller.view.scene?.childNode(withName: "Layer 0") as? SKSpriteNode)
        #expect(sprite.action(forKey: "wpe.effect.shake") == nil)
    }

    @Test("Scene load builds the WPE render graph for material/effect metadata")
    func loadBuildsWPERenderGraph() async throws {
        let fixture = try makeFixture(
            layers: ["a.png"],
            textFiles: [
                "materials/base.json": """
                {
                    "passes": [{
                        "shader": "genericimage2"
                    }]
                }
                """,
                "effects/custom/effect.json": """
                {
                    "passes": [{
                        "material": "materials/effects/custom.json",
                        "bind": [{ "index": 1, "name": "previous" }]
                    }]
                }
                """,
                "materials/effects/custom.json": """
                {
                    "passes": [{
                        "shader": "effects/custom",
                        "constantshadervalues": { "strength": 0.5 }
                    }]
                }
                """,
                "shaders/effects/custom.vert": """
                attribute vec3 a_Position;
                void main() { gl_Position = vec4(a_Position, 1.0); }
                """,
                "shaders/effects/custom.frag": """
                uniform sampler2D g_Texture0;
                void main() { gl_FragColor = texSample2D(g_Texture0, vec2(0.5)); }
                """
            ],
            objectOverrides: [
                """
                {
                    "id": "layer-graph",
                    "name": "Layer Graph",
                    "type": "image",
                    "image": "materials/a.png",
                    "material": "materials/base.json",
                    "origin": "0.5 0.5 0",
                    "scale": "1 1 1",
                    "alpha": 1,
                    "effects": [{
                        "id": 1,
                        "name": "Custom",
                        "file": "effects/custom/effect.json",
                        "visible": true
                    }]
                }
                """
            ]
        )
        defer { fixture.cleanup() }

        let controller = SceneRenderingController(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.cacheRoot,
            frame: CGRect(x: 0, y: 0, width: 200, height: 200)
        )
        try await controller.load()

        let graph = try #require(controller.renderGraph)
        let layer = try #require(graph.layers.first)
        #expect(layer.passes.map(\.shader) == ["genericimage2", "effects/custom"])
        #expect(layer.passes[1].binds[1] == .previous)

        let pipeline = try #require(controller.renderPipeline)
        let preparedLayer = try #require(pipeline.layers.first)
        #expect(preparedLayer.passes.map(\.pass.shader) == ["genericimage2", "effects/custom"])
        #expect(preparedLayer.passes[0].shader?.isBuiltin == true)
        #expect(preparedLayer.passes[1].shader?.fragmentSource.contains("#define texSample2D") == true)
    }

    @Test("Scene renderer treats WPE angles as radians")
    func sceneRendererUsesRadianAngles() async throws {
        let fixture = try makeFixture(
            layers: ["a.png"],
            objectOverrides: [
                """
                {
                    "id": "layer-radians",
                    "name": "Layer Radians",
                    "type": "image",
                    "image": "materials/a.png",
                    "origin": "0.5 0.5 0",
                    "scale": "1 1 1",
                    "angles": "0 0 1.5707963267948966",
                    "alpha": 1
                }
                """
            ]
        )
        defer { fixture.cleanup() }

        let controller = SceneRenderingController(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.cacheRoot,
            frame: CGRect(x: 0, y: 0, width: 200, height: 200)
        )
        try await controller.load()

        let sprite = try #require(controller.view.scene?.childNode(withName: "Layer Radians") as? SKSpriteNode)
        #expect(abs(sprite.zRotation - CGFloat(Double.pi / 2)) < 0.0001)
    }

    @Test("Scene renderer resolves declared dependency image references")
    func sceneRendererResolvesDeclaredDependencyImageReferences() async throws {
        let fixture = try makeFixture(
            layers: [],
            objectOverrides: [
                """
                {
                    "id": "dependency-layer",
                    "name": "Dependency Layer",
                    "type": "image",
                    "image": "../123/materials/dep.png",
                    "origin": "0.5 0.5 0",
                    "scale": "1 1 1",
                    "alpha": 1
                }
                """
            ]
        )
        defer { fixture.cleanup() }
        let dependencyRoot = fixture.root.appendingPathComponent("dependency-123", isDirectory: true)
        let dependencyMaterials = dependencyRoot.appendingPathComponent("materials", isDirectory: true)
        try FileManager.default.createDirectory(at: dependencyMaterials, withIntermediateDirectories: true)
        try writePNG(at: dependencyMaterials.appendingPathComponent("dep.png"))

        let controller = SceneRenderingController(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.cacheRoot,
            dependencyMounts: [WPEAssetMount(workshopID: "123", rootURL: dependencyRoot)],
            frame: CGRect(x: 0, y: 0, width: 200, height: 200)
        )
        try await controller.load()

        let sprite = controller.view.scene?.childNode(withName: "Dependency Layer") as? SKSpriteNode
        #expect(sprite != nil)
    }

    // MARK: - Fixture

    private struct Fixture {
        let root: URL
        let cacheRoot: URL
        let descriptor: SceneDescriptor

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeFixture(
        layers: [String],
        declaredLayers: [String]? = nil,
        textFiles: [String: String] = [:],
        objectOverrides: [String]? = nil,
        includeSceneJSON: Bool = true
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SceneRenderingControllerTests-\(UUID().uuidString)", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("wpe-cache/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)

        // Materials live one folder deep so we exercise the resolver's
        // subdirectory standardization path.
        let materials = cacheRoot.appendingPathComponent("materials", isDirectory: true)
        try FileManager.default.createDirectory(at: materials, withIntermediateDirectories: true)
        for layer in layers {
            try writePNG(at: materials.appendingPathComponent(layer))
        }
        for (relativePath, contents) in textFiles {
            let fileURL = cacheRoot.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: fileURL)
        }

        if includeSceneJSON {
            let objects: String
            if let objectOverrides {
                objects = objectOverrides.joined(separator: ",\n")
            } else {
                let layerJSONPaths = (declaredLayers ?? layers.map { "materials/\($0)" })
                objects = layerJSONPaths.enumerated().map { index, path in
                    """
                    {
                        "id": "layer-\(index)",
                        "name": "Layer \(index)",
                        "type": "image",
                        "image": "\(path)",
                        "origin": "0.5 0.5 0",
                        "scale": "1 1 1",
                        "alpha": 1,
                        "blendmode": "normal"
                    }
                    """
                }.joined(separator: ",\n")
            }

            let json = """
            {
                "camera": { "center": "0 0 0" },
                "general": {
                    "orthogonalprojection": { "width": 200, "height": 200, "auto": true }
                },
                "objects": [\(objects)]
            }
            """
            try Data(json.utf8).write(to: cacheRoot.appendingPathComponent("scene.json"))
        }

        let descriptor = SceneDescriptor(
            workshopID: cacheRoot.lastPathComponent,
            cacheRelativePath: "wpe-cache/\(cacheRoot.lastPathComponent)",
            entryFile: "scene.json",
            capabilityTier: .imageOnly
        )
        return Fixture(root: root, cacheRoot: cacheRoot, descriptor: descriptor)
    }

    private func writePNG(at url: URL) throws {
        guard let context = CGContext(
            data: nil,
            width: 8,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw NSError(domain: "fixture", code: -1) }
        context.setFillColor(CGColor(red: 1, green: 0.5, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        guard let image = context.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "fixture", code: -2)
        }
        CGImageDestinationAddImage(dest, image, nil)
        if !CGImageDestinationFinalize(dest) {
            throw NSError(domain: "fixture", code: -3)
        }
    }
}
