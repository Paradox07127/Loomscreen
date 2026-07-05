#if !LITE_BUILD
import CoreGraphics
import CoreText
import Foundation
import simd

final class WPEMSDFGlyphGenerator: @unchecked Sendable {
    private let parameters: WPEMSDFParameters
    private static let neutralFill = SIMD4<Float>(0.5, 0.5, 0.5, 1)

    /// The one font point size glyphs are generated at. Distance fields are
    /// resolution-independent, so a glyph is rasterized ONCE at this canonical
    /// size and scaled to any on-screen size through its em-normalized metrics —
    /// the atlas must never fork entries by live pixel size.
    var canonicalPixelSize: Int { max(parameters.generationCellCap, 1) }

    init(parameters: WPEMSDFParameters = WPEMSDFParameters()) {
        self.parameters = parameters
    }

    func generate(
        glyph: CGGlyph,
        font: CTFont,
        maxCellSide: Int? = nil
    ) -> (bitmap: WPEMSDFBitmap, metrics: WPEMSDFGlyphMetrics)? {
        guard let prep = prepareGlyph(glyph: glyph, font: font, maxCellSide: maxCellSide) else {
            return nil
        }

        // Hoist per-glyph work (segment bounding boxes + the once-flattened
        // winding polyline) out of the 64×64 pixel loop. Every pixel then
        // queries this prepared value instead of re-deriving both from scratch.
        let prepared = prep.shape.prepared()
        let bitmap = rasterize(prep) { prepared.signedDistances(at: $0) }
        return (bitmap: bitmap, metrics: prep.metrics)
    }

    /// Shared per-glyph setup: build the shape from the outline, fit it into the
    /// cell, apply edge coloring, and derive metrics. The rasterization strategy
    /// (prepared vs. brute-force reference) is decoupled so tests can prove the
    /// two produce identical bitmaps.
    private struct PreparedGlyph {
        let shape: WPEMSDFShape
        let cellSide: Int
        let pixelRange: Double
        let metrics: WPEMSDFGlyphMetrics
    }

    private func prepareGlyph(
        glyph: CGGlyph,
        font: CTFont,
        maxCellSide: Int?
    ) -> PreparedGlyph? {
        guard let sizing = cellSizing(font: font, maxCellSide: maxCellSide) else { return nil }
        let padding = sizing.padding
        let cellSide = sizing.cellSide
        let advance = advanceForGlyph(glyph, font: font)
        let pathUnitsToEm = pathUnitsToEmUnits(font: font)

        // No outline (whitespace / control / unsupported color glyph) → nil, so
        // the atlas marks it `.skip` (advance past it, draw nothing) instead of
        // emitting a 0.5-filled quad that the MSDF shader renders as a gray box.
        guard let path = CTFontCreatePathForGlyph(font, glyph, nil), !path.isEmpty else {
            return nil
        }

        var shape = buildShape(from: path)
        // Tight bounds from the actual curve (boundingBoxOfPath), not the Bézier
        // control points, so off-curve handles can't inflate the cell mapping
        // and shrink/misplace the glyph.
        let sourceBounds = path.boundingBoxOfPath
        guard !shape.contours.isEmpty, !sourceBounds.isNull,
              sourceBounds.width > 0 || sourceBounds.height > 0 else {
            return nil
        }

        let sourceWidth = Double(sourceBounds.width)
        let sourceHeight = Double(sourceBounds.height)
        let available = max(Double(cellSide - padding * 2), 1)
        let widthScale = sourceWidth > WPEMSDFGeometryMath.epsilon ? available / sourceWidth : Double.greatestFiniteMagnitude
        let heightScale = sourceHeight > WPEMSDFGeometryMath.epsilon ? available / sourceHeight : Double.greatestFiniteMagnitude
        let scale = min(widthScale, heightScale)
        guard scale.isFinite, scale > WPEMSDFGeometryMath.epsilon else {
            return nil
        }

        let contentWidth = sourceWidth * scale
        let contentHeight = sourceHeight * scale
        let translate = WPEMSDFPoint(
            Double(padding) + (available - contentWidth) * 0.5 - Double(sourceBounds.minX) * scale,
            Double(padding) + (available - contentHeight) * 0.5 - Double(sourceBounds.minY) * scale
        )

        shape.applyTransform(scale: scale, translate: translate)
        WPEMSDFEdgeColoring.colorShape(&shape, angleThreshold: parameters.angleThreshold)

        let pixelRange = max(parameters.pixelRange, 0.001)
        let cellOrigin = WPEMSDFPoint(-translate.x / scale, -translate.y / scale)
        let metrics = WPEMSDFGlyphMetrics(
            cellSize: CGSize(width: cellSide, height: cellSide),
            bearing: cellOrigin * pathUnitsToEm,
            advance: advance * pathUnitsToEm,
            scale: scale,
            translate: translate,
            emUnitsPerPixel: pathUnitsToEm / scale
        )
        return PreparedGlyph(shape: shape, cellSide: cellSide, pixelRange: pixelRange, metrics: metrics)
    }

    private func rasterize(
        _ prep: PreparedGlyph,
        signedDistances: (WPEMSDFPoint) -> (r: Double, g: Double, b: Double)
    ) -> WPEMSDFBitmap {
        let cellSide = prep.cellSide
        let pixelRange = prep.pixelRange
        var bitmap = WPEMSDFBitmap(width: cellSide, height: cellSide, fill: Self.neutralFill)
        // The glyph shape lives in CTFont path space: +Y UP, ascenders at high y.
        // The bitmap must be stored TOP-DOWN (row 0 = glyph top) because every
        // consumer is y-down: the atlas uploads rows verbatim into an MTLTexture
        // (row 0 = v0 = top) and the layout's quads pin uvRect.minY to the quad's
        // screen-top edge. Sampling row y at path height − y makes storage match —
        // without this flip every glyph renders upside down in place.
        for y in 0..<bitmap.height {
            let pathY = Double(bitmap.height - 1 - y) + 0.5
            for x in 0..<bitmap.width {
                let point = WPEMSDFPoint(Double(x) + 0.5, pathY)
                let d = signedDistances(point)
                bitmap[x, y] = SIMD4<Float>(
                    encodedDistance(d.r, pixelRange: pixelRange),
                    encodedDistance(d.g, pixelRange: pixelRange),
                    encodedDistance(d.b, pixelRange: pixelRange),
                    1
                )
            }
        }
        return bitmap
    }

    #if DEBUG
    /// Test-only oracle: rasterize the SAME glyph via the original brute-force
    /// signed-distance path (no bbox culling, winding re-flattened per pixel).
    /// The equivalence test asserts this is byte-identical to `generate`.
    func generateBruteForceReference(
        glyph: CGGlyph,
        font: CTFont,
        maxCellSide: Int? = nil
    ) -> WPEMSDFBitmap? {
        guard let prep = prepareGlyph(glyph: glyph, font: font, maxCellSide: maxCellSide) else {
            return nil
        }
        return rasterize(prep) { prep.shape.signedDistancesBruteForce(at: $0) }
    }
    #endif

    /// Rejects non-finite or overflowing font sizes (so `Int(ceil(...))` never
    /// traps) and any cell larger than the atlas page can hold.
    private func cellSizing(font: CTFont, maxCellSide: Int?) -> (padding: Int, cellSide: Int)? {
        let padding = max(parameters.padding, 0)
        let limit = max(maxCellSide ?? Int.max, 1)
        let rawSize = CTFontGetSize(font)
        guard rawSize.isFinite, rawSize > 0 else { return nil }
        let roundedSize = ceil(rawSize)
        guard roundedSize <= CGFloat(Int.max) else { return nil }
        let pointSize = max(Int(roundedSize), 1)
        guard padding <= (Int.max - pointSize) / 2 else { return nil }
        let naturalCell = pointSize + padding * 2
        // Clamp to a fixed generation resolution (resolution-independence): a
        // 200px on-screen glyph still rasterizes into ~64px and is scaled up by
        // the shader, instead of a 200² per-pixel signed-distance sweep.
        let cap = max(parameters.generationCellCap, padding * 2 + 1)
        let cellSide = min(naturalCell, min(cap, limit))
        return (padding, cellSide)
    }


    private func buildShape(from path: CGPath) -> WPEMSDFShape {
        var contours: [WPEMSDFContour] = []
        var segments: [WPEMSDFSegment] = []
        var currentPoint: WPEMSDFPoint?
        var contourStart: WPEMSDFPoint?

        func finishContour() {
            guard !segments.isEmpty else { return }
            contours.append(WPEMSDFContour(segments: segments))
            segments.removeAll(keepingCapacity: true)
            currentPoint = nil
            contourStart = nil
        }

        func closeContourIfNeeded() {
            guard let currentPoint, let contourStart else { return }
            if Self.distance(currentPoint, contourStart) > WPEMSDFGeometryMath.epsilon {
                segments.append(.linear(p0: currentPoint, p1: contourStart, color: .white))
            }
        }

        path.applyWithBlock { elementPointer in
            let element = elementPointer.pointee
            switch element.type {
            case .moveToPoint:
                finishContour()
                let point = Self.point(from: element.points[0])
                currentPoint = point
                contourStart = point
            case .addLineToPoint:
                guard let current = currentPoint else { return }
                let point = Self.point(from: element.points[0])
                if Self.distance(current, point) > WPEMSDFGeometryMath.epsilon {
                    segments.append(.linear(p0: current, p1: point, color: .white))
                }
                currentPoint = point
            case .addQuadCurveToPoint:
                guard let current = currentPoint else { return }
                let control = Self.point(from: element.points[0])
                let point = Self.point(from: element.points[1])
                segments.append(.quadratic(p0: current, c: control, p1: point, color: .white))
                currentPoint = point
            case .addCurveToPoint:
                guard let current = currentPoint else { return }
                let control0 = Self.point(from: element.points[0])
                let control1 = Self.point(from: element.points[1])
                let point = Self.point(from: element.points[2])
                segments.append(.cubic(p0: current, c0: control0, c1: control1, p1: point, color: .white))
                currentPoint = point
            case .closeSubpath:
                closeContourIfNeeded()
                finishContour()
            @unknown default:
                break
            }
        }

        finishContour()
        return WPEMSDFShape(contours: contours)
    }

    private func encodedDistance(_ distance: Double, pixelRange: Double) -> Float {
        let value = 0.5 + distance / pixelRange
        guard value.isFinite else { return 0.5 }
        return Float(min(max(value, 0), 1))
    }

    private func advanceForGlyph(_ glyph: CGGlyph, font: CTFont) -> WPEMSDFPoint {
        var glyphValue = glyph
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphValue, &advance, 1)
        return WPEMSDFPoint(Double(advance.width), Double(advance.height))
    }

    private func pathUnitsToEmUnits(font: CTFont) -> Double {
        let unitsPerEm = max(Double(CTFontGetUnitsPerEm(font)), 1)
        let fontSize = max(Double(CTFontGetSize(font)), 1.0e-6)
        return unitsPerEm / fontSize
    }

    private static func point(from point: CGPoint) -> WPEMSDFPoint {
        WPEMSDFPoint(Double(point.x), Double(point.y))
    }

    private static func distance(_ a: WPEMSDFPoint, _ b: WPEMSDFPoint) -> Double {
        WPEMSDFGeometryMath.length(a - b)
    }
}
#endif
