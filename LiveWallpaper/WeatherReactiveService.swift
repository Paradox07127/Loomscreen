import Foundation
import CoreLocation
import Observation

@MainActor @Observable
final class WeatherReactiveService {

    static let refreshInterval: Duration = .seconds(3600)

    private(set) var currentCondition: WeatherDescription?
    private(set) var currentParticleEffect: ParticleEffect = .none
    private(set) var currentEffectAdjustments: WeatherEffectAdjustments = .neutral
    private(set) var locationStatus: LocationStatus = .notDetermined
    private(set) var lastError: String?
    /// `nil` until at least one resolve completes. Drives the status badge.
    private(set) var activeLocationLabel: String?

    // MARK: - Types

    enum LocationStatus: String {
        case notDetermined = "Not Determined"
        case authorized = "Authorized"
        case denied = "Location Denied"
        case fetching = "Fetching..."
        case available = "Available"
        case error = "Error"
    }

    enum WeatherDescription: String {
        case clear = "Clear"
        case partlyCloudy = "Partly Cloudy"
        case cloudy = "Overcast"
        case foggy = "Foggy"
        case drizzle = "Drizzle"
        case rain = "Rain"
        case heavyRain = "Heavy Rain"
        case snow = "Snow"
        case heavySnow = "Heavy Snow"
        case thunderstorm = "Thunderstorm"
        case unknown = "Unknown"
    }

    struct WeatherEffectAdjustments: Equatable {
        var saturation: Double
        var brightness: Double
        var warmth: Double
        var blurRadius: Double
        var vignetteIntensity: Double

        static let neutral = WeatherEffectAdjustments(
            saturation: 1.0, brightness: 0, warmth: 6500, blurRadius: 0, vignetteIntensity: 0
        )
    }

    @ObservationIgnored private let locationProvider: WeatherLocationProviding
    @ObservationIgnored nonisolated(unsafe) private var updateTask: Task<Void, Never>?
    /// Separate from `updateTask` so an explicit `refresh()` can supersede
    /// the in-flight fetch without tearing down the hourly poll cycle.
    @ObservationIgnored nonisolated(unsafe) private var fetchTask: Task<Void, Never>?
    /// `nonisolated(unsafe)`: only mutated from MainActor code, but deinit
    /// (released on an arbitrary queue) also touches it, which Swift 6 can't prove safe.
    @ObservationIgnored nonisolated(unsafe) private var preferenceObserver: NSObjectProtocol?

    // MARK: - Open-Meteo Response Model

    private struct OpenMeteoResponse: Decodable {
        struct Current: Decodable {
            let weather_code: Int
            let temperature_2m: Double
            let cloud_cover: Double
        }
        let current: Current
    }

    // MARK: - Initialization

    init(locationProvider: WeatherLocationProviding = WeatherLocationProvider()) {
        self.locationProvider = locationProvider
        observePreferenceChanges()
    }

    deinit {
        updateTask?.cancel()
        fetchTask?.cancel()
        if let observer = preferenceObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Public API

    func startMonitoring() {
        locationProvider.requestCoreLocationAuthorizationIfNeeded()

        updateTask?.cancel()
        startFetch()
        updateTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.refreshInterval)
                } catch {
                    return
                }
                await MainActor.run {
                    self?.startFetch()
                }
            }
        }
    }

    func stopMonitoring() {
        updateTask?.cancel()
        updateTask = nil
        fetchTask?.cancel()
        fetchTask = nil
    }

    func refresh() {
        startFetch()
    }

    /// Single-flight fetch — supersedes any in-flight fetch so refresh taps don't pile up overlapping requests.
    private func startFetch() {
        fetchTask?.cancel()
        fetchTask = Task { [weak self] in
            await self?.fetchWeatherIfPossible()
        }
    }

    // MARK: - Preference Observer

    private func observePreferenceChanges() {
        guard preferenceObserver == nil else { return }
        preferenceObserver = NotificationCenter.default.addObserver(
            forName: .weatherLocationPreferenceDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    // MARK: - Weather Fetch (Open-Meteo)

    private func fetchWeatherIfPossible() async {
        // Off means the entire weather-reactive pipeline is dormant: no
        // location query, no Open-Meteo request, no observable updates.
        // We still clear the cached state so a previously-rendered
        // particle effect stops driving the wallpaper.
        let preference = SettingsManager.shared.loadGlobalSettings().weatherLocation
        if preference.source == .off {
            currentCondition = nil
            currentParticleEffect = .none
            currentEffectAdjustments = .neutral
            activeLocationLabel = nil
            lastError = nil
            locationStatus = .notDetermined
            return
        }

        locationStatus = .fetching

        let resolution = await locationProvider.resolveCoordinate()
        guard !Task.isCancelled else { return }
        activeLocationLabel = resolution.displayName

        guard let coordinate = resolution.coordinate else {
            lastError = resolution.error
            locationStatus = resolution.error == nil ? .notDetermined : .denied
            return
        }

        let lat = coordinate.latitude
        let lon = coordinate.longitude
        let urlString = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=weather_code,temperature_2m,cloud_cover&timezone=auto"

        guard let url = URL(string: urlString) else {
            lastError = String(localized: "Invalid URL", defaultValue: "Invalid URL", comment: "Weather fetch error.")
            locationStatus = .error
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            try Task.checkCancellation()
            let response = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
            try Task.checkCancellation()

            let weatherCode = response.current.weather_code
            let cloudCover = response.current.cloud_cover / 100.0
            let description = mapWMOCode(weatherCode)

            currentCondition = description
            currentParticleEffect = mapDescriptionToParticle(description)
            currentEffectAdjustments = mapDescriptionToEffects(description, cloudCover: cloudCover)
            locationStatus = .available
            lastError = nil

            Logger.info("Weather updated: \(description.rawValue), code=\(weatherCode), particle=\(currentParticleEffect.rawValue), source=\(resolution.resolvedSource?.rawValue ?? "none")", category: .screenManager)
        } catch is CancellationError {
            return
        } catch {
            lastError = error.localizedDescription
            locationStatus = .error
            Logger.error("Weather fetch failed: \(error.localizedDescription)", category: .screenManager)
        }
    }

    // MARK: - WMO Weather Code → Description

    private func mapWMOCode(_ code: Int) -> WeatherDescription {
        switch code {
        case 0:           return .clear
        case 1, 2:        return .partlyCloudy
        case 3:           return .cloudy
        case 45, 48:      return .foggy
        case 51, 53, 55:  return .drizzle
        case 56, 57:      return .drizzle
        case 61, 63, 80:  return .rain
        case 65, 81, 82:  return .heavyRain
        case 66, 67:      return .rain
        case 71, 73, 85:  return .snow
        case 75, 77, 86:  return .heavySnow
        case 95:          return .thunderstorm
        case 96, 99:      return .thunderstorm
        default:          return .unknown
        }
    }

    // MARK: - Weather → Particle Mapping

    /// Maps a weather description to a particle effect for auto-reactive
    /// mode. Time-of-day–dependent effects (fireflies, stars) and seasonal
    /// effects (sakura, falling leaves) are intentionally excluded — they
    /// belong to manual user selection because the weather API exposes
    /// neither timestamp nor season. `lightning` likewise stays out: a
    /// surprise full-screen flash imposed without consent is jarring.
    private func mapDescriptionToParticle(_ desc: WeatherDescription) -> ParticleEffect {
        switch desc {
        case .clear:        return .none
        case .partlyCloudy: return .dust
        case .cloudy:       return .none
        case .foggy:        return .none
        case .drizzle:      return .rain
        case .rain:         return .rain
        case .heavyRain:    return .rain
        case .snow:         return .snow
        case .heavySnow:    return .snow
        case .thunderstorm: return .rain
        case .unknown:      return .none
        }
    }

    // MARK: - Weather → CIFilter Mapping

    private func mapDescriptionToEffects(_ desc: WeatherDescription, cloudCover: Double) -> WeatherEffectAdjustments {
        switch desc {
        case .clear:
            return WeatherEffectAdjustments(
                saturation: 1.15, brightness: 0.02, warmth: 5500,
                blurRadius: 0, vignetteIntensity: 0.3
            )
        case .partlyCloudy:
            return WeatherEffectAdjustments(
                saturation: 1.0, brightness: 0, warmth: 6200,
                blurRadius: 0, vignetteIntensity: 0
            )
        case .cloudy:
            return WeatherEffectAdjustments(
                saturation: 0.75, brightness: -0.05, warmth: 7000,
                blurRadius: 0, vignetteIntensity: 0.5
            )
        case .foggy:
            return WeatherEffectAdjustments(
                saturation: 0.6, brightness: -0.03, warmth: 7500,
                blurRadius: 4, vignetteIntensity: 0.8
            )
        case .drizzle:
            return WeatherEffectAdjustments(
                saturation: 0.8, brightness: -0.05, warmth: 7000,
                blurRadius: 0.5, vignetteIntensity: 0.5
            )
        case .rain:
            return WeatherEffectAdjustments(
                saturation: 0.7, brightness: -0.08, warmth: 7500,
                blurRadius: 1, vignetteIntensity: 1.0
            )
        case .heavyRain:
            return WeatherEffectAdjustments(
                saturation: 0.6, brightness: -0.12, warmth: 8000,
                blurRadius: 2, vignetteIntensity: 1.5
            )
        case .snow:
            return WeatherEffectAdjustments(
                saturation: 0.65, brightness: 0.05, warmth: 8000,
                blurRadius: 1, vignetteIntensity: 0.3
            )
        case .heavySnow:
            return WeatherEffectAdjustments(
                saturation: 0.5, brightness: 0.08, warmth: 8500,
                blurRadius: 3, vignetteIntensity: 0.5
            )
        case .thunderstorm:
            return WeatherEffectAdjustments(
                saturation: 0.5, brightness: -0.15, warmth: 8000,
                blurRadius: 2, vignetteIntensity: 1.5
            )
        case .unknown:
            return .neutral
        }
    }
}
