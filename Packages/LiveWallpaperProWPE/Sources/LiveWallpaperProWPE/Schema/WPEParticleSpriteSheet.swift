import Foundation

/// Per-texture sprite-sheet description from the WPE-shipped `<texture>.tex-json`
/// sibling: an animated particle atlas plus its `spritesheetsequences` slicing.
///
/// `isAlphaMask` (true for `r8` atlases) is load-bearing: r8 stores the sprite as
/// a single-channel alpha mask, so the fragment shader must treat the sample as an
/// opacity multiplier and pull RGB from the per-particle tint, not the texture.
public struct WPEParticleSpriteSheet: Sendable, Equatable {
    public let cols: Int
    public let rows: Int
    /// Number of frames the particle simulator cycles through. When
    /// `frameRects` is present this is derived from `frameRects.count` so the
    /// CPU frame index and the GPU rect lookup cannot diverge.
    public let frameCount: Int
    /// Frames-per-second baseline from the `.tex-json` (sequence
    /// `frames / duration`). The runtime multiplies this by the
    /// particle JSON's `sequencemultiplier` to derive the live frame.
    public let baseFrameRate: Double
    public let isAlphaMask: Bool
    /// Explicit normalized UV rects, one per frame, in top-left texture
    /// coordinates `(x0, y0, x1, y1)`. TEXS-backed atlases (e.g. the Matrix
    /// glyph sheet) don't fill the texture as a uniform `cols × rows` grid, so
    /// the Metal vertex path slices by these rects when present. `nil` ⇒ the
    /// uniform-grid path.
    public let frameRects: [SIMD4<Float>]?

    public init(
        cols: Int,
        rows: Int,
        frameCount: Int,
        baseFrameRate: Double,
        isAlphaMask: Bool,
        frameRects: [SIMD4<Float>]? = nil
    ) {
        let resolvedRects = (frameRects?.isEmpty == false) ? frameRects : nil
        self.cols = max(1, cols)
        self.rows = max(1, rows)
        self.frameCount = resolvedRects?.count ?? max(1, frameCount)
        self.baseFrameRate = max(0, baseFrameRate)
        self.isAlphaMask = isAlphaMask
        self.frameRects = resolvedRects
    }
}

/// Parses the `.tex-json` sidecar. Returns `nil` if missing, malformed, or lacking
/// a `spritesheetsequences` entry — the caller then treats the texture as a
/// single-frame static sprite.
///
/// Example payload (leaves7.tex-json):
/// ```json
/// {
///   "format": "rgba8888",
///   "spritesheetsequences": [
///     { "duration": 1, "frames": 30, "width": 85.334, "height": 102.4 }
///   ]
/// }
/// ```
public enum WPEParticleSpriteSheetParser {
    public static func parse(data: Data, atlasPixelSize: (width: Int, height: Int)) -> WPEParticleSpriteSheet? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return parse(dictionary: json, atlasPixelSize: atlasPixelSize)
    }

    public static func parse(
        dictionary json: [String: Any],
        atlasPixelSize: (width: Int, height: Int)
    ) -> WPEParticleSpriteSheet? {
        let format = (json["format"] as? String)?.lowercased() ?? "rgba8888"
        let isAlphaMask = (format == "r8")
        guard let sequences = json["spritesheetsequences"] as? [[String: Any]],
              let first = sequences.first else {
            return nil
        }
        let frameW = doubleValue(first["width"]) ?? 0
        let frameH = doubleValue(first["height"]) ?? 0
        let frameCountRaw = intValue(first["frames"]) ?? 0
        let duration = doubleValue(first["duration"]) ?? 1
        guard frameW > 0, frameH > 0, frameCountRaw > 0 else { return nil }
        let cols = max(1, Int((Double(atlasPixelSize.width) / frameW).rounded()))
        let rows = max(1, Int((Double(atlasPixelSize.height) / frameH).rounded()))
        let baseFrameRate = duration > 0 ? Double(frameCountRaw) / duration : Double(frameCountRaw)
        return WPEParticleSpriteSheet(
            cols: cols,
            rows: rows,
            frameCount: frameCountRaw,
            baseFrameRate: baseFrameRate,
            isAlphaMask: isAlphaMask
        )
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let v = value as? Double { return v }
        if let v = value as? Int { return Double(v) }
        if let v = value as? String { return Double(v) }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let v = value as? Int { return v }
        if let v = value as? Double { return Int(v) }
        if let v = value as? String { return Int(v) }
        return nil
    }
}
