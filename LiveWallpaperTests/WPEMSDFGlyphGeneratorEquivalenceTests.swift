import CoreGraphics
import CoreText
import Testing
@testable import LiveWallpaper

/// Guards the two lossless speedups in the MSDF glyph generator:
///   A) per-segment bounding-box early-out in the nearest-segment search, and
///   B) hoisting the winding-number polyline flatten to once-per-glyph.
///
/// Both are pure CPU optimizations — the generated bitmaps MUST stay byte-for-
/// byte identical to the original brute-force path. `generateBruteForceReference`
/// rasterizes the same glyph via the un-optimized oracle so we can assert exact
/// equivalence, not just plausible invariants.
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

    /// Optimized output must be byte-identical to the brute-force reference across
    /// a spread of glyph shapes: straight edges (I), diagonals + junctions (A, B),
    /// deep curves (S, g, e), and a counter/hole (O) that exercises winding.
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
            // Exact equality: SIMD4<Float> stored verbatim, no quantization here.
            #expect(
                optimized.bitmap.pixels == reference.pixels,
                "bitmaps diverged for glyph \(character)"
            )
        }
    }

    /// The same equivalence must hold at the clamped generation size (the large-
    /// font resolution-independence path), where the cell is capped and every
    /// pixel maps to a very different query point.
    @Test("Optimized and reference agree at the capped generation cell size")
    func optimizedMatchesBruteForceAtCap() throws {
        let font = CTFontCreateWithName("Helvetica" as CFString, 256, nil)
        let generator = WPEMSDFGlyphGenerator()
        let target = glyph("B", font: font)

        let optimized = try #require(generator.generate(glyph: target, font: font))
        let reference = try #require(generator.generateBruteForceReference(glyph: target, font: font))
        #expect(optimized.bitmap.pixels == reference.pixels)
    }

    /// Belt-and-suspenders: even if the reference oracle were ever removed, these
    /// invariants must survive the optimizations. The O counter reads OUTSIDE in
    /// the hole and INSIDE on the ring, and the fill sign is correct.
    @Test("Winding invariants survive the optimizations (O counter, filled interior)")
    func windingInvariantsHold() throws {
        let font = CTFontCreateWithName("Helvetica" as CFString, 32, nil)
        let generator = WPEMSDFGlyphGenerator()

        let o = try #require(generator.generate(glyph: glyph("O", font: font), font: font)).bitmap
        #expect(median(o[o.width / 2, o.height / 2]) < 0.5)   // hole = outside
        #expect(o.pixels.contains { median($0) > 0.5 })        // ring = inside

        let b = try #require(generator.generate(glyph: glyph("B", font: font), font: font)).bitmap
        #expect(median(b[0, 0]) < 0.5)                         // padded corner = outside
        #expect(b.pixels.contains { median($0) > 0.5 })        // stroke = inside
    }
}
