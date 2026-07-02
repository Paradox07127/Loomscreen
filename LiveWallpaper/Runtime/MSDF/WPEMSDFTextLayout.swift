#if !LITE_BUILD
import CoreGraphics
import CoreText
import Foundation
import LiveWallpaperProWPE
import simd

struct WPEMSDFTextVertex {
    var position: SIMD2<Float>
    var uv: SIMD2<Float>
}

struct WPEMSDFTextMesh {
    var perPage: [Int: [WPEMSDFTextVertex]]
    var size: CGSize
}

@MainActor
struct WPEMSDFTextLayout {
    func layout(
        object: WPESceneTextObject,
        font: CTFont,
        atlas: WPEMSDFAtlas,
        generator: WPEMSDFGlyphGenerator
    ) -> WPEMSDFTextMesh? {
        guard !object.text.isEmpty else { return nil }
        // MSDF lays out a SINGLE line; defer multi-line / wrapping objects to the
        // CoreText framesetter instead of mispositioning them.
        if object.text.contains(where: \.isNewline) { return nil }
        let attributed = attributedString(for: object, font: font)
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let rawLineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let naturalHeight = max(ascent + descent + leading, 1)
        let padding = CGFloat(max(object.padding, 0))
        if let maxWidth = object.maxWidth.map({ CGFloat(max($0, 1)) }), rawLineWidth > maxWidth + 0.5 {
            return nil // would wrap → CoreText framesetter handles it
        }
        let lineWidth = max(rawLineWidth, 1)
        let boxSize = object.boxSize.map {
            CGSize(width: max($0.x, 1), height: max($0.y, 1))
        } ?? CGSize(
            width: lineWidth + padding * 2,
            height: naturalHeight + padding * 2
        )
        let innerWidth = max(boxSize.width - padding * 2, 1)
        let innerHeight = max(boxSize.height - padding * 2, 1)
        let alignedLineWidth = min(lineWidth, innerWidth)
        let xOffset = padding + horizontalOffset(
            alignment: object.horizontalAlignment,
            lineWidth: alignedLineWidth,
            innerWidth: innerWidth
        )
        let baseline = padding + baselineOffset(
            alignment: object.verticalAlignment,
            ascent: ascent,
            descent: descent,
            naturalHeight: naturalHeight,
            innerHeight: innerHeight
        )
        // Per-UTF16-unit whitespace flags (grapheme-level isWhitespace expanded
        // across UTF-16 units) so a glyph is classified in O(1) by its string index.
        var whitespaceByUTF16: [Bool] = []
        whitespaceByUTF16.reserveCapacity(object.text.utf16.count)
        for character in object.text {
            let isWhitespace = character.isWhitespace
            for _ in 0..<String(character).utf16.count {
                whitespaceByUTF16.append(isWhitespace)
            }
        }
        let runs = (CTLineGetGlyphRuns(line) as? [CTRun]) ?? []
        var perPage: [Int: [WPEMSDFTextVertex]] = [:]
        var isComplete = true

        for run in runs {
            let glyphCount = CTRunGetGlyphCount(run)
            guard glyphCount > 0 else { continue }
            let range = CFRange(location: 0, length: glyphCount)
            var glyphs = [CGGlyph](repeating: 0, count: glyphCount)
            var positions = [CGPoint](repeating: .zero, count: glyphCount)
            var stringIndices = [CFIndex](repeating: 0, count: glyphCount)
            CTRunGetGlyphs(run, range, &glyphs)
            CTRunGetPositions(run, range, &positions)
            CTRunGetStringIndices(run, range, &stringIndices)

            // Use the run's ACTUAL font: CoreText substitutes a fallback font for
            // glyphs the scene font lacks, and glyph IDs are relative to that font.
            let runFont = Self.runFont(run) ?? font
            let runFontID = Self.fontIdentifier(runFont)
            let runPixelSize = max(Int(ceil(CTFontGetSize(runFont))), 1)
            let runPathUnitsToEm = Self.pathUnitsToEmUnits(font: runFont)

            for index in 0..<glyphCount {
                let glyph = glyphs[index]
                let key = WPEMSDFGlyphKey(fontID: runFontID, glyph: glyph, pixelSize: runPixelSize)
                let entry: WPEMSDFAtlasEntry
                switch atlas.requestEntry(for: key, generator: generator, font: runFont) {
                case .ready(let ready):
                    entry = ready
                case .pending:
                    isComplete = false
                    continue
                case .skip:
                    // Whitespace has no outline → advance, draw nothing. A
                    // non-whitespace glyph with no MSDF outline (emoji/color/
                    // unsupported) must NOT be dropped — fall the whole object
                    // back to CoreText so it renders correctly.
                    if Self.isWhitespace(stringIndices[index], flags: whitespaceByUTF16) { continue }
                    return nil
                }
                let position = positions[index]
                let bearing = entry.metrics.bearing / runPathUnitsToEm
                let glyphWidth = Double(entry.metrics.cellSize.width) / entry.metrics.scale
                let glyphHeight = Double(entry.metrics.cellSize.height) / entry.metrics.scale
                let x = Double(xOffset) + Double(position.x) + bearing.x
                let y = Double(baseline) - Double(position.y) - (bearing.y + glyphHeight)
                appendQuad(
                    page: entry.page,
                    rect: CGRect(x: x, y: y, width: glyphWidth, height: glyphHeight),
                    uvRect: entry.uvRect,
                    perPage: &perPage
                )
            }
        }

        guard isComplete, !perPage.isEmpty else { return nil }
        return WPEMSDFTextMesh(perPage: perPage, size: boxSize)
    }

    private func attributedString(for object: WPESceneTextObject, font: CTFont) -> CFAttributedString {
        var attributes: [CFString: Any] = [kCTFontAttributeName: font]
        if object.letterSpacing != 0 {
            attributes[kCTKernAttributeName] = object.letterSpacing
        }
        return CFAttributedStringCreate(nil, object.text as CFString, attributes as CFDictionary)!
    }

    private func horizontalOffset(alignment: String, lineWidth: CGFloat, innerWidth: CGFloat) -> CGFloat {
        switch alignment.lowercased() {
        case "left":
            return 0
        case "right":
            return max(innerWidth - lineWidth, 0)
        default:
            return max((innerWidth - lineWidth) * 0.5, 0)
        }
    }

    private func baselineOffset(
        alignment: String,
        ascent: CGFloat,
        descent: CGFloat,
        naturalHeight: CGFloat,
        innerHeight: CGFloat
    ) -> CGFloat {
        switch alignment.lowercased() {
        case "top":
            return ascent
        case "bottom":
            return max(innerHeight - descent, ascent)
        default:
            return max((innerHeight - naturalHeight) * 0.5, 0) + ascent
        }
    }

    private func appendQuad(
        page: Int,
        rect: CGRect,
        uvRect: CGRect,
        perPage: inout [Int: [WPEMSDFTextVertex]]
    ) {
        let x0 = Float(rect.minX)
        let y0 = Float(rect.minY)
        let x1 = Float(rect.maxX)
        let y1 = Float(rect.maxY)
        let u0 = Float(uvRect.minX)
        let v0 = Float(uvRect.minY)
        let u1 = Float(uvRect.maxX)
        let v1 = Float(uvRect.maxY)
        perPage[page, default: []].append(contentsOf: [
            WPEMSDFTextVertex(position: SIMD2<Float>(x0, y0), uv: SIMD2<Float>(u0, v0)),
            WPEMSDFTextVertex(position: SIMD2<Float>(x1, y0), uv: SIMD2<Float>(u1, v0)),
            WPEMSDFTextVertex(position: SIMD2<Float>(x0, y1), uv: SIMD2<Float>(u0, v1)),
            WPEMSDFTextVertex(position: SIMD2<Float>(x1, y0), uv: SIMD2<Float>(u1, v0)),
            WPEMSDFTextVertex(position: SIMD2<Float>(x1, y1), uv: SIMD2<Float>(u1, v1)),
            WPEMSDFTextVertex(position: SIMD2<Float>(x0, y1), uv: SIMD2<Float>(u0, v1))
        ])
    }

    private static func pathUnitsToEmUnits(font: CTFont) -> Double {
        let unitsPerEm = max(Double(CTFontGetUnitsPerEm(font)), 1)
        let fontSize = max(Double(CTFontGetSize(font)), 1.0e-6)
        return unitsPerEm / fontSize
    }

    /// The font CoreText actually used for this run (may be a substituted fallback
    /// when the scene font lacks a glyph; glyph IDs are relative to it).
    private static func runFont(_ run: CTRun) -> CTFont? {
        let attributes = CTRunGetAttributes(run) as NSDictionary
        guard let value = attributes[kCTFontAttributeName as String] else { return nil }
        if CFGetTypeID(value as CFTypeRef) == CTFontGetTypeID() {
            return (value as! CTFont)
        }
        return nil
    }

    private static func fontIdentifier(_ font: CTFont) -> String {
        let name = CTFontCopyPostScriptName(font) as String
        return "\(name)@\(Int(ceil(CTFontGetSize(font))))"
    }

    private static func isWhitespace(_ utf16Offset: CFIndex, flags: [Bool]) -> Bool {
        utf16Offset >= 0 && utf16Offset < flags.count && flags[utf16Offset]
    }
}
#endif
