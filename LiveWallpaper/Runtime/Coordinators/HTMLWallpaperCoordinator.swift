import AppKit
import CoreGraphics
import Foundation

/// Owns HTML wallpaper management: the 4 public setters
/// (`setHTMLWallpaper` variants + `updateHTMLConfig`) plus the
/// multi-instance audio-leader / trust-evaluation policy. Carved out of
/// `ScreenManager` so the manager doesn't have to host both video and
/// HTML-specific session logic.
///
/// Pure orchestration: borrows refs to the store + screensProvider and
/// takes callbacks for the side-effects ScreenManager still owns
/// (saveConfiguration, restoreWallpaperSession, notifyWallpaperSessionChanged).
@MainActor
final class HTMLWallpaperCoordinator {
    private let configurationStore: WallpaperConfigurationStore
    private let screensProvider: @MainActor () -> [Screen]
    private let saveConfiguration: @MainActor (ScreenConfiguration) -> Void
    private let restoreWallpaperSession: @MainActor (Screen, ScreenConfiguration, Bool) -> Void
    private let notifyWallpaperSessionChanged: @MainActor () -> Void
    private let originReconciler: any OriginReconciler

    init(
        configurationStore: WallpaperConfigurationStore,
        screensProvider: @MainActor @escaping () -> [Screen],
        saveConfiguration: @MainActor @escaping (ScreenConfiguration) -> Void,
        restoreWallpaperSession: @MainActor @escaping (Screen, ScreenConfiguration, Bool) -> Void,
        notifyWallpaperSessionChanged: @MainActor @escaping () -> Void,
        originReconciler: any OriginReconciler
    ) {
        self.configurationStore = configurationStore
        self.screensProvider = screensProvider
        self.saveConfiguration = saveConfiguration
        self.restoreWallpaperSession = restoreWallpaperSession
        self.notifyWallpaperSessionChanged = notifyWallpaperSessionChanged
        self.originReconciler = originReconciler
    }

    // MARK: - Multi-instance diagnostics

    /// Maps each currently-active HTML source signature to the screens that run it.
    func sourceMultiplicity() -> [String: [CGDirectDisplayID]] {
        var map: [String: [CGDirectDisplayID]] = [:]
        for screen in screensProvider() {
            guard screen.runtimeSession?.wallpaperType == .html,
                  let config = configurationStore.get(for: screen.id),
                  case .html(let source, _) = config.activeWallpaper else { continue }
            map[source.diagnosticSignature, default: []].append(screen.id)
        }
        return map
    }

    /// Screens (other than `excluding`) currently running the same HTML source.
    func screensRunningSameSource(as source: HTMLSource, excluding: CGDirectDisplayID) -> [Screen] {
        let signature = source.diagnosticSignature
        return screensProvider().filter { other in
            other.id != excluding
                && other.runtimeSession?.wallpaperType == .html
                && (configurationStore.get(for: other.id)?.activeWallpaper).flatMap { content -> String? in
                    if case .html(let s, _) = content { return s.diagnosticSignature }
                    return nil
                } == signature
        }
    }

    /// True when no other screen is already playing this HTML source — the caller becomes the audio leader.
    func isAudioLeader(source: HTMLSource, excluding screenID: CGDirectDisplayID) -> Bool {
        screensRunningSameSource(as: source, excluding: screenID).isEmpty
    }

    /// Audio-leader policy + trust evaluation merged into the effective HTMLConfig used by the runtime session.
    func runtimeConfig(source: HTMLSource, config: HTMLConfig, for screen: Screen) -> HTMLConfig {
        var effectiveConfig = config

        if !isAudioLeader(source: source, excluding: screen.id), !effectiveConfig.muteAudio {
            effectiveConfig.muteAudio = true
            Logger.info("Multi-instance HTML wallpaper: muting screen \(screen.id) (audio leader is another screen running same source)", category: .screenManager)
        }

        return HTMLWallpaperCompatibilityPolicy.runtimeConfig(
            source: source,
            config: effectiveConfig,
            trustedOrigins: TrustedHostStore.shared.originSet
        ).config
    }

    // MARK: - Public setters

    func setWallpaper(
        source: HTMLSource,
        config: HTMLConfig = .default,
        forceReload: Bool = false,
        for screen: Screen
    ) {
        var configuration = configurationStore.get(for: screen.id) ?? ScreenConfiguration(
            screenID: screen.id,
            wallpaper: .html(source: source, config: config)
        )
        if !forceReload,
           case .html(let existingSource, let existingConfig) = configuration.activeWallpaper,
           existingSource == source,
           existingConfig == config,
           screen.runtimeSession?.wallpaperType == .html {
            Logger.info("HTML wallpaper unchanged for screen \(screen.id); keeping existing WKWebView session", category: .screenManager)
            return
        }

        let previousContent = configurationStore.get(for: screen.id)?.activeWallpaper
        configuration.setHTMLWallpaper(source: source, config: config)
        originReconciler.reconcile(
            &configuration,
            event: .userReplacedActiveWallpaper(previous: previousContent)
        )
        saveConfiguration(configuration)

        restoreWallpaperSession(screen, configuration, false)
    }

    /// Swaps HTML source while keeping existing HTML settings.
    func setWallpaperPreservingConfig(source: HTMLSource, for screen: Screen) {
        let preserved = configurationStore.get(for: screen.id)?.htmlConfig ?? .default
        setWallpaper(source: source, config: preserved, for: screen)
    }

    func setWallpaper(url: String, for screen: Screen) {
        guard let source = HTMLSource(userInput: url) else { return }
        setWallpaper(source: source, for: screen)
    }

    /// Updates the HTML runtime config — mute, JS toggle, mouse, ephemeral storage, tracker blocker.
    func updateConfig(_ config: HTMLConfig, for screen: Screen) {
        guard var existing = configurationStore.get(for: screen.id),
              case .html(let source, let previousConfig) = existing.activeWallpaper else { return }
        guard previousConfig != config else { return }
        existing.activeWallpaper = .html(source: source, config: config)
        saveConfiguration(existing)

        let runtimeConfigValue = runtimeConfig(source: source, config: config, for: screen)
        if !Self.requiresSessionRebuild(previous: previousConfig, current: config),
           let applier = screen.runtimeSession as? any HTMLWallpaperConfigApplying,
           applier.applyHTMLConfig(runtimeConfigValue) {
            if let window = screen.activeWallpaperWindow as? VideoWallpaperWindow {
                window.setWallpaperMouseInteractionEnabled(config.allowMouseInteraction)
            }
            notifyWallpaperSessionChanged()
            return
        }

        restoreWallpaperSession(screen, existing, false)
    }

    private static func requiresSessionRebuild(previous: HTMLConfig, current: HTMLConfig) -> Bool {
        previous.useEphemeralStorage != current.useEphemeralStorage
            || previous.allowJavaScript != current.allowJavaScript
            || previous.blockTrackers != current.blockTrackers
    }
}
