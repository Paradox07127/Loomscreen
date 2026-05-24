import Foundation
import CoreLocation

/// User preference for how the weather pipeline acquires a coordinate.
///
/// Weather-reactive effects (rain, snow, fog particles) consult this
/// preference through `WeatherReactiveService` to decide whether to fetch
/// remote weather data at all and, if so, where the user's coordinate
/// should come from. There is intentionally **no IP-geolocation source**:
/// silently contacting a third-party endpoint for a coarse coordinate is
/// a privacy compromise we no longer make. Users who do not want to
/// share location with macOS simply pick `.off`.
public struct WeatherLocationPreference: Codable, Equatable, Sendable {
    /// What the user explicitly chose. The provider may walk a small
    /// fallback chain (e.g. `.coreLocation` → `.manual` if a manual city
    /// has been entered) but never invents a third-party source.
    public var source: Source

    /// Manually entered coordinate + label. Always populated when
    /// `source == .manual`, but kept across source switches so the user
    /// can flip back without re-typing.
    public var manual: ManualLocation?

    public init(source: Source, manual: ManualLocation? = nil) {
        self.source = source
        self.manual = manual
    }

    public enum Source: String, Codable, Sendable {
        /// Weather-reactive pipeline is disabled. No location is fetched,
        /// no weather API is called. Wallpaper effects keep working but
        /// never auto-trigger based on real-world conditions.
        case off
        /// macOS Core Location flow. Prompts on first use.
        case coreLocation
        /// User-entered coordinate + display name.
        case manual

        /// Migrates the removed `"ipGeolocation"` rawValue (and any other
        /// unknown future value) to a safe default rather than failing
        /// decode of the entire `GlobalSettings` blob.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            switch raw {
            case "off":           self = .off
            case "coreLocation":  self = .coreLocation
            case "manual":        self = .manual
            case "ipGeolocation": self = .coreLocation
            default:              self = .coreLocation
            }
        }
    }

    public struct ManualLocation: Codable, Equatable, Sendable {
        public var latitude: Double
        public var longitude: Double
        /// Display label — typically `"<City>, <Country>"`. Shown in
        /// settings + status badge so users can confirm the current source.
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
