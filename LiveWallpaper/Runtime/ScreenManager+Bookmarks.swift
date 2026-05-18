import Foundation

extension ScreenManager {
    func applyBookmark(_ bookmark: WallpaperBookmark, to screen: Screen) {
        Logger.info("Applying bookmark to screen \(screen.id): \(bookmark.wallpaperType.rawValue)", category: .ui)

        // Apply the playback / effect snapshot BEFORE the content swap so
        // each setter has time to write the field into the stored config.
        // The content swap (setVideo / setHTMLWallpaper) reads the config at
        // player-creation time, so the new player starts up with the saved
        // effects already in place. Doing it in the opposite order leaves
        // the new player initialized from the prior screen's effects and
        // racing against post-creation setter calls — which is why the
        // first version of this code looked like it dropped the effects.
        if let settings = bookmark.playbackSettings {
            applyPlaybackSettings(settings, to: screen)
        }

        switch bookmark.content {
        case .video(let bookmarkData):
            guard case .success(let resolved) = SecurityScopedBookmarkResolver.shared.resolve(
                bookmarkData,
                target: .transient
            ) else {
                Logger.warning("Bookmark video unresolvable; user may need to re-pick", category: .fileAccess)
                return
            }
            setVideo(url: resolved.url, bookmarkData: resolved.bookmarkData, for: screen)
        case .html(let source, let config):
            setHTMLWallpaper(source: source, config: config, for: screen)
        case .metalShader(let preset):
            setShaderWallpaper(preset: preset, for: screen)
        case .scene(let descriptor):
            setSceneWallpaper(descriptor: descriptor, origin: bookmark.wpeOrigin, for: screen)
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
