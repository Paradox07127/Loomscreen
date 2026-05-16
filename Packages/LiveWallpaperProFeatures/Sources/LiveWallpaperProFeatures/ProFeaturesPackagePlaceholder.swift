import Foundation
import LiveWallpaperCore

/// Phase 5 scaffold placeholder for the LiveWallpaperProFeatures SPM package.
///
/// This package will host the Pro-exclusive subsystems (plan §8):
/// SystemMonitor + view, GlobalShortcutManager + ShortcutsSettingsView,
/// WeatherReactiveService + provider chain + settings view,
/// WallpaperAutomationOrchestrator + Schedule/Playlist policies + views,
/// LockScreenSnapshotCoordinator + DesktopPictureFrameExtractor,
/// VideoEffectsManager + ColorAdjustmentsView + ParticleOverlayView +
/// MetalWallpaperView, DeveloperToolsView, and the Inspector inline
/// preview (InspectorPreviewController + VideoPreviewSection).
///
/// The placeholder type itself is unused; Phase 5b removes it.
public enum LiveWallpaperProFeatures {
    public static let packageVersion: String = "0.1.0-scaffold"
}
