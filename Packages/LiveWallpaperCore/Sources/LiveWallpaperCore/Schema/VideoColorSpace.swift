import Foundation

/// Per-screen color management for the video wallpaper's `AVPlayerLayer`.
/// `auto` leaves the layer untouched so AVFoundation's system-default color
/// path (including automatic EDR upgrade for HDR) keeps working unchanged.
/// Non-auto cases set `CALayer.colorspace` to force a specific `CGColorSpace`;
/// `rec2020HDR` additionally enables extended dynamic range so HDR transfer
/// curves are preserved instead of tone-mapped to SDR.
public enum VideoColorSpace: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case sRGB
    case displayP3
    case rec2020HDR
    /// Forces an HDR stream through a Rec.709 `AVVideoComposition` so it
    /// renders as SDR (escape hatch for HDR sources that look washed out on
    /// SDR-only external displays).
    /// Composition-based — mutually exclusive with the frame-rate cap
    /// (re-applying either replaces the active composition).
    case forceSDR

    public var id: String { rawValue }

    public var titleKey: String {
        switch self {
        case .auto:        return "Auto"
        case .sRGB:        return "sRGB"
        case .displayP3:   return "Display P3"
        case .rec2020HDR:  return "Rec.2020 HDR"
        case .forceSDR:    return "Force SDR"
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
        case .forceSDR:
            return "Render HDR content as SDR via Rec.709. Disables frame-rate limit."
        }
    }
}
