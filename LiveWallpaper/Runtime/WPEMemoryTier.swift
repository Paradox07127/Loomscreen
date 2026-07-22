#if !LITE_BUILD
import Foundation

/// Physical-memory tiers driving renderer resource defaults, so base-RAM Macs
/// (8 GB M1/M2) get bounded texture residency out of the box while high-RAM
/// machines keep the everything-resident behavior. Manual defaults always win
/// (`WPEMetalTextureCacheBudgetMiB`; explicit 0 ⇒ unbounded).
enum WPEMemoryTier: Equatable, Sendable {
    case constrained
    case standard
    case expansive

    static let current = tier(forPhysicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)

    /// Boundaries sit between shipping Apple-silicon RAM points (8/16/18/24/32…):
    /// <12 GiB captures the 8 GB baseline, <24 GiB captures 16/18 GB.
    static func tier(forPhysicalMemoryBytes bytes: UInt64) -> WPEMemoryTier {
        let gib = Double(bytes) / 1_073_741_824
        if gib < 12 { return .constrained }
        if gib < 24 { return .standard }
        return .expansive
    }

    var defaultTextureCacheBudgetBytes: Int? {
        switch self {
        case .constrained: return 256 * 1_048_576
        case .standard: return 512 * 1_048_576
        case .expansive: return nil
        }
    }

    /// Caps native-resolution perspective rendering to bound FBO memory growth.
    /// HDR halves the pixel budget because `rgba16Float` doubles bytes per pixel.
    func perspectiveRenderPixelBudget(hdr: Bool) -> Double {
        let base = 1920.0 * 1080.0
        let multiplier: Double
        switch self {
        case .constrained: multiplier = 1.0   // 8 GB: no native-res bump
        case .standard: multiplier = 2.25      // 16/18 GB: up to ~1620p
        case .expansive: multiplier = 4.0      // ≥24 GB: up to 4K
        }
        // rgba16Float doubles bytes/pixel, so halve the pixel budget for HDR.
        return base * (hdr ? multiplier * 0.5 : multiplier)
    }

    /// Routes large animated textures to lazy streaming instead of eager upload.
    var lazyAnimationRawByteThreshold: Int {
        switch self {
        case .constrained: return 100_000_000
        case .standard, .expansive: return 200_000_000
        }
    }
}
#endif
