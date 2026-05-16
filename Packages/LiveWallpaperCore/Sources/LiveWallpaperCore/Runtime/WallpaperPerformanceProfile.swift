import Foundation

/// Runtime rendering profile applied uniformly across wallpaper types.
/// Only two states: normal animation (`.quality`) or frozen/paused (`.suspended`).
/// Battery handling is a pause (`.suspended`), not degraded animation —
/// see `WallpaperPolicyEngine.performanceProfile`.
public enum WallpaperPerformanceProfile: Equatable, Sendable {
    case quality
    case suspended

    public var shaderFramesPerSecond: Int {
        switch self {
        case .quality:
            return 30
        case .suspended:
            return 0
        }
    }
}
