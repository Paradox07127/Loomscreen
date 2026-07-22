import CoreGraphics
import CoreText
import Testing
@testable import LiveWallpaper

struct WPEMSDFGlyphGeneratorEquivalenceTests {

    private func glyph(_ character: Character, font: CTFont) -> CGGlyph {
        var chars = Array(String(character).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        _ = CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count)
        return glyphs[0]
    }

    private func median(_ pixel: SIMD4<Float>) -> Float {
        max(min(pixel.x, pixel.y), min(max(pixel.x, pixel.y), pixel.z))
    }

    @Test("Optimized MSDF bitmap is byte-identical to the brute-force reference")
    func optimizedMatchesBruteForce() throws {
        let font = CTFontCreateWithName("Helvetica" as CFString, 32, nil)
        let generator = WPEMSDFGlyphGenerator()

        for character: Character in ["I", "A", "B", "O", "S", "g", "e", "Q", "8", "R"] {
            let target = glyph(character, font: font)
            let optimized = try #require(
                generator.generate(glyph: target, font: font),
                "optimized path returned nil for \(character)"
            )
            let reference = try #require(
                generator.generateBruteForceReference(glyph: target, font: font),
                "reference path returned nil for \(character)"
            )

            #expect(optimized.bitmap.width == reference.width)
            #expect(optimized.bitmap.height == reference.height)
            #expect(
                optimized.bitmap.pixels == reference.pixels,
                "bitmaps diverged for glyph \(character)"
            )
        }
    }

    @Test("Optimized and reference agree at the capped generation cell size")
    func optimizedMatchesBruteForceAtCap() throws {
        let font = CTFontCreateWithName("Helvetica" as CFString, 256, nil)
        let generator = WPEMSDFGlyphGenerator()
        let target = glyph("B", font: font)

        let optimized = try #require(generator.generate(glyph: target, font: font))
        let reference = try #require(generator.generateBruteForceReference(glyph: target, font: font))
        #expect(optimized.bitmap.pixels == reference.pixels)
    }

    @Test("Winding invariants survive the optimizations (O counter, filled interior)")
    func windingInvariantsHold() throws {
        let font = CTFontCreateWithName("Helvetica" as CFString, 32, nil)
        let generator = WPEMSDFGlyphGenerator()

        let o = try #require(generator.generate(glyph: glyph("O", font: font), font: font)).bitmap
        #expect(median(o[o.width / 2, o.height / 2]) < 0.5)
        #expect(o.pixels.contains { median($0) > 0.5 })

        let b = try #require(generator.generate(glyph: glyph("B", font: font), font: font)).bitmap
        #expect(median(b[0, 0]) < 0.5)
        #expect(b.pixels.contains { median($0) > 0.5 })
    }
}
