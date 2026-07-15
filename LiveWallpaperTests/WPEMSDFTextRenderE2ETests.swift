import CoreGraphics
import CoreText
import Foundation
import LiveWallpaperProWPE
import Metal
import Testing
@testable import LiveWallpaper

/// End-to-end gate for the GPU MSDF text path: the bundled clean-room
/// `shaders/font.frag` resolves through the builtin fallback (the same cascade
/// `resolveMSDFFontFragmentSource()` uses), `WPEMSDFTextRenderer` produces a
/// draw payload, and `executor.drawMSDFText` puts real glyph coverage into an
/// offscreen texture — compared loosely against the CoreText rasterizer that
/// serves as the fallback path.
///
/// Single-line text only: multi-line / wrapping objects are deliberately
/// punted to CoreText by `WPEMSDFTextLayout` and stay out of scope here.
@MainActor
@Suite("GPU MSDF text end-to-end")
struct WPEMSDFTextRenderE2ETests {

    // MARK: - Fixtures

    /// Empty primary root so `shaders/font.frag` can only resolve through the
    /// app-bundled built-ins — exactly the zero-config user situation.
    /// The resolver keeps its primary root private, so the root comes back
    /// alongside it for callers to `defer`-remove.
    private func makeEmptyPrimaryResolver() throws -> (resolver: WPEMultiRootResourceResolver, root: URL) {
        let primaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("msdf-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: primaryRoot, withIntermediateDirectories: true)
        return (WPEMultiRootResourceResolver(primaryRootURL: primaryRoot, dependencyMounts: []), primaryRoot)
    }

    private func makeTextObject(text: String = "Hi", origin: SIMD3<Double>) -> WPESceneTextObject {
        WPESceneTextObject(
            id: "e2e",
            name: "E2E",
            text: text,
            fontRelativePath: nil,
            pointSize: 64,
            color: SIMD3<Double>(1, 1, 1),
            alpha: 1,
            origin: origin,
            scale: SIMD3<Double>(1, 1, 1),
            visible: true,
            horizontalAlignment: "center",
            verticalAlignment: "middle",
            maxWidth: nil,
            parallaxDepth: SIMD2<Double>(0, 0)
        )
    }

    /// Glyph generation is async (off-main): the first payload is nil while the
    /// atlas fills in the background; poll like the production per-frame loop.
    private func awaitPayload(
        renderer: WPEMSDFTextRenderer,
        object: WPESceneTextObject,
        sceneSize: CGSize,
        attempts: Int = 200
    ) async -> WPEMSDFTextDrawPayload? {
        for _ in 0..<attempts {
            if let payload = renderer.drawPayload(
                for: object,
                sceneSize: sceneSize,
                parallaxOffset: SIMD2<Float>(0, 0)
            ) {
                return payload
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    private func makeOutputTexture(device: MTLDevice, width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        // drawMSDFText loads the existing contents (composite pass); start from
        // fully transparent black so every non-zero pixel is glyph coverage.
        let zeroes = [UInt8](repeating: 0, count: width * height * 4)
        zeroes.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: width * 4
            )
        }
        return texture
    }

    // MARK: - Resolution preconditions (mirrors resolveMSDFFontFragmentSource)

    @Test(
        "font.frag resolves through the builtin fallback with an empty scene root",
        .enabled(if: WPEBuiltinFrameworkAssets.rootURL != nil)
    )
    func fontFragResolvesThroughBuiltinFallback() throws {
        let (resolver, primaryRoot) = try makeEmptyPrimaryResolver()
        defer { try? FileManager.default.removeItem(at: primaryRoot) }
        // Same call shape as resolveMSDFFontFragmentSource() in the renderer.
        let data = try resolver.data(relativePath: "shaders/font.frag", optional: true)
        let source = try #require(String(data: data, encoding: .utf8))
        #expect(!source.isEmpty)
        #expect(source.contains("gl_FragColor"))
        // Clean-room marker: the shipped shader is ours, not an engine copy.
        #expect(source.contains("clean-room"))
    }

    @Test("Without the builtin root the fragment source misses → renderer stays nil")
    func missingBuiltinRootLeavesCoreTextOnly() throws {
        let primaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("msdf-e2e-neg-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: primaryRoot) }
        try FileManager.default.createDirectory(at: primaryRoot, withIntermediateDirectories: true)
        let resolver = WPEMultiRootResourceResolver(
            primaryRootURL: primaryRoot,
            dependencyMounts: [],
            builtinRootURL: nil
        )
        // Both candidate paths that resolveMSDFFontFragmentSource() probes must
        // miss, which is what keeps msdfTextRenderer nil (CoreText-only).
        #expect(throws: SceneResourceResolver.ResolveError.fileMissing) {
            _ = try resolver.data(relativePath: "shaders/font.frag", optional: true)
        }
        #expect(throws: SceneResourceResolver.ResolveError.fileMissing) {
            _ = try resolver.data(relativePath: "shaders/effects/font.frag", optional: true)
        }
    }

    // MARK: - End-to-end pixel test

    @Test(
        "Bundled font.frag renders visible glyph coverage that tracks the CoreText baseline",
        .enabled(if: WPEBuiltinFrameworkAssets.rootURL != nil && MTLCreateSystemDefaultDevice() != nil)
    )
    func rendersGlyphCoverageMatchingCoreTextBaseline() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        executor.synchronizeFrameCompletion = true

        let (resolver, primaryRoot) = try makeEmptyPrimaryResolver()
        defer { try? FileManager.default.removeItem(at: primaryRoot) }
        let fragData = try resolver.data(relativePath: "shaders/font.frag", optional: true)
        let fontFragmentSource = try #require(String(data: fragData, encoding: .utf8))

        let sceneSize = CGSize(width: 256, height: 128)
        let object = makeTextObject(origin: SIMD3<Double>(128, 64, 0))
        let renderer = WPEMSDFTextRenderer(
            device: device,
            resolver: resolver,
            fontFragmentSource: fontFragmentSource
        )

        let payload = try #require(
            await awaitPayload(renderer: renderer, object: object, sceneSize: sceneSize)
        )
        #expect(!payload.pages.isEmpty)
        #expect(payload.combos["MSDF"] == 1)

        let output = try makeOutputTexture(device: device, width: 256, height: 128)
        try executor.drawMSDFText(payloads: [payload], sceneSize: sceneSize, output: output)

        // Non-empty coverage: enough lit pixels for "Hi" at 64 pt, with a
        // solid (near-opaque, near-white) interior.
        let ink = try #require(inkBounds(of: output), "MSDF draw produced an empty frame")
        #expect(ink.pixelCount > 200, "expected substantive glyph coverage, got \(ink.pixelCount) px")
        #expect(ink.maxChannel >= 200, "expected a solid glyph interior, got max channel \(ink.maxChannel)")

        // The glyph box is centered on object.origin; ink is roughly centered
        // in the box. Generous tolerance — this is a placement sanity gate,
        // not a rasterization-exactness gate.
        #expect(abs(ink.centerX - 128) <= 24, "ink center x \(ink.centerX) strayed from origin 128")
        #expect(abs(ink.centerY - 64) <= 24, "ink center y \(ink.centerY) strayed from origin 64")

        // Loose CoreText baseline: the fallback rasterizer's ink for the SAME
        // object should have comparable dimensions (both draw "Hi" at 64 pt).
        // MSDF AA and CoreText hinting differ, so compare ratios, not pixels.
        let coreText = WPETextRenderer(device: device, resolver: resolver)
        let baseline = try #require(coreText.rasterize(object))
        let baselineInk = try #require(inkBounds(of: baseline.texture), "CoreText baseline drew nothing")
        let widthRatio = Double(ink.width) / Double(max(baselineInk.width, 1))
        let heightRatio = Double(ink.height) / Double(max(baselineInk.height, 1))
        #expect(widthRatio > 0.55 && widthRatio < 1.8, "ink width diverged from CoreText: ratio \(widthRatio)")
        #expect(heightRatio > 0.55 && heightRatio < 1.8, "ink height diverged from CoreText: ratio \(heightRatio)")
    }

    @Test(
        "WPE author-space origin (+Y up) lands on the correct screen row and glyphs read upright",
        .enabled(if: WPEBuiltinFrameworkAssets.rootURL != nil && MTLCreateSystemDefaultDevice() != nil)
    )
    func authorSpaceOriginIsYUpAndGlyphsUpright() async throws {
        // Regression for the y-mirror: WPE text origins are +Y UP (y=0 at the
        // scene BOTTOM — the CoreText overlay path maps them to NDC unflipped),
        // but the MSDF mesh/vertex path works in top-left y-DOWN pixels. The
        // ortho branch passed the author origin through unconverted, so all
        // MSDF text mirrored about the horizontal midline the moment the async
        // atlas finished and the path took over from CoreText. A CENTERED
        // fixture can't see that mirror — this one is authored off-center.
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        executor.synchronizeFrameCompletion = true

        let (resolver, primaryRoot) = try makeEmptyPrimaryResolver()
        defer { try? FileManager.default.removeItem(at: primaryRoot) }
        let fragData = try resolver.data(relativePath: "shaders/font.frag", optional: true)
        let fontFragmentSource = try #require(String(data: fragData, encoding: .utf8))

        let sceneSize = CGSize(width: 256, height: 128)
        // Author space: y=88 of 128 is well ABOVE the vertical center → the
        // text must render in the TOP half, ink center near screen row
        // 128 − 88 = 40. The mirror bug drew it at row ≈88 instead.
        let object = makeTextObject(text: "T", origin: SIMD3<Double>(128, 88, 0))
        let renderer = WPEMSDFTextRenderer(
            device: device,
            resolver: resolver,
            fontFragmentSource: fontFragmentSource
        )
        let payload = try #require(
            await awaitPayload(renderer: renderer, object: object, sceneSize: sceneSize)
        )
        let output = try makeOutputTexture(device: device, width: 256, height: 128)
        try executor.drawMSDFText(payloads: [payload], sceneSize: sceneSize, output: output)

        let ink = try #require(inkBounds(of: output), "MSDF draw produced an empty frame")
        #expect(abs(ink.centerY - 40) <= 24, "author y=88 (y-up) must land near screen row 40, got \(ink.centerY)")
        #expect(ink.centerY < 64, "text authored above center rendered in the bottom half (y-mirror regression)")

        // Glyph orientation, asserted against SCREEN truth: "T" is top-heavy
        // (full-width crossbar at the top, narrow stem below) in any Latin font,
        // so the ink mass in the rendered frame must sit in the TOP half of the
        // ink box. This is deliberately absolute — an earlier version compared
        // signs against `WPETextRenderer.rasterize`'s texture, but that texture
        // is stored bottom-up (CG convention; the overlay vertex shader
        // compensates via its uv corners), so an upside-down MSDF glyph and the
        // flipped baseline agreed and the check passed falsely.
        let msdfTop = try #require(inkTopHalfFraction(of: output))
        #expect(
            msdfTop > 0.5,
            "\"T\" rendered bottom-heavy (top ink fraction \(msdfTop)) — MSDF glyphs are upside down in place"
        )
    }

    // MARK: - Canonical-size atlas keying

    private func awaitMesh(
        layout: WPEMSDFTextLayout,
        object: WPESceneTextObject,
        font: CTFont,
        atlas: WPEMSDFAtlas,
        generator: WPEMSDFGlyphGenerator,
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

    @Test(
        "Two font sizes share ONE canonical atlas entry and scale via em metrics",
        .enabled(if: MTLCreateSystemDefaultDevice() != nil)
    )
    func canonicalSizeKeysShareAtlasEntries() async throws {
        // Regression for the clock-tick regen storm: the glyph key used to embed
        // the LIVE pixel size (and the fontID embedded it again), so box-fit text
        // whose fitted size moved with the current line width — a ticking clock
        // with non-tabular digits — regenerated its whole glyph set every second
        // (sustained CPU burn) and flickered back to CoreText while regenerated
        // glyphs were pending. Distance fields are resolution-independent:
        // one canonical-size entry must serve every on-screen size.
        let device = try #require(MTLCreateSystemDefaultDevice())
        let atlas = WPEMSDFAtlas(device: device)
        let generator = WPEMSDFGlyphGenerator()
        let layout = WPEMSDFTextLayout()
        let object = makeTextObject(text: "11", origin: SIMD3<Double>(0, 0, 0))
        let font32 = CTFontCreateWithName("Helvetica" as CFString, 32, nil)
        let font64 = CTFontCreateWithName("Helvetica" as CFString, 64, nil)

        let mesh32 = try #require(
            await awaitMesh(layout: layout, object: object, font: font32, atlas: atlas, generator: generator)
        )
        let entriesAfterFirstSize = atlas.entryCount
        #expect(entriesAfterFirstSize == 1, "\"11\" has one unique glyph; got \(entriesAfterFirstSize) entries")

        let mesh64 = try #require(
            await awaitMesh(layout: layout, object: object, font: font64, atlas: atlas, generator: generator)
        )
        #expect(
            atlas.entryCount == entriesAfterFirstSize,
            "a second font size forked new atlas entries (\(atlas.entryCount)) — canonical keying is broken"
        )

        // Em-metric scaling: the 64 pt mesh must be ~2× the 32 pt mesh.
        func inkWidth(_ mesh: WPEMSDFTextMesh) -> Float {
            let xs = mesh.perPage.values.flatMap { $0 }.map(\.position.x)
            return (xs.max() ?? 0) - (xs.min() ?? 0)
        }
        let ratio = Double(inkWidth(mesh64)) / Double(max(inkWidth(mesh32), 0.001))
        #expect(ratio > 1.8 && ratio < 2.2, "64 pt / 32 pt mesh width ratio \(ratio), expected ≈2")
    }
}

// MARK: - Pixel readback helpers

private struct InkBounds {
    var minX: Int
    var minY: Int
    var maxX: Int
    var maxY: Int
    var pixelCount: Int
    var maxChannel: UInt8

    var width: Int { maxX - minX + 1 }
    var height: Int { maxY - minY + 1 }
    var centerX: Double { Double(minX + maxX) * 0.5 }
    var centerY: Double { Double(minY + maxY) * 0.5 }
}

/// Fraction of total ink mass in the TOP half of the ink bounding box —
/// orientation probe: an upside-down glyph inverts a letterform's vertical
/// asymmetry. Nil when the frame is empty.
private func inkTopHalfFraction(of texture: MTLTexture, threshold: UInt8 = 8) -> Double? {
    guard let bounds = inkBounds(of: texture, threshold: threshold) else { return nil }
    var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
    texture.getBytes(
        &bytes,
        bytesPerRow: texture.width * 4,
        from: MTLRegionMake2D(0, 0, texture.width, texture.height),
        mipmapLevel: 0
    )
    let midY = Double(bounds.minY + bounds.maxY) * 0.5
    var top = 0.0
    var total = 0.0
    for y in bounds.minY...bounds.maxY {
        for x in bounds.minX...bounds.maxX {
            let index = (y * texture.width + x) * 4
            let value = max(max(bytes[index], bytes[index + 1]), max(bytes[index + 2], bytes[index + 3]))
            guard value > threshold else { continue }
            total += Double(value)
            if Double(y) < midY { top += Double(value) }
        }
    }
    guard total > 0 else { return nil }
    return top / total
}

/// Bounding box of "inked" pixels (any channel above a small threshold) in a
/// shared rgba8Unorm texture; nil when the frame is empty.
private func inkBounds(of texture: MTLTexture, threshold: UInt8 = 8) -> InkBounds? {
    var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
    texture.getBytes(
        &bytes,
        bytesPerRow: texture.width * 4,
        from: MTLRegionMake2D(0, 0, texture.width, texture.height),
        mipmapLevel: 0
    )
    var bounds: InkBounds?
    for y in 0..<texture.height {
        for x in 0..<texture.width {
            let index = (y * texture.width + x) * 4
            let value = max(max(bytes[index], bytes[index + 1]), max(bytes[index + 2], bytes[index + 3]))
            guard value > threshold else { continue }
            if var current = bounds {
                current.minX = min(current.minX, x)
                current.minY = min(current.minY, y)
                current.maxX = max(current.maxX, x)
                current.maxY = max(current.maxY, y)
                current.pixelCount += 1
                current.maxChannel = max(current.maxChannel, value)
                bounds = current
            } else {
                bounds = InkBounds(minX: x, minY: y, maxX: x, maxY: y, pixelCount: 1, maxChannel: value)
            }
        }
    }
    return bounds
}
