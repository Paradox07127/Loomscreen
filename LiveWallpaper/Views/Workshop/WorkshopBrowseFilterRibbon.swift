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
/// Adaptive layout (the core ask): a glass-capsule search matching the local
/// library bar, then a filter cluster that renders inline — Type chips + Sort +
/// a "Filters" popover — while it fits, and collapses everything into a single
/// "Filters" popover when the window is too narrow (`ViewThatFits`). A refresh
/// control and the trailing key-status / quota chip round it out.
struct WorkshopBrowseFilterRibbon: View {
    let viewModel: WorkshopBrowseViewModel
    let hasWebAPIKey: Bool
    let onRequestKeyEntry: () -> Void

    // One presentation source anchored on the container (below), so swapping
    // the `ViewThatFits` branch on resize can't tear down a live popover.
    // `popoverIncludesPrimary` records which layout opened it (collapsed mode
    // folds Type + Sort in; inline mode shows only Maturity).
    @State private var showPopover = false
    @State private var popoverIncludesPrimary = false
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        AdaptiveGlassContainer(spacing: DesignTokens.Spacing.sm) {
            HStack(spacing: DesignTokens.Spacing.md) {
                searchField

                ViewThatFits(in: .horizontal) {
                    inlineControls
                    collapsedControls
                }

                refreshButton

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
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            filtersPopover(includesPrimary: popoverIncludesPrimary)
                .disabled(controlsDisabled)
        }
    }

    // MARK: - Adaptive filter cluster

    /// Wide layout: Type as inline chips + Sort menu + a Filters popover that
    /// holds only the secondary (Maturity) controls. `fixedSize` makes it report
    /// its full intrinsic width so `ViewThatFits` yields to `collapsedControls`
    /// instead of letting the chips squeeze.
    private var inlineControls: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            typeChips
            sortMenu
            if viewModel.preferredSort == .trending {
                trendingPeriodMenu
            }
            filtersButton(includesPrimary: false)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// Trending (`query_type=3`) needs a time window — surface week / month /
    /// year next to the sort control whenever Trending is the active sort.
    private var trendingPeriodMenu: some View {
        Picker("Period", selection: Binding(
            get: { viewModel.trendingDays },
            set: { viewModel.updateTrendingDays($0) }
        )) {
            ForEach(Self.trendingPeriods, id: \.days) { period in
                Text(period.title).tag(period.days)
            }
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .fixedSize()
        .disabled(controlsDisabled)
        .help(Text("Trending period"))
    }

    /// Narrow layout: a single Filters popover that holds everything (Type,
    /// Sort, Maturity).
    private var collapsedControls: some View {
        filtersButton(includesPrimary: true)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var typeChips: some View {
        HStack(spacing: 6) {
            ForEach(WorkshopContentTypeFilter.allCases) { type in
                FilterChip(
                    title: Text(type.displayName),
                    isSelected: viewModel.typeFilter == type
                ) {
                    viewModel.updateType(type)
                }
                .disabled(controlsDisabled)
            }
        }
    }

    private var sortMenu: some View {
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
        .fixedSize()
        .disabled(controlsDisabled)
        .help(Text("Sort criteria"))
    }

    private func filtersButton(includesPrimary: Bool) -> some View {
        Button {
            popoverIncludesPrimary = includesPrimary
            showPopover.toggle()
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

    private func filtersPopover(includesPrimary: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                if includesPrimary {
                    filterGroup("Type") {
                        // Horizontal scroll guards against clipping when localized
                        // type names widen past the fixed popover width.
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(WorkshopContentTypeFilter.allCases) { type in
                                    FilterChip(
                                        title: Text(type.displayName),
                                        isSelected: viewModel.typeFilter == type
                                    ) {
                                        viewModel.updateType(type)
                                    }
                                }
                            }
                        }
                    }
                    filterGroup("Sort") {
                        VStack(alignment: .leading, spacing: 6) {
                            Picker("Sort", selection: Binding(
                                get: { viewModel.preferredSort },
                                set: { viewModel.updateSort($0) }
                            )) {
                                ForEach(Self.visibleSorts, id: \.self) { sort in
                                    Text(sort.displayName).tag(sort)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()

                            if viewModel.preferredSort == .trending {
                                Picker("Period", selection: Binding(
                                    get: { viewModel.trendingDays },
                                    set: { viewModel.updateTrendingDays($0) }
                                )) {
                                    ForEach(Self.trendingPeriods, id: \.days) { period in
                                        Text(period.title).tag(period.days)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                            }
                        }
                    }
                }

                filterGroup("Maturity") {
                    Picker("Maturity", selection: Binding(
                        get: { viewModel.ageRating },
                        set: { viewModel.updateAgeRating($0) }
                    )) {
                        ForEach(WorkshopAgeRatingFilter.allCases) { rating in
                            Text(rating.displayName).tag(rating)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .help(Text("Maximum maturity to show — hides ratings above the chosen level."))
                }

                filterGroup("Resolution") {
                    Picker("Resolution", selection: Binding(
                        get: { viewModel.resolution },
                        set: { viewModel.updateResolution($0) }
                    )) {
                        ForEach(WorkshopResolutionFilter.allCases) { resolution in
                            Text(resolution.displayName).tag(resolution)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                filterGroup("Genre") {
                    genreCheckboxGrid
                }

                if activeFilterCount > 0 {
                    Button("Clear filters") { clearFilters() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
            .padding(DesignTokens.Spacing.md)
        }
        .frame(width: 300)
        .frame(maxHeight: 430)
    }

    /// Two-column checkbox grid of the official genre tags. Selecting several
    /// ANDs them (Steam-native). Toggles route through the view-model's
    /// debounced reload, so ticking three genres issues a single query.
    private var genreCheckboxGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), alignment: .leading),
                GridItem(.flexible(), alignment: .leading)
            ],
            alignment: .leading,
            spacing: 4
        ) {
            ForEach(WorkshopGenre.allTags, id: \.self) { tag in
                Toggle(isOn: Binding(
                    get: { viewModel.selectedGenres.contains(tag) },
                    set: { _ in viewModel.toggleGenre(tag) }
                )) {
                    Text(tag)
                        .font(.system(size: 11))
                        .lineLimit(1)
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
            }
        }
    }

    private func filterGroup<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
    }

    // MARK: - Search / refresh / status

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search Workshop", text: Binding(
                get: { viewModel.searchInput },
                set: { viewModel.updateSearch($0) }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .focused($isSearchFocused)
            .disabled(controlsDisabled)
            if !viewModel.searchInput.isEmpty {
                Button {
                    viewModel.updateSearch("")
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

    /// Active non-default secondary filters, surfaced as the Filters badge.
    private var activeFilterCount: Int {
        var count = 0
        if viewModel.typeFilter != .all { count += 1 }
        if viewModel.ageRating != .everyone { count += 1 }
        if viewModel.resolution != .any { count += 1 }
        count += viewModel.selectedGenres.count
        return count
    }

    private func clearFilters() {
        // Each call schedules the same debounced reload, so they coalesce into
        // a single query rather than firing one per cleared filter.
        if viewModel.typeFilter != .all { viewModel.updateType(.all) }
        if viewModel.ageRating != .everyone { viewModel.updateAgeRating(.everyone) }
        if viewModel.resolution != .any { viewModel.updateResolution(.any) }
        if !viewModel.selectedGenres.isEmpty { viewModel.clearGenres() }
    }

    private static let visibleSorts: [WorkshopSortMode] = [.topRated, .newest, .trending, .mostSubscribed]

    private static let trendingPeriods: [(title: LocalizedStringKey, days: Int)] = [
        ("Week", 7),
        ("Month", 30),
        ("Year", 365)
    ]
}
#endif
