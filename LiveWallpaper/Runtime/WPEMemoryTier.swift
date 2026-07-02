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
