#if !LITE_BUILD && DIRECT_DISTRIBUTION
import AppKit
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

    @State private var isFilterPanelExpanded = false
    @FocusState private var isSearchFocused: Bool
    /// Measured natural height of the four chip rows, used to size the panel's
    /// internal scroll exactly to its content up to `maxRowsHeight`.
    @State private var filterRowsHeight: CGFloat = 240

    /// Cap on the chip area. Beyond it the rows scroll internally instead of
    /// growing the ribbon unbounded — at narrow widths Genre wraps onto many
    /// rows, which would otherwise overrun the layout. Below it the panel sizes
    /// to content (no wasted empty scroll area).
    private static let maxRowsHeight: CGFloat = 240

    var body: some View {
        // Plain bar (no glass card / no internal divider) so it reads like the
        // Installed tab's LibraryFilterBar — same horizontal/vertical padding.
        VStack(spacing: 0) {
            topRow
                .padding(.horizontal, DesignTokens.LibraryFilterBar.horizontalPadding)
                .padding(.vertical, DesignTokens.LibraryFilterBar.verticalPadding)

            if isFilterPanelExpanded {
                filterPanel
                    .disabled(controlsDisabled)
            }
        }
    }

    // MARK: - Top row

    private var topRow: some View {
        HStack(spacing: DesignTokens.LibraryFilterBar.contentSpacing) {
            searchField

            filtersToggle

            if viewModel.hasPendingChanges {
                searchButton
            }

            Spacer(minLength: DesignTokens.Spacing.sm)

            // Sort sits on the trailing edge (right-aligned). The key status and
            // today's request count now live in the pane hero, not in this row.
            sortMenu
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
        .labelsHidden()
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
            // The chip rows scroll inside a height-capped box so the ribbon never
            // grows tall enough to overrun the layout above it.
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    filterRow("Type") {
                        HStack(spacing: 6) {
                            ForEach(WorkshopContentTypeFilter.selectableCases) { type in
                                WorkshopFilterChip(
                                    title: Text(type.displayName),
                                    isSelected: viewModel.selectedTypes.contains(type),
                                    onIsolate: { viewModel.isolateType(type) }
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
                                    isSelected: viewModel.selectedAgeRatings.contains(rating),
                                    onIsolate: { viewModel.isolateAgeRating(rating) }
                                ) {
                                    viewModel.toggleAgeRating(rating)
                                }
                            }
                        }
                    }

                    filterRow("Resolution") {
                        chipFlow {
                            ForEach(WorkshopResolutionFilter.selectableCases) { resolution in
                                WorkshopFilterChip(
                                    title: Text(verbatim: resolution.displayName),
                                    isSelected: viewModel.selectedResolutions.contains(resolution),
                                    onIsolate: { viewModel.isolateResolution(resolution) }
                                ) {
                                    viewModel.toggleResolution(resolution)
                                }
                            }
                        }
                    }

                    filterRow("Genre") {
                        chipFlow {
                            ForEach(WorkshopGenre.allTags, id: \.self) { tag in
                                WorkshopFilterChip(
                                    title: Text(verbatim: tag),
                                    isSelected: viewModel.selectedGenres.contains(tag),
                                    onIsolate: { viewModel.isolateGenre(tag) }
                                ) {
                                    viewModel.toggleGenre(tag)
                                }
                            }
                        }
                    }
                }
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: FilterRowsHeightKey.self, value: geo.size.height)
                    }
                )
            }
            .frame(height: min(filterRowsHeight, Self.maxRowsHeight))
            .onPreferenceChange(FilterRowsHeightKey.self) { filterRowsHeight = $0 }

            // Apply lives in the top row's single "Search" button (issue: two
            // Search controls appeared once the panel was open). Here we keep
            // only the panel-scoped reset, pinned below the scroll so it's always
            // reachable.
            if activeFilterCount > 0 {
                Button("Clear filters") { viewModel.resetFilters() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .padding(.leading, 74 + DesignTokens.Spacing.sm)
            }
        }
        .padding(.horizontal, DesignTokens.LibraryFilterBar.horizontalPadding)
        .padding(.bottom, DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func filterRow<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        // Top-aligned so the category label pins to the first chip row when the
        // chips wrap onto several lines (Genre / Resolution).
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .frame(width: 74, alignment: .leading)
                .padding(.top, 4)
            content()
        }
    }

    /// Wrapping chip row — every tag stays visible across as many lines as it
    /// takes (replaces a horizontal scroll that hid most options off-screen).
    private func chipFlow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        WorkshopChipFlow(spacing: 6, lineSpacing: 6) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        .frame(
            minWidth: DesignTokens.LibraryFilterBar.searchMinWidth,
            idealWidth: DesignTokens.LibraryFilterBar.searchIdealWidth,
            maxWidth: DesignTokens.LibraryFilterBar.searchMaxWidth
        )
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

/// Multi-select filter chip in the *deselect-to-hide* model: every option is
/// selected (shown) by default, and tapping a chip deselects it to exclude that
/// tag. To make that reverse semantics self-evident WITHOUT a hint line, a
/// deselected chip reads as "switched off" — dimmed, struck through, faint
/// border — while a selected chip keeps the solid accent treatment. Scoped to
/// the Workshop filter panel so it doesn't leak into the shared `FilterChip`.
/// Shared filter chip — default-selected, deselect-to-hide, Option-click to
/// isolate. Used by the online ribbon and the Installed type row so both read
/// identically. Internal (not private) so `WorkshopInstalledView` can reuse it.
struct WorkshopFilterChip: View {
    let title: Text
    let isSelected: Bool
    /// Option-click handler: collapse the category to just this option. `nil`
    /// disables the shortcut (and its hint).
    var onIsolate: (() -> Void)? = nil
    let action: () -> Void

    var body: some View {
        Button {
            if let onIsolate, NSEvent.modifierFlags.contains(.option) {
                onIsolate()
            } else {
                action()
            }
        } label: {
            title
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .strikethrough(!isSelected, color: .secondary)
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .opacity(isSelected ? 1 : 0.5)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
                )
                .overlay(
                    Capsule().strokeBorder(
                        isSelected ? Color.accentColor : Color.primary.opacity(0.10),
                        lineWidth: isSelected ? 1.5 : 0.5
                    )
                )
        }
        .buttonStyle(.plain)
        .help(onIsolate != nil
            ? Text("Click to show/hide · Option-click to show only this")
            : Text(""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(isSelected ? Text("Shown") : Text("Hidden"))
    }
}

/// Carries the chip rows' natural height up so the panel can size its internal
/// scroll to content (capped at `maxRowsHeight`).
private struct FilterRowsHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Minimal flow layout: lays chips left-to-right and wraps to a new line when
/// the next one would overflow the proposed width, so a long tag list stays
/// fully visible (vs a horizontal scroll that hides most of it).
private struct WorkshopChipFlow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = computeRows(maxWidth: maxWidth, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: maxWidth == .infinity ? widest : min(widest, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let rows = computeRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let projected = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if projected > maxWidth, !current.indices.isEmpty {
                rows.append(current)
                current = Row(indices: [index], width: size.width, height: size.height)
            } else {
                if !current.indices.isEmpty { current.width += spacing }
                current.indices.append(index)
                current.width += size.width
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
#endif
