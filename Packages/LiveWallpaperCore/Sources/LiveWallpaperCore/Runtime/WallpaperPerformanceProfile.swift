import Foundation

/// Runtime rendering profile applied uniformly across wallpaper types.
/// Two states drive the policy response — graduated thermal handling is
/// intentionally absent so per-screen frame-rate caps stay user-owned and
/// system pressure converts straight to a pause:
/// - `.quality`: source frame rate, full work
/// - `.suspended`: paused, last frame held
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
