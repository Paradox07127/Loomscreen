import Foundation
import LiveWallpaperCore

/// Phase 2 scaffold placeholder for the LiveWallpaperVideoWeb SPM package.
///
/// This package will host the video + HTML wallpaper runtime
/// (WallpaperVideoPlayer / HTMLWallpaperView / VideoWallpaperSession /
/// AmbientWallpaperSession / PlaybackCoordinator / HTMLWallpaperCoordinator
/// + helpers). Phase 2 will migrate them out of the main target into
/// this Sources/ directory.
///
/// The placeholder type itself is unused; it exists so the package has
/// at least one source file and `swift build` succeeds before the real
/// types land. Phase 2b removes it.
public enum LiveWallpaperVideoWeb {
    /// Version stamp used by integration tests as a quick "is the package
    /// linked" sentinel. Bumped on every package contract change.
    public static let packageVersion: String = "0.1.0-scaffold"
}
