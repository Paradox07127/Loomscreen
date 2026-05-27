import AppKit
import Foundation
import Observation

/// Owns video-effect application (CIFilter pipeline) and weather-reactive
/// monitoring. Replaces the cluster of effects + weather methods that
/// previously lived directly on `ScreenManager`. Two callbacks bridge back
/// to runtime concerns that aren't part of effects responsibility yet:
/// `saveConfiguration` funnels writes through
/// `WallpaperPersistenceCoordinator`, and `applyFrameRateLimit` /
/// `screenRefreshRate` reach into the playback / refresh-rate cache the
/// manager still owns.
@MainActor
final class WallpaperEffectsCoordinator {
    let weatherService: WeatherReactiveService
    private let videoEffectsApplier: VideoEffectsApplicationService

    private let configurationStore: WallpaperConfigurationStore
    private let screensProvider: @MainActor () -> [Screen]
    private let saveConfiguration: @MainActor (ScreenConfiguration) -> Void
    private let applyFrameRateLimit: @MainActor (FrameRateLimit, Screen) -> Void
    private let screenRefreshRate: @MainActor (CGDirectDisplayID) -> Int

    /// Bumped each time `observeWeatherChanges()` registers a new observer.
    /// The onChange callback short-circuits when its captured generation no
    /// longer matches the latest value, so accidentally re-registering does
    /// not cascade into stacked callbacks.
    private var weatherTrackingGeneration: UInt64 = 0

    init(
        weatherService: WeatherReactiveService = WeatherReactiveService(),
        videoEffectsApplier: VideoEffectsApplicationService = VideoEffectsApplicationService(),
        configurationStore: WallpaperConfigurationStore,
        screensProvider: @MainActor @escaping () -> [Screen],
        saveConfiguration: @MainActor @escaping (ScreenConfiguration) -> Void,
        applyFrameRateLimit: @MainActor @escaping (FrameRateLimit, Screen) -> Void,
        screenRefreshRate: @MainActor @escaping (CGDirectDisplayID) -> Int
    ) {
        self.weatherService = weatherService
        self.videoEffectsApplier = videoEffectsApplier
        self.configurationStore = configurationStore
        self.screensProvider = screensProvider
        self.saveConfiguration = saveConfiguration
        self.applyFrameRateLimit = applyFrameRateLimit
        self.screenRefreshRate = screenRefreshRate
    }

    // MARK: - Public API (called from ScreenManager facade)

    func updateEffectConfig(_ effectConfig: VideoEffectConfig, for screen: Screen) {
        guard var config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
              config.effectConfig != effectConfig else { return }
        config.effectConfig = effectConfig
        saveConfiguration(config)
        applyVideoEffects(for: screen, config: config)
    }

    func updateParticleEffect(_ effect: ParticleEffect, for screen: Screen) {
        guard var config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
              config.particleEffect != effect else { return }
        config.particleEffect = effect
        saveConfiguration(config)
        applyParticleEffect(effect, density: config.effectConfig.particleDensity, to: screen)
    }

    func updateParticleDensity(_ density: Double, for screen: Screen) {
        guard var config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else { return }
        let clamped = min(max(density, 0.2), 3.0)
        guard abs(clamped - config.effectConfig.particleDensity) > 0.001 else { return }
        config.effectConfig.particleDensity = clamped
        saveConfiguration(config)
        screen.videoPlayer?.setParticleDensity(clamped)
    }

    func setWeatherReactive(_ enabled: Bool, for screen: Screen) {
        guard var config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
              config.effectConfig.weatherReactive != enabled else { return }
        config.effectConfig.weatherReactive = enabled
        saveConfiguration(config)
        refreshWeatherMonitoringState()

        if enabled {
            applyWeatherEffects(for: screen)
        } else {
            applyParticleEffect(config.particleEffect, density: config.effectConfig.particleDensity, to: screen)
            applyVideoEffects(for: screen, config: config)
        }
    }

    func applyWeatherEffects(for screen: Screen) {
        guard let config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
              config.effectConfig.weatherReactive else { return }

        applyParticleEffect(
            weatherService.currentParticleEffect,
            density: config.effectConfig.particleDensity,
            to: screen
        )

        let adj = weatherService.currentEffectAdjustments
        var weatherConfig = config.effectConfig
        weatherConfig.saturation = adj.saturation
        weatherConfig.brightness = adj.brightness
        weatherConfig.warmth = adj.warmth
        weatherConfig.blurRadius = adj.blurRadius
        weatherConfig.vignetteIntensity = adj.vignetteIntensity

        var updatedConfig = config
        updatedConfig.effectConfig = weatherConfig
        applyVideoEffects(for: screen, config: updatedConfig)
    }

    func startWeatherMonitoring() {
        observeWeatherChanges()
        refreshWeatherMonitoringState()
    }

    /// Applies the CIFilter chain to a screen's active video player.
    func applyVideoEffects(for screen: Screen, config: ScreenConfiguration) {
        guard let player = screen.videoPlayer else {
            Logger.warning("Cannot apply effects: no active player for screen \(screen.id)", category: .videoPlayer)
            return
        }

        videoEffectsApplier.applyEffects(
            to: player,
            screenID: screen.id,
            config: config,
            screenRefreshRate: screenRefreshRate(screen.id),
            noEffectsHandler: { [weak self, weak screen] in
                guard let self, let screen else { return }
                self.applyFrameRateLimit(config.frameRateLimit, screen)
            }
        )
    }

    /// Cancels any in-flight effect application for the given screen.
    func cancelInflight(for screenID: CGDirectDisplayID) {
        videoEffectsApplier.cancelInflight(for: screenID)
    }

    // MARK: - Private helpers

    private func applyParticleEffect(_ effect: ParticleEffect, density: Double, to screen: Screen) {
        screen.videoPlayer?.setParticleEffect(effect, density: density)
    }

    private func refreshWeatherMonitoringState() {
        let activeScreens = screensProvider()
        let activeScreenIDs = Set(activeScreens.map(\.id))
        let configurations = activeScreenIDs.compactMap { configurationStore.get(for: $0) }
        if WeatherReactivePolicy.shouldMonitor(configurations: configurations, activeScreenIDs: activeScreenIDs) {
            weatherService.startMonitoring()
        } else {
            weatherService.stopMonitoring()
        }
    }

    private func observeWeatherChanges() {
        weatherTrackingGeneration &+= 1
        let generation = weatherTrackingGeneration
        withObservationTracking {
            _ = weatherService.currentParticleEffect
            _ = weatherService.currentEffectAdjustments
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.weatherTrackingGeneration == generation else { return }
                for screen in self.screensProvider() {
                    guard let config = self.configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
                          config.effectConfig.weatherReactive else { continue }
                    self.applyWeatherEffects(for: screen)
                }
                self.observeWeatherChanges()
            }
        }
    }
}
