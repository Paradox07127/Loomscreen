import CoreGraphics
import CoreText
import LiveWallpaperProWPE
import Metal
import Testing
@testable import LiveWallpaper

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
            maxWidth: nil, parallaxDepth: SIMD2<Double>(0, 0),
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

        #expect(material.uniforms["g_RenderVar0"]?.vectorValue == [4, 3, 2, 4])
        #expect(material.uniforms["g_RenderVar1"]?.vectorValue == [0, 1, 0, 5])
        #expect(material.uniforms["g_RenderVar2"]?.vectorValue == [0, 0, 1, -6])
        #expect(material.uniforms["g_RenderVar3"]?.vectorValue == [1, 0, 0, 0])
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

    @Test("Object brightness multiplies fill, outline, and shadow colours (not alpha/offsets)")
    func fontMaterialAppliesObjectBrightness() {
        let object = WPESceneTextObject(
            id: "t", name: "T", text: "Hi",
            fontRelativePath: nil, pointSize: 32,
            color: SIMD3<Double>(1, 0.5, 0.25), brightness: 2, alpha: 0.8,
            origin: SIMD3<Double>(0, 0, 0), scale: SIMD3<Double>(1, 1, 1),
            visible: true, horizontalAlignment: "center", verticalAlignment: "middle",
            maxWidth: nil, parallaxDepth: SIMD2<Double>(0, 0),
            outlineSize: 3, outlineColor: SIMD3<Double>(0, 1, 0),
            blurSize: 0, shadowSize: 4, shadowColor: SIMD3<Double>(0, 0, 1),
            shadowOffset: SIMD2<Double>(5, -6), letterSpacing: 1
        )
        let material = WPEMSDFFontMaterial.make(object: object, parameters: WPEMSDFParameters())
        #expect(material.uniforms["g_Color4"]?.vectorValue == [2, 1, 0.5, 0.8])
        #expect(material.uniforms["g_RenderVar1"]?.vectorValue == [0, 2, 0, 5])
        #expect(material.uniforms["g_RenderVar2"]?.vectorValue == [0, 0, 2, -6])
    }

    @Test("Layout produces one six-vertex quad per glyph grouped by atlas page")
    func layoutProducesQuadsPerGlyph() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let atlas = WPEMSDFAtlas(device: device)
        let generator = WPEMSDFGlyphGenerator()
        let layout = WPEMSDFTextLayout()
        let font = CTFontCreateWithName("Helvetica" as CFString, 32, nil)
        let object = makeTextObject(text: "Hi")

        var mesh: WPEMSDFTextMesh?
        for _ in 0..<200 where mesh == nil {
            mesh = layout.layout(
                object: object,
                font: font,
                atlas: atlas,
                generator: generator
            )
            if mesh == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        let resolved = try #require(mesh)

        #expect(!resolved.perPage.isEmpty)
        let totalVertices = resolved.perPage.values.reduce(0) { $0 + $1.count }
        #expect(totalVertices == 12)
        #expect(totalVertices % 6 == 0)
    }

    private func awaitMesh(
        _ object: WPESceneTextObject,
        font: CTFont,
        atlas: WPEMSDFAtlas,
        generator: WPEMSDFGlyphGenerator,
        layout: WPEMSDFTextLayout,
        attempts: Int = 200
    ) async -> WPEMSDFTextMesh? {
        for _ in 0..<attempts {
            if let mesh = layout.layout(object: object, font: font, atlas: atlas, generator: generator) {
                return mesh
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    @Test("Whitespace is advanced past, not drawn (A B → two quads, space skipped)")
    func whitespaceIsSkippedNotDrawn() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let atlas = WPEMSDFAtlas(device: device)
        let generator = WPEMSDFGlyphGenerator()
        let layout = WPEMSDFTextLayout()
        let font = CTFontCreateWithName("Helvetica" as CFString, 32, nil)

        let mesh = await awaitMesh(makeTextObject(text: "A B"), font: font, atlas: atlas, generator: generator, layout: layout)
        let resolved = try #require(mesh)
        let totalVertices = resolved.perPage.values.reduce(0) { $0 + $1.count }
        #expect(totalVertices == 12)
    }

    @Test("Emoji (no MSDF outline) makes the whole object fall back to CoreText")
    func emojiObjectFallsBackToCoreText() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let atlas = WPEMSDFAtlas(device: device)
        let generator = WPEMSDFGlyphGenerator()
        let layout = WPEMSDFTextLayout()
        let font = CTFontCreateWithName("Helvetica" as CFString, 32, nil)

        let mesh = await awaitMesh(makeTextObject(text: "😀"), font: font, atlas: atlas, generator: generator, layout: layout, attempts: 40)
        #expect(mesh == nil)
    }
}
