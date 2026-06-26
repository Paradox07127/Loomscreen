import CoreGraphics
import CoreText
import Testing
@testable import LiveWallpaper

struct WPEMSDFGlyphGeneratorTests {

    private func glyph(_ character: Character, font: CTFont) -> CGGlyph {
        var chars = Array(String(character).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        _ = CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count)
        return glyphs[0]
    }

    private func median(_ pixel: SIMD4<Float>) -> Float {
        max(min(pixel.x, pixel.y), min(max(pixel.x, pixel.y), pixel.z))
    }

    @Test("Filled glyph yields a square MSDF bitmap, inside above 0.5 and padded corner below")
    func generatesFilledGlyph() throws {
        let font = CTFontCreateWithName("Helvetica" as CFString, 32, nil)
        let generator = WPEMSDFGlyphGenerator()
        let result = try #require(generator.generate(glyph: glyph("B", font: font), font: font))
        let bitmap = result.bitmap

        #expect(bitmap.width == bitmap.height)
        #expect(bitmap.width > 0)
        #expect(bitmap.pixels.count == bitmap.width * bitmap.height)
        // Top-left corner sits in the transparent padding → outside → median < 0.5.
        #expect(median(bitmap[0, 0]) < 0.5)
        #expect(bitmap.pixels.contains { median($0) > 0.5 })
        // No NaN distances.
        #expect(bitmap.pixels.allSatisfy { $0.w == 1 && $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
    }

    @Test("Large on-screen font still rasterizes into the capped atlas cell (resolution independence)")
    func largeFontClampsToCellCap() throws {
        // A 256pt glyph would otherwise rasterize into a ~264px cell — a ~70k-pixel
        // signed-distance sweep that stalls the main thread. MSDF is resolution-
        // independent, so the cap keeps the atlas glyph tiny and the shader scales it.
        let font = CTFontCreateWithName("Helvetica" as CFString, 256, nil)
        let generator = WPEMSDFGlyphGenerator()
        let result = try #require(generator.generate(glyph: glyph("B", font: font), font: font))
        #expect(result.bitmap.width <= WPEMSDFParameters().generationCellCap)
        #expect(result.bitmap.width == result.bitmap.height)
        #expect(result.bitmap.pixels.contains { median($0) > 0.5 })
    }

    @Test("Glyph generation is deterministic")
    func generationIsDeterministic() throws {
        let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        let generator = WPEMSDFGlyphGenerator()
        let target = glyph("A", font: font)
        let first = try #require(generator.generate(glyph: target, font: font))
        let second = try #require(generator.generate(glyph: target, font: font))
        #expect(first.bitmap.pixels == second.bitmap.pixels)
    }

    @Test("Whitespace glyph has no outline → generator returns nil (atlas marks it skip)")
    func whitespaceGlyphReturnsNil() throws {
        // A space has no drawable outline. Returning nil lets the atlas mark it
        // `.skip` (advance, draw nothing) instead of emitting a 0.5-filled quad
        // that the MSDF shader would render as a gray box.
        let font = CTFontCreateWithName("Helvetica" as CFString, 32, nil)
        let generator = WPEMSDFGlyphGenerator()
        #expect(generator.generate(glyph: glyph(" ", font: font), font: font) == nil)
    }

    @Test("Counter glyph (O) is filled on the ring and empty in the hole")
    func counterGlyphHoleIsOutside() throws {
        // Guards the winding/orientation handling for glyphs with holes: the
        // enclosed counter must read as OUTSIDE (median < 0.5) while the ring
        // reads INSIDE (median > 0.5) — i.e. the hole isn't filled / inverted.
        let font = CTFontCreateWithName("Helvetica" as CFString, 32, nil)
        let generator = WPEMSDFGlyphGenerator()
        let result = try #require(generator.generate(glyph: glyph("O", font: font), font: font))
        let bitmap = result.bitmap
        let center = bitmap[bitmap.width / 2, bitmap.height / 2]
        #expect(median(center) < 0.5)                       // hole = outside
        #expect(bitmap.pixels.contains { median($0) > 0.5 }) // ring = inside
    }
}
