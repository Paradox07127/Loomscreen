import SwiftUI
import AppKit

struct WeatherStatusBadge: View {
    var weatherService: WeatherReactiveService
    var refresh: () -> Void

    /// Accessory apps (LSUIElement) cannot show the system Location permission
    /// dialog directly; we surface a one-tap shortcut to System Settings instead.
    /// Also covers `.error` since `didFailWithError` collapses kCLErrorDenied into
    /// generic `.error` — and Settings is still the right action for those.
    private var needsLocationSettingsLink: Bool {
        switch weatherService.locationStatus {
        case .notDetermined, .denied, .error: return true
        default: return false
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: weatherIcon)
                .font(.footnote)
                .foregroundStyle(statusColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                if let condition = weatherService.currentCondition {
                    Text(condition.titleKey)
                        .font(.footnote.weight(.medium))
                } else {
                    Text(weatherService.locationStatus.titleKey)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let label = weatherService.activeLocationLabel, weatherService.lastError == nil {
                    Text(verbatim: label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if let error = weatherService.lastError {
                    Text(verbatim: error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }
            // Status text combines into one VoiceOver string; the buttons below
            // intentionally stay outside this group so each remains focusable.
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Weather status: \(weatherStatusLabel)", comment: "Weather badge a11y label. The placeholder is the current condition or location status."))

            Spacer()

            if weatherService.currentParticleEffect != .none {
                Image(systemName: weatherService.currentParticleEffect.iconName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }

            if needsLocationSettingsLink {
                Button(action: openLocationSettings) {
                    Text("Open Settings")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(GlassCapsuleButtonStyle(fontSize: 10, horizontalPadding: 7, verticalPadding: 3))
                .help(Text("Open System Settings → Privacy & Security → Location Services"))
                .accessibilityLabel(Text("Open Location Services settings"))
            }

            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .help(Text("Refresh weather now"))
            .accessibilityLabel(Text("Refresh weather"))
        }
        .padding(.vertical, 4)
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
    }

    private func openLocationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    private var weatherIcon: String {
        switch weatherService.locationStatus {
        case .available: return "cloud.sun.fill"
        case .fetching: return "arrow.triangle.2.circlepath"
        case .denied: return "location.slash"
        case .error: return "exclamationmark.triangle"
        default: return "cloud.fill"
        }
    }

    private var statusColor: Color {
        switch weatherService.locationStatus {
        case .available: return .cyan
        case .fetching: return .orange
        case .denied: return .red
        case .error: return .red
        default: return .secondary
        }
    }

    private var weatherStatusLabel: String {
        if let condition = weatherService.currentCondition {
            return condition.localizedTitle
        }
        return weatherService.locationStatus.localizedTitle
    }
}

private extension WeatherReactiveService.LocationStatus {
    var titleKey: LocalizedStringKey {
        switch self {
        case .notDetermined: return "Not Determined"
        case .authorized: return "Authorized"
        case .denied: return "Location Denied"
        case .fetching: return "Fetching..."
        case .available: return "Available"
        case .error: return "Error"
        }
    }

    var localizedTitle: String {
        switch self {
        case .notDetermined:
            return String(localized: "Not Determined", defaultValue: "Not Determined", comment: "Weather location status.")
        case .authorized:
            return String(localized: "Authorized", defaultValue: "Authorized", comment: "Weather location status.")
        case .denied:
            return String(localized: "Location Denied", defaultValue: "Location Denied", comment: "Weather location status.")
        case .fetching:
            return String(localized: "Fetching...", defaultValue: "Fetching...", comment: "Weather location status.")
        case .available:
            return String(localized: "Available", defaultValue: "Available", comment: "Weather location status.")
        case .error:
            return String(localized: "Error", defaultValue: "Error", comment: "Weather location status.")
        }
    }
}

private extension WeatherReactiveService.WeatherDescription {
    var titleKey: LocalizedStringKey {
        switch self {
        case .clear: return "Clear"
        case .partlyCloudy: return "Partly Cloudy"
        case .cloudy: return "Overcast"
        case .foggy: return "Foggy"
        case .drizzle: return "Drizzle"
        case .rain: return "Rain"
        case .heavyRain: return "Heavy Rain"
        case .snow: return "Snow"
        case .heavySnow: return "Heavy Snow"
        case .thunderstorm: return "Thunderstorm"
        case .unknown: return "Unknown"
        }
    }

    var localizedTitle: String {
        switch self {
        case .clear:
            return String(localized: "Clear", defaultValue: "Clear", comment: "Weather condition.")
        case .partlyCloudy:
            return String(localized: "Partly Cloudy", defaultValue: "Partly Cloudy", comment: "Weather condition.")
        case .cloudy:
            return String(localized: "Overcast", defaultValue: "Overcast", comment: "Weather condition.")
        case .foggy:
            return String(localized: "Foggy", defaultValue: "Foggy", comment: "Weather condition.")
        case .drizzle:
            return String(localized: "Drizzle", defaultValue: "Drizzle", comment: "Weather condition.")
        case .rain:
            return String(localized: "Rain", defaultValue: "Rain", comment: "Weather condition.")
        case .heavyRain:
            return String(localized: "Heavy Rain", defaultValue: "Heavy Rain", comment: "Weather condition.")
        case .snow:
            return String(localized: "Snow", defaultValue: "Snow", comment: "Weather condition.")
        case .heavySnow:
            return String(localized: "Heavy Snow", defaultValue: "Heavy Snow", comment: "Weather condition.")
        case .thunderstorm:
            return String(localized: "Thunderstorm", defaultValue: "Thunderstorm", comment: "Weather condition.")
        case .unknown:
            return String(localized: "Unknown", defaultValue: "Unknown", comment: "Weather condition.")
        }
    }
}
