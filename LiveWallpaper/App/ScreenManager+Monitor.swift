import SwiftUI
import Combine
import Observation

extension ScreenManager {
    // MARK: - Monitor overlay layer

    /// Reconcile the Monitor overlay for every live display against its persisted
    /// `monitorOverlay` config. Runs on startup, screen-set / frame changes, and
    /// after an overlay setting is toggled: tears down overlays for gone or disabled
    /// displays and creates/updates the rest. Idempotent.
    func reconcileMonitorOverlays() {
        MonitorOverlayController.shared.onOverlayEdited = { [weak self] screenID, board in
            self?.persistMonitorOverlayBoard(board, screenID: screenID)
        }
        MonitorOverlayController.shared.retainOnly(Set(screens.map(\.id)))
        let agentFleetEnabled = featureCatalog.isEnabled(.agentFleet)
        for screen in screens {
            let overlay = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint)?.monitorOverlay
            let frame = displayRegistry.findNSScreen(for: screen.id)?.frame ?? screen.frame
            MonitorOverlayController.shared.apply(
                overlay: overlay,
                screenID: screen.id,
                screenFrame: frame,
                agentFleetEnabled: agentFleetEnabled
            )
        }
    }

    /// Reconcile on the NEXT runloop tick. Menu controls (the overlay toggle /
    /// layer picker) mutate config inside a SwiftUI action; running the reconcile
    /// there would push the board's observable state DURING the view update
    /// ("Publishing changes from within view updates"). Deferring moves the whole
    /// create/apply/push chain out of that cycle. Idempotent, so coalescing rapid
    /// toggles is harmless.
    private func scheduleMonitorOverlayReconcile() {
        Task { @MainActor [weak self] in self?.reconcileMonitorOverlays() }
    }

    /// Persist an overlay board edit made ON the floating overlay back into the
    /// screen's `monitorOverlay`. The edit already shows on the overlay, so this
    /// only writes it through — no push-back needed.
    private func persistMonitorOverlayBoard(_ board: MonitorBoardConfiguration, screenID: CGDirectDisplayID) {
        guard let screen = screens.first(where: { $0.id == screenID }),
              var configuration = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else { return }
        var overlay = configuration.monitorOverlay ?? .default
        guard overlay.board != board else { return }
        overlay.board = board
        configuration.monitorOverlay = overlay
        saveConfiguration(configuration)
    }

    /// True when at least one display has its Monitor overlay switched on.
    var isMonitorOverlayEnabled: Bool {
        screens.contains { screen in
            configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint)?.monitorOverlay?.enabled == true
        }
    }

    /// Toggle the Monitor overlay on every display (menu-bar master switch).
    func setMonitorOverlayEnabled(_ enabled: Bool) {
        for screen in screens {
            guard var configuration = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else { continue }
            var overlay = configuration.monitorOverlay ?? .default
            guard overlay.enabled != enabled else { continue }
            overlay.enabled = enabled
            configuration.monitorOverlay = overlay
            saveConfiguration(configuration)
        }
        scheduleMonitorOverlayReconcile()
    }

    /// The active overlay z-plane (first enabled display's, else the default).
    var monitorOverlayLevel: MonitorOverlayLevel {
        for screen in screens {
            if let overlay = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint)?.monitorOverlay,
               overlay.enabled {
                return overlay.level
            }
        }
        return .desktop
    }

    /// Set the overlay z-plane on every display.
    func setMonitorOverlayLevel(_ level: MonitorOverlayLevel) {
        for screen in screens {
            guard var configuration = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else { continue }
            var overlay = configuration.monitorOverlay ?? .default
            guard overlay.level != level else { continue }
            overlay.level = level
            configuration.monitorOverlay = overlay
            saveConfiguration(configuration)
        }
        scheduleMonitorOverlayReconcile()
    }

    /// Enter widget edit mode on every active overlay (menu-bar driven). The
    /// board's own Done control also exits.
    func setMonitorOverlayWidgetsEditing(_ editing: Bool) {
        MonitorOverlayController.shared.setEditing(editing)
    }

    /// True when at least one overlay panel is currently on screen.
    var hasActiveMonitorOverlay: Bool { MonitorOverlayController.shared.hasActiveOverlay }

    /// True when at least one screen is currently running a Monitor wallpaper —
    /// drives the menu-bar "Edit Widgets" entry's visibility.
    var hasActiveMonitorWallpaper: Bool {
        screens.contains { $0.runtimeSession?.wallpaperType == .monitor }
    }

    /// Enter/exit widget edit mode on every live Monitor board. The board's own
    /// Done control also exits, so this is a fire-once "enter" from the menu bar.
    func setMonitorWidgetsEditing(_ editing: Bool) {
        for view in liveMonitorBoardViews() {
            view.setEditing(editing)
        }
    }

    func liveMonitorBoardViews() -> [MonitorWallpaperView] {
        screens.compactMap { screen in
            guard screen.runtimeSession?.wallpaperType == .monitor else { return nil }
            return screen.runtimeSession?.wallpaperWindow?.contentView as? MonitorWallpaperView
        }
    }

    func liveMonitorBoardViews(for screen: Screen) -> [MonitorWallpaperView] {
        guard screen.runtimeSession?.wallpaperType == .monitor,
              let view = screen.runtimeSession?.wallpaperWindow?.contentView as? MonitorWallpaperView else {
            return []
        }
        return [view]
    }

    func setSceneWallpaper(descriptor: SceneDescriptor, origin: WPEOrigin?, for screen: Screen) {
        var configuration = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) ?? ScreenConfiguration(
            screenID: screen.id,
            wallpaper: .scene(descriptor)
        ).applyingDisplayDefaults(SettingsManager.shared.loadDisplayDefaults())
        if configuration.activeWallpaper == .scene(descriptor),
           configuration.wpeOrigin == origin,
           screen.runtimeSession?.wallpaperType == .scene {
            Logger.info("Scene wallpaper already active for screen \(screen.id); keeping existing scene session", category: .screenManager)
            return
        }

        configuration.setSceneWallpaper(descriptor, origin: origin)
        saveConfiguration(configuration)
        restoreWallpaperSession(for: screen, configuration: configuration, preservingState: false)
    }

    func activateAmbientWallpaper(
        _ definition: WallpaperSessionDefinition,
        for screen: Screen,
        configuration: ScreenConfiguration
    ) {
        releaseRuntimeSession(screen)

        let session: AmbientWallpaperSession

        switch definition {
        case .html(let source, let htmlConfig):
            let isLeader = htmlCoordinator.isAudioLeader(source: source, excluding: screen.id)
            let effectiveConfig = htmlCoordinator.runtimeConfig(source: source, config: htmlConfig, for: screen)
            session = ambientSessionBuilder.makeHTMLSession(source: source, config: effectiveConfig, frame: screen.frame)
            Logger.info("Set HTML wallpaper for screen \(screen.id) — \(source.displayName) [leader=\(isLeader)]", category: .screenManager)
        case .metalShader(let shaderSource):
            #if !LITE_BUILD
            session = ambientSessionBuilder.makeShaderSession(source: shaderSource, frame: screen.frame)
            Logger.info("Set shader wallpaper (\(shaderSource)) for screen \(screen.id)", category: .screenManager)
            #else
            _ = shaderSource
            return
            #endif
        case .scene(let descriptor):
            #if !LITE_BUILD
            let dependencyMounts = WPEDependencyMountResolver().mounts(
                dependencyWorkshopIDs: descriptor.dependencyWorkshopIDs,
                origin: configuration.wpeOrigin
            )
            let engineRoot = WPEEngineAssetsLibrary.shared.resolveAuthorizedRoot()
            guard let sceneSession = ambientSessionBuilder.makeSceneSession(
                descriptor: descriptor,
                origin: configuration.wpeOrigin,
                frame: screen.frame,
                dependencyMounts: dependencyMounts,
                engineAssetsRootURL: engineRoot
            ) else {
                Logger.warning("Scene wallpaper for screen \(screen.id) (workshop \(descriptor.workshopID)) could not be built — cache missing or descriptor invalid", category: .screenManager)
                // The old session was already torn down at the top of this
                // method; without this the menu/inspector summary cache keeps
                // showing the now-dead scene as active. Refresh so the screen
                // reads as not-configured instead of silently going stale.
                notifyWallpaperSessionChanged()
                return
            }
            observeRuntimeErrors(for: sceneSession)
            screen.installRuntimeSession(sceneSession)
            // Push the persisted playback inspector state into the freshly
            // installed scene session so the user's saved Frame Rate /
            // Mute / Volume take effect from the first frame instead of
            // only after the inspector slider moves. (For mute/volume
            // this is also why those controls used to be dead UI for
            // `.scene` — there was nothing to push them through.)
            sceneSession.frameRateController?.setFrameRateLimit(configuration.frameRateLimit)
            sceneSession.setMouseInteractionEnabled(configuration.sceneMouseInteractionEnabled)
            sceneSession.setClickCaptureEnabled(configuration.sceneClickCaptureEnabled)
            sceneSession.setSceneFitMode(configuration.fitMode)
            if let audio = sceneSession.audioController {
                audio.setAudioMuted(configuration.muted)
                audio.setAudioVolume(configuration.videoVolume)
            }
            applyPerformancePolicy(to: screen)
            Logger.info("Set scene wallpaper (workshop \(descriptor.workshopID)) for screen \(screen.id)", category: .screenManager)
            notifyWallpaperSessionChanged()
            #else
            _ = descriptor
            #endif
            return
        case .monitor(let monitorConfig):
            session = ambientSessionBuilder.makeMonitorSession(
                monitorConfig,
                agentFleetEnabled: featureCatalog.isEnabled(.agentFleet),
                frame: screen.frame,
                onConfigurationEdited: { [weak self, weak screen] edited in
                    guard let self, let screen else { return }
                    self.persistMonitorConfigurationFromBoard(edited, for: screen)
                }
            )
            Logger.info("Set monitor wallpaper for screen \(screen.id) [agentFleet=\(featureCatalog.isEnabled(.agentFleet))]", category: .screenManager)
        case .video:
            return
        }

        observeRuntimeErrors(for: session)
        screen.installRuntimeSession(session)
        applyPerformancePolicy(to: screen)
        notifyWallpaperSessionChanged()
    }

}
