import Foundation

/// Per-texture sprite-sheet description sourced from the WPE-shipped
/// `<texture>.tex-json` sibling file. WPE packs an animated particle
/// sprite (a leaf flipping through 30 hand-drawn poses, a fog blob
/// breathing through 64 alpha masks, …) as a single atlas with a
/// `spritesheetsequences` block describing how to slice it.
///
/// We also stash the texture's pixel format here because `r8` atlases
/// store the sprite as a single-channel alpha mask — the fragment
/// shader must treat the sample as an opacity multiplier and pull the
/// RGB colour from the per-particle tint, not from the texture.
public struct WPEParticleSpriteSheet: Sendable, Equatable {
    public let cols: Int
    public let rows: Int
    public let frameCount: Int
    /// Frames-per-second baseline from the `.tex-json` (sequence
    /// `frames / duration`). The runtime multiplies this by the
    /// particle JSON's `sequencemultiplier` to derive the live frame.
    public let baseFrameRate: Double
    public let isAlphaMask: Bool

    public init(cols: Int, rows: Int, frameCount: Int, baseFrameRate: Double, isAlphaMask: Bool) {
        self.cols = max(1, cols)
        self.rows = max(1, rows)
        self.frameCount = max(1, frameCount)
        self.baseFrameRate = max(0, baseFrameRate)
        self.isAlphaMask = isAlphaMask
    }
}

/// Parses the `.tex-json` sidecar shipped with every WPE particle
/// atlas. Returns `nil` if the file is missing, malformed, or has no
/// `spritesheetsequences` entry — the caller should then assume the
/// texture is a single-frame static sprite.
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
