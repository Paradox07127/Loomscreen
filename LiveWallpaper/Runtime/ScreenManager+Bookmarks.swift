import Foundation

extension ScreenManager {
    func applyBookmark(_ bookmark: WallpaperBookmark, to screen: Screen) {
        Logger.info("Applying bookmark to screen \(screen.id): \(bookmark.wallpaperType.rawValue)", category: .ui)

        if let settings = bookmark.playbackSettings {
            applyPlaybackSettings(settings, to: screen)
        }

        switch bookmark.content {
        case .video(let bookmarkData, let packageEntryName):
            guard case .success(let resolved) = SecurityScopedBookmarkResolver.shared.resolve(
                bookmarkData,
                target: .transient
            ) else {
                Logger.warning("Bookmark video unresolvable; user may need to re-pick", category: .fileAccess)
                return
            }
            setVideo(
                url: resolved.url,
                bookmarkData: resolved.bookmarkData,
                packageEntryName: packageEntryName,
                for: screen
            )
        case .html(let source, let config):
            setHTMLWallpaper(source: source, config: config, for: screen)
        case .metalShader(let source):
            setShaderWallpaper(source: source, for: screen)
        case .scene(let descriptor):
            setSceneWallpaper(descriptor: descriptor, origin: bookmark.wpeOrigin, for: screen)
        case .monitor(let monitorConfig):
            switchToMonitorWallpaper(for: screen)
            updateMonitorConfiguration(monitorConfig, for: screen)
        }
    }

    private func applyPlaybackSettings(_ settings: BookmarkPlaybackSettings, to screen: Screen) {
        if let value = settings.playbackSpeed   { updatePlaybackSpeed(value, for: screen) }
        if let value = settings.fitMode         { updateFitMode(value, for: screen) }
        if let value = settings.frameRateLimit  { updateFrameRateLimit(value, for: screen) }
        if let value = settings.particleEffect  { updateParticleEffect(value, for: screen) }
        if let value = settings.effectConfig    { updateEffectConfig(value, for: screen) }
        if let value = settings.muted           { updateMuted(value, for: screen) }
        if let value = settings.videoVolume     { updateVideoVolume(value, for: screen) }
        if let value = settings.setAsLockScreen { updateSetAsDesktopPicture(value, for: screen) }
    }
}
