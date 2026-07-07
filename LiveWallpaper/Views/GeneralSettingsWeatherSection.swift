import AppKit
import CoreLocation
import LiveWallpaperCore
import SwiftUI

extension GeneralSettingsView {
    @ViewBuilder
    var weatherSection: some View {
        Section {
            SettingRow(
                icon: "cloud.sun",
                iconColor: weatherShowsInlineStatus ? weatherPermissionColor : .cyan,
                title: "Weather Location",
                subtitle: "Where weather-reactive effects read conditions"
            ) {
                HStack(spacing: 8) {
                    if weatherShowsInlineStatus {
                        GeneralSettingsStatusPill(text: weatherPermissionText, color: weatherPermissionColor)
                            .help(Text(verbatim: weatherPermissionSubtitle))
                    }

                    if weatherShowsGrantButton {
                        Button(weatherGrantButtonTitle) {
                            handleWeatherGrantAction()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .fixedSize()
                    }

                    Picker("Source", selection: weatherSourceBinding) {
                        Text("Off").tag(WeatherLocationPreference.Source.off)
                        Text("System").tag(WeatherLocationPreference.Source.coreLocation)
                        Text("Manual").tag(WeatherLocationPreference.Source.manual)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel(Text("Weather location source"))
                }
            }

            if weatherLocation.source == .manual {
                ManualLocationPicker(
                    currentSelection: weatherLocation.manual,
                    onCommit: { manual in
                        weatherLocation.manual = manual
                        persistWeatherLocation()
                    }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }

        } header: {
            Text("Weather")
        } footer: {
            Text("System uses Location Services; Manual lets you pick a city. Powers rain, snow, and fog effects.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var weatherSourceBinding: Binding<WeatherLocationPreference.Source> {
        Binding(
            get: { weatherLocation.source },
            set: { newValue in
                guard weatherLocation.source != newValue else { return }
                weatherLocation.source = newValue
                persistWeatherLocation()
                if newValue == .coreLocation {
                    scheduleSystemStatusRefresh(.weatherLocation)
                } else {
                    weatherStatusRefreshPending = false
                    refreshLocationAuthorizationStatus()
                }
            }
        )
    }

    private func persistWeatherLocation() {
        var settings = SettingsManager.shared.loadGlobalSettings()
        settings.weatherLocation = weatherLocation
        SettingsManager.shared.saveGlobalSettings(settings)
        postSettingsNotificationAsync(.weatherLocationPreferenceDidChange)
        refreshLocationAuthorizationStatus()
    }

    // MARK: - Weather Inline Status

    private var weatherPermissionText: String {
        if weatherStatusRefreshPending, weatherLocation.source == .coreLocation {
            return "Checking…"
        }
        switch weatherLocation.source {
        case .off:
            return "Off"
        case .manual:
            return weatherLocation.manual == nil ? "Manual Needed" : "Manual"
        case .coreLocation:
            return locationAuthorizationStatus.displayTitle
        }
    }

    private var weatherPermissionSubtitle: String {
        if weatherStatusRefreshPending, weatherLocation.source == .coreLocation {
            return "Waiting for macOS to update Location Services status"
        }
        switch weatherLocation.source {
        case .off:
            return "Weather effects are disabled"
        case .manual:
            return weatherLocation.manual == nil ? "Choose a manual location" : "Using manual location"
        case .coreLocation:
            return locationAuthorizationStatus.displaySubtitle
        }
    }

    private var weatherPermissionColor: Color {
        if weatherStatusRefreshPending, weatherLocation.source == .coreLocation {
            return .secondary
        }
        switch weatherLocation.source {
        case .off, .manual:
            return .secondary
        case .coreLocation:
            return locationAuthorizationStatus.displayColor
        }
    }

    private var weatherShowsGrantButton: Bool {
        guard weatherLocation.source == .coreLocation, !weatherStatusRefreshPending else { return false }
        switch locationAuthorizationStatus {
        case .notDetermined, .denied, .restricted:
            return true
        default:
            return false
        }
    }

    private var weatherGrantButtonTitle: String {
        switch locationAuthorizationStatus {
        case .notDetermined:
            return "Re-grant Access"
        default:
            return "Open"
        }
    }

    private var weatherShowsInlineStatus: Bool {
        switch weatherLocation.source {
        case .off:
            false
        case .manual:
            weatherLocation.manual == nil
        case .coreLocation:
            true
        }
    }

    private func handleWeatherGrantAction() {
        switch locationAuthorizationStatus {
        case .notDetermined:
            screenManager.weatherService.requestLocationAuthorizationIfNeeded()
            screenManager.weatherService.refresh()
            scheduleSystemStatusRefresh(.weatherLocation)
        default:
            openLocationServicesSettings()
            scheduleSystemStatusRefresh(.weatherLocation)
        }
    }

    private func openLocationServicesSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }
}

private extension CLAuthorizationStatus {
    var displayTitle: String {
        switch self {
        case .authorizedAlways, .authorizedWhenInUse:
            return "Granted"
        case .denied:
            return "Denied"
        case .restricted:
            return "Restricted"
        case .notDetermined:
            return "Not Determined"
        @unknown default:
            return "Unknown"
        }
    }

    var displaySubtitle: String {
        switch self {
        case .authorizedAlways, .authorizedWhenInUse:
            return "Location Services access is granted"
        case .denied:
            return "Allow access in Location Services"
        case .restricted:
            return "Location Services is restricted on this Mac"
        case .notDetermined:
            return "macOS has not asked for Location Services yet"
        @unknown default:
            return "macOS returned an unknown location status"
        }
    }

    var displayColor: Color {
        switch self {
        case .authorizedAlways, .authorizedWhenInUse:
            return DesignTokens.Colors.Status.active
        case .denied, .restricted:
            return DesignTokens.Colors.Status.danger
        case .notDetermined:
            return DesignTokens.Colors.Status.warning
        @unknown default:
            return .secondary
        }
    }
}
