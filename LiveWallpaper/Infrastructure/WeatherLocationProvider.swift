import Foundation
import CoreLocation

/// Resolves a coordinate for the weather pipeline by walking the
/// user-preferred chain of `WeatherLocationPreference.Source` values.
///
/// `WeatherReactiveService` calls into this provider; the provider does
/// **not** keep a persistent reference to the service. That keeps the
/// fallback logic isolated and testable: each source is a tiny pure-ish
/// function that either returns a coordinate or fails fast so the caller
/// can try the next link in the chain.
@MainActor
protocol WeatherLocationProviding: AnyObject {
    /// Pull the latest known location preference and resolve it. Returns
    /// the working source's coordinate plus an updated status describing
    /// what actually succeeded (the user-preferred source may be downgraded
    /// at runtime — e.g. CoreLocation denied → IP geo).
    func resolveCoordinate() async -> WeatherLocationResolution

    /// Triggers a CoreLocation authorisation prompt if the user has chosen
    /// `.coreLocation` and we haven't asked yet. Idempotent.
    func requestCoreLocationAuthorizationIfNeeded()

    /// Drops any cached IP-derived coordinate so a future resolve hits the
    /// network again. Useful when the user explicitly refreshes weather.
    func invalidateIPGeolocationCache()
}

/// What a location resolution actually produced. The status mirrors the
/// existing `WeatherReactiveService.LocationStatus` enum so the badge UI
/// keeps rendering the same vocabulary.
struct WeatherLocationResolution: Equatable {
    /// Successful coordinate, or `nil` if every source in the chain failed.
    var coordinate: CLLocationCoordinate2D?
    /// What actually produced (or attempted to produce) the coordinate. Lets
    /// the UI show "Using IP location — Core Location denied".
    var resolvedSource: WeatherLocationPreference.Source?
    /// Human-readable label for the source — used by the status badge.
    var displayName: String?
    var error: String?

    static let unresolved = WeatherLocationResolution(
        coordinate: nil, resolvedSource: nil, displayName: nil, error: nil
    )

    /// Required so the type can be `Equatable` (CLLocationCoordinate2D
    /// isn't Equatable by default).
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
    private var ipCache: IPGeoCacheEntry?
    private let urlSession: URLSession

    private struct IPGeoCacheEntry {
        let coordinate: CLLocationCoordinate2D
        let label: String
        let timestamp: Date

        var isFresh: Bool {
            Date().timeIntervalSince(timestamp) < 60 * 60 * 24
        }
    }

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    // MARK: - Public API

    func resolveCoordinate() async -> WeatherLocationResolution {
        let preference = SettingsManager.shared.loadGlobalSettings().weatherLocation

        switch preference.source {
        case .coreLocation:
            if let resolved = await tryCoreLocation() { return resolved }
            // Cascade — if CoreLocation can't deliver, fall through to IP geo
            // so the user keeps seeing live weather without re-prompting.
            if let resolved = await tryIPGeolocation(noteCoreLocationFallback: true) { return resolved }
            return tryManual(preference)
                ?? WeatherLocationResolution(
                    coordinate: nil,
                    resolvedSource: .coreLocation,
                    displayName: nil,
                    error: "Location unavailable. Enable Location Services or set a manual city in Settings → Weather."
                )

        case .manual:
            if let resolved = tryManual(preference) { return resolved }
            // No manual coord saved — fall through to IP so weather keeps
            // working until the user enters one.
            if let resolved = await tryIPGeolocation(noteCoreLocationFallback: false) { return resolved }
            return WeatherLocationResolution(
                coordinate: nil,
                resolvedSource: .manual,
                displayName: nil,
                error: "Manual location not set."
            )

        case .ipGeolocation:
            if let resolved = await tryIPGeolocation(noteCoreLocationFallback: false) { return resolved }
            return tryManual(preference)
                ?? WeatherLocationResolution(
                    coordinate: nil,
                    resolvedSource: .ipGeolocation,
                    displayName: nil,
                    error: "IP geolocation unavailable. Check your internet connection."
                )
        }
    }

    func requestCoreLocationAuthorizationIfNeeded() {
        // Only nudge the system permission dialog when CoreLocation is
        // actually the user's preferred source. Manual / IP users explicitly
        // opted out of Location Services and would find the prompt
        // surprising.
        guard SettingsManager.shared.loadGlobalSettings().weatherLocation.source == .coreLocation else {
            return
        }
        // `requestWhenInUseAuthorization()` exists on macOS even though the
        // returned status maps to `.authorized` rather than the iOS-style
        // `.authorizedWhenInUse`. The legacy `requestAlwaysAuthorization()`
        // is gone from Catalyst's macOS surface.
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
    }

    func invalidateIPGeolocationCache() {
        ipCache = nil
    }

    // MARK: - CoreLocation

    private func tryCoreLocation() async -> WeatherLocationResolution? {
        // macOS only exposes `.authorized` (no in-use vs always split). We
        // accept that plus `.authorizedAlways` to stay symmetric with iOS-
        // shaped status returns from rare framework variants.
        let status = locationManager.authorizationStatus
        guard status == .authorizedAlways || status == .authorized else {
            if status == .notDetermined {
                locationManager.requestWhenInUseAuthorization()
            }
            return nil
        }

        // Single-flight: if a previous resolve is still waiting on
        // didUpdateLocations, return nil so the fallback chain proceeds
        // immediately rather than queueing a second `requestLocation()`
        // that would race with the in-flight one.
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
            displayName: String(localized: "System location", defaultValue: "System location", comment: "Weather source label for macOS Core Location."),
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
        // No-op: the resolve path will check authorisation on its next pass.
        // Posting `weatherLocationPreferenceDidChange` here would be wrong —
        // the preference didn't change, only the underlying authorization.
    }

    private func fulfillCoreLocationRequest(with location: CLLocation?) {
        let continuation = pendingCoreLocationContinuation
        pendingCoreLocationContinuation = nil
        coreLocationRequestInFlight = false
        continuation?.resume(returning: location)
    }

    /// Cancellation path — the awaiting Task was cancelled before
    /// CoreLocation responded. Resumes the continuation with nil so the
    /// awaiter doesn't deadlock.
    private func cancelCoreLocationRequest() {
        let continuation = pendingCoreLocationContinuation
        pendingCoreLocationContinuation = nil
        coreLocationRequestInFlight = false
        continuation?.resume(returning: nil)
    }

    // MARK: - IP Geolocation

    private struct IPGeoResponse: Decodable {
        let latitude: Double
        let longitude: Double
        let city: String?
        let country_name: String?
    }

    private func tryIPGeolocation(noteCoreLocationFallback: Bool) async -> WeatherLocationResolution? {
        if let cache = ipCache, cache.isFresh {
            return WeatherLocationResolution(
                coordinate: cache.coordinate,
                resolvedSource: .ipGeolocation,
                displayName: noteCoreLocationFallback
                    ? String(localized: "Using IP location (Core Location unavailable)", defaultValue: "Using IP location (Core Location unavailable)", comment: "Weather source label when Core Location is unavailable.")
                    : String(localized: "IP location: \(cache.label)", comment: "Weather source label. The placeholder is the inferred city or region."),
                error: nil
            )
        }

        guard let url = URL(string: "https://ipapi.co/json/") else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("LiveWallpaper/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard
                let http = response as? HTTPURLResponse,
                (200...299).contains(http.statusCode)
            else {
                return nil
            }
            let decoded = try JSONDecoder().decode(IPGeoResponse.self, from: data)
            // Defensive: external endpoints occasionally return out-of-range
            // or NaN values during outages. Reject them rather than feed
            // garbage into the weather URL builder.
            guard let coord = validatedCoordinate(latitude: decoded.latitude, longitude: decoded.longitude) else {
                Logger.warning("IP geolocation returned invalid coordinate", category: .screenManager)
                return nil
            }
            let label: String = {
                let parts = [decoded.city, decoded.country_name].compactMap(sanitizedLabelPart)
                return parts.isEmpty ? "your network area" : parts.joined(separator: ", ")
            }()
            ipCache = IPGeoCacheEntry(coordinate: coord, label: label, timestamp: Date())

            return WeatherLocationResolution(
                coordinate: coord,
                resolvedSource: .ipGeolocation,
                displayName: noteCoreLocationFallback
                    ? String(localized: "Using IP location (Core Location unavailable)", defaultValue: "Using IP location (Core Location unavailable)", comment: "Weather source label when Core Location is unavailable.")
                    : String(localized: "IP location: \(label)", comment: "Weather source label. The placeholder is the inferred city or region."),
                error: nil
            )
        } catch {
            Logger.warning("IP geolocation failed: \(error.localizedDescription)", category: .screenManager)
            return nil
        }
    }

    // MARK: - Manual

    private func tryManual(_ preference: WeatherLocationPreference) -> WeatherLocationResolution? {
        guard let manual = preference.manual else { return nil }
        return WeatherLocationResolution(
            coordinate: manual.coordinate,
            resolvedSource: .manual,
            displayName: String(localized: "Manual: \(manual.name)", comment: "Weather source label. The placeholder is the user-selected location name."),
            error: nil
        )
    }

    // MARK: - Defensive Validation

    private func validatedCoordinate(latitude: Double, longitude: Double) -> CLLocationCoordinate2D? {
        guard latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude),
              (-180...180).contains(longitude) else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    private func sanitizedLabelPart(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = trimmed.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let limited = String(String.UnicodeScalarView(filtered.prefix(80)))
        return limited.isEmpty ? nil : limited
    }
}
