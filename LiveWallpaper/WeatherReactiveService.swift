import Foundation
import CoreLocation
import Observation

@MainActor @Observable
final class WeatherReactiveService: NSObject, CLLocationManagerDelegate {

    private(set) var currentCondition: WeatherDescription?
    private(set) var currentParticleEffect: ParticleEffect = .none
    private(set) var currentEffectAdjustments: WeatherEffectAdjustments = .neutral
    private(set) var locationStatus: LocationStatus = .notDetermined
    private(set) var lastError: String?

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

    @ObservationIgnored private let locationManager = CLLocationManager()
    @ObservationIgnored private var currentLocation: CLLocation?
    @ObservationIgnored private var updateTask: Task<Void, Never>?

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

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    // MARK: - Public API

    func startMonitoring() {
        let status = locationManager.authorizationStatus
        switch status {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            locationManager.requestLocation()
        default:
            break
        }

        updateTask?.cancel()
        updateTask = Task { [weak self] in
            await self?.fetchWeatherIfPossible()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(900))
                } catch {
                    return
                }
                await self?.fetchWeatherIfPossible()
            }
        }
    }

    func stopMonitoring() {
        updateTask?.cancel()
        updateTask = nil
        locationManager.stopUpdatingLocation()
    }

    func refresh() {
        Task { await fetchWeatherIfPossible() }
    }

    // MARK: - Weather Fetch (Open-Meteo)

    private func fetchWeatherIfPossible() async {
        guard let location = currentLocation else {
            locationManager.requestLocation()
            return
        }

        locationStatus = .fetching

        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        let urlString = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=weather_code,temperature_2m,cloud_cover&timezone=auto"

        guard let url = URL(string: urlString) else {
            lastError = "Invalid URL"
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

            Logger.info("Weather updated: \(description.rawValue), code=\(weatherCode), particle=\(currentParticleEffect.rawValue)", category: .screenManager)
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

    private func mapDescriptionToParticle(_ desc: WeatherDescription) -> ParticleEffect {
        switch desc {
        case .clear:        return .fireflies
        case .partlyCloudy: return .none
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

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let location = locations.last
        Task { @MainActor [weak self] in
            guard let self, let location = location else { return }
            self.currentLocation = location
            self.locationStatus = .authorized
            self.locationManager.stopUpdatingLocation()
            await self.fetchWeatherIfPossible()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let errorDesc = error.localizedDescription
        Task { @MainActor [weak self] in
            self?.lastError = errorDesc
            self?.locationStatus = .error
            Logger.warning("Location failed: \(errorDesc)", category: .screenManager)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch status {
            case .authorizedAlways, .authorizedWhenInUse:
                self.locationStatus = .authorized
                self.locationManager.requestLocation()
            case .denied, .restricted:
                self.locationStatus = .denied
            case .notDetermined:
                self.locationStatus = .notDetermined
            @unknown default:
                break
            }
        }
    }
}
