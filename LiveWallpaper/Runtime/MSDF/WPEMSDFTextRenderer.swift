#if !LITE_BUILD
import CoreGraphics
import CoreText
import Foundation
import LiveWallpaperProWPE
import Metal
import simd

struct WPEMSDFTextPageDraw {
    let page: Int
    let vertexBuffer: MTLBuffer
    let vertexCount: Int
    let texture: MTLTexture
}

struct WPEMSDFTextDrawPayload {
    let pages: [WPEMSDFTextPageDraw]
    /// Rebuilt cheaply every frame from the object's color/alpha (#4): NOT part
    /// of the frame cache key, so animated-alpha / recolored text keeps hitting
    /// the cached mesh while only these uniforms change.
    var uniforms: [String: WPESceneShaderConstantValue]
    let combos: [String: Int]
    let shaderRequest: WPEShaderCompileRequest
}

@MainActor
final class WPEMSDFTextRenderer {
    private let device: MTLDevice
    private let resolver: WPEMultiRootResourceResolver
    private let fontFragmentSource: String
    private let parameters: WPEMSDFParameters
    private let atlas: WPEMSDFAtlas
    private let generator: WPEMSDFGlyphGenerator
    private let layout = WPEMSDFTextLayout()
    private var registeredFonts: Set<String> = []
    /// Memoizes the box-fit font size per (text, font, box) state — `drawPayload`
    /// runs every frame and the fit otherwise re-created a CTFont + CTLine each
    /// time. A ticking clock cycles through a small set of texts, so this stays
    /// hot; cleared wholesale on overflow (no LRU bookkeeping needed).
    private var fittedFontSizeCache: [String: CGFloat] = [:]

    // MARK: - Per-object payload frame cache (#4)

    /// A cached built payload keyed by geometry, reused across frames while the
    /// object's geometry is unchanged. `mesh`/`pages` (the MTLBuffers + page
    /// textures) are the expensive part; color/alpha are re-applied per frame.
    private struct CachedPayload {
        let geometryKey: String
        /// Atlas epoch when this payload was built. If the atlas has evicted a
        /// page since (epoch advanced), the vertex UVs may point at overwritten
        /// pixels — the payload must be rebuilt (see `WPEMSDFAtlas.generation`).
        let atlasGeneration: UInt64
        let payload: WPEMSDFTextDrawPayload
    }

    /// Cached payloads keyed by object id. drawPayload re-ran full CTLine layout
    /// + per-page `makeBuffer` EVERY frame for EVERY visible text object even
    /// when nothing changed; this reuses the built mesh across frames.
    private var payloadCache: [String: CachedPayload] = [:]

    init(
        device: MTLDevice,
        resolver: WPEMultiRootResourceResolver,
        fontFragmentSource: String,
        parameters: WPEMSDFParameters = WPEMSDFParameters()
    ) {
        self.device = device
        self.resolver = resolver
        self.fontFragmentSource = fontFragmentSource
        self.parameters = parameters
        self.atlas = WPEMSDFAtlas(device: device)
        self.generator = WPEMSDFGlyphGenerator(parameters: parameters)
    }

    /// - Parameters:
    ///   - originOverride: When non-nil, the text-box center in absolute top-left
    ///     scene pixels WITH parallax already folded in, used instead of
    ///     `object.origin + parallaxOffset`. The renderer supplies this for
    ///     perspective scenes (world-unit origin camera-projected to pixels) AND
    ///     for ortho objects whose origin was live-recomposed through a
    ///     script-driven parent chain.
    ///   - sizeScale: Extra uniform scale applied on top of `object.scale`
    ///     (focal ÷ depth for perspective; 1 for ortho) so distant text shrinks.
    ///   - rotation: Composed z rotation (radians, author-space CCW) inherited
    ///     from the object's transform-host chain; the quad rotates around the
    ///     text-box center (3470764447's -15° 总组件角度 tilts its clock stack).
    func drawPayload(
        for object: WPESceneTextObject,
        sceneSize: CGSize,
        parallaxOffset: SIMD2<Float>,
        originOverride: SIMD2<Double>? = nil,
        sizeScale: Double = 1,
        rotation: Double = 0
    ) -> WPEMSDFTextDrawPayload? {
        let material = WPEMSDFFontMaterial.make(object: object, parameters: parameters)

        // #4: reuse the cached mesh/buffers if geometry is unchanged AND the
        // atlas hasn't evicted a page since (which could repoint our UVs). Only
        // the uniforms (color/alpha) are rebuilt each frame.
        let geometryKey = payloadGeometryKey(
            object: object,
            sceneSize: sceneSize,
            parallaxOffset: parallaxOffset,
            originOverride: originOverride,
            sizeScale: sizeScale,
            rotation: rotation,
            combos: material.combos
        )
        if let cached = payloadCache[object.id],
           cached.geometryKey == geometryKey,
           cached.atlasGeneration == atlas.generation {
            var reused = cached.payload
            reused.uniforms = material.uniforms
            return reused
        }

        let font = resolveFont(for: object)
        guard let request = try? shaderRequest(comboValues: material.combos) else { return nil }

        // Glyph generation is ALWAYS asynchronous (off-main). The first layout of
        // an uncached object returns nil (→ CoreText for a frame or two) while its
        // glyphs generate on background threads; once ready the object flips to
        // MSDF. Generating inline here would block the @MainActor render loop —
        // a text/CJK-heavy scene's whole glyph set is millions–billions of float
        // ops and beachballed the first frame for seconds. Warm/disk-cached
        // glyphs are returned immediately by the async path (`.ready`), so
        // already-cached text still shows MSDF on frame 1 with no stall.
        guard let mesh = layout.layout(
            object: object,
            font: font,
            atlas: atlas,
            generator: generator
        ) else {
            // Nothing to draw yet (glyphs pending) — but make sure this object's
            // FULL character set is queued so a ticking clock's not-yet-seen
            // digits are already warming before they first appear (kills the
            // per-digit CoreText flash when the minute rolls over).
            prewarmGlyphs(for: object, font: font)
            return nil
        }
        prewarmGlyphs(for: object, font: font)

        // Snapshot the epoch BEFORE building buffers so an eviction that races
        // in later is caught by the guard on the next frame.
        let builtAtGeneration = atlas.generation
        let transformed = transform(
            mesh: mesh,
            object: object,
            sceneSize: sceneSize,
            parallaxOffset: parallaxOffset,
            originOverride: originOverride,
            sizeScale: sizeScale,
            rotation: rotation
        )
        let pages = transformed.perPage.keys.sorted().compactMap { page -> WPEMSDFTextPageDraw? in
            guard let vertices = transformed.perPage[page], !vertices.isEmpty,
                  let texture = atlas.texture(page: page) else {
                return nil
            }
            let buffer = vertices.withUnsafeBytes { rawBuffer -> MTLBuffer? in
                guard let baseAddress = rawBuffer.baseAddress else { return nil }
                return device.makeBuffer(bytes: baseAddress, length: rawBuffer.count, options: [])
            }
            guard let buffer else { return nil }
            return WPEMSDFTextPageDraw(
                page: page,
                vertexBuffer: buffer,
                vertexCount: vertices.count,
                texture: texture
            )
        }
        guard pages.count == transformed.perPage.count, !pages.isEmpty else { return nil }
        let payload = WPEMSDFTextDrawPayload(
            pages: pages,
            uniforms: material.uniforms,
            combos: material.combos,
            shaderRequest: request
        )
        payloadCache[object.id] = CachedPayload(
            geometryKey: geometryKey,
            atlasGeneration: builtAtGeneration,
            payload: payload
        )
        return payload
    }

    /// Geometry-only cache key (#4). Color/alpha are DELIBERATELY excluded so
    /// animated-alpha / recolored text still hits the cached mesh; the combos
    /// ARE included because effect toggles change the compiled shader request.
    private func payloadGeometryKey(
        object: WPESceneTextObject,
        sceneSize: CGSize,
        parallaxOffset: SIMD2<Float>,
        originOverride: SIMD2<Double>?,
        sizeScale: Double,
        rotation: Double,
        combos: [String: Int]
    ) -> String {
        let fontSize = effectiveFontSize(for: object)
        let comboSig = combos.keys.sorted().map { "\($0)=\(combos[$0] ?? 0)" }.joined(separator: ",")
        let boxSig = object.boxSize.map { "\($0.x)x\($0.y)" } ?? "nil"
        let originSig = originOverride.map { "\($0.x),\($0.y)" } ?? "nil"
        return [
            object.id,
            object.text,
            object.fontRelativePath ?? "",
            "\(fontSize)",
            "\(object.letterSpacing)",
            object.horizontalAlignment,
            object.verticalAlignment,
            boxSig,
            "\(object.origin.x),\(object.origin.y),\(object.origin.z)",
            "\(parallaxOffset.x),\(parallaxOffset.y)",
            "\(object.scale.x),\(object.scale.y)",
            "\(sceneSize.width)x\(sceneSize.height)",
            originSig,
            "\(sizeScale)",
            "\(rotation)",
            "\(object.padding)",
            "\(object.maxWidth ?? -1)",
            comboSig
        ].joined(separator: "|")
    }

    private func transform(
        mesh: WPEMSDFTextMesh,
        object: WPESceneTextObject,
        sceneSize: CGSize,
        parallaxOffset: SIMD2<Float>,
        originOverride: SIMD2<Double>?,
        sizeScale: Double,
        rotation: Double
    ) -> WPEMSDFTextMesh {
        let scale = SIMD2<Double>(
            max(object.scale.x, 0.0001) * sizeScale,
            max(object.scale.y, 0.0001) * sizeScale
        )
        let scaledSize = SIMD2<Double>(
            Double(mesh.size.width) * scale.x,
            Double(mesh.size.height) * scale.y
        )
        // `object.origin` is WPE author space: +Y UP, y=0 at the BOTTOM of the
        // scene (the CoreText overlay path maps it to NDC with no flip — see
        // wpe_text_overlay_vertex's "must NOT be flipped" note). This mesh and
        // wpe_msdf_text_vertex work in top-left y-DOWN pixels, so flip the
        // ortho origin here, folding parallax in BEFORE the flip like the
        // CoreText path does. `originOverride` arrives already converted to
        // top-left y-down (parallax folded) by the scene renderer — pass through.
        let boxCenter = originOverride ?? SIMD2<Double>(
            object.origin.x + Double(parallaxOffset.x),
            Double(sceneSize.height) - (object.origin.y + Double(parallaxOffset.y))
        )
        let topLeft = SIMD2<Double>(
            boxCenter.x - scaledSize.x * 0.5,
            boxCenter.y - scaledSize.y * 0.5
        )
        // Author-space CCW rotation about the box center. These vertices are
        // top-left y-DOWN pixels, where the same visual rotation has the
        // opposite sign — so rotate by -rotation here.
        let cosR = cos(-rotation)
        let sinR = sin(-rotation)
        let rotate: (SIMD2<Double>) -> SIMD2<Double> = rotation == 0
            ? { $0 }
            : { p in
                let d = p - boxCenter
                return SIMD2<Double>(
                    boxCenter.x + d.x * cosR - d.y * sinR,
                    boxCenter.y + d.x * sinR + d.y * cosR
                )
            }
        var transformed: [Int: [WPEMSDFTextVertex]] = [:]
        for (page, vertices) in mesh.perPage {
            transformed[page] = vertices.map { vertex in
                let local = SIMD2<Double>(Double(vertex.position.x), Double(vertex.position.y))
                let placed = rotate(SIMD2<Double>(
                    topLeft.x + local.x * scale.x,
                    topLeft.y + local.y * scale.y
                ))
                return WPEMSDFTextVertex(
                    position: SIMD2<Float>(Float(placed.x), Float(placed.y)),
                    uv: vertex.uv
                )
            }
        }
        return WPEMSDFTextMesh(perPage: transformed, size: mesh.size)
    }

    private func shaderRequest(comboValues: [String: Int]) throws -> WPEShaderCompileRequest {
        let processor = WPEShaderPreprocessor { [resolver] path, _ in
            Self.readInclude(path: path, resolver: resolver)
        }
        // Prepend the WPE builtin macro prelude (CAST2/ddx/ddy/saturate/…). The
        // generic pipeline builder injects it for every other shader; this path
        // builds its request directly, so without it font.frag fails to compile
        // (file-scope ScreenPxRange uses CAST2 + ddx/ddy) and text reverts to CoreText.
        let preludedFragment = WPEShaderBuiltinMacros.glslPrelude + "\n" + fontFragmentSource
        return try processor.process(
            shaderName: "font",
            vertexSource: Self.vertexStub,
            fragmentSource: preludedFragment,
            comboValues: comboValues,
            materialTextureBindings: [:]
        )
    }

    // MARK: - Digit pre-warm (kills the clock-tick CoreText flash)

    /// Fonts whose 0-9 digit glyphs have already been queued, so the prewarm
    /// runs once per font, not every frame. Per-renderer (one renderer per
    /// scene), so it resets naturally on scene reload.
    private var digitsWarmedFonts: Set<String> = []

    /// Queue async generation of a numeric object's FULL digit set (0-9) the
    /// first time we see it, so a not-yet-shown digit is already warming before
    /// it first appears. A clock renders "12:00" but will later show every
    /// digit; laying out only the current text queues only the visible glyphs,
    /// so a fresh digit generates cold the frame the minute rolls over — the
    /// object flips to CoreText for those frames (a visible jitter). This uses
    /// the same async, concurrency-capped, disk-first path as normal layout and
    /// never blocks; it only enqueues (deduped per font).
    private func prewarmGlyphs(for object: WPESceneTextObject, font: CTFont) {
        guard object.text.contains(where: { $0.isNumber }) else { return }
        guard digitsWarmedFonts.insert(WPEMSDFTextLayout.fontIdentifier(font)).inserted else { return }
        let canonicalPixelSize = generator.canonicalPixelSize
        let attributed = CFAttributedStringCreate(
            nil, "0123456789" as CFString, [kCTFontAttributeName: font] as CFDictionary
        )!
        let line = CTLineCreateWithAttributedString(attributed)
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let glyphCount = CTRunGetGlyphCount(run)
            guard glyphCount > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: glyphCount)
            CTRunGetGlyphs(run, CFRange(location: 0, length: glyphCount), &glyphs)
            let runFont = Self.runFont(run) ?? font
            let runFontID = WPEMSDFTextLayout.fontIdentifier(runFont)
            // Mirror the layout's canonical-size keying so these entries are the
            // ones the ticking clock's layout will actually hit.
            let generationFont: CTFont = CTFontGetSize(runFont) == CGFloat(canonicalPixelSize)
                ? runFont
                : CTFontCreateCopyWithAttributes(runFont, CGFloat(canonicalPixelSize), nil, nil)
            for glyph in glyphs {
                let key = WPEMSDFGlyphKey(fontID: runFontID, glyph: glyph, pixelSize: canonicalPixelSize)
                _ = atlas.requestEntry(for: key, generator: generator, font: generationFont)
            }
        }
    }

    /// The font CoreText actually used for a run (fallback-aware), mirroring the
    /// layout's run-font resolution so the prewarm keys glyphs on the same face
    /// the layout will.
    private static func runFont(_ run: CTRun) -> CTFont? {
        let attributes = CTRunGetAttributes(run) as NSDictionary
        guard let value = attributes[kCTFontAttributeName as String] else { return nil }
        if CFGetTypeID(value as CFTypeRef) == CTFontGetTypeID() {
            return (value as! CTFont)
        }
        return nil
    }

    private func resolveFont(for object: WPESceneTextObject) -> CTFont {
        font(for: object, size: effectiveFontSize(for: object))
    }

    /// Size-independent CTFontDescriptor per font path. Resolving the file URL
    /// (stat/symlink) + `CTFontManagerCreateFontDescriptorsFromURL` is the costly
    /// part and, uncached, re-ran on every geometry change — a clock's
    /// once-a-second text re-statted the font file each tick (the payload cache
    /// short-circuits before `font()` on a HIT, but a text change misses).
    /// Mirrors `WPETextRenderer.fontDescriptorCache`; `CTFontCreateWithFontDescriptor`
    /// at the current size is cheap.
    private var fontDescriptorCache: [String: CTFontDescriptor] = [:]

    /// Used both for the final glyph font and for box measurement, so box-fit is
    /// computed with the SAME typeface that will be rendered.
    private func font(for object: WPESceneTextObject, size: CGFloat) -> CTFont {
        if let path = object.fontRelativePath {
            if WPESystemFont.isReference(path) {
                return WPESystemFont.font(for: path, size: size)
            }
            if let descriptor = fontDescriptor(forPath: path) {
                return CTFontCreateWithFontDescriptor(descriptor, size, nil)
            }
        }
        return CTFontCreateWithName("HelveticaNeue" as CFString, size, nil)
    }

    private func fontDescriptor(forPath path: String) -> CTFontDescriptor? {
        if let cached = fontDescriptorCache[path] { return cached }
        registerFontIfNeeded(path)
        guard let url = try? resolver.resolveExistingFileURL(relativePath: path),
              let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let descriptor = descriptors.first else { return nil }
        fontDescriptorCache[path] = descriptor
        return descriptor
    }

    private func registerFontIfNeeded(_ path: String) {
        guard !WPESystemFont.isReference(path), !registeredFonts.contains(path) else { return }
        registeredFonts.insert(path)
        guard let url = try? resolver.resolveExistingFileURL(relativePath: path) else { return }
        var unmanagedError: Unmanaged<CFError>?
        _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &unmanagedError)
        unmanagedError?.release()
    }

    private func effectiveFontSize(for object: WPESceneTextObject) -> CGFloat {
        let base = CGFloat(max(object.pointSize, 1))
        // Perspective scenes render at raw pointsize — see
        // WPESceneTextObject.fitsTextToBox / WPETextRenderer.effectiveFontSize.
        guard object.fitsTextToBox else { return base }
        guard let box = object.boxSize, box.x > 0, box.y > 0 else { return base }
        let cacheKey = "\(object.text)|\(object.fontRelativePath ?? "")|\(base)|\(object.letterSpacing)|\(box.x)x\(box.y)|\(object.padding)"
        if let cached = fittedFontSizeCache[cacheKey] { return cached }
        let font = font(for: object, size: base)
        let attributed = CFAttributedStringCreate(nil, object.text as CFString, [kCTFontAttributeName: font] as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        // Only the vertical metrics matter — WPE fits text to the box HEIGHT (the
        // width is a layout envelope the word may overflow), so the typographic
        // width return is discarded.
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let height = max(ascent + descent + leading, 0.5)
        let innerH = max(CGFloat(box.y - 2 * object.padding), 1)
        // Height-fill (RenderDoc-verified on 3470764447): short words in wide or
        // near-square boxes (weekday, date) were width-limited and under-sized ~5×
        // by the old min(widthFit, heightFit). Up-scale only; see
        // WPETextRenderer.effectiveFontSize for the full rationale.
        let fit = max(innerH / height, 1)
        guard fit.isFinite, fit > 0 else { return base }
        if fittedFontSizeCache.count >= 256 { fittedFontSizeCache.removeAll(keepingCapacity: true) }
        fittedFontSizeCache[cacheKey] = base * fit
        return base * fit
    }

    private static func readInclude(path: String, resolver: WPEMultiRootResourceResolver) -> String? {
        let candidates = path.hasPrefix("shaders/") ? [path] : ["shaders/\(path)", path]
        for candidate in candidates {
            guard let url = try? resolver.resolveExistingFileURL(relativePath: candidate),
                  let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else {
                continue
            }
            return text
        }
        return nil
    }

    private static let vertexStub = """
    #version 410 core
    void main() {}
    """
}
#endif
