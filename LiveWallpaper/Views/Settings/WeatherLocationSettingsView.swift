import SwiftUI
import MapKit

/// Settings tab that lets users pick how the weather pipeline gets a
/// location. Three sources, in order of decreasing privacy intrusion:
///
/// - **System Location** – the existing CoreLocation flow.
/// - **Manual** – type a city; we use `MKLocalSearchCompleter` to suggest
///   completions and `MKLocalSearch` to convert the completion into a
///   coordinate. No geocoder API key required.
/// - **IP Geolocation** – HTTPS call to ipapi.co; coarse but zero-permission.
struct WeatherLocationSettingsView: View {
    @State private var preference: WeatherLocationPreference

    init() {
        _preference = State(initialValue: SettingsManager.shared.loadGlobalSettings().weatherLocation)
    }

    var body: some View {
        Form {
            Section {
                Picker("Source", selection: Binding(
                    get: { preference.source },
                    set: { newValue in
                        preference.source = newValue
                        persist()
                    }
                )) {
                    Text("System Location").tag(WeatherLocationPreference.Source.coreLocation)
                    Text("Manual City").tag(WeatherLocationPreference.Source.manual)
                    Text("IP Geolocation").tag(WeatherLocationPreference.Source.ipGeolocation)
                }
                .pickerStyle(.segmented)

                Text(sourceExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Location Source")
            }

            if preference.source == .manual {
                Section {
                    ManualLocationPicker(
                        currentSelection: preference.manual,
                        onCommit: { manual in
                            preference.manual = manual
                            persist()
                        }
                    )
                } header: {
                    Text("Manual Location")
                }
            }

            Section {
                Text("If your preferred source is unavailable (e.g. Location Services denied), the app will automatically fall back to IP geolocation so weather effects keep working.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 500, minHeight: 400)
    }

    private var sourceExplanation: String {
        switch preference.source {
        case .coreLocation:
            return "Uses macOS Location Services. You'll be asked to allow access the first time. Most accurate."
        case .manual:
            return "Type a city below. No network or location permission needed."
        case .ipGeolocation:
            return "Looks up an approximate location from your IP address. Coarse — typically city-level."
        }
    }

    private func persist() {
        var settings = SettingsManager.shared.loadGlobalSettings()
        settings.weatherLocation = preference
        SettingsManager.shared.saveGlobalSettings(settings)
        NotificationCenter.default.post(name: .weatherLocationPreferenceDidChange, object: nil)
    }
}

private struct ManualLocationPicker: View {
    let currentSelection: WeatherLocationPreference.ManualLocation?
    let onCommit: (WeatherLocationPreference.ManualLocation?) -> Void

    @State private var query: String = ""
    @StateObject private var completer = LocationCompleterModel()
    @State private var resolutionError: String?
    @State private var resolvingTitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let current = currentSelection {
                HStack {
                    Image(systemName: "mappin.and.ellipse")
                        .foregroundStyle(.green)
                    Text(current.name)
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Button("Clear") {
                        onCommit(nil)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.bottom, 4)
            }

            TextField("Search city or place", text: $query)
                .textFieldStyle(.roundedBorder)
                .onChange(of: query) { _, newValue in
                    completer.update(query: newValue)
                }

            if !completer.results.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(completer.results, id: \.self) { result in
                        Button {
                            select(result)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(result.title)
                                        .font(.system(size: 12, weight: .medium))
                                    if !result.subtitle.isEmpty {
                                        Text(result.subtitle)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if resolvingTitle == result.title {
                                    ProgressView().controlSize(.small)
                                }
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
                .background(Color(NSColor.textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
            }

            if let error = resolutionError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func select(_ completion: MKLocalSearchCompletion) {
        resolvingTitle = completion.title
        resolutionError = nil

        let request = MKLocalSearch.Request(completion: completion)
        let search = MKLocalSearch(request: request)
        search.start { response, error in
            DispatchQueue.main.async {
                resolvingTitle = nil
                if let item = response?.mapItems.first {
                    let coord = item.placemark.coordinate
                    let displayName = [completion.title, completion.subtitle]
                        .filter { !$0.isEmpty }
                        .joined(separator: ", ")
                    let manual = WeatherLocationPreference.ManualLocation(
                        latitude: coord.latitude,
                        longitude: coord.longitude,
                        name: displayName.isEmpty ? completion.title : displayName
                    )
                    onCommit(manual)
                    query = ""
                    completer.update(query: "")
                } else if let error {
                    resolutionError = "Could not find that location: \(error.localizedDescription)"
                } else {
                    resolutionError = "Could not find that location."
                }
            }
        }
    }
}

/// Wraps `MKLocalSearchCompleter` for SwiftUI consumption. Cities + points
/// of interest only — the completer can suggest streets / addresses too,
/// but for weather we only care about geographic regions.
@MainActor
final class LocationCompleterModel: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var results: [MKLocalSearchCompletion] = []

    private let completer: MKLocalSearchCompleter

    override init() {
        completer = MKLocalSearchCompleter()
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            results = []
            return
        }
        completer.queryFragment = trimmed
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        // `MKLocalSearchCompletion` is not Sendable, so capture the titles
        // up front and re-fetch the corresponding completions on the main
        // actor. In practice the completer is only mutated on the main
        // thread, so this round-trip is safe.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.results = Array(self.completer.results.prefix(8))
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.results = []
        }
    }
}
