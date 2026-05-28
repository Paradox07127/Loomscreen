#if !LITE_BUILD && DIRECT_DISTRIBUTION
import LiveWallpaperSharedUI
import SwiftUI

/// Tracks an honest "requests issued from this Mac today" count. Steam does
/// not return remaining quota, so this is the only count we can truthfully
/// show — never a "remaining" figure. Backed by `UserDefaults` so the ribbon
/// (display) and the pane (increment) share one source.
enum WorkshopRequestCounter {
    private static let countKey = "loomscreen.workshop.requestsToday.count"
    private static let dateKey = "loomscreen.workshop.requestsToday.date"

    static func todayString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    static func countForToday() -> Int {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: dateKey) == todayString() else { return 0 }
        return defaults.integer(forKey: countKey)
    }

    static func increment() {
        let defaults = UserDefaults.standard
        let today = todayString()
        if defaults.string(forKey: dateKey) == today {
            defaults.set(defaults.integer(forKey: countKey) + 1, forKey: countKey)
        } else {
            defaults.set(today, forKey: dateKey)
            defaults.set(1, forKey: countKey)
        }
    }
}

/// Filter ribbon pinned under the pane header for the Browse Online tab:
/// search + Sort / Type / Age menus + Refresh, with a trailing key-status
/// chip. Wrapped in `AdaptiveGlassContainer` for parity with the local
/// library's header chrome.
struct WorkshopBrowseFilterRibbon: View {
    let viewModel: WorkshopBrowseViewModel
    let hasWebAPIKey: Bool
    let onRequestKeyEntry: () -> Void

    var body: some View {
        AdaptiveGlassContainer(spacing: DesignTokens.Spacing.sm) {
            HStack(spacing: DesignTokens.Spacing.md) {
                searchField

                Picker("Sort", selection: Binding(
                    get: { viewModel.preferredSort },
                    set: { viewModel.updateSort($0) }
                )) {
                    ForEach(Self.visibleSorts, id: \.self) { sort in
                        Text(sort.displayName).tag(sort)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(width: 150)
                .disabled(controlsDisabled)
                .help(Text("Sort criteria"))

                Picker("Type", selection: Binding(
                    get: { viewModel.typeFilter },
                    set: { viewModel.updateType($0) }
                )) {
                    ForEach(WorkshopContentTypeFilter.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(width: 110)
                .disabled(controlsDisabled)
                .help(Text("Filter by content type"))

                Picker("Age", selection: Binding(
                    get: { viewModel.ageRating },
                    set: { viewModel.updateAgeRating($0) }
                )) {
                    ForEach(WorkshopAgeRatingFilter.allCases) { rating in
                        Text(rating.displayName).tag(rating)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(width: 120)
                .disabled(controlsDisabled)
                .help(Text("Maturity filter"))

                Button {
                    Task { await viewModel.reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(controlsDisabled || viewModel.isLoading)
                .help(Text("Refresh"))

                Spacer(minLength: DesignTokens.Spacing.sm)

                if hasWebAPIKey {
                    keyStatusChip
                } else {
                    setKeyButton
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.sm)
        }
    }

    private var controlsDisabled: Bool {
        !hasWebAPIKey || viewModel.isRateLimited
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search Workshop", text: Binding(
                get: { viewModel.searchInput },
                set: { viewModel.updateSearch($0) }
            ))
            .textFieldStyle(.plain)
            .disabled(controlsDisabled)
            if !viewModel.searchInput.isEmpty {
                Button {
                    viewModel.updateSearch("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(Text("Clear search"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(.controlBackgroundColor), in: RoundedRectangle(cornerRadius: DesignTokens.Corner.sm))
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Corner.sm)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .frame(maxWidth: 240)
        .opacity(controlsDisabled ? 0.5 : 1)
    }

    private var keyStatusChip: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark")
                .foregroundStyle(.green)
                .font(.system(size: 10, weight: .bold))
            Text("Web API key set · \(WorkshopRequestCounter.countForToday()) reqs from this Mac today")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.04), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .help(Text("Steam doesn't expose remaining quota; we only count requests this Mac has issued."))
    }

    private var setKeyButton: some View {
        Button {
            onRequestKeyEntry()
        } label: {
            Label("Set Web API key", systemImage: "key.fill")
                .font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
    }

    private static let visibleSorts: [WorkshopSortMode] = [.topRated, .newest, .trending, .mostSubscribed]
}
#endif
