import CoreGraphics
import Foundation

/// Owns playlist + schedule automation: per-screen playlist bookmarks /
/// shuffle / rotation, the schedule slot table, the `applyCursor` /
/// `performScheduledSwitch` transition machines, and the
/// `automationCoordinator.start(...)` wiring that drives both from the
/// shared timer.
///
/// Reuses the existing `WallpaperAutomationCoordinator` (low-level
/// scheduler service) as a borrowed ref; this orchestrator is the
/// behavior layer on top of it.
@MainActor
final class WallpaperAutomationOrchestrator {
    private let configurationStore: WallpaperConfigurationStore
    private let automationCoordinator: WallpaperAutomationCoordinator
    private let playableVideoLoader: any PlayableVideoLoading
    private let screensProvider: @MainActor () -> [Screen]
    private let saveConfiguration: @MainActor (ScreenConfiguration) -> Void
    private let recordBookmarkDisplayName: @MainActor (Data, String?) -> Void
    private let releaseRuntimeSession: @MainActor (Screen) -> Void
    private let setupVideoPlayback: @MainActor (URL, Screen) -> Void
    private let reloadWallpaperForScreen: @MainActor (Screen) -> Void
    private let bumpTransition: @MainActor (CGDirectDisplayID) -> Int
    private let isCurrentTransition: @MainActor (Int, CGDirectDisplayID) -> Bool

    init(
        configurationStore: WallpaperConfigurationStore,
        automationCoordinator: WallpaperAutomationCoordinator,
        playableVideoLoader: any PlayableVideoLoading,
        screensProvider: @MainActor @escaping () -> [Screen],
        saveConfiguration: @MainActor @escaping (ScreenConfiguration) -> Void,
        recordBookmarkDisplayName: @MainActor @escaping (Data, String?) -> Void,
        releaseRuntimeSession: @MainActor @escaping (Screen) -> Void,
        setupVideoPlayback: @MainActor @escaping (URL, Screen) -> Void,
        reloadWallpaperForScreen: @MainActor @escaping (Screen) -> Void,
        bumpTransition: @MainActor @escaping (CGDirectDisplayID) -> Int,
        isCurrentTransition: @MainActor @escaping (Int, CGDirectDisplayID) -> Bool
    ) {
        self.configurationStore = configurationStore
        self.automationCoordinator = automationCoordinator
        self.playableVideoLoader = playableVideoLoader
        self.screensProvider = screensProvider
        self.saveConfiguration = saveConfiguration
        self.recordBookmarkDisplayName = recordBookmarkDisplayName
        self.releaseRuntimeSession = releaseRuntimeSession
        self.setupVideoPlayback = setupVideoPlayback
        self.reloadWallpaperForScreen = reloadWallpaperForScreen
        self.bumpTransition = bumpTransition
        self.isCurrentTransition = isCurrentTransition
    }

    // MARK: - Playlist

    func updatePlaylistBookmarks(_ bookmarks: [Data], for screen: Screen) {
        guard var config = configurationStore.get(for: screen.id) else { return }
        config.playlistBookmarks = bookmarks.isEmpty ? nil : bookmarks
        saveConfiguration(config)
    }

    func setPrimaryVideo(bookmark: Data, for screen: Screen) {
        guard var config = configurationStore.get(for: screen.id),
              config.savedVideoBookmarkData != bookmark else { return }

        var extras = config.playlistBookmarks ?? []
        if let oldPrimary = config.savedVideoBookmarkData,
           !extras.contains(oldPrimary), oldPrimary != bookmark {
            extras.append(oldPrimary)
        }
        extras.removeAll(where: { $0 == bookmark })

        config.replacePrimaryVideo(bookmarkData: bookmark)
        config.playlistBookmarks = extras.isEmpty ? nil : extras
        saveConfiguration(config)

        reloadWallpaperForScreen(screen)
    }

    /// Writes reordered playlist entries while preserving the active bookmark.
    func replacePlaylist(primary: Data, extras: [Data], for screen: Screen) {
        guard var config = configurationStore.get(for: screen.id) else { return }

        let oldCombined = [config.savedVideoBookmarkData].compactMap { $0 } + (config.playlistBookmarks ?? [])
        let oldCursor = config.playlistCursorIndex ?? 0
        let oldActive: Data? = oldCursor < oldCombined.count ? oldCombined[oldCursor] : config.videoBookmarkData

        let primaryChanged = config.savedVideoBookmarkData != primary
        config.savedVideoBookmarkData = primary
        config.playlistBookmarks = extras.isEmpty ? nil : extras

        let newCombined = [primary] + extras
        if primaryChanged {
            config.playlistCursorIndex = 0
            config.activeWallpaper = .video(bookmarkData: primary)
        } else {
            let resolved = PlaylistPolicy.resolveCursor(activeBookmark: oldActive, in: newCombined)
            config.playlistCursorIndex = resolved
            if resolved < newCombined.count {
                config.activeWallpaper = .video(bookmarkData: newCombined[resolved])
            }
        }
        saveConfiguration(config)

        if primaryChanged {
            reloadWallpaperForScreen(screen)
        }
    }

    func playPlaylistEntry(at index: Int, for screen: Screen) {
        guard let config = configurationStore.get(for: screen.id),
              let primary = config.savedVideoBookmarkData else { return }
        let combined = [primary] + (config.playlistBookmarks ?? [])
        guard index >= 0, index < combined.count else { return }
        applyCursor(index, combined: combined, screen: screen, label: "jumping")
    }

    func updateShufflePlaylist(_ shuffle: Bool, for screen: Screen) {
        guard var config = configurationStore.get(for: screen.id),
              config.shufflePlaylist != shuffle else { return }
        config.shufflePlaylist = shuffle
        saveConfiguration(config)
    }

    func advancePlaylist(for screen: Screen) {
        guard let config = configurationStore.get(for: screen.id),
              config.wallpaperMode == .playlist,
              let primary = config.savedVideoBookmarkData else { return }

        let combined = [primary] + (config.playlistBookmarks ?? [])
        guard combined.count > 1 else { return }

        let currentCursor = config.playlistCursorIndex ?? 0
        guard let nextCursor = PlaylistPolicy.nextCursor(
            currentCursor: currentCursor,
            playlistCount: combined.count,
            shuffle: config.shufflePlaylist
        ) else { return }

        applyCursor(nextCursor, combined: combined, screen: screen, label: "advancing")
    }

    func regressPlaylist(for screen: Screen) {
        guard let config = configurationStore.get(for: screen.id),
              config.wallpaperMode == .playlist,
              let primary = config.savedVideoBookmarkData else { return }

        let combined = [primary] + (config.playlistBookmarks ?? [])
        guard combined.count > 1 else { return }

        let currentCursor = config.playlistCursorIndex ?? 0
        guard let prevCursor = PlaylistPolicy.previousCursor(
            currentCursor: currentCursor,
            playlistCount: combined.count,
            shuffle: config.shufflePlaylist
        ) else { return }

        applyCursor(prevCursor, combined: combined, screen: screen, label: "regressing")
    }

    func replaceActiveBookmark(_ bookmarkData: Data, for screen: Screen) {
        guard let config = configurationStore.get(for: screen.id) else { return }
        let updated = config.withUpdatedActiveBookmark(bookmarkData)
        saveConfiguration(updated)
    }

    func updateWallpaperMode(_ mode: WallpaperMode, for screen: Screen) {
        guard var config = configurationStore.get(for: screen.id),
              config.wallpaperType == .video,
              config.hasConfiguredVideoSource,
              config.wallpaperMode != mode else { return }
        config.wallpaperMode = mode
        saveConfiguration(config)
    }

    func updatePlaylistRotationMinutes(_ minutes: Int?, for screen: Screen) {
        guard var config = configurationStore.get(for: screen.id) else { return }
        config.playlistRotationMinutes = minutes
        saveConfiguration(config)
    }

    private func applyCursor(
        _ cursor: Int,
        combined: [Data],
        screen: Screen,
        label: String
    ) {
        guard cursor < combined.count else { return }
        let targetBookmark = combined[cursor]

        guard let url = try? ResourceUtilities.resolveBookmark(targetBookmark).url else { return }
        recordBookmarkDisplayName(targetBookmark, url.lastPathComponent)

        let screenID = screen.id
        let generation = bumpTransition(screenID)
        let videoLoader = playableVideoLoader

        Task { [weak self] in
            do {
                try await videoLoader.validatePlayableVideo(at: url)
                await MainActor.run { [weak self] in
                    guard let self,
                          self.isCurrentTransition(generation, screenID),
                          let liveScreen = self.screensProvider().first(where: { $0.id == screenID }),
                          var liveConfig = self.configurationStore.get(for: screenID) else { return }
                    liveConfig.playlistCursorIndex = cursor
                    liveConfig.activeWallpaper = .video(bookmarkData: targetBookmark)
                    self.saveConfiguration(liveConfig)
                    Logger.info("Playlist: \(label) to \(url.lastPathComponent) (cursor \(cursor)) for screen \(screenID)", category: .screenManager)
                    self.releaseRuntimeSession(liveScreen)
                    self.setupVideoPlayback(url, liveScreen)
                }
            } catch {
                Logger.error("Playlist \(label) failed for screen \(screenID): \(error.localizedDescription)", category: .screenManager)
            }
        }
    }

    // MARK: - Schedule

    func updateScheduleSlots(_ slots: [ScheduleSlot]?, for screen: Screen) {
        guard var config = configurationStore.get(for: screen.id) else { return }
        config.scheduleSlots = slots
        saveConfiguration(config)

        if slots != nil {
            checkAndApplySchedule(for: screen)
        }
    }

    func checkAndApplySchedule(for screen: Screen) {
        guard let config = configurationStore.get(for: screen.id) else { return }

        let currentHour = Calendar.current.component(.hour, from: Date())

        switch SchedulePolicy.decision(for: config, hour: currentHour) {
        case .none:
            return

        case .applySlot(let slot, let bookmark):
            performScheduledSwitch(
                bookmark: bookmark,
                logLabel: "switching to \(slot.label) wallpaper",
                for: screen
            ) { config in
                config.applyScheduledBookmark(bookmark)
            }

        case .restorePrimary(let bookmark):
            performScheduledSwitch(
                bookmark: bookmark,
                logLabel: "slot window ended, restoring primary",
                for: screen
            ) { config in
                _ = config.activateSavedVideoWallpaper()
            }
        }
    }

    private func performScheduledSwitch(
        bookmark: Data,
        logLabel: String,
        for screen: Screen,
        mutate: @escaping (inout ScreenConfiguration) -> Void
    ) {
        guard let url = try? ResourceUtilities.resolveBookmark(bookmark).url else { return }
        recordBookmarkDisplayName(bookmark, url.lastPathComponent)

        let screenID = screen.id
        let generation = bumpTransition(screenID)
        let videoLoader = playableVideoLoader

        Task { [weak self] in
            do {
                try await videoLoader.validatePlayableVideo(at: url)
                await MainActor.run { [weak self] in
                    guard let self,
                          self.isCurrentTransition(generation, screenID),
                          let liveScreen = self.screensProvider().first(where: { $0.id == screenID }),
                          var liveConfig = self.configurationStore.get(for: screenID) else { return }
                    Logger.info("Schedule: \(logLabel) for screen \(screenID)", category: .screenManager)
                    mutate(&liveConfig)
                    self.saveConfiguration(liveConfig)
                    self.releaseRuntimeSession(liveScreen)
                    self.setupVideoPlayback(url, liveScreen)
                }
            } catch {
                Logger.error("Schedule transition failed for screen \(screenID): \(error.localizedDescription)", category: .screenManager)
            }
        }
    }

    // MARK: - Automation start

    /// Wires the shared timer (`WallpaperAutomationCoordinator`) into the
    /// per-screen schedule + playlist handlers. ScreenManager calls this
    /// once during launch / restore.
    func startMonitoring() {
        automationCoordinator.start(
            screenProvider: { [weak self] in
                self?.screensProvider() ?? []
            },
            configurationProvider: { [weak self] screenID in
                self?.configurationStore.get(for: screenID)
            },
            scheduleHandler: { [weak self] screen in
                self?.checkAndApplySchedule(for: screen)
            },
            playlistHandler: { [weak self] screen in
                self?.advancePlaylist(for: screen)
            }
        )
    }
}
