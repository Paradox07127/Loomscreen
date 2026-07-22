import CoreGraphics
import CoreText
import Metal
import Testing
@testable import LiveWallpaper

@MainActor
struct WPEMSDFAtlasTests {

    private func glyph(_ character: Character, font: CTFont) -> CGGlyph {
        var chars = Array(String(character).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        _ = CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count)
        return glyphs[0]
    }

    @Test("Atlas packs a glyph, caches the entry, and exposes a page texture")
    func packsAndCaches() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let font = CTFontCreateWithName("Helvetica" as CFString, 32, nil)
        let generator = WPEMSDFGlyphGenerator()
        let atlas = WPEMSDFAtlas(device: device)
        let key = WPEMSDFGlyphKey(fontID: "Helvetica", glyph: glyph("A", font: font), pixelSize: 32)

        let first = try #require(atlas.entry(for: key, generator: generator, font: font))
        let second = try #require(atlas.entry(for: key, generator: generator, font: font))

        #expect(first.page == second.page)
        #expect(first.uvRect == second.uvRect)
        #expect(first.uvRect.minX >= 0 && first.uvRect.maxX <= 1)
        #expect(first.uvRect.minY >= 0 && first.uvRect.maxY <= 1)
        #expect(atlas.texture(page: first.page) != nil)
    }

    @Test("Atlas evicts the LRU page when full and regenerates on demand")
    func evictsLeastRecentlyUsedPage() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let font = CTFontCreateWithName("Helvetica" as CFString, 32, nil)
        let generator = WPEMSDFGlyphGenerator()
        let atlas = WPEMSDFAtlas(device: device, pageSize: 64, maxPages: 1)
        let keyA = WPEMSDFGlyphKey(fontID: "Helvetica", glyph: glyph("A", font: font), pixelSize: 32)
        let keyB = WPEMSDFGlyphKey(fontID: "Helvetica", glyph: glyph("B", font: font), pixelSize: 32)

        _ = try #require(atlas.entry(for: keyA, generator: generator, font: font))
        let b = try #require(atlas.entry(for: keyB, generator: generator, font: font))
        #expect(atlas.livePages().count <= 1)

        let aAgain = try #require(atlas.entry(for: keyA, generator: generator, font: font))
        #expect(aAgain.page == b.page)
    }

    @Test("Eviction advances the atlas generation epoch (payload-cache invalidation signal)")
    func evictionAdvancesGeneration() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let font = CTFontCreateWithName("Helvetica" as CFString, 32, nil)
        let generator = WPEMSDFGlyphGenerator()
        let atlas = WPEMSDFAtlas(device: device, pageSize: 64, maxPages: 1)
        let keyA = WPEMSDFGlyphKey(fontID: "Helvetica", glyph: glyph("A", font: font), pixelSize: 32)
        let keyB = WPEMSDFGlyphKey(fontID: "Helvetica", glyph: glyph("B", font: font), pixelSize: 32)

        let before = atlas.generation
        _ = try #require(atlas.entry(for: keyA, generator: generator, font: font))
        _ = try #require(atlas.entry(for: keyB, generator: generator, font: font))
        #expect(atlas.generation > before, "eviction must bump the generation epoch")
    }
}
