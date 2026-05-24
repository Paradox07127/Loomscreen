import Foundation
import CoreLocation

/// Resolves a coordinate for the weather pipeline by walking the
/// user-preferred chain of `WeatherLocationPreference.Source` values.
///
/// `WeatherReactiveService` calls into this provider; the provider does
/// **not** keep a persistent reference to the service. There is no IP-
/// geolocation source: the only ways to obtain a coordinate are macOS
/// Core Location (with explicit user permission) or a manually-typed
/// city. Choosing `.off` short-circuits the whole resolve so no location
/// is touched at all.
@MainActor
protocol WeatherLocationProviding: AnyObject {
    /// Pull the latest known location preference and resolve it.
    func resolveCoordinate() async -> WeatherLocationResolution

    /// Triggers a CoreLocation authorisation prompt if the user has chosen `.coreLocation` and we haven't asked yet.
    func requestCoreLocationAuthorizationIfNeeded()
}

/// What a location resolution actually produced. The status mirrors the
/// existing `WeatherReactiveService.LocationStatus` enum so the badge UI
/// keeps rendering the same vocabulary.
struct WeatherLocationResolution: Equatable {
    /// Successful coordinate, or `nil` if every source in the chain failed.
    var coordinate: CLLocationCoordinate2D?
    /// What actually produced (or attempted to produce) the coordinate.
    var resolvedSource: WeatherLocationPreference.Source?
    /// Human-readable label for the source — used by the status badge.
    var displayName: String?
    var error: String?

    static let unresolved = WeatherLocationResolution(
        coordinate: nil, resolvedSource: nil, displayName: nil, error: nil
    )

    /// Required so the type can be `Equatable` (CLLocationCoordinate2D isn't Equatable by default).
    static func == (lhs: WeatherLocationResolution, rhs: WeatherLocationResolution) -> Bool {
        lhs.resolvedSource == rhs.resolvedSource &&
        lhs.displayName == rhs.displayName &&
        lhs.error == rhs.error &&
        lhs.coordinate?.latitude == rhs.coordinate?.latitude &&
        lhs.coordinate?.longitude == rhs.coordinate?.longitude
    }
}

@MainActor
final class WeatherLocationProvider: NSObject, WeatherLocationProviding, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    private var pendingCoreLocationContinuation: CheckedContinuation<CLLocation?, Never>?
    /// True between `requestLocation()` and the matching delegate callback.
    /// Concurrent resolves piggyback on the in-flight request rather than
    /// firing a second `requestLocation()` (which would fail with
    /// kCLErrorLocationUnknown on macOS when a request is already pending).
    private var coreLocationRequestInFlight = false

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    // MARK: - Public API

    func resolveCoordinate() async -> WeatherLocationResolution {
        let preference = SettingsManager.shared.loadGlobalSettings().weatherLocation

        switch preference.source {
        case .off:
            return .unresolved

        case .coreLocation:
            if let resolved = await tryCoreLocation() { return resolved }
            if let resolved = tryManual(preference) { return resolved }
            return WeatherLocationResolution(
                coordinate: nil,
                resolvedSource: .coreLocation,
                displayName: nil,
                error: String(
                    localized: "Location unavailable. Allow Location Services or pick Manual in Settings → Weather.",
                    defaultValue: "Location unavailable. Allow Location Services or pick Manual in Settings → Weather.",
                    comment: "Weather error shown when System location is selected but Core Location did not yield a coordinate and no manual city is set."
                )
            )

        case .manual:
            if let resolved = tryManual(preference) { return resolved }
            return WeatherLocationResolution(
                coordinate: nil,
                resolvedSource: .manual,
                displayName: nil,
                error: String(
                    localized: "Manual location not set. Type a city in Settings → Weather.",
                    defaultValue: "Manual location not set. Type a city in Settings → Weather.",
                    comment: "Weather error shown when Manual source is selected but the user has not typed a city yet."
                )
            )
        }
    }

    func requestCoreLocationAuthorizationIfNeeded() {
        guard SettingsManager.shared.loadGlobalSettings().weatherLocation.source == .coreLocation else {
            return
        }
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
    }

    // MARK: - CoreLocation

    private func tryCoreLocation() async -> WeatherLocationResolution? {
        let status = locationManager.authorizationStatus
        guard status == .authorizedAlways || status == .authorized else {
            if status == .notDetermined {
                locationManager.requestWhenInUseAuthorization()
            }
            return nil
        }

        guard !coreLocationRequestInFlight else { return nil }

        let location = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<CLLocation?, Never>) in
                coreLocationRequestInFlight = true
                pendingCoreLocationContinuation = continuation
                locationManager.requestLocation()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelCoreLocationRequest()
            }
        }

        guard let location else { return nil }
        return WeatherLocationResolution(
            coordinate: location.coordinate,
            resolvedSource: .coreLocation,
            displayName: String(
                localized: "System location",
                defaultValue: "System location",
                comment: "Weather source label for macOS Core Location."
            ),
            error: nil
        )
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let location = locations.last
        Task { @MainActor [weak self] in
            self?.fulfillCoreLocationRequest(with: location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.fulfillCoreLocationRequest(with: nil)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    }

    private func fulfillCoreLocationRequest(with location: CLLocation?) {
        let continuation = pendingCoreLocationContinuation
        pendingCoreLocationContinuation = nil
        coreLocationRequestInFlight = false
        continuation?.resume(returning: location)
    }

    /// Cancellation path — the awaiting Task was cancelled before CoreLocation responded.
    private func cancelCoreLocationRequest() {
        let continuation = pendingCoreLocationContinuation
        pendingCoreLocationContinuation = nil
        coreLocationRequestInFlight = false
        continuation?.resume(returning: nil)
    }

    // MARK: - Manual

    private func tryManual(_ preference: WeatherLocationPreference) -> WeatherLocationResolution? {
        guard let manual = preference.manual else { return nil }
        return WeatherLocationResolution(
            coordinate: manual.coordinate,
            resolvedSource: .manual,
            displayName: String(
                localized: "Manual: \(manual.name)",
                comment: "Weather source label. The placeholder is the user-selected location name."
            ),
            error: nil
        )
    }
}
