import SwiftUI

/// Secondary control row anchored beneath `DetailHeaderBar` on library pages
/// (Bookmarks / Aerials / Workshop). Owns the canonical Apple-style filter
/// idiom: glass-capsule search on the leading edge, an optional caller-supplied
/// chip / picker slot, and a monospaced result counter on the trailing edge.
///
/// Pages stay structurally identical — the only per-page divergence is what
/// goes into the `filters` view-builder slot (Bookmarks: type chips when the
/// library is large; Workshop: Type + Sort pickers; Aerials: nothing).
public struct LibraryFilterBar<Filters: View>: View {
    @Binding private var searchText: String
    private let searchPrompt: LocalizedStringKey
    private let resultCount: Int?
    private let totalCount: Int?
    private let isDisabled: Bool
    private let filters: Filters

    public init(
        searchText: Binding<String>,
        searchPrompt: LocalizedStringKey = "Search…",
        resultCount: Int? = nil,
        totalCount: Int? = nil,
        isDisabled: Bool = false,
        @ViewBuilder filters: () -> Filters
    ) {
        self._searchText = searchText
        self.searchPrompt = searchPrompt
        self.resultCount = resultCount
        self.totalCount = totalCount
        self.isDisabled = isDisabled
        self.filters = filters()
    }

    public var body: some View {
        HStack(spacing: DesignTokens.LibraryFilterBar.contentSpacing) {
            searchField

            filters

            Spacer(minLength: DesignTokens.LibraryFilterBar.contentSpacing)

            // Only surface the counter when filtering actually narrowed the
            // result set — an unfiltered "12" sitting on the right just
            // duplicates the header's own count.
            if let resultCount, let totalCount, resultCount != totalCount {
                resultCounter(resultCount, totalCount)
            }
        }
        .padding(.horizontal, DesignTokens.LibraryFilterBar.horizontalPadding)
        .padding(.vertical, DesignTokens.LibraryFilterBar.verticalPadding)
        .disabled(isDisabled)
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField(searchPrompt, text: $searchText)
                .textFieldStyle(.plain)
                .font(DesignTokens.Typography.body)
                .accessibilityLabel(Text(searchPrompt))

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(Text("Clear search"))
                .accessibilityLabel(Text("Clear search"))
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
    }

    // MARK: - Result counter

    private func resultCounter(_ visible: Int, _ total: Int) -> some View {
        Text(verbatim: visible == total ? "\(total)" : "\(visible)/\(total)")
            .font(DesignTokens.Typography.metric)
            .foregroundStyle(.secondary)
            .help(visible == total
                  ? Text("\(total) items")
                  : Text("\(visible) of \(total) shown"))
    }
}

extension LibraryFilterBar where Filters == EmptyView {
    /// Convenience initializer for library pages that have nothing to put in
    /// the chip slot — the search field + counter alone.
    public init(
        searchText: Binding<String>,
        searchPrompt: LocalizedStringKey = "Search…",
        resultCount: Int? = nil,
        totalCount: Int? = nil,
        isDisabled: Bool = false
    ) {
        self.init(
            searchText: searchText,
            searchPrompt: searchPrompt,
            resultCount: resultCount,
            totalCount: totalCount,
            isDisabled: isDisabled,
            filters: { EmptyView() }
        )
    }
}
