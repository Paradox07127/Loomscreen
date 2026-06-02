import CoreGraphics
import CoreText
import LiveWallpaperProWPE
import Metal
import Testing
@testable import LiveWallpaper

/// Standalone gate for the GPU MSDF text pipeline (Milestone D) — exercises the
/// font-material packing and CoreText→atlas layout without the live scene-render
/// wiring, so the math is locked in before any on-device draw integration.
@MainActor
struct WPEMSDFTextPipelineTests {

    private func makeTextObject(
        text: String = "Hi",
        outlineSize: Double = 0,
        blurSize: Double = 0,
        shadowSize: Double = 0,
        shadowOffset: SIMD2<Double> = SIMD2<Double>(0, 0)
    ) -> WPESceneTextObject {
        WPESceneTextObject(
            id: "t", name: "T", text: text,
            fontRelativePath: nil, pointSize: 32,
            color: SIMD3<Double>(1, 0.5, 0.25), alpha: 0.8,
            origin: SIMD3<Double>(0, 0, 0), scale: SIMD3<Double>(1, 1, 1),
            visible: true, horizontalAlignment: "center", verticalAlignment: "middle",
            maxWidth: nil, parallaxDepth: 0,
            outlineSize: outlineSize, outlineColor: SIMD3<Double>(0, 1, 0),
            blurSize: blurSize, shadowSize: shadowSize, shadowColor: SIMD3<Double>(0, 0, 1),
            shadowOffset: shadowOffset, letterSpacing: 1
        )
    }

    @Test("Font material packs the authoritative RenderVar layout and derives combos")
    func fontMaterialPacksRenderVars() {
        let object = makeTextObject(outlineSize: 3, blurSize: 2, shadowSize: 4, shadowOffset: SIMD2<Double>(5, -6))
        let material = WPEMSDFFontMaterial.make(object: object, parameters: WPEMSDFParameters())

        #expect(material.combos["MSDF"] == 1)
        #expect(material.combos["COLORFONT"] == 0)
        #expect(material.combos["OUTLINE_ENABLED"] == 1)
        #expect(material.combos["BLUR_ENABLED"] == 1)
        #expect(material.combos["DROP_SHADOW_ENABLED"] == 1)

        // g_RenderVar0 = (MSDF_RANGE, OUTLINE_WIDTH, BLUR_RADIUS, DROP_SHADOW_RADIUS)
        #expect(material.uniforms["g_RenderVar0"]?.vectorValue == [4, 3, 2, 4])
        // g_RenderVar1 = (OUTLINE_COLOR.rgb, DROP_SHADOW_OFFSET.x)
        #expect(material.uniforms["g_RenderVar1"]?.vectorValue == [0, 1, 0, 5])
        // g_RenderVar2 = (DROP_SHADOW_COLOR.rgb, DROP_SHADOW_OFFSET.y)
        #expect(material.uniforms["g_RenderVar2"]?.vectorValue == [0, 0, 1, -6])
        // g_RenderVar3 = (DROP_SHADOW_OPACITY, 0, 0, 0)
        #expect(material.uniforms["g_RenderVar3"]?.vectorValue == [1, 0, 0, 0])
        // Fill color = g_Color4 (rgb + alpha).
        #expect(material.uniforms["g_Color4"]?.vectorValue == [1, 0.5, 0.25, 0.8])
    }

    @Test("Plain text disables every optional effect combo")
    func fontMaterialPlainTextDisablesEffects() {
        let material = WPEMSDFFontMaterial.make(object: makeTextObject(), parameters: WPEMSDFParameters())
        #expect(material.combos["OUTLINE_ENABLED"] == 0)
        #expect(material.combos["BLUR_ENABLED"] == 0)
        #expect(material.combos["DROP_SHADOW_ENABLED"] == 0)
        #expect(material.uniforms["g_RenderVar3"]?.vectorValue == [0, 0, 0, 0])
    }

    @Test("Layout produces one six-vertex quad per glyph grouped by atlas page")
    func layoutProducesQuadsPerGlyph() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let atlas = WPEMSDFAtlas(device: device)
        let generator = WPEMSDFGlyphGenerator()
        let layout = WPEMSDFTextLayout()
        let font = CTFontCreateWithName("Helvetica" as CFString, 32, nil)
        let object = makeTextObject(text: "Hi")

        let mesh = try #require(layout.layout(
            object: object,
            font: font,
            atlas: atlas,
            generator: generator,
            fontID: "Helvetica@32"
        ))

        #expect(!mesh.perPage.isEmpty)
        let totalVertices = mesh.perPage.values.reduce(0) { $0 + $1.count }
        // Two glyphs ("Hi") × 6 vertices per quad.
        #expect(totalVertices == 12)
        #expect(totalVertices % 6 == 0)
    }
}
