import CoreGraphics
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

    @Test("Model puppet path is preserved on render layer")
    func modelPuppetPathIsPreservedOnRenderLayer() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPERenderGraphBuilderTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try writeJSON([
            "material": "materials/layer.json",
            "puppet": "models/layer_puppet.mdl"
        ], to: root.appendingPathComponent("models/layer.json"))
        try writeJSON([
            "passes": [[
                "shader": "genericimage4",
                "textures": ["layer_albedo"]
            ]]
        ], to: root.appendingPathComponent("materials/layer.json"))

        let scenePayload: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 1920, "height": 1080, "auto": true]],
            "objects": [[
                "id": "layer",
                "name": "Layer",
                "type": "image",
                "image": "models/layer.json"
            ]]
        ]
        let sceneData = try JSONSerialization.data(withJSONObject: scenePayload)
        let document = try WPESceneDocumentParser.parse(data: sceneData)

        let graph = try WPERenderGraphBuilder(cacheRootURL: root).build(document: document)
        let layer = try #require(graph.layers.first)

        #expect(layer.materialPath == "materials/layer.json")
        #expect(layer.puppetPath == "models/layer_puppet.mdl")
        #expect(layer.passes.map(\.target) == [
            .layerComposite(name: "_rt_imageLayerComposite_layer_a"),
            .scene
        ])
        #expect(layer.passes[0].phase == .material)
        let scenePass = try #require(layer.passes.dropFirst().first)
        #expect(scenePass.phase == .command(file: "materials/util/copy.json"))
        #expect(scenePass.source == .fbo("_rt_imageLayerComposite_layer_a"))
    }

    @Test("Hidden image dependencies still write composites without drawing to scene")
    func hiddenImageDependenciesWriteCompositeOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPERenderGraphBuilderTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try writeJSON(["material": "materials/dependency.json"], to: root.appendingPathComponent("models/dependency.json"))
        try writeJSON(["material": "materials/visible.json"], to: root.appendingPathComponent("models/visible.json"))
        try writeJSON([
            "passes": [[
                "shader": "genericimage2",
                "textures": ["dependency_albedo"]
            ]]
        ], to: root.appendingPathComponent("materials/dependency.json"))
        try writeJSON([
            "passes": [[
                "shader": "genericimage2",
                "textures": ["visible_albedo"]
            ]]
        ], to: root.appendingPathComponent("materials/visible.json"))
        try writeJSON([
            "passes": [[
                "material": "materials/effects/blend.json",
                "bind": [["index": 0, "name": "previous"]]
            ]]
        ], to: root.appendingPathComponent("effects/blend/effect.json"))
        try writeJSON([
            "passes": [[
                "shader": "effects/blend",
                "textures": [NSNull(), "_rt_imageLayerComposite_14942_a"]
            ]]
        ], to: root.appendingPathComponent("materials/effects/blend.json"))

        let scenePayload: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 1920, "height": 1080, "auto": true]],
            "objects": [
                [
                    "id": 14942,
                    "name": "Dependency",
                    "type": "image",
                    "image": "models/dependency.json",
                    "visible": false
                ],
                [
                    "id": 4604,
                    "name": "Visible",
                    "type": "image",
                    "image": "models/visible.json",
                    "dependencies": [14942],
                    "effects": [[
                        "id": 4607,
                        "file": "effects/blend/effect.json",
                        "passes": [[
                            "textures": [NSNull(), "_rt_imageLayerComposite_14942_a"]
                        ]]
                    ]]
                ]
            ]
        ]
        let sceneData = try JSONSerialization.data(withJSONObject: scenePayload)
        let document = try WPESceneDocumentParser.parse(data: sceneData)

        #expect(document.imageObjects[1].dependencies == ["14942"])

        let graph = try WPERenderGraphBuilder(cacheRootURL: root).build(document: document)

        #expect(graph.layers.map(\.objectID) == ["14942", "4604"])
        let dependencyLayer = try #require(graph.layers.first)
        let visibleLayer = try #require(graph.layers.dropFirst().first)
        #expect(dependencyLayer.passes.map(\.target) == [
            .layerComposite(name: "_rt_imageLayerComposite_14942_a")
        ])
        #expect(visibleLayer.passes.last?.textures[1] == .fbo("_rt_imageLayerComposite_14942_a"))
        #expect(visibleLayer.passes.last?.target == .scene)
    }

    @Test("Visible image dependencies keep composites before drawing to scene")
    func visibleImageDependenciesKeepCompositeThenDrawScene() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPERenderGraphBuilderTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try writeJSON(["material": "materials/mask.json"], to: root.appendingPathComponent("models/mask.json"))
        try writeJSON(["material": "materials/visible.json"], to: root.appendingPathComponent("models/visible.json"))
        try writeJSON([
            "passes": [[
                "shader": "genericimage2",
                "textures": ["mask_albedo"],
                "blending": "translucent"
            ]]
        ], to: root.appendingPathComponent("materials/mask.json"))
        try writeJSON([
            "passes": [[
                "shader": "genericimage2",
                "textures": ["visible_albedo"]
            ]]
        ], to: root.appendingPathComponent("materials/visible.json"))
        try writeJSON([
            "passes": [[
                "material": "materials/effects/masked.json",
                "bind": [["index": 0, "name": "previous"]]
            ]]
        ], to: root.appendingPathComponent("effects/masked/effect.json"))
        try writeJSON([
            "passes": [[
                "shader": "effects/masked",
                "textures": [NSNull(), "_rt_imageLayerComposite_16613_a"]
            ]]
        ], to: root.appendingPathComponent("materials/effects/masked.json"))

        let scenePayload: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 1920, "height": 1080, "auto": true]],
            "objects": [
                [
                    "id": 16613,
                    "name": "Visible Mask",
                    "type": "image",
                    "image": "models/mask.json"
                ],
                [
                    "id": 4149,
                    "name": "Masked Layer",
                    "type": "image",
                    "image": "models/visible.json",
                    "dependencies": [16613],
                    "effects": [[
                        "id": 1317,
                        "file": "effects/masked/effect.json",
                        "passes": [[
                            "textures": [NSNull(), "_rt_imageLayerComposite_16613_a"]
                        ]]
                    ]]
                ]
            ]
        ]
        let sceneData = try JSONSerialization.data(withJSONObject: scenePayload)
        let document = try WPESceneDocumentParser.parse(data: sceneData)

        let graph = try WPERenderGraphBuilder(cacheRootURL: root).build(document: document)

        #expect(graph.layers.map(\.objectID) == ["16613", "4149"])
        let maskLayer = try #require(graph.layers.first)
        let maskedLayer = try #require(graph.layers.dropFirst().first)

        #expect(maskLayer.passes.map(\.target) == [
            .layerComposite(name: "_rt_imageLayerComposite_16613_a"),
            .scene
        ])
        let compositePass = try #require(maskLayer.passes.first)
        let scenePass = try #require(maskLayer.passes.dropFirst().first)
        #expect(compositePass.blending == "normal")
        #expect(scenePass.shader == "materials/util/copy.json")
        #expect(scenePass.source == .fbo("_rt_imageLayerComposite_16613_a"))
        #expect(scenePass.textures[0] == .fbo("_rt_imageLayerComposite_16613_a"))
        #expect(scenePass.blending == "translucent")
        #expect(maskedLayer.passes.last?.textures[1] == .fbo("_rt_imageLayerComposite_16613_a"))
        #expect(maskedLayer.passes.last?.target == .scene)
    }

    @Test("Composite dependency producer is emitted before an earlier consumer")
    func compositeDependencyProducerIsEmittedBeforeEarlierConsumer() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPERenderGraphBuilderTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try writeJSON(["material": "materials/consumer.json"], to: root.appendingPathComponent("models/consumer.json"))
        try writeJSON(["material": "materials/producer.json"], to: root.appendingPathComponent("models/producer.json"))
        try writeJSON([
            "passes": [[
                "shader": "genericimage2",
                "textures": ["consumer_albedo"]
            ]]
        ], to: root.appendingPathComponent("materials/consumer.json"))
        try writeJSON([
            "passes": [[
                "shader": "genericimage2",
                "textures": ["producer_albedo"]
            ]]
        ], to: root.appendingPathComponent("materials/producer.json"))
        try writeJSON([
            "passes": [[
                "material": "materials/effects/read_composite.json",
                "bind": [["index": 0, "name": "previous"]]
            ]]
        ], to: root.appendingPathComponent("effects/read_composite/effect.json"))
        try writeJSON([
            "passes": [[
                "shader": "effects/read_composite",
                "textures": [NSNull(), "_rt_imageLayerComposite_411_a"]
            ]]
        ], to: root.appendingPathComponent("materials/effects/read_composite.json"))

        let scenePayload: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 1920, "height": 1080, "auto": true]],
            "objects": [
                [
                    "id": 1111,
                    "name": "Consumer",
                    "type": "image",
                    "image": "models/consumer.json",
                    "effects": [[
                        "id": 1,
                        "file": "effects/read_composite/effect.json",
                        "passes": [[
                            "textures": [NSNull(), "_rt_imageLayerComposite_411_a"]
                        ]]
                    ]]
                ],
                [
                    "id": 411,
                    "name": "Producer",
                    "type": "image",
                    "image": "models/producer.json"
                ]
            ]
        ]
        let sceneData = try JSONSerialization.data(withJSONObject: scenePayload)
        let document = try WPESceneDocumentParser.parse(data: sceneData)

        let graph = try WPERenderGraphBuilder(cacheRootURL: root).build(document: document)
        let ids = graph.layers.map(\.objectID)

        #expect(ids == ["411", "1111"])
        let producerIndex = try #require(ids.firstIndex(of: "411"))
        let consumerIndex = try #require(ids.firstIndex(of: "1111"))
        #expect(producerIndex < consumerIndex)
        #expect(graph.layers.last?.passes.last?.textures[1] == .fbo("_rt_imageLayerComposite_411_a"))
    }

    @Test("Unrelated image layers keep their original scene order")
    func unrelatedImageLayersKeepOriginalSceneOrder() throws {
        let document = WPESceneDocument(
            camera: .defaultCamera,
            general: .defaultGeneral,
            imageObjects: [
                plainImageObject(id: "first"),
                plainImageObject(id: "second"),
                plainImageObject(id: "third")
            ],
            diagnostics: []
        )

        let graph = try WPERenderGraphBuilder(
            cacheRootURL: FileManager.default.temporaryDirectory
        ).build(document: document)

        #expect(graph.layers.map(\.objectID) == ["first", "second", "third"])
    }

    @Test("Composite dependency cycle keeps all layers in deterministic scene order")
    func compositeDependencyCycleKeepsAllLayersInDeterministicSceneOrder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPERenderGraphBuilderTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try writeJSON(["material": "materials/a.json"], to: root.appendingPathComponent("models/a.json"))
        try writeJSON(["material": "materials/b.json"], to: root.appendingPathComponent("models/b.json"))
        try writeJSON([
            "passes": [[
                "shader": "genericimage2",
                "textures": ["a_albedo"]
            ]]
        ], to: root.appendingPathComponent("materials/a.json"))
        try writeJSON([
            "passes": [[
                "shader": "genericimage2",
                "textures": ["b_albedo"]
            ]]
        ], to: root.appendingPathComponent("materials/b.json"))
        try writeJSON([
            "passes": [[
                "material": "materials/effects/read_composite.json",
                "bind": [["index": 0, "name": "previous"]]
            ]]
        ], to: root.appendingPathComponent("effects/read_composite/effect.json"))
        try writeJSON([
            "passes": [[
                "shader": "effects/read_composite"
            ]]
        ], to: root.appendingPathComponent("materials/effects/read_composite.json"))

        let scenePayload: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 1920, "height": 1080, "auto": true]],
            "objects": [
                [
                    "id": "A",
                    "name": "A",
                    "type": "image",
                    "image": "models/a.json",
                    "effects": [[
                        "id": 1,
                        "file": "effects/read_composite/effect.json",
                        "passes": [[
                            "textures": [NSNull(), "_rt_imageLayerComposite_B_a"]
                        ]]
                    ]]
                ],
                [
                    "id": "B",
                    "name": "B",
                    "type": "image",
                    "image": "models/b.json",
                    "effects": [[
                        "id": 2,
                        "file": "effects/read_composite/effect.json",
                        "passes": [[
                            "textures": [NSNull(), "_rt_imageLayerComposite_A_a"]
                        ]]
                    ]]
                ]
            ]
        ]
        let sceneData = try JSONSerialization.data(withJSONObject: scenePayload)
        let document = try WPESceneDocumentParser.parse(data: sceneData)

        let graph = try WPERenderGraphBuilder(cacheRootURL: root).build(document: document)

        #expect(Set(graph.layers.map(\.objectID)) == Set(["A", "B"]))
        #expect(graph.layers.map(\.objectID) == ["A", "B"])
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

    @Test("Render graph preserves image object geometry on layer")
    func renderGraphPreservesImageObjectGeometry() throws {
        let object = WPESceneImageObject(
            id: "hero",
            name: "Hero",
            imageRelativePath: "materials/hero.png",
            materialRelativePath: nil,
            origin: SIMD3<Double>(120, 240, 3),
            scale: SIMD3<Double>(1.5, 0.75, 1),
            angles: SIMD3<Double>(0.1, 0.2, 0.3),
            visible: true,
            alpha: 0.65,
            color: SIMD3<Double>(0.25, 0.5, 0.75),
            brightness: 1.25,
            blendMode: .translucent,
            alignment: .bottomRight,
            size: CGSize(width: 320, height: 180),
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

        let geometry = try #require(graph.layers.first?.geometry)
        #expect(geometry.origin == SIMD3<Double>(120, 240, 3))
        #expect(geometry.scale == SIMD3<Double>(1.5, 0.75, 1))
        #expect(geometry.angles == SIMD3<Double>(0.1, 0.2, 0.3))
        #expect(geometry.alignment == .bottomRight)
        #expect(geometry.size == CGSize(width: 320, height: 180))
        #expect(geometry.alpha == 0.65)
        #expect(geometry.color == SIMD3<Double>(0.25, 0.5, 0.75))
        #expect(geometry.brightness == 1.25)
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

    @Test("Puppet cropoffset expands geometry and stores inverse vertex offset")
    func puppetCropOffsetExpandsGeometryAndStoresInverseVertexOffset() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPERenderGraphBuilderTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try writePuppetModelJSON(
            root: root,
            path: "models/fll.json",
            puppetPath: "models/fll_puppet.mdl",
            cropOffset: "-170 183"
        )
        try writePuppetFixture(
            vertices: frierenPuppetBoundsVertices(),
            to: root.appendingPathComponent("models/fll_puppet.mdl")
        )

        let graph = try buildPuppetFixtureGraph(
            root: root,
            modelPath: "models/fll.json",
            objectID: "22",
            size: "4028 2263"
        )
        let layer = try #require(graph.layers.first)

        #expect(layer.objectID == "22")
        #expect(layer.puppetPath == "models/fll_puppet.mdl")
        #expect(layer.geometry.size == CGSize(width: 4028, height: 3498))
        #expect(layer.geometry.puppetVertexOffset == SIMD2<Double>(170, -183))
    }

    @Test("Puppet bounds are no-op when cropoffset is absent and declared size contains mesh")
    func puppetBoundsNoOpWhenDefaultCropOffsetFitsDeclaredSize() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPERenderGraphBuilderTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try writePuppetModelJSON(
            root: root,
            path: "models/person.json",
            puppetPath: "models/person_puppet.mdl",
            cropOffset: nil
        )
        try writePuppetFixture(
            vertices: [
                (position: SIMD3<Float>(-800, -900, 0), uv: SIMD2<Float>(0, 1)),
                (position: SIMD3<Float>(800, -900, 0), uv: SIMD2<Float>(1, 1)),
                (position: SIMD3<Float>(-800, 900, 0), uv: SIMD2<Float>(0, 0)),
                (position: SIMD3<Float>(800, 900, 0), uv: SIMD2<Float>(1, 0))
            ],
            to: root.appendingPathComponent("models/person_puppet.mdl")
        )

        let graph = try buildPuppetFixtureGraph(
            root: root,
            modelPath: "models/person.json",
            objectID: "person",
            size: "2000 2000"
        )
        let layer = try #require(graph.layers.first)

        #expect(layer.geometry.size == CGSize(width: 2000, height: 2000))
        #expect(layer.geometry.puppetVertexOffset == SIMD2<Double>(0, 0))
    }

    @Test("Frieren puppet vertices fit clip space after cropoffset and effective size")
    func frierenPuppetVerticesFitClipSpaceAfterCropOffsetAndEffectiveSize() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPERenderGraphBuilderTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let vertices = frierenPuppetBoundsVertices()
        try writePuppetModelJSON(
            root: root,
            path: "models/fll.json",
            puppetPath: "models/fll_puppet.mdl",
            cropOffset: "-170 183"
        )
        try writePuppetFixture(
            vertices: vertices,
            to: root.appendingPathComponent("models/fll_puppet.mdl")
        )

        let graph = try buildPuppetFixtureGraph(
            root: root,
            modelPath: "models/fll.json",
            objectID: "22",
            size: "4028 2263"
        )
        let layer = try #require(graph.layers.first)
        let size = try #require(layer.geometry.size)
        let halfSize = SIMD2<Double>(Double(size.width) * 0.5, Double(size.height) * 0.5)

        for vertex in vertices {
            let corrected = SIMD2<Double>(
                Double(vertex.position.x) + layer.geometry.puppetVertexOffset.x,
                Double(vertex.position.y) + layer.geometry.puppetVertexOffset.y
            )
            let clip = corrected / halfSize
            #expect(clip.x >= -1 && clip.x <= 1)
            #expect(clip.y >= -1 && clip.y <= 1)
        }
    }

    private func plainImageObject(id: String) -> WPESceneImageObject {
        WPESceneImageObject(
            id: id,
            name: id,
            imageRelativePath: "materials/\(id).png",
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
    }

    private func writeJSON(_ object: Any, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        try data.write(to: url)
    }

    private func buildPuppetFixtureGraph(
        root: URL,
        modelPath: String,
        objectID: String,
        size: String
    ) throws -> WPERenderGraph {
        let scenePayload: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 1920, "height": 1080, "auto": true]],
            "objects": [[
                "id": objectID,
                "name": objectID,
                "type": "image",
                "image": modelPath,
                "size": size
            ]]
        ]
        let sceneData = try JSONSerialization.data(withJSONObject: scenePayload)
        let document = try WPESceneDocumentParser.parse(data: sceneData)
        return try WPERenderGraphBuilder(cacheRootURL: root).build(document: document)
    }

    private func writePuppetModelJSON(
        root: URL,
        path: String,
        puppetPath: String,
        cropOffset: String?
    ) throws {
        var modelJSON: [String: Any] = [
            "material": "materials/puppet.json",
            "puppet": puppetPath,
            "autosize": true
        ]
        if let cropOffset {
            modelJSON["cropoffset"] = cropOffset
        }
        try writeJSON(modelJSON, to: root.appendingPathComponent(path))
        try writeJSON([
            "passes": [[
                "shader": "genericimage4",
                "textures": ["models/puppet_d"]
            ]]
        ], to: root.appendingPathComponent("materials/puppet.json"))
    }

    private func writePuppetFixture(
        vertices: [(position: SIMD3<Float>, uv: SIMD2<Float>)],
        to url: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try makePuppetModelData(vertices: vertices).write(to: url)
    }

    private func frierenPuppetBoundsVertices() -> [(position: SIMD3<Float>, uv: SIMD2<Float>)] {
        [
            (position: SIMD3<Float>(-1865, -1566, 0), uv: SIMD2<Float>(0, 1)),
            (position: SIMD3<Float>(-60, -1566, 0), uv: SIMD2<Float>(1, 1)),
            (position: SIMD3<Float>(-1865, 549, 0), uv: SIMD2<Float>(0, 0)),
            (position: SIMD3<Float>(-60, 549, 0), uv: SIMD2<Float>(1, 0))
        ]
    }

    private func makePuppetModelData(vertices: [(position: SIMD3<Float>, uv: SIMD2<Float>)]) -> Data {
        var data = Data()
        data.append(contentsOf: Array("MDLV0023".utf8))
        data.appendLittleEndian(UInt32(0x80000900))
        data.append(UInt8(1))
        data.appendLittleEndian(UInt32(1))
        data.appendLittleEndian(UInt32(1))

        data.appendCString("materials/test.json")
        data.appendLittleEndian(UInt32(0))
        let minX = vertices.map { $0.position.x }.min() ?? 0
        let minY = vertices.map { $0.position.y }.min() ?? 0
        let maxX = vertices.map { $0.position.x }.max() ?? 0
        let maxY = vertices.map { $0.position.y }.max() ?? 0
        data.appendLittleEndian(minX)
        data.appendLittleEndian(minY)
        data.appendLittleEndian(Float(0))
        data.appendLittleEndian(maxX)
        data.appendLittleEndian(maxY)
        data.appendLittleEndian(Float(0))
        data.appendLittleEndian(UInt32(0x180000f))

        let vertexData = Data.wpePuppetVertices(vertices)
        data.appendLittleEndian(UInt32(vertexData.count))
        data.append(vertexData)

        let indices: [UInt16] = vertices.count >= 4 ? [0, 1, 2, 2, 1, 3] : [0, 1, 2]
        data.appendLittleEndian(UInt32(indices.count * MemoryLayout<UInt16>.size))
        for index in indices {
            data.appendLittleEndian(index)
        }

        data.append(UInt8(0))
        data.append(UInt8(1))
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt32(7))
        data.appendLittleEndian(UInt32(0))
        data.appendLittleEndian(UInt32(0))
        data.appendLittleEndian(UInt32(indices.count))

        return data
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian(_ value: Float) {
        appendLittleEndian(value.bitPattern)
    }

    mutating func appendCString(_ string: String) {
        append(contentsOf: Array(string.utf8))
        append(UInt8(0))
    }

    static func wpePuppetVertices(_ vertices: [(position: SIMD3<Float>, uv: SIMD2<Float>)]) -> Data {
        var data = Data()
        for vertex in vertices {
            data.appendLittleEndian(vertex.position.x)
            data.appendLittleEndian(vertex.position.y)
            data.appendLittleEndian(vertex.position.z)
            data.appendLittleEndian(Float(0))
            data.appendLittleEndian(Float(0))
            data.appendLittleEndian(Float(1))
            data.appendLittleEndian(Float(1))
            data.appendLittleEndian(Float(0))
            data.appendLittleEndian(Float(0))
            data.appendLittleEndian(Float(1))
            data.appendLittleEndian(Float(0))
            data.appendLittleEndian(Float(0))
            data.appendLittleEndian(Float(0))
            data.appendLittleEndian(Float(0))
            data.appendLittleEndian(Float(1))
            data.appendLittleEndian(Float(0))
            data.appendLittleEndian(Float(0))
            data.appendLittleEndian(Float(0))
            data.appendLittleEndian(vertex.uv.x)
            data.appendLittleEndian(vertex.uv.y)
        }
        return data
    }
}
