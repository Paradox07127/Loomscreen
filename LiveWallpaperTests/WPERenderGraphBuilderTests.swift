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

    @Test("User-toggleable hidden image stays in graph with a scene pass and visible=false")
    func userToggleableHiddenImageStaysInGraph() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPERenderGraphBuilderTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try writeJSON(["material": "materials/himmel.json"], to: root.appendingPathComponent("models/himmel.json"))
        try writeJSON([
            "passes": [[
                "shader": "genericimage2",
                "textures": ["himmel_albedo"]
            ]]
        ], to: root.appendingPathComponent("materials/himmel.json"))

        let scenePayload: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 1920, "height": 1080, "auto": true]],
            "objects": [[
                "id": "64",
                "name": "Himmel",
                "type": "image",
                "image": "models/himmel.json",
                "visible": ["user": "xme", "value": true]
            ]]
        ]
        let sceneData = try JSONSerialization.data(withJSONObject: scenePayload)
        // Authored visible, but the user override hides it. Because the
        // visibility is user-toggleable, the layer must still be built with a
        // scene-target pass so a later toggle applies without a graph rebuild.
        let document = try WPESceneDocumentParser.parse(data: sceneData, userValues: ["xme": .bool(false)])
        #expect(document.imageObjects.first?.visible == false)

        let graph = try WPERenderGraphBuilder(cacheRootURL: root).build(document: document)
        let layer = try #require(graph.layers.first { $0.objectID == "64" })
        #expect(layer.visible == false)
        #expect(layer.passes.contains { $0.target == .scene })
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
        #expect(compositePass.blending == "premultiplied")
        #expect(scenePass.shader == "materials/util/copy.json")
        #expect(scenePass.source == .fbo("_rt_imageLayerComposite_16613_a"))
        #expect(scenePass.textures[0] == .fbo("_rt_imageLayerComposite_16613_a"))
        #expect(scenePass.blending == "premultiplied")
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
        #expect(pass.shader == "solidlayer")
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

        #expect(layer.passes.map(\.blending) == ["premultiplied", "premultiplied"])
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

    // MARK: - Puppet placement (mesh-bbox sizing + position-preserving re-origin)

    @Test("Cropped puppet (Frieren) is re-placed to its mesh bbox at native size")
    func croppedPuppetReplacedToMeshBboxFrieren() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPERenderGraphBuilderTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try writePuppetModelJSON(root: root, path: "models/fll.json", puppetPath: "models/fll_puppet.mdl")
        try writePuppetFixture(
            vertices: boundsVertices(minX: -1865, minY: -1566, maxX: -60, maxY: 549),
            to: root.appendingPathComponent("models/fll_puppet.mdl")
        )

        let graph = try buildPuppetGraph(
            root: root, modelPath: "models/fll.json", objectID: "22",
            size: "4028 2263", scale: "0.99 0.99 1", origin: "2233.56958 1499.62573 0",
            projectionWidth: 3840, projectionHeight: 2160
        )
        let layer = try #require(graph.layers.first)
        let size = try #require(layer.geometry.size)

        // Composite + scene quad sized to the mesh bbox (native 1:1, no shrink).
        #expect(abs(Double(size.width) - 1805) < 0.5)
        #expect(abs(Double(size.height) - 2115) < 0.5)
        // Mesh centered in its composite.
        #expect(abs(layer.geometry.puppetMeshCenter.x - (-962.5)) < 0.01)
        #expect(abs(layer.geometry.puppetMeshCenter.y - (-508.5)) < 0.01)
        // Origin recomputed to preserve the mesh-bbox center's screen position
        // (no bottom clamp — the authored boot cut edge stays flush at the
        // screen bottom rather than floating up).
        #expect(abs(layer.geometry.origin.x - 1280.695) < 1.0)
        #expect(abs(layer.geometry.origin.y - 996.211) < 1.0)
    }

    @Test("Cropped puppet (Himmel) cross-validates the placement formula")
    func croppedPuppetReplacedToMeshBboxHimmel() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPERenderGraphBuilderTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try writePuppetModelJSON(root: root, path: "models/xme.json", puppetPath: "models/xme_puppet.mdl")
        try writePuppetFixture(
            vertices: boundsVertices(minX: -96, minY: -1117, maxX: 1574, maxY: 765),
            to: root.appendingPathComponent("models/xme_puppet.mdl")
        )

        let graph = try buildPuppetGraph(
            root: root, modelPath: "models/xme.json", objectID: "64",
            size: "2808 2268", scale: "0.99 0.99 1", origin: "2047.19226 1189.41614 0",
            projectionWidth: 3840, projectionHeight: 2160
        )
        let layer = try #require(graph.layers.first)
        let size = try #require(layer.geometry.size)

        #expect(abs(Double(size.width) - 1670) < 0.5)
        #expect(abs(Double(size.height) - 1882) < 0.5)
        #expect(abs(layer.geometry.puppetMeshCenter.x - 739) < 0.01)
        #expect(abs(layer.geometry.puppetMeshCenter.y - (-176)) < 0.01)
        #expect(abs(layer.geometry.origin.x - 2778.802) < 1.0)
        #expect(abs(layer.geometry.origin.y - 1015.176) < 1.0)
    }

    @Test("Puppet whose mesh fits the declared size keeps its geometry (no-op)")
    func fittingPuppetKeepsGeometry() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPERenderGraphBuilderTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try writePuppetModelJSON(root: root, path: "models/p.json", puppetPath: "models/p_puppet.mdl")
        // Mesh ±800 × ±900 fits inside a 2000×2000 object (local range [200,1800]×[100,1900]).
        try writePuppetFixture(
            vertices: boundsVertices(minX: -800, minY: -900, maxX: 800, maxY: 900),
            to: root.appendingPathComponent("models/p_puppet.mdl")
        )

        let graph = try buildPuppetGraph(
            root: root, modelPath: "models/p.json", objectID: "p",
            size: "2000 2000", scale: "1 1 1", origin: "1000 1000 0",
            projectionWidth: 3840, projectionHeight: 2160
        )
        let layer = try #require(graph.layers.first)

        #expect(layer.geometry.size == CGSize(width: 2000, height: 2000))
        #expect(layer.geometry.puppetMeshCenter == SIMD2<Double>(0, 0))
        #expect(layer.geometry.origin == SIMD3<Double>(1000, 1000, 0))
    }

    private func buildPuppetGraph(
        root: URL, modelPath: String, objectID: String,
        size: String, scale: String, origin: String,
        projectionWidth: Int, projectionHeight: Int
    ) throws -> WPERenderGraph {
        let scenePayload: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": projectionWidth, "height": projectionHeight, "auto": true]],
            "objects": [[
                "id": objectID, "name": objectID, "type": "image", "image": modelPath,
                "size": size, "scale": scale, "origin": origin
            ]]
        ]
        let sceneData = try JSONSerialization.data(withJSONObject: scenePayload)
        let document = try WPESceneDocumentParser.parse(data: sceneData)
        return try WPERenderGraphBuilder(cacheRootURL: root).build(document: document)
    }

    private func writePuppetModelJSON(root: URL, path: String, puppetPath: String) throws {
        try writeJSON([
            "material": "materials/puppet.json",
            "puppet": puppetPath,
            "autosize": true
        ], to: root.appendingPathComponent(path))
        try writeJSON([
            "passes": [["shader": "genericimage4", "textures": ["models/puppet_d"]]]
        ], to: root.appendingPathComponent("materials/puppet.json"))
    }

    private func writePuppetFixture(
        vertices: [(position: SIMD3<Float>, uv: SIMD2<Float>)],
        to url: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try makePuppetModelData(vertices: vertices).write(to: url)
    }

    private func boundsVertices(
        minX: Float, minY: Float, maxX: Float, maxY: Float
    ) -> [(position: SIMD3<Float>, uv: SIMD2<Float>)] {
        [
            (SIMD3<Float>(minX, minY, 0), SIMD2<Float>(0, 1)),
            (SIMD3<Float>(maxX, minY, 0), SIMD2<Float>(1, 1)),
            (SIMD3<Float>(minX, maxY, 0), SIMD2<Float>(0, 0)),
            (SIMD3<Float>(maxX, maxY, 0), SIMD2<Float>(1, 0))
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
        for _ in 0..<6 { data.appendLittleEndian(Float(0)) }
        data.appendLittleEndian(UInt32(0x180000f))

        let vertexData = Data.wpePuppetVertices(vertices)
        data.appendLittleEndian(UInt32(vertexData.count))
        data.append(vertexData)

        let indices: [UInt16] = vertices.count >= 4 ? [0, 1, 2, 2, 1, 3] : [0, 1, 2]
        data.appendLittleEndian(UInt32(indices.count * MemoryLayout<UInt16>.size))
        for index in indices { data.appendLittleEndian(index) }

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
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
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
            data.appendLittleEndian(Float(0)); data.appendLittleEndian(Float(0)); data.appendLittleEndian(Float(1))
            data.appendLittleEndian(Float(1)); data.appendLittleEndian(Float(0)); data.appendLittleEndian(Float(0)); data.appendLittleEndian(Float(1))
            data.appendLittleEndian(Float(0)); data.appendLittleEndian(Float(0)); data.appendLittleEndian(Float(0)); data.appendLittleEndian(Float(0))
            data.appendLittleEndian(Float(1)); data.appendLittleEndian(Float(0)); data.appendLittleEndian(Float(0)); data.appendLittleEndian(Float(0))
            data.appendLittleEndian(vertex.uv.x)
            data.appendLittleEndian(vertex.uv.y)
        }
        return data
    }
}
