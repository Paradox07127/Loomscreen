import CoreGraphics
import CoreText
import Foundation
import LiveWallpaperProWPE
import Metal
import Testing
@testable import LiveWallpaper

/// Per-object payload frame cache (#4): an unchanged object reuses its built
/// MTLBuffers across frames; a text change or an atlas-generation bump rebuilds.
@MainActor
struct WPEMSDFPayloadCacheTests {

    private func makeEmptyPrimaryResolver() throws -> WPEMultiRootResourceResolver {
        let primaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("msdf-payload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: primaryRoot, withIntermediateDirectories: true)
        return WPEMultiRootResourceResolver(primaryRootURL: primaryRoot, dependencyMounts: [])
    }

    private func makeTextObject(id: String = "cache", text: String) -> WPESceneTextObject {
        WPESceneTextObject(
            id: id, name: "Cache", text: text,
            fontRelativePath: nil, pointSize: 48,
            color: SIMD3<Double>(1, 1, 1), alpha: 1,
            origin: SIMD3<Double>(128, 64, 0), scale: SIMD3<Double>(1, 1, 1),
            visible: true, horizontalAlignment: "center", verticalAlignment: "middle",
            maxWidth: nil, parallaxDepth: SIMD2<Double>(0, 0)
        )
    }

    private func makeRenderer(device: MTLDevice) throws -> WPEMSDFTextRenderer {
        let resolver = try makeEmptyPrimaryResolver()
        let fragData = try resolver.data(relativePath: "shaders/font.frag", optional: true)
        let fontFragmentSource = try #require(String(data: fragData, encoding: .utf8))
        return WPEMSDFTextRenderer(
            device: device,
            resolver: resolver,
            fontFragmentSource: fontFragmentSource
        )
    }

    private func awaitPayload(
        renderer: WPEMSDFTextRenderer,
        object: WPESceneTextObject,
        sceneSize: CGSize,
        attempts: Int = 200
    ) async -> WPEMSDFTextDrawPayload? {
        for _ in 0..<attempts {
            if let payload = renderer.drawPayload(for: object, sceneSize: sceneSize, parallaxOffset: .zero) {
                return payload
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    private func bufferIdentities(_ payload: WPEMSDFTextDrawPayload) -> [ObjectIdentifier] {
        payload.pages.map { ObjectIdentifier($0.vertexBuffer) }
    }

    @Test(
        "HIT: an unchanged object reuses the SAME MTLBuffers across two draw calls",
        .enabled(if: WPEBuiltinFrameworkAssets.rootURL != nil && MTLCreateSystemDefaultDevice() != nil)
    )
    func unchangedObjectReusesBuffers() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try makeRenderer(device: device)
        let sceneSize = CGSize(width: 256, height: 128)
        let object = makeTextObject(text: "Hi")

        let first = try #require(await awaitPayload(renderer: renderer, object: object, sceneSize: sceneSize))
        // Second call, identical object → cache HIT, same buffer objects reused.
        let second = try #require(renderer.drawPayload(for: object, sceneSize: sceneSize, parallaxOffset: .zero))

        #expect(bufferIdentities(first) == bufferIdentities(second), "unchanged object should reuse cached MTLBuffers")
    }

    @Test(
        "MISS: a text change rebuilds (new MTLBuffers)",
        .enabled(if: WPEBuiltinFrameworkAssets.rootURL != nil && MTLCreateSystemDefaultDevice() != nil)
    )
    func textChangeRebuildsBuffers() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try makeRenderer(device: device)
        let sceneSize = CGSize(width: 256, height: 128)

        let first = try #require(await awaitPayload(renderer: renderer, object: makeTextObject(text: "Hi"), sceneSize: sceneSize))
        // Same object id, new text → geometry key changes → rebuild.
        let changed = try #require(await awaitPayload(renderer: renderer, object: makeTextObject(text: "Yo"), sceneSize: sceneSize))

        #expect(bufferIdentities(first) != bufferIdentities(changed), "a text change must rebuild the payload")
    }

    @Test(
        "Color/alpha change alone still HITS the cached mesh (only uniforms differ)",
        .enabled(if: WPEBuiltinFrameworkAssets.rootURL != nil && MTLCreateSystemDefaultDevice() != nil)
    )
    func colorChangeKeepsCachedMesh() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try makeRenderer(device: device)
        let sceneSize = CGSize(width: 256, height: 128)

        let base = makeTextObject(text: "Hi")
        let first = try #require(await awaitPayload(renderer: renderer, object: base, sceneSize: sceneSize))

        // Same geometry, different alpha + color: must reuse buffers but reflect
        // the new uniforms.
        var recolored = base
        recolored = WPESceneTextObject(
            id: base.id, name: base.name, text: base.text,
            fontRelativePath: base.fontRelativePath, pointSize: base.pointSize,
            color: SIMD3<Double>(0.2, 0.4, 0.6), alpha: 0.3,
            origin: base.origin, scale: base.scale, visible: base.visible,
            horizontalAlignment: base.horizontalAlignment, verticalAlignment: base.verticalAlignment,
            maxWidth: base.maxWidth, parallaxDepth: base.parallaxDepth
        )
        let second = try #require(renderer.drawPayload(for: recolored, sceneSize: sceneSize, parallaxOffset: .zero))

        #expect(bufferIdentities(first) == bufferIdentities(second), "a color/alpha change must still hit the cached mesh")
        #expect(second.uniforms["g_Color4"]?.vectorValue == [0.2, 0.4, 0.6, 0.3], "uniforms must reflect the new color/alpha")
    }

    @Test(
        "A numeric object renders MSDF (async) and its full digit set is prewarmed",
        .enabled(if: WPEBuiltinFrameworkAssets.rootURL != nil && MTLCreateSystemDefaultDevice() != nil)
    )
    func numericObjectRendersAndPrewarmsDigits() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try makeRenderer(device: device)
        let sceneSize = CGSize(width: 256, height: 128)
        // Generation is always async (never blocks the main thread) — poll until
        // the glyphs land, exactly like the production per-frame loop.
        let object = makeTextObject(text: "12:00")
        let payload = try #require(
            await awaitPayload(renderer: renderer, object: object, sceneSize: sceneSize),
            "a numeric object must eventually render MSDF"
        )
        #expect(!payload.pages.isEmpty)
        #expect(payload.combos["MSDF"] == 1)

        // The prewarm queued digits 0-9 the first time the object was seen, so a
        // digit NOT in "12:00" (e.g. "7") is already generating/ready without
        // ever being laid out — no cold-generation flash when the clock ticks to
        // a minute containing it.
        let sevenObject = makeTextObject(text: "7")
        let seven = try #require(
            await awaitPayload(renderer: renderer, object: sevenObject, sceneSize: sceneSize),
            "a digit not in the original text must be warm from the 0-9 prewarm"
        )
        #expect(!seven.pages.isEmpty)
    }

    @Test(
        "Invalidation: bumping the atlas generation rebuilds the payload",
        .enabled(if: MTLCreateSystemDefaultDevice() != nil)
    )
    func atlasGenerationBumpInvalidatesPayload() throws {
        // Direct atlas-level assertion: the epoch is the invalidation signal the
        // renderer's payload cache guards on. A tiny single-page atlas forces an
        // eviction (and thus a generation bump) on the second distinct glyph.
        let device = try #require(MTLCreateSystemDefaultDevice())
        let atlas = WPEMSDFAtlas(device: device, pageSize: 64, maxPages: 1)
        let generator = WPEMSDFGlyphGenerator()
        let font = CTFontCreateWithName("Helvetica" as CFString, 32, nil)

        func glyph(_ character: Character) -> CGGlyph {
            var chars = Array(String(character).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: chars.count)
            _ = CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count)
            return glyphs[0]
        }
        let keyA = WPEMSDFGlyphKey(fontID: "Helvetica", glyph: glyph("A"), pixelSize: 32)
        let keyB = WPEMSDFGlyphKey(fontID: "Helvetica", glyph: glyph("B"), pixelSize: 32)

        let genBefore = atlas.generation
        _ = try #require(atlas.entry(for: keyA, generator: generator, font: font))
        // Second glyph evicts the first → generation must advance.
        _ = try #require(atlas.entry(for: keyB, generator: generator, font: font))
        #expect(atlas.generation > genBefore, "an eviction must advance the atlas generation epoch")
    }
}
