import Foundation
import CoreLocation

/// User preference for how the weather pipeline acquires a coordinate.
///
/// `WeatherReactiveService` resolves the active source through
/// `WeatherLocationProvider`, which honours this preference and falls back
/// to the next viable source when the preferred one is unavailable
/// (denied / network failure / no manual coordinate set yet).
struct WeatherLocationPreference: Codable, Equatable {
    /// What the user explicitly chose. The provider may downgrade at runtime
    /// (e.g. fall back to IP geolocation when CoreLocation is denied) without
    /// mutating this preference — restoring the user's choice the moment the
    /// underlying authorisation flips back.
    var source: Source

    /// Manually entered coordinate + label. Always populated when
    /// `source == .manual`, but kept across source switches so the user can
    /// flip back without re-typing.
    var manual: ManualLocation?

    enum Source: String, Codable {
        case coreLocation
        case manual
        case ipGeolocation
    }

    struct ManualLocation: Codable, Equatable {
        var latitude: Double
        var longitude: Double
        /// Display label — typically `"<City>, <Country>"`. Shown in settings
        /// + status badge so users can confirm the current source.
        var name: String

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    static let `default` = WeatherLocationPreference(source: .coreLocation, manual: nil)
}
