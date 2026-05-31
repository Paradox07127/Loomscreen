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

/// Filter ribbon pinned under the pane header for the Workshop (online) tab.
/// A glass-capsule search (submit-driven — no per-keystroke querying), the
/// primary Type chips + a Sort menu that folds the Trending period into itself,
/// and a "Filters" disclosure that expands a panel DOWNWARD (rather than a
/// popover) holding Maturity / Resolution / Genre as horizontally-scrolling
/// chip rows. A refresh control and the key-status / quota chip round it out.
struct WorkshopBrowseFilterRibbon: View {
    let viewModel: WorkshopBrowseViewModel
    let hasWebAPIKey: Bool
    let onRequestKeyEntry: () -> Void

    @State private var isFilterPanelExpanded = false
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        AdaptiveGlassContainer(spacing: DesignTokens.Spacing.sm) {
            VStack(spacing: 0) {
                topRow
                    .padding(.horizontal, DesignTokens.Spacing.md)
                    .padding(.vertical, DesignTokens.Spacing.sm)

                if isFilterPanelExpanded {
                    Divider()
                    filterPanel
                        .disabled(controlsDisabled)
                }
            }
        }
    }

    // MARK: - Top row

    private var topRow: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            searchField

            sortMenu
            filtersToggle

            if viewModel.hasPendingChanges {
                searchButton
            }

            refreshButton

            Spacer(minLength: DesignTokens.Spacing.sm)

            if hasWebAPIKey {
                keyStatusChip
            } else {
                setKeyButton
            }
        }
    }

    /// Sort menu with the Trending window folded in as discrete entries, so
    /// there's a single control (no separate period picker taking up space).
    private var sortMenu: some View {
        Picker("Sort", selection: Binding(
            get: { currentSortOption },
            set: { viewModel.updateSortOption($0.sort, days: $0.days) }
        )) {
            ForEach(Self.sortOptions) { option in
                Text(option.title).tag(option)
            }
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .fixedSize()
        .disabled(controlsDisabled)
        .help(Text("Sort criteria"))
    }

    private var filtersToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { isFilterPanelExpanded.toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease")
                Text("Filters")
                if activeFilterCount > 0 {
                    Text(verbatim: "\(activeFilterCount)")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor, in: Capsule())
                }
                Image(systemName: isFilterPanelExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(controlsDisabled)
        .help(Text("Filter options"))
        .accessibilityLabel(Text("Filters"))
        .accessibilityValue(activeFilterCount > 0
            ? Text("\(activeFilterCount) active")
            : Text("None active"))
    }

    // MARK: - Expanding filter panel

    private var filterPanel: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            filterRow("Type") {
                HStack(spacing: 6) {
                    ForEach(WorkshopContentTypeFilter.selectableCases) { type in
                        WorkshopFilterChip(
                            title: Text(type.displayName),
                            isSelected: viewModel.selectedTypes.contains(type)
                        ) {
                            viewModel.toggleType(type)
                        }
                    }
                }
            }

            filterRow("Maturity") {
                HStack(spacing: 6) {
                    ForEach(WorkshopAgeRatingFilter.allCases) { rating in
                        WorkshopFilterChip(
                            title: Text(verbatim: rating.displayName),
                            isSelected: viewModel.selectedAgeRatings.contains(rating)
                        ) {
                            viewModel.toggleAgeRating(rating)
                        }
                    }
                }
            }

            filterRow("Resolution") {
                chipScroll {
                    ForEach(WorkshopResolutionFilter.selectableCases) { resolution in
                        WorkshopFilterChip(
                            title: Text(verbatim: resolution.displayName),
                            isSelected: viewModel.selectedResolutions.contains(resolution)
                        ) {
                            viewModel.toggleResolution(resolution)
                        }
                    }
                }
            }

            filterRow("Genre") {
                chipScroll {
                    ForEach(WorkshopGenre.allTags, id: \.self) { tag in
                        WorkshopFilterChip(
                            title: Text(verbatim: tag),
                            isSelected: viewModel.selectedGenres.contains(tag)
                        ) {
                            viewModel.toggleGenre(tag)
                        }
                    }
                }
            }

            HStack(spacing: DesignTokens.Spacing.md) {
                if viewModel.hasPendingChanges {
                    Button("Search") { Task { await viewModel.submitSearch() } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(controlsDisabled)
                        .help(Text("Apply these filters"))
                }
                if activeFilterCount > 0 {
                    Button("Clear filters") { viewModel.resetFilters() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
            .padding(.leading, 74 + DesignTokens.Spacing.sm)
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func filterRow<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.sm) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .frame(width: 74, alignment: .leading)
            content()
        }
    }

    private func chipScroll<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                content()
            }
            .padding(.vertical, 1)
        }
    }

    // MARK: - Search / refresh / status

    private var searchField: some View {
        HStack(spacing: 7) {
            // Search is manual now (issue #5): clicking the glass or pressing
            // Return runs the query — typing alone never fires a request.
            Button {
                Task { await viewModel.submitSearch() }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(controlsDisabled)
            .help(Text("Search"))

            TextField("Search Workshop", text: Binding(
                get: { viewModel.searchInput },
                set: { viewModel.searchInput = $0 }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .focused($isSearchFocused)
            .disabled(controlsDisabled)
            .onSubmit { Task { await viewModel.submitSearch() } }

            if !viewModel.searchInput.isEmpty {
                Button {
                    Task { await viewModel.clearSearch() }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(Text("Clear search"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minWidth: 180, idealWidth: 240, maxWidth: 280)
        .adaptiveGlassSurface(.capsule, interactive: true)
        // Explicit keyboard-focus ring — the plain field inside the glass
        // capsule has none of its own.
        .overlay {
            if isSearchFocused {
                Capsule().strokeBorder(Color.accentColor, lineWidth: 1.5)
            }
        }
        .opacity(controlsDisabled ? 0.5 : 1)
    }

    /// Appears only when there are unapplied filter/search edits — the single
    /// "apply everything now" action (issue: stop querying on every tag toggle).
    private var searchButton: some View {
        Button {
            Task { await viewModel.submitSearch() }
        } label: {
            Text("Search")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(controlsDisabled)
        .help(Text("Apply filters and search"))
    }

    private var refreshButton: some View {
        Button {
            Task { await viewModel.reload() }
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(controlsDisabled || viewModel.isLoading)
        .help(Text("Refresh"))
    }

    private var keyStatusChip: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .font(.system(size: 11))
            Text("API key · \(WorkshopRequestCounter.countForToday()) today")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.04), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .help(Text("Steam doesn't expose remaining quota; we only count requests this Mac has issued today (\(WorkshopRequestCounter.countForToday()))."))
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

    // MARK: - Helpers

    private var controlsDisabled: Bool {
        !hasWebAPIKey || viewModel.isRateLimited
    }

    /// Number of filter categories currently narrowing results (a proper,
    /// non-empty subset), surfaced as the Filters badge.
    private var activeFilterCount: Int {
        var count = 0
        if isNarrowing(viewModel.selectedTypes, total: WorkshopContentTypeFilter.selectableCases.count) { count += 1 }
        if isNarrowing(viewModel.selectedAgeRatings, total: WorkshopAgeRatingFilter.allCases.count) { count += 1 }
        if isNarrowing(viewModel.selectedResolutions, total: WorkshopResolutionFilter.selectableCases.count) { count += 1 }
        if isNarrowing(viewModel.selectedGenres, total: WorkshopGenre.allTags.count) { count += 1 }
        return count
    }

    private func isNarrowing<T>(_ selected: Set<T>, total: Int) -> Bool {
        !selected.isEmpty && selected.count < total
    }

    // MARK: - Sort options (Trending period folded in)

    private var currentSortOption: SortOption {
        switch viewModel.preferredSort {
        case .trending:
            switch viewModel.trendingDays {
            case 30: return .trendingMonth
            case 365: return .trendingYear
            default: return .trendingWeek
            }
        case .newest: return .newest
        case .mostSubscribed: return .mostSubscribed
        case .topRated, .search: return .topRated
        }
    }

    private static let sortOptions: [SortOption] = [
        .topRated, .newest, .trendingWeek, .trendingMonth, .trendingYear, .mostSubscribed
    ]

    enum SortOption: Hashable, Identifiable {
        case topRated, newest, mostSubscribed
        case trendingWeek, trendingMonth, trendingYear

        var id: Self { self }

        var sort: WorkshopSortMode {
            switch self {
            case .topRated: return .topRated
            case .newest: return .newest
            case .mostSubscribed: return .mostSubscribed
            case .trendingWeek, .trendingMonth, .trendingYear: return .trending
            }
        }

        var days: Int {
            switch self {
            case .trendingWeek: return 7
            case .trendingMonth: return 30
            case .trendingYear: return 365
            default: return 0
            }
        }

        var title: LocalizedStringKey {
            switch self {
            case .topRated: return "Top Rated"
            case .newest: return "Newest"
            case .mostSubscribed: return "Most Subscribed"
            case .trendingWeek: return "Trending · Week"
            case .trendingMonth: return "Trending · Month"
            case .trendingYear: return "Trending · Year"
            }
        }
    }
}

/// Multi-select filter chip with a clear blue border when selected (tap again
/// to deselect). Scoped to the Workshop filter panel so the bolder selected
/// treatment doesn't leak into the shared `FilterChip` used elsewhere.
private struct WorkshopFilterChip: View {
    let title: Text
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            title
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(isSelected ? Color.blue.opacity(0.12) : Color.primary.opacity(0.05))
                )
                .overlay(
                    Capsule().strokeBorder(
                        isSelected ? Color.blue : Color.primary.opacity(0.10),
                        lineWidth: isSelected ? 1.5 : 0.5
                    )
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
#endif
