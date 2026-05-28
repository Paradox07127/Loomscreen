import Foundation
import Testing
@testable import LiveWallpaper

@Suite("WPE render graph builder")
struct WPERenderGraphBuilderTests {
    @Test("Builds material and effect passes from WPE asset JSON without effect-name fallbacks")
    func buildsMaterialAndEffectPassGraph() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPERenderGraphBuilderTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try writeJSON(["material": "materials/layer.json"], to: root.appendingPathComponent("models/layer.json"))
        try writeJSON([
            "passes": [[
                "shader": "genericimage2",
                "blending": "translucent",
                "combos": ["VERSION": 2],
                "textures": ["layer_albedo"]
            ]]
        ], to: root.appendingPathComponent("materials/layer.json"))
        try writeJSON([
            "passes": [[
                "material": "materials/effects/custom.json",
                "target": "_rt_CustomBuffer",
                "bind": [["index": 0, "name": "previous"]]
            ]],
            "fbos": [[
                "name": "_rt_CustomBuffer",
                "scale": 4,
                "format": "rgba_backbuffer",
                "unique": true
            ]]
        ], to: root.appendingPathComponent("effects/custom/effect.json"))
        try writeJSON([
            "passes": [[
                "shader": "effects/custom",
                "textures": [NSNull(), "effects/noise"],
                "constantshadervalues": ["base": 0.25],
                "combos": ["LOCAL": 1]
            ]]
        ], to: root.appendingPathComponent("materials/effects/custom.json"))

        let scenePayload: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 1920, "height": 1080, "auto": true]],
            "objects": [[
                "id": 7,
                "name": "Layer",
                "type": "image",
                "image": "models/layer.json",
                "effects": [[
                    "id": 3,
                    "name": "NotASpecialCase",
                    "file": "effects/custom/effect.json",
                    "passes": [[
                        "combos": ["OVERRIDE": 1],
                        "constantshadervalues": ["strength": 0.75],
                        "textures": [NSNull(), "masks/custom_mask"]
                    ]]
                ]]
            ]]
        ]
        let sceneData = try JSONSerialization.data(withJSONObject: scenePayload)
        let document = try WPESceneDocumentParser.parse(data: sceneData)

        let graph = try WPERenderGraphBuilder(cacheRootURL: root).build(document: document)

        let layer = try #require(graph.layers.first)
        #expect(layer.objectID == "7")
        #expect(layer.materialPath == "materials/layer.json")
        #expect(layer.localFBOs == [
            WPERenderFBO(name: "_rt_CustomBuffer", scale: 4, format: "rgba_backbuffer", unique: true)
        ])
        #expect(layer.passes.map(\.shader) == ["genericimage2", "effects/custom"])
        #expect(layer.passes[0].phase == .material)
        #expect(layer.passes[0].source == .asset("layer_albedo"))
        #expect(layer.passes[0].textures[0] == .asset("layer_albedo"))
        #expect(layer.passes[0].target == .layerComposite(name: "_rt_imageLayerComposite_7_a"))

        let effectPass = layer.passes[1]
        #expect(effectPass.phase == .effect(file: "effects/custom/effect.json"))
        #expect(effectPass.binds[0] == .previous)
        #expect(effectPass.textures[1] == .asset("masks/custom_mask"))
        #expect(effectPass.combos["LOCAL"] == 1)
        #expect(effectPass.combos["OVERRIDE"] == 1)
        #expect(effectPass.constants["base"]?.numberValue == 0.25)
        #expect(effectPass.constants["strength"]?.numberValue == 0.75)
        #expect(effectPass.target == .fbo(name: "_rt_CustomBuffer"))
    }

    @Test("Final pass without an explicit target composites to the scene framebuffer")
    func finalUntargetedPassTargetsScene() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPERenderGraphBuilderTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try writeJSON(["material": "materials/layer.json"], to: root.appendingPathComponent("models/layer.json"))
        try writeJSON([
            "passes": [[
                "shader": "genericimage2",
                "textures": ["layer_albedo"]
            ]]
        ], to: root.appendingPathComponent("materials/layer.json"))
        try writeJSON([
            "passes": [[
                "material": "materials/effects/final.json",
                "bind": [["index": 0, "name": "previous"]]
            ]]
        ], to: root.appendingPathComponent("effects/final/effect.json"))
        try writeJSON([
            "passes": [[
                "shader": "effects/final"
            ]]
        ], to: root.appendingPathComponent("materials/effects/final.json"))

        let scenePayload: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 1920, "height": 1080, "auto": true]],
            "objects": [[
                "id": "layer",
                "name": "Layer",
                "type": "image",
                "image": "models/layer.json",
                "effects": [[
                    "id": 1,
                    "file": "effects/final/effect.json"
                ]]
            ]]
        ]
        let sceneData = try JSONSerialization.data(withJSONObject: scenePayload)
        let document = try WPESceneDocumentParser.parse(data: sceneData)

        let graph = try WPERenderGraphBuilder(cacheRootURL: root).build(document: document)

        let layer = try #require(graph.layers.first)
        #expect(layer.passes.map(\.shader) == ["genericimage2", "effects/final"])
        #expect(layer.passes[0].target == .layerComposite(name: "_rt_imageLayerComposite_layer_a"))
        #expect(layer.passes[1].binds[0] == .previous)
        #expect(layer.passes[1].target == .scene)
    }

    @Test("Builds built-in solid layer model without requiring packaged model JSON")
    func buildsBuiltinSolidLayerModel() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPERenderGraphBuilderTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let scenePayload: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 1920, "height": 1080, "auto": true]],
            "objects": [[
                "id": 384,
                "name": "Solid",
                "type": "image",
                "image": "models/util/solidlayer.json",
                "alpha": 0.5,
                "brightness": 0.8,
                "color": "1 0.5 0.25"
            ]]
        ]
        let sceneData = try JSONSerialization.data(withJSONObject: scenePayload)
        let document = try WPESceneDocumentParser.parse(data: sceneData)

        let graph = try WPERenderGraphBuilder(cacheRootURL: root).build(document: document)

        let layer = try #require(graph.layers.first)
        let pass = try #require(layer.passes.first)

        #expect(layer.materialPath == "models/util/solidlayer.json")
        #expect(pass.shader == "solidcolor")
        #expect(pass.target == .scene)
        #expect(pass.constants["g_Color"]?.vectorValue == [0.8, 0.4, 0.2, 0.5])
    }

    @Test("Moves the first pass blend mode onto the final scene pass")
    func movesFirstPassBlendModeToFinalScenePass() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPERenderGraphBuilderTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try writeJSON(["material": "materials/base.json"], to: root.appendingPathComponent("models/layer.json"))
        try writeJSON([
            "passes": [[
                "shader": "genericimage2",
                "blending": "translucent"
            ]]
        ], to: root.appendingPathComponent("materials/base.json"))
        try writeJSON([
            "passes": [[
                "material": "materials/effects/final.json",
                "bind": [["index": 0, "name": "previous"]]
            ]]
        ], to: root.appendingPathComponent("effects/final/effect.json"))
        try writeJSON([
            "passes": [[
                "shader": "effects/final",
                "blending": "normal"
            ]]
        ], to: root.appendingPathComponent("materials/effects/final.json"))

        let scenePayload: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 1920, "height": 1080, "auto": true]],
            "objects": [[
                "id": "blend-layer",
                "name": "Blend Layer",
                "type": "image",
                "image": "models/layer.json",
                "effects": [[
                    "id": 1,
                    "file": "effects/final/effect.json"
                ]]
            ]]
        ]
        let sceneData = try JSONSerialization.data(withJSONObject: scenePayload)
        let document = try WPESceneDocumentParser.parse(data: sceneData)

        let graph = try WPERenderGraphBuilder(cacheRootURL: root).build(document: document)
        let layer = try #require(graph.layers.first)

        #expect(layer.passes.map(\.blending) == ["normal", "translucent"])
        #expect(layer.passes[1].target == .scene)
    }

    @Test("Render graph preserves image object parallax depth on layer")
    func renderGraphPreservesParallaxDepth() throws {
        let object = WPESceneImageObject(
            id: "hero",
            name: "Hero",
            imageRelativePath: "materials/hero.png",
            materialRelativePath: nil,
            origin: SIMD3<Double>(0, 0, 0),
            scale: SIMD3<Double>(1, 1, 1),
            angles: SIMD3<Double>(0, 0, 0),
            visible: true,
            alpha: 1,
            color: SIMD3<Double>(1, 1, 1),
            brightness: 1,
            blendMode: .normal,
            alignment: .center,
            size: nil,
            effects: [],
            animationLayers: [],
            parallaxDepth: 0.2
        )
        let document = WPESceneDocument(
            camera: .defaultCamera,
            general: .defaultGeneral,
            imageObjects: [object],
            diagnostics: []
        )

        let graph = try WPERenderGraphBuilder(
            cacheRootURL: FileManager.default.temporaryDirectory
        ).build(document: document)

        #expect(graph.layers.first?.parallaxDepth == 0.2)
    }

    @Test("Underscore-prefixed texture refs route through .fbo regardless of suffix")
    func underscorePrefixTexturesRouteToFBO() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPERenderGraphBuilderTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try writeJSON(["material": "materials/layer.json"], to: root.appendingPathComponent("models/layer.json"))
        try writeJSON([
            "passes": [[
                "shader": "compose",
                "textures": ["_downscaled1", "_alias_x", "_rt_FullFrameBuffer"]
            ]]
        ], to: root.appendingPathComponent("materials/layer.json"))

        let object = WPESceneImageObject(
            id: "hero",
            name: "Hero",
            imageRelativePath: "models/layer.json",
            materialRelativePath: nil,
            origin: SIMD3<Double>(0, 0, 0),
            scale: SIMD3<Double>(1, 1, 1),
            angles: SIMD3<Double>(0, 0, 0),
            visible: true,
            alpha: 1,
            color: SIMD3<Double>(1, 1, 1),
            brightness: 1,
            blendMode: .normal,
            alignment: .center,
            size: nil,
            effects: [],
            animationLayers: [],
            parallaxDepth: 0
        )
        let document = WPESceneDocument(
            camera: .defaultCamera,
            general: .defaultGeneral,
            imageObjects: [object],
            diagnostics: []
        )

        let graph = try WPERenderGraphBuilder(cacheRootURL: root).build(document: document)
        let pass = try #require(graph.layers.first?.passes.first)
        #expect(pass.textures[0] == .fbo("_downscaled1"))
        #expect(pass.textures[1] == .fbo("_alias_x"))
        #expect(pass.textures[2] == .fbo("_rt_FullFrameBuffer"))
    }

    @Test("Effect-declared FBO refs route through .fbo even without underscore prefix")
    func declaredEffectFBOTexturesRouteToFBO() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPERenderGraphBuilderTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try writeJSON(["material": "materials/layer.json"], to: root.appendingPathComponent("models/layer.json"))
        try writeJSON([
            "passes": [[
                "shader": "genericimage2",
                "textures": ["layer_albedo"]
            ]]
        ], to: root.appendingPathComponent("materials/layer.json"))
        try writeJSON([
            "fbos": [[
                "name": "blur_start_2",
                "scale": 0.5,
                "format": "rgba8888",
                "unique": false
            ]],
            "passes": [
                [
                    "material": "materials/effects/write_blur.json",
                    "target": "blur_start_2",
                    "bind": [["index": 0, "name": "previous"]]
                ],
                [
                    "material": "materials/effects/read_blur.json",
                    "bind": [["index": 0, "name": "blur_start_2"]]
                ]
            ]
        ], to: root.appendingPathComponent("effects/blur/effect.json"))
        try writeJSON([
            "passes": [[
                "shader": "effects/write_blur"
            ]]
        ], to: root.appendingPathComponent("materials/effects/write_blur.json"))
        try writeJSON([
            "passes": [[
                "shader": "effects/read_blur"
            ]]
        ], to: root.appendingPathComponent("materials/effects/read_blur.json"))

        let scenePayload: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 1920, "height": 1080, "auto": true]],
            "objects": [[
                "id": "layer",
                "name": "Layer",
                "type": "image",
                "image": "models/layer.json",
                "effects": [[
                    "id": 1,
                    "file": "effects/blur/effect.json"
                ]]
            ]]
        ]
        let sceneData = try JSONSerialization.data(withJSONObject: scenePayload)
        let document = try WPESceneDocumentParser.parse(data: sceneData)

        let graph = try WPERenderGraphBuilder(cacheRootURL: root).build(document: document)
        let layer = try #require(graph.layers.first)

        #expect(layer.localFBOs == [
            WPERenderFBO(name: "blur_start_2", scale: 0.5, format: "rgba8888", unique: false)
        ])
        #expect(layer.passes[1].target == .fbo(name: "blur_start_2"))
        #expect(layer.passes[2].binds[0] == .fbo("blur_start_2"))
    }

    private func writeJSON(_ object: Any, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        try data.write(to: url)
    }
}
