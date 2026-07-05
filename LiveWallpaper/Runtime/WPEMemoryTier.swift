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

    /// Max scene-render pixel budget for perspective scenes rendered at native
    /// resolution (crisp HUD text). Bounds the FBO-memory blow-up: native 4K is
    /// 4× the 1080 baseline, and HDR scenes double bytes/pixel (rgba16Float) on
    /// top — 8× combined would OOM this scene (already ~1.4 GB at 1080/8-bit).
    /// The caller clamps the drawable size to this, never below the authored
    /// size (so `constrained` HDR effectively stays at 1080).
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

    /// Raw-bytes cutoff routing multi-frame `.tex` to the lazy streaming source
    /// instead of eager-resident upload (`lazyAnimationRawByteThreshold`).
    /// Halved on 8 GB machines: a ~150 MB resident animation is 2% of the whole
    /// machine there, and the streaming source's bounded prefetch already keeps
    /// playback seamless.
    var lazyAnimationRawByteThreshold: Int {
        switch self {
        case .constrained: return 100_000_000
        case .standard, .expansive: return 200_000_000
        }
    }
}
#endif
