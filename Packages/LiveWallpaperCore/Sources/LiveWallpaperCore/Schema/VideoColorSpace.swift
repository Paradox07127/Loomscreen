import Foundation

/// Per-screen color management preference applied to the video wallpaper's
/// `AVPlayerLayer`. `auto` leaves the layer untouched so AVFoundation's
/// system-default color path (including any automatic EDR upgrade for HDR
/// content) keeps working unchanged.
///
/// The non-auto cases set `CALayer.colorspace` to force the output through a
/// specific `CGColorSpace`. `rec2020HDR` additionally enables the layer's
/// extended dynamic range output so HDR transfer curves are preserved
/// instead of being tone-mapped to SDR.
public enum VideoColorSpace: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case sRGB
    case displayP3
    case rec2020HDR

    public var id: String { rawValue }

    public var titleKey: String {
        switch self {
        case .auto:        return "Auto"
        case .sRGB:        return "sRGB"
        case .displayP3:   return "Display P3"
        case .rec2020HDR:  return "Rec.2020 HDR"
        }
    }

    public var descriptionKey: String {
        switch self {
        case .auto:
            return "Use the display's native profile."
        case .sRGB:
            return "Force sRGB output — most accurate for SDR content."
        case .displayP3:
            return "Wide-gamut output for P3-capable displays."
        case .rec2020HDR:
            return "HDR-aware output. Requires an HDR-capable display."
        }
    }
}
