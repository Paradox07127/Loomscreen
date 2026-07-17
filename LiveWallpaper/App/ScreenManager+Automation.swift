import SwiftUI
import Combine
import LiveWallpaperCore
import Observation

extension ScreenManager {
    #if !LITE_BUILD
    func wpeImportError(for screen: Screen) -> AppError? {
        wpeImportTracker.error(for: screen.id)
    }

    func clearWPEImportError(for screen: Screen) {
        wpeImportTracker.clearError(for: screen.id)
    }

    typealias WPEProjectApplyOutcome = WPEImportCoordinator.ApplyOutcome

    @discardableResult
    func importWallpaperEngineProject(at folderURL: URL, for screen: Screen) async -> WPEProjectApplyOutcome {
        guard !isTerminating else {
            return .rejected(reason: "Application terminating")
        }
        return await wpeImportCoordinator.importProject(at: folderURL, for: screen)
    }

    func activateWPEHistoryEntry(_ entry: WPEHistoryEntry, for screen: Screen) async {
        guard !isTerminating else { return }
        await wpeImportCoordinator.activateHistoryEntry(entry, for: screen)
    }

    func removeWPEImport(workshopID: String) {
        guard !isTerminating else { return }
        clearActiveWPEWallpaper(workshopID: workshopID)
        wpeImportCoordinator.removeWorkshop(workshopID: workshopID)
    }
    /// Installed-page CAS delete: only an exact persisted identity match may
    /// disturb live sessions or scrub configuration references.
    @discardableResult
    func removeWPEImport(workshopID: String, matchingImportedAt importedAt: Date) -> Bool {
        guard !isTerminating,
              SettingsManager.shared.removeWPEImport(
                  workshopID: workshopID,
                  matchingImportedAt: importedAt
              ) else { return false }
        clearActiveWPEWallpaper(workshopID: workshopID)
        wpeImportCoordinator.clearRemovedWorkshopReferences(workshopID: workshopID)
        return true
    }
    private func clearActiveWPEWallpaper(workshopID: String) {
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
    }
    #endif

    func updateEffectConfig(_ effectConfig: VideoEffectConfig, for screen: Screen) {
        guard !isTerminating else { return }
        effectsCoordinator.updateEffectConfig(effectConfig, for: screen)
    }

    func updateParticleEffect(_ effect: ParticleEffect, for screen: Screen) {
        guard !isTerminating else { return }
        effectsCoordinator.updateParticleEffect(effect, for: screen)
    }

    func updateParticleDensity(_ density: Double, for screen: Screen) {
        guard !isTerminating else { return }
        effectsCoordinator.updateParticleDensity(density, for: screen)
    }

    func setWeatherReactive(_ enabled: Bool, for screen: Screen) {
        guard !isTerminating else { return }
        effectsCoordinator.setWeatherReactive(enabled, for: screen)
    }

    func startWeatherMonitoring() {
        guard !isTerminating else { return }
        effectsCoordinator.startWeatherMonitoring()
    }

    func updatePlaylistBookmarks(_ bookmarks: [Data], for screen: Screen) {
        guard !isTerminating else { return }
        automationOrchestrator.updatePlaylistBookmarks(bookmarks, for: screen)
    }

    func setPrimaryVideo(bookmark: Data, for screen: Screen) {
        guard !isTerminating else { return }
        automationOrchestrator.setPrimaryVideo(bookmark: bookmark, for: screen)
    }

    func replacePlaylist(ordered: [Data], primary: Data, for screen: Screen) {
        guard !isTerminating else { return }
        automationOrchestrator.replacePlaylist(ordered: ordered, primary: primary, for: screen)
    }

    func playPlaylistEntry(at index: Int, for screen: Screen) {
        guard !isTerminating else { return }
        automationOrchestrator.playPlaylistEntry(at: index, for: screen)
    }

    func updateShufflePlaylist(_ shuffle: Bool, for screen: Screen) {
        guard !isTerminating else { return }
        automationOrchestrator.updateShufflePlaylist(shuffle, for: screen)
    }

    func advancePlaylist(for screen: Screen) {
        guard !isTerminating else { return }
        automationOrchestrator.advancePlaylist(for: screen)
    }

    func regressPlaylist(for screen: Screen) {
        guard !isTerminating else { return }
        automationOrchestrator.regressPlaylist(for: screen)
    }

    func replaceActiveBookmark(_ bookmarkData: Data, for screen: Screen) {
        guard !isTerminating else { return }
        automationOrchestrator.replaceActiveBookmark(bookmarkData, for: screen)
    }

    func updateWallpaperMode(_ mode: WallpaperMode, for screen: Screen) {
        guard !isTerminating else { return }
        automationOrchestrator.updateWallpaperMode(mode, for: screen)
    }

    func updateScheduleSlots(_ slots: [ScheduleSlot]?, for screen: Screen) {
        guard !isTerminating else { return }
        automationOrchestrator.updateScheduleSlots(slots, for: screen)
    }

    func updatePlaylistRotationMinutes(_ minutes: Int?, for screen: Screen) {
        guard !isTerminating else { return }
        automationOrchestrator.updatePlaylistRotationMinutes(minutes, for: screen)
    }
}
