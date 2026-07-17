import AppKit
import LiveWallpaperCore
import LiveWallpaperSharedUI
import MapKit
import SwiftUI

struct ManualLocationPicker: View {
    let currentSelection: WeatherLocationPreference.ManualLocation?
    let onCommit: (WeatherLocationPreference.ManualLocation?) -> Void

    @State private var query: String = ""
    @StateObject private var completer = LocationCompleterModel()
    @State private var resolutionError: String?
    @State private var resolvingTitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let current = currentSelection {
                HStack(spacing: 6) {
                    Image(systemName: "mappin.and.ellipse")
                        .foregroundStyle(DesignTokens.Colors.Status.active)
                    Text(verbatim: current.name)
                        .font(DesignTokens.Typography.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button("Clear") {
                        onCommit(nil)
                    }
                    .buttonStyle(.borderless)
                    .destructiveControlTint()
                }
            }

            // Placeholder doubles as the prompt; a separate labelled row would squash the field.
            TextField(text: $query) {
                Text("City, region, or place")
            }
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: .infinity)
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
                                    Text(verbatim: result.title)
                                        .font(DesignTokens.Typography.body)
                                    if !result.subtitle.isEmpty {
                                        Text(verbatim: result.subtitle)
                                            .font(DesignTokens.Typography.badge)
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
                Text(verbatim: error)
                    .font(.caption)
                    .foregroundStyle(DesignTokens.Colors.Status.danger)
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
                    resolutionError = String(localized: "Could not find that location: \(error.localizedDescription)", comment: "Manual weather location lookup error. The placeholder is the system error.")
                } else {
                    resolutionError = String(localized: "Could not find that location.", defaultValue: "Could not find that location.", comment: "Manual weather location lookup error.")
                }
            }
        }
    }
}

/// For weather we only care about geographic regions, not arbitrary street addresses.
@MainActor
final class LocationCompleterModel: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var results: [MKLocalSearchCompletion] = []

    private let completer: MKLocalSearchCompleter
    private var debounceTask: Task<Void, Never>?

    override init() {
        completer = MKLocalSearchCompleter()
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    deinit {
        debounceTask?.cancel()
    }

    /// Coalesces typing bursts so the city search fires at most every
    /// 300 ms. Without this each keystroke pushes a fresh
    /// `queryFragment` and MapKit dispatches a network request — common
    /// editing patterns yielded 4-5 round-trips per word.
    func update(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        debounceTask?.cancel()
        if trimmed.isEmpty {
            results = []
            completer.queryFragment = ""
            return
        }
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.completer.queryFragment = trimmed
        }
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
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
