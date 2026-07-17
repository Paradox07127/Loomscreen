import Foundation
import LiveWallpaperProWPE
import Testing
@testable import LiveWallpaper

@Suite("WPE render pipeline builder spritesheet")
struct WPERenderPipelineBuilderSpriteSheetTests {

    @Test("Generic image pass emits g_Texture0 sprite-sheet uniforms only when SPRITESHEET combo is enabled")
    func genericImageSpriteSheetEmitsTransformUniformsOnlyWhenEnabled() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let builder = WPERenderPipelineBuilder(cacheRootURL: fixture.root)

        let spritePipeline = try builder.build(graph: makeGraph(combos: ["SPRITESHEET": 1]))
        let spriteVertex = try #require(spritePipeline.layers.first?.passes.first?.shader?.vertexSource)

        #expect(spriteVertex.contains("uniform vec2 g_Texture0Translation"))
        #expect(spriteVertex.contains("uniform vec2 g_Texture0TranslationNext"))
        #expect(spriteVertex.contains("uniform vec4 g_Texture0Rotation"))
        #expect(spriteVertex.contains("a_TexCoord.x * g_Texture0Rotation.xy"))
        #expect(spriteVertex.contains("a_TexCoord.y * g_Texture0Rotation.zw"))
        #expect(spriteVertex.contains("#define SPRITESHEET 1"))

        let spriteFragment = try #require(spritePipeline.layers.first?.passes.first?.shader?.fragmentSource)
        #expect(spriteFragment.contains("uniform float g_SpriteFrameBlend"))
        #expect(spriteFragment.contains("mix("))

        let plainPipeline = try builder.build(graph: makeGraph(combos: [:]))
        let plainVertex = try #require(plainPipeline.layers.first?.passes.first?.shader?.vertexSource)

        #expect(plainVertex.contains("g_Texture0Translation") == false)
        #expect(plainVertex.contains("g_Texture0Rotation") == false)
    }

    @Test("Lowercase spritesheet combo also activates the sprite vertex path")
    func lowercaseSpriteSheetComboActivatesSpriteVertexPath() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let builder = WPERenderPipelineBuilder(cacheRootURL: fixture.root)
        let pipeline = try builder.build(graph: makeGraph(combos: ["spritesheet": 1]))
        let vertex = try #require(pipeline.layers.first?.passes.first?.shader?.vertexSource)

        #expect(vertex.contains("uniform vec2 g_Texture0Translation"))
        #expect(vertex.contains("uniform vec4 g_Texture0Rotation"))
    }

    private func makeGraph(combos: [String: Int]) -> WPERenderGraph {
        WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "materials/base.tex",
                materialPath: "materials/base.json",
                geometry: .identity,
                compositeA: "_rt_imageLayerComposite_1_a",
                compositeB: "_rt_imageLayerComposite_1_b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "1.0",
                        phase: .material,
                        shader: "genericimage4",
                        source: .image("materials/base.tex"),
                        target: .scene,
                        textures: [:],
                        binds: [:],
                        constants: [:],
                        combos: combos,
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                ]
            )
        ])
    }

    private struct Fixture {
        let root: URL

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPERenderPipelineBuilderSpriteSheetTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Fixture(root: root)
    }
}
