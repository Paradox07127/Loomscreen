import Foundation
import CoreLocation

/// User preference for how the weather pipeline acquires a coordinate.
///
/// `WeatherReactiveService` resolves the active source through
/// `WeatherLocationProvider`, which honours this preference and falls back
/// to the next viable source when the preferred one is unavailable
/// (denied / network failure / no manual coordinate set yet).
public struct WeatherLocationPreference: Codable, Equatable, Sendable {
    /// What the user explicitly chose. The provider may downgrade at runtime
    /// (e.g. fall back to IP geolocation when CoreLocation is denied) without
    /// mutating this preference — restoring the user's choice the moment the
    /// underlying authorisation flips back.
    public var source: Source

    /// Manually entered coordinate + label. Always populated when
    /// `source == .manual`, but kept across source switches so the user can
    /// flip back without re-typing.
    public var manual: ManualLocation?

    public init(source: Source, manual: ManualLocation? = nil) {
        self.source = source
        self.manual = manual
    }

    public enum Source: String, Codable, Sendable {
        case coreLocation
        case manual
        case ipGeolocation
    }

    public struct ManualLocation: Codable, Equatable, Sendable {
        public var latitude: Double
        public var longitude: Double
        /// Display label — typically `"<City>, <Country>"`. Shown in settings
        /// + status badge so users can confirm the current source.
        public var name: String

        public init(latitude: Double, longitude: Double, name: String) {
            self.latitude = latitude
            self.longitude = longitude
            self.name = name
        }

        public var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    public static let `default` = WeatherLocationPreference(source: .coreLocation, manual: nil)
}
