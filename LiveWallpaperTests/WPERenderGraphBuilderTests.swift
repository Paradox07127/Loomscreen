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

    @Test("Structured effect overrides: array constants with {user,value} + dict texture slots")
    func structuredEffectOverridesBindConstantsAndMask() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPERenderGraphBuilderTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try writeJSON(["material": "materials/layer.json"], to: root.appendingPathComponent("models/layer.json"))
        try writeJSON([
            "passes": [["shader": "genericimage2", "textures": ["layer_albedo"]]]
        ], to: root.appendingPathComponent("materials/layer.json"))
        try writeJSON([
            "passes": [[
                "material": "materials/effects/pulse_.json",
                "bind": [["index": 0, "name": "previous"]]
            ]]
        ], to: root.appendingPathComponent("effects/pulse_/effect.json"))
        try writeJSON([
            "passes": [[
                "shader": "workshop/2718465779/effects/pulse_",
                "textures": [NSNull(), "util/noise"],
                "constantshadervalues": ["pulseamount": 1, "pulsespeed": 1]
            ]]
        ], to: root.appendingPathComponent("materials/effects/pulse_.json"))

        // The structured form WPE writes for user-bound effect instances:
        // constants as an ARRAY of {name, value:{user,value}} entries, and the
        // per-instance opacity mask as a DICT texture slot entry.
        let scenePayload: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 1920, "height": 1080, "auto": true]],
            "objects": [[
                "id": 161,
                "name": "Cloud band",
                "type": "image",
                "image": "models/layer.json",
                "effects": [[
                    "id": 854,
                    "file": "effects/pulse_/effect.json",
                    "passes": [[
                        "constantshadervalues": [
                            ["name": "pulseamount", "value": ["user": "amt", "value": 2]],
                            ["name": "pulsespeed", "value": ["user": "spd", "value": 0.84]]
                        ],
                        "textures": [NSNull(), NSNull(), ["name": "masks/pulse__mask_9913c181"]]
                    ]]
                ]]
            ]]
        ]
        let sceneData = try JSONSerialization.data(withJSONObject: scenePayload)
        let document = try WPESceneDocumentParser.parse(data: sceneData)

        let graph = try WPERenderGraphBuilder(cacheRootURL: root).build(document: document)
        let effectPass = try #require(graph.layers.first?.passes.first {
            $0.shader == "workshop/2718465779/effects/pulse_"
        })

        #expect(effectPass.textures[1] == .asset("util/noise"))
        #expect(effectPass.textures[2] == .asset("masks/pulse__mask_9913c181"))
        #expect(effectPass.constants["pulseamount"]?.numberValue == 2)
        #expect(effectPass.constants["pulsespeed"]?.numberValue == 0.84)
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

    @Test("Composelayer with children renders subtree into a local group target")
    func composelayerWithChildrenBuildsLocalGroupTarget() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPERenderGraphBuilderTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try writeJSON(["material": "materials/util/composelayer.json"], to: root.appendingPathComponent("models/util/composelayer.json"))
        try writeJSON([
            "passes": [[
                "shader": "compose",
                "textures": ["_rt_FullFrameBuffer"]
            ]]
        ], to: root.appendingPathComponent("materials/util/composelayer.json"))
        try writeJSON(["material": "materials/child.json"], to: root.appendingPathComponent("models/child.json"))
        try writeJSON([
            "passes": [[
                "shader": "genericimage2",
                "textures": ["child_albedo"]
            ]]
        ], to: root.appendingPathComponent("materials/child.json"))

        let scenePayload: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 1000, "height": 800, "auto": true]],
            "objects": [
                [
                    "id": "group",
                    "name": "Group",
                    "type": "image",
                    "image": "models/util/composelayer.json",
                    "origin": "500 400 0",
                    "size": "200 100 0"
                ],
                [
                    "id": "container",
                    "name": "Container",
                    "type": "group",
                    "parent": "group",
                    "origin": "20 10 0"
                ],
                [
                    "id": "child",
                    "name": "Child",
                    "type": "image",
                    "image": "models/child.json",
                    "parent": "container",
                    "origin": "5 7 0",
                    "size": "40 30 0"
                ]
            ]
        ]
        let sceneData = try JSONSerialization.data(withJSONObject: scenePayload)
        let document = try WPESceneDocumentParser.parse(data: sceneData)

        let graph = try WPERenderGraphBuilder(cacheRootURL: root).build(document: document)

        #expect(graph.layers.map(\.objectID) == ["child", "group"])
        let child = try #require(graph.layers.first { $0.objectID == "child" })
        let group = try #require(graph.layers.first { $0.objectID == "group" })
        let groupTarget = "_rt_layerGroup_group"

        #expect(child.groupRenderTarget == groupTarget)
        #expect(child.passes.last?.target == .fbo(name: groupTarget))
        #expect(child.groupLocalGeometry?.origin == SIMD3<Double>(125, 67, 0))

        #expect(group.groupCompositeSource == groupTarget)
        #expect(group.localFBOs.contains(WPERenderFBO(
            name: groupTarget,
            scale: 1,
            format: "rgba8888",
            pixelSize: CGSize(width: 200, height: 100)
        )))
        #expect(group.passes.first?.source == .fbo(groupTarget))
        #expect(group.passes.first?.textures[0] == .fbo(groupTarget))
        #expect(group.passes.last?.target == .scene)
    }

    @Test("Composelayer wrapping only a particle is dropped from the graph")
    func composelayerWrappingOnlyParticleIsDropped() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPERenderGraphBuilderTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try writeJSON(["material": "materials/util/composelayer.json"], to: root.appendingPathComponent("models/util/composelayer.json"))
        try writeJSON([
            "passes": [["shader": "compose", "textures": ["_rt_FullFrameBuffer"]]]
        ], to: root.appendingPathComponent("materials/util/composelayer.json"))

        // A composelayer whose ONLY child is a particle system is an isolated
        // effect wrapper (tint/opacity baked onto the particle in the renderer),
        // so it must not emit a full-frame-capture layer. Mirrors 3462491575's
        // matrix-rain compose group 1322.
        let scenePayload: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 1000, "height": 800, "auto": true]],
            "objects": [
                [
                    "id": "rainGroup",
                    "name": "Rain Group",
                    "type": "image",
                    "image": "models/util/composelayer.json",
                    "origin": "500 400 0",
                    "size": "1000 800 0",
                    "effects": [[
                        "file": "effects/opacity/effect.json",
                        "passes": [["textures": [NSNull(), "masks/rain_mask"]]]
                    ]]
                ],
                [
                    "id": "rain",
                    "name": "Matrix Rain",
                    "type": "particle",
                    "particle": "particles/rain.json",
                    "parent": "rainGroup",
                    "origin": "0 0 0"
                ]
            ]
        ]
        let sceneData = try JSONSerialization.data(withJSONObject: scenePayload)
        let document = try WPESceneDocumentParser.parse(data: sceneData)
        let graph = try WPERenderGraphBuilder(cacheRootURL: root).build(document: document)

        #expect(!graph.layers.contains { $0.objectID == "rainGroup" })
    }

    @Test("copybackground false composelayer with only scroll visible does not capture scene")
    func copyBackgroundFalseComposelayerWithOnlyScrollVisibleDoesNotCaptureScene() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPERenderGraphBuilderTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try writeJSON(["material": "materials/util/composelayer.json"], to: root.appendingPathComponent("models/util/composelayer.json"))
        try writeJSON([
            "passes": [[
                "shader": "compose",
                "textures": ["_rt_FullFrameBuffer"]
            ]]
        ], to: root.appendingPathComponent("materials/util/composelayer.json"))
        try writeJSON([
            "passes": [[
                "material": "materials/workshop/3302578859/effects/scroll.json"
            ]]
        ], to: root.appendingPathComponent("effects/workshop/3302578859/scroll/effect.json"))
        try writeJSON([
            "passes": [[
                "shader": "workshop/3302578859/effects/scroll"
            ]]
        ], to: root.appendingPathComponent("materials/workshop/3302578859/effects/scroll.json"))

        let scenePayload: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 3840, "height": 2160, "auto": true]],
            "objects": [[
                "id": 387,
                "name": "Bar 3",
                "type": "image",
                "image": "models/util/composelayer.json",
                "config": ["passthrough": true],
                "copybackground": false,
                "effects": [
                    [
                        "id": 388,
                        "file": "effects/workshop/3299008209/workshop/2084198056/Simple_Audio_Bars/effect.json",
                        "visible": false
                    ],
                    [
                        "id": 3051,
                        "file": "effects/workshop/3302578859/scroll/effect.json",
                        "visible": true
                    ]
                ]
            ]]
        ]
        let sceneData = try JSONSerialization.data(withJSONObject: scenePayload)
        let document = try WPESceneDocumentParser.parse(data: sceneData)

        let graph = try WPERenderGraphBuilder(cacheRootURL: root).build(document: document)

        #expect(graph.layers.isEmpty)
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

    @Test("Top-level solid MDL objects build mesh-backed render layers")
    func topLevelSolidModelBuildsMeshBackedRenderLayer() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPERenderGraphBuilderTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try writePuppetFixture(
            vertices: boundsVertices(minX: -10, minY: -10, maxX: 10, maxY: 10),
            to: root.appendingPathComponent("models/sky/sky.mdl")
        )
        try writeJSON([
            "passes": [[
                "shader": "generic4",
                "textures": ["sky_albedo"],
                "depthtest": "enabled",
                "depthwrite": "enabled"
            ]]
        ], to: root.appendingPathComponent("materials/test.json"))

        let scenePayload: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 1920, "height": 1080, "auto": true]],
            "objects": [[
                "id": "sky",
                "name": "Sky",
                "solid": true,
                "model": "models/sky/sky.mdl",
                "scale": "2 2 2"
            ]]
        ]
        let sceneData = try JSONSerialization.data(withJSONObject: scenePayload)
        let document = try WPESceneDocumentParser.parse(data: sceneData)

        let graph = try WPERenderGraphBuilder(cacheRootURL: root).build(document: document)
        let layer = try #require(graph.layers.first)

        #expect(layer.objectID == "sky")
        #expect(layer.imagePath == "models/sky/sky.mdl")
        #expect(layer.materialPath == "materials/test.json")
        #expect(layer.puppetPath == "models/sky/sky.mdl")
        #expect(layer.geometry.scale == SIMD3<Double>(2, 2, 2))
        #expect(layer.passes.map(\.shader) == ["generic4"])
        #expect(layer.passes[0].target == .scene)
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

    @Test("Layer-script-referenced hidden layers survive pruning (3470764447 day/night bands)")
    func layerScriptReferencedHiddenLayersSurvivePruning() throws {
        // A time-of-day script reveals authored-hidden band layers by name (here in
        // an array literal, like 3470764447's 后处理层). They must stay in the graph
        // so their videos load — otherwise the switch lands on a layer that isn't
        // there → black background. An unrelated hidden layer the script never names
        // must still get pruned (no regression to all-variants-render, 3226487183).
        let script = """
        var displayVideo = ["day", "night"].map(v => thisScene.getLayer(v));
        export function init() {}
        export function update() {}
        """
        func band(_ id: String, visible: Bool, visibleScript: String? = nil) -> WPESceneImageObject {
            WPESceneImageObject(
                id: id, name: id,
                imageRelativePath: "materials/\(id).png", materialRelativePath: nil,
                origin: SIMD3<Double>(0, 0, 0), scale: SIMD3<Double>(1, 1, 1), angles: SIMD3<Double>(0, 0, 0),
                visible: visible, alpha: 1, color: SIMD3<Double>(1, 1, 1), brightness: 1,
                blendMode: .normal, alignment: .center, size: nil,
                effects: [], animationLayers: [], visibleScript: visibleScript
            )
        }
        let document = WPESceneDocument(
            camera: .defaultCamera,
            general: .defaultGeneral,
            imageObjects: [
                band("day", visible: true),
                band("night", visible: false),
                band("unrelated", visible: false),
                band("post", visible: true, visibleScript: script)
            ],
            diagnostics: []
        )

        let graph = try WPERenderGraphBuilder(
            cacheRootURL: FileManager.default.temporaryDirectory
        ).build(document: document)
        let ids = Set(graph.layers.map(\.objectID))

        #expect(ids.contains("night"))
        #expect(ids.contains("day"))
        #expect(!ids.contains("unrelated"))
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

    @Test("Object additive blend overrides final scene composite blend")
    func objectAdditiveBlendOverridesFinalSceneCompositeBlend() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPERenderGraphBuilderTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try writeJSON(["material": "materials/ripple.json"], to: root.appendingPathComponent("models/ripple.json"))
        try writeJSON([
            "passes": [[
                "shader": "genericimage2",
                "blending": "translucent"
            ]]
        ], to: root.appendingPathComponent("materials/ripple.json"))
        try writeJSON([
            "passes": [[
                "material": "materials/effects/pulse.json",
                "bind": [["index": 0, "name": "previous"]]
            ]]
        ], to: root.appendingPathComponent("effects/pulse/effect.json"))
        try writeJSON([
            "passes": [[
                "shader": "workshop/2655151285/effects/pulse",
                "blending": "normal"
            ]]
        ], to: root.appendingPathComponent("materials/effects/pulse.json"))

        let scenePayload: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 1920, "height": 1080, "auto": true]],
            "objects": [[
                "id": "88",
                "name": "ripple1440p",
                "type": "image",
                "image": "models/ripple.json",
                "colorBlendMode": 9,
                "effects": [[
                    "id": 92,
                    "file": "effects/pulse/effect.json"
                ]]
            ]]
        ]
        let sceneData = try JSONSerialization.data(withJSONObject: scenePayload)
        let document = try WPESceneDocumentParser.parse(data: sceneData)

        let graph = try WPERenderGraphBuilder(cacheRootURL: root).build(document: document)
        let layer = try #require(graph.layers.first)

        #expect(layer.passes.map(\.blending) == [
            "premultiplied",
            "premultiplied",
            "premultipliedAdditive"
        ])
        #expect(layer.passes.last?.target == .scene)
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
            parallaxDepth: SIMD2<Double>(0.2, 0.2)
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

        #expect(graph.layers.first?.parallaxDepth == SIMD2<Double>(0.2, 0.2))
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
            parallaxDepth: SIMD2<Double>(0.2, 0.2)
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

    @Test("A hidden parent suppresses its visible children from the scene (variant visibility inheritance)")
    func hiddenAncestorSuppressesVisibleChildren() throws {
        func image(_ id: String, visible: Bool, parent: String?) -> WPESceneImageObject {
            WPESceneImageObject(
                id: id,
                name: id,
                imageRelativePath: "materials/\(id).png",
                materialRelativePath: nil,
                parentObjectID: parent,
                origin: SIMD3<Double>(0, 0, 0),
                scale: SIMD3<Double>(1, 1, 1),
                angles: SIMD3<Double>(0, 0, 0),
                visible: visible,
                alpha: 1,
                color: SIMD3<Double>(1, 1, 1),
                brightness: 1,
                blendMode: .normal,
                alignment: .center,
                size: nil,
                effects: [],
                animationLayers: [],
                parallaxDepth: SIMD2<Double>(0, 0)
            )
        }
        // A body-split style variant: a hidden variant background with an authored-visible
        // child body, alongside the shown variant. Only the shown variant's subtree should
        // composite — the hidden variant's visible child must inherit the hidden state.
        let document = WPESceneDocument(
            camera: .defaultCamera,
            general: .defaultGeneral,
            imageObjects: [
                image("hiddenVariant", visible: false, parent: nil),
                image("hiddenChildBody", visible: true, parent: "hiddenVariant"),
                image("hiddenGrandchildMask", visible: true, parent: "hiddenChildBody"),
                image("shownVariant", visible: true, parent: nil),
                image("shownChildBody", visible: true, parent: "shownVariant")
            ],
            diagnostics: []
        )

        let graph = try WPERenderGraphBuilder(
            cacheRootURL: FileManager.default.temporaryDirectory
        ).build(document: document)

        let built = Set(graph.layers.map(\.objectID))
        // Hidden variant and its (authored-visible) descendants are dropped from the graph.
        #expect(!built.contains("hiddenVariant"))
        #expect(!built.contains("hiddenChildBody"))
        #expect(!built.contains("hiddenGrandchildMask"))
        // The shown variant subtree is unaffected.
        #expect(built.contains("shownVariant"))
        #expect(built.contains("shownChildBody"))
    }

    @Test("A visible child of a user-toggleable (condition-less) hidden parent stays in the graph")
    func liveToggleableHiddenParentKeepsVisibleChildren() throws {
        // Parser-driven so the real property-binding → live-visibility flow runs: the parent
        // resolves hidden (toggle == false) but its `visible` binding is a condition-less live
        // toggle, so it stays in the graph — and so must its authored-visible child, otherwise
        // toggling the parent back on at runtime would reveal an empty subtree.
        let payload: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 1920, "height": 1080, "auto": true]],
            "objects": [
                [
                    "id": 1, "name": "toggleParent", "image": "models/util/solidlayer.json",
                    "visible": ["user": "toggle", "value": true]
                ],
                [
                    "id": 2, "name": "child", "image": "models/util/solidlayer.json",
                    "parent": 1, "visible": true
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        let document = try WPESceneDocumentParser.parse(data: data, userValues: ["toggle": .bool(false)])
        #expect(document.imageObjects.first(where: { $0.id == "1" })?.visible == false)

        let graph = try WPERenderGraphBuilder(
            cacheRootURL: FileManager.default.temporaryDirectory
        ).build(document: document)

        #expect(Set(graph.layers.map(\.objectID)).contains("2"))
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
            parallaxDepth: SIMD2<Double>(0, 0)
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

    @Test("Double-underscore generated texture refs route through asset lookup")
    func doubleUnderscoreGeneratedTextureRefsRouteToAssetLookup() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPERenderGraphBuilderTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let generatedName = "__yuuki_shibou_yuugi_de_meshi_wo_kuu_drawn_by_nekometaru__ae12f81d42ef9a8b610029375bac6b70"
        try writeJSON(["material": "materials/layer.json"], to: root.appendingPathComponent("models/layer.json"))
        try writeJSON([
            "passes": [[
                "shader": "genericimage2",
                "textures": [generatedName]
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
            parallaxDepth: SIMD2<Double>(0, 0)
        )
        let document = WPESceneDocument(
            camera: .defaultCamera,
            general: .defaultGeneral,
            imageObjects: [object],
            diagnostics: []
        )

        let graph = try WPERenderGraphBuilder(cacheRootURL: root).build(document: document)
        let pass = try #require(graph.layers.first?.passes.first)
        #expect(pass.textures[0] == .asset(generatedName))
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

    @Test("Both solidlayer model variants use the premultiplied solidlayer builtin")
    func solidLayerVariantsUsePremultipliedBuiltin() throws {
        func shaders(forModel model: String) throws -> [String] {
            let object = WPESceneImageObject(
                id: "1", name: "solid", imageRelativePath: model,
                materialRelativePath: nil,
                origin: SIMD3<Double>(0, 0, 0), scale: SIMD3<Double>(1, 1, 1),
                angles: SIMD3<Double>(0, 0, 0), visible: true, alpha: 1,
                color: SIMD3<Double>(1, 1, 1), brightness: 1, blendMode: .normal,
                alignment: .center, size: nil, effects: [], animationLayers: [],
                parallaxDepth: SIMD2<Double>(0, 0)
            )
            let document = WPESceneDocument(
                camera: .defaultCamera, general: .defaultGeneral,
                imageObjects: [object], diagnostics: []
            )
            let graph = try WPERenderGraphBuilder(cacheRootURL: FileManager.default.temporaryDirectory)
                .build(document: document)
            return try #require(graph.layers.first).passes.map(\.shader)
        }
        // Plain + depth-test variant must BOTH use `solidlayer` (premultiplied,
        // rgb*alpha) — not `solidcolor` (straight), which paints opaque white
        // for a transparent base under the premultiplied blend.
        for model in ["models/util/solidlayer.json", "models/util/solidlayer_depthtest.json"] {
            let used = try shaders(forModel: model)
            #expect(used.contains("solidlayer"), "\(model) should use the solidlayer builtin")
            #expect(!used.contains("solidcolor"), "\(model) must not fall back to solidcolor")
        }
    }

    @Test("Alpha-0 layer composites to scene only when it carries a visible effect")
    func alphaZeroCompositesWhenItHasAVisibleEffect() {
        func object(alpha: Double, effectVisible: Bool?) -> WPESceneImageObject {
            let effects = effectVisible.map {
                [WPESceneImageEffect(
                    id: "e", name: "audioline",
                    fileRelativePath: "effects/workshop/3578699527/audioline/effect.json",
                    visible: $0, passOverrides: []
                )]
            } ?? []
            return WPESceneImageObject(
                id: "1", name: "音频线",
                imageRelativePath: "models/util/solidlayer_depthtest.json",
                materialRelativePath: nil,
                origin: SIMD3<Double>(0, 0, 0), scale: SIMD3<Double>(1, 1, 1),
                angles: SIMD3<Double>(0, 0, 0), visible: true, alpha: alpha,
                color: SIMD3<Double>(1, 1, 1), brightness: 1, blendMode: .normal,
                alignment: .center, size: nil, effects: effects,
                animationLayers: [], parallaxDepth: SIMD2<Double>(0, 0)
            )
        }
        // The 3719111841 audio-line case: alpha 0 + a visible effect → must composite.
        #expect(WPERenderGraphBuilder.compositesToScene(object(alpha: 0, effectVisible: true), liveVisibilityIDs: []))
        // Alpha 0 with no effect (or an invisible one) contributes nothing → dropped.
        #expect(!WPERenderGraphBuilder.compositesToScene(object(alpha: 0, effectVisible: nil), liveVisibilityIDs: []))
        #expect(!WPERenderGraphBuilder.compositesToScene(object(alpha: 0, effectVisible: false), liveVisibilityIDs: []))
        // Opaque layers are unaffected.
        #expect(WPERenderGraphBuilder.compositesToScene(object(alpha: 1, effectVisible: nil), liveVisibilityIDs: []))
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
            parallaxDepth: SIMD2<Double>(0, 0)
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

    // MARK: - Puppet placement (preserve authored canvas)

    @Test("Cropped puppet (Frieren) keeps its authored canvas")
    func croppedPuppetKeepsAuthoredCanvasFrieren() throws {
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

        #expect(abs(Double(size.width) - 4028) < 0.5)
        #expect(abs(Double(size.height) - 2263) < 0.5)
        #expect(layer.geometry.puppetMeshCenter == SIMD2<Double>(0, 0))
        #expect(abs(layer.geometry.origin.x - 2233.56958) < 0.01)
        #expect(abs(layer.geometry.origin.y - 1499.62573) < 0.01)
    }

    @Test("Cropped puppet (Himmel) keeps its authored canvas")
    func croppedPuppetKeepsAuthoredCanvasHimmel() throws {
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

        #expect(abs(Double(size.width) - 2808) < 0.5)
        #expect(abs(Double(size.height) - 2268) < 0.5)
        #expect(layer.geometry.puppetMeshCenter == SIMD2<Double>(0, 0))
        #expect(abs(layer.geometry.origin.x - 2047.19226) < 0.01)
        #expect(abs(layer.geometry.origin.y - 1189.41614) < 0.01)
    }

    @Test("Puppet body with smaller MDLV bbox keeps scene and texture canvas (scene 3462491575)")
    func puppetBodyWithSmallerMeshBoundsKeepsCanvas() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPERenderGraphBuilderTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try writePuppetModelJSON(root: root, path: "models/body.json", puppetPath: "models/body_puppet.mdl")
        try writePuppetFixture(
            vertices: boundsVertices(minX: -715, minY: -917, maxX: 711, maxY: 861),
            to: root.appendingPathComponent("models/body_puppet.mdl")
        )

        let graph = try buildPuppetGraph(
            root: root, modelPath: "models/body.json", objectID: "1607",
            size: "1490 1792", scale: "1 1 1", origin: "500 -304 0",
            projectionWidth: 3840, projectionHeight: 2160
        )
        let layer = try #require(graph.layers.first)
        let size = try #require(layer.geometry.size)

        #expect(abs(Double(size.width) - 1490) < 0.5)
        #expect(abs(Double(size.height) - 1792) < 0.5)
        #expect(layer.geometry.puppetMeshCenter == SIMD2<Double>(0, 0))
        #expect(abs(layer.geometry.origin.x - 500) < 0.01)
        #expect(abs(layer.geometry.origin.y - (-304)) < 0.01)
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

    @Test("Cropped puppet whose MDLV bbox is outside its local FBO uses mesh bbox center")
    func offCanvasCroppedPuppetUsesMeshBoundsCenter() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPERenderGraphBuilderTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try writePuppetModelJSON(
            root: root,
            path: "models/eyes.json",
            puppetPath: "models/eyes_puppet.mdl",
            cropOffset: "564.00000 494.50000"
        )
        try writePuppetFixture(
            vertices: boundsVertices(minX: -1001, minY: -146, maxX: -696, maxY: 107),
            to: root.appendingPathComponent("models/eyes_puppet.mdl")
        )

        let graph = try buildPuppetGraph(
            root: root, modelPath: "models/eyes.json", objectID: "115",
            size: "584 759", scale: "1 1 1", origin: "630 -1 0",
            projectionWidth: 3840, projectionHeight: 2160
        )
        let layer = try #require(graph.layers.first)

        #expect(layer.geometry.puppetMeshCenter == SIMD2<Double>(-848.5, -19.5))
        #expect(layer.localGeometry?.puppetMeshCenter == SIMD2<Double>(-848.5, -19.5))
        #expect(layer.geometry.origin == SIMD3<Double>(-218.5, -20.5, 0))
        #expect(layer.localGeometry?.origin == SIMD3<Double>(-218.5, -20.5, 0))
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

    private func writePuppetModelJSON(
        root: URL,
        path: String,
        puppetPath: String,
        cropOffset: String? = nil
    ) throws {
        var model: [String: Any] = [
            "material": "materials/puppet.json",
            "puppet": puppetPath,
            "autosize": true
        ]
        if let cropOffset {
            model["cropoffset"] = cropOffset
        }
        try writeJSON(model, to: root.appendingPathComponent(path))
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

    @Test("Texture names keep significant trailing space (scene 3351072238)")
    func parseTexturePathPreservesSignificantWhitespace() {
        // The packaged asset is literally `materials/妃咲 60帧 .tex`; trimming the
        // reference broke the candidate lookup. Verbatim name, blank-only → nil.
        #expect(WPERenderGraphBuilder.parseTexturePath("妃咲 60帧 ") == "妃咲 60帧 ")
        #expect(WPERenderGraphBuilder.parseTexturePath(["name": "妃咲 60帧 "]) == "妃咲 60帧 ")
        #expect(WPERenderGraphBuilder.parseTexturePath("layer_albedo") == "layer_albedo")
        #expect(WPERenderGraphBuilder.parseTexturePath("   ") == nil)
        #expect(WPERenderGraphBuilder.parseTexturePath("") == nil)
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
