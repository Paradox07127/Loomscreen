import SwiftUI
import Combine
import Observation

extension ScreenManager {
    #if !LITE_BUILD
    // MARK: - Wallpaper Engine Import

    func wpeImportError(for screen: Screen) -> AppError? {
        wpeImportTracker.error(for: screen.id)
    }

    func clearWPEImportError(for screen: Screen) {
        wpeImportTracker.clearError(for: screen.id)
    }

    typealias WPEProjectApplyOutcome = WPEImportCoordinator.ApplyOutcome

    @discardableResult
    func importWallpaperEngineProject(at folderURL: URL, for screen: Screen) async -> WPEProjectApplyOutcome {
        await wpeImportCoordinator.importProject(at: folderURL, for: screen)
    }

    func activateWPEHistoryEntry(_ entry: WPEHistoryEntry, for screen: Screen) async {
        await wpeImportCoordinator.activateHistoryEntry(entry, for: screen)
    }

    func removeWPEImport(workshopID: String) {
        // If a screen is currently rendering the scene being deleted, switch it
        // away FIRST — otherwise its live renderer keeps reading the cache files
        // that the delete is about to move to the Trash. `clearWallpaperOfType`
        // tears down the scene session (synchronously, on every fallback path)
        // and falls back to the screen's saved video/html (or blanks it),
        // persisting the result. Match the active SceneDescriptor — what
        // actually drives the renderer and names the cache dir — not the
        // separate `wpeOrigin` metadata, which can be nil or stale.
        // Match scenes by their live descriptor AND video/web by their persisted
        // `wpeOrigin` — a packaged video/web import renders as `.video`/`.html`,
        // so a scene-only match left it rendering from files about to be deleted.
        let cacheRelativePath = "wpe-cache/\(workshopID)"
        for screen in screens {
            guard let config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else { continue }
            let matchesScene: Bool
            if case .scene(let descriptor) = config.activeWallpaper {
                matchesScene = descriptor.workshopID == workshopID || descriptor.cacheRelativePath == cacheRelativePath
            } else {
                matchesScene = false
            }
            guard matchesScene || config.wpeOrigin?.workshopID == workshopID else { continue }
            clearWallpaperOfType(config.activeWallpaper.wallpaperType, for: screen)
        }
        wpeImportCoordinator.removeWorkshop(workshopID: workshopID)
    }
    #endif

    // MARK: - Video Effects / Weather-Reactive (delegates to coordinator)

    func updateEffectConfig(_ effectConfig: VideoEffectConfig, for screen: Screen) {
        effectsCoordinator.updateEffectConfig(effectConfig, for: screen)
    }

    func updateParticleEffect(_ effect: ParticleEffect, for screen: Screen) {
        effectsCoordinator.updateParticleEffect(effect, for: screen)
    }

    func updateParticleDensity(_ density: Double, for screen: Screen) {
        effectsCoordinator.updateParticleDensity(density, for: screen)
    }

    func setWeatherReactive(_ enabled: Bool, for screen: Screen) {
        effectsCoordinator.setWeatherReactive(enabled, for: screen)
    }

    func startWeatherMonitoring() {
        effectsCoordinator.startWeatherMonitoring()
    }

    // MARK: - Playlist + Schedule (delegates to WallpaperAutomationOrchestrator)

    func updatePlaylistBookmarks(_ bookmarks: [Data], for screen: Screen) {
        automationOrchestrator.updatePlaylistBookmarks(bookmarks, for: screen)
    }

    func setPrimaryVideo(bookmark: Data, for screen: Screen) {
        automationOrchestrator.setPrimaryVideo(bookmark: bookmark, for: screen)
    }

    func replacePlaylist(ordered: [Data], primary: Data, for screen: Screen) {
        automationOrchestrator.replacePlaylist(ordered: ordered, primary: primary, for: screen)
    }

    func playPlaylistEntry(at index: Int, for screen: Screen) {
        automationOrchestrator.playPlaylistEntry(at: index, for: screen)
    }

    func updateShufflePlaylist(_ shuffle: Bool, for screen: Screen) {
        automationOrchestrator.updateShufflePlaylist(shuffle, for: screen)
    }

    func advancePlaylist(for screen: Screen) {
        automationOrchestrator.advancePlaylist(for: screen)
    }

    func regressPlaylist(for screen: Screen) {
        automationOrchestrator.regressPlaylist(for: screen)
    }

    func replaceActiveBookmark(_ bookmarkData: Data, for screen: Screen) {
        automationOrchestrator.replaceActiveBookmark(bookmarkData, for: screen)
    }

    func updateWallpaperMode(_ mode: WallpaperMode, for screen: Screen) {
        automationOrchestrator.updateWallpaperMode(mode, for: screen)
    }

    func updateScheduleSlots(_ slots: [ScheduleSlot]?, for screen: Screen) {
        automationOrchestrator.updateScheduleSlots(slots, for: screen)
    }

    func updatePlaylistRotationMinutes(_ minutes: Int?, for screen: Screen) {
        automationOrchestrator.updatePlaylistRotationMinutes(minutes, for: screen)
    }
}
