import SwiftUI

struct WeatherStatusBadge: View {
    var weatherService: WeatherReactiveService
    var refresh: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: weatherIcon)
                .font(.system(size: 11))
                .foregroundStyle(statusColor)

            VStack(alignment: .leading, spacing: 1) {
                if let condition = weatherService.currentCondition {
                    Text(condition.rawValue.capitalized)
                        .font(.system(size: 11, weight: .medium))
                } else {
                    Text(weatherService.locationStatus.rawValue)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                if let error = weatherService.lastError {
                    Text(error)
                        .font(.system(size: 9))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }

            Spacer()

            if weatherService.currentParticleEffect != .none {
                Image(systemName: weatherService.currentParticleEffect.iconName)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Refresh weather now")
            .accessibilityLabel("Refresh weather")
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Weather status: \(weatherService.currentCondition?.rawValue ?? "loading")")
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
}
