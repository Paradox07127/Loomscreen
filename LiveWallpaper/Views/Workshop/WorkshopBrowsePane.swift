#if !LITE_BUILD && DIRECT_DISTRIBUTION
import LiveWallpaperSharedUI
import SwiftUI

/// The "Browse Online" tab content, carved out of `WorkshopBrowseView` so it
/// can be embedded headerless inside `WorkshopPaneView`. Owns the filter
/// ribbon, the skeleton / populated / empty / error states, the load-more
/// footer, the rate-limit countdown banner, and the per-item detail sheet.
struct WorkshopBrowsePane: View {
    let viewModel: WorkshopBrowseViewModel
    let doctor: SteamCMDDoctorService
    let onRequestKeyEntry: () -> Void

    @Environment(WorkshopServices.self) private var services
    @State private var selectedItem: WorkshopQueryItem?
    @State private var rateLimitRemaining: TimeInterval = 0
    /// Editable page-number field in the pager (jump-to-page).
    @State private var pageJumpText: String = "1"
    /// Workshop ids already in the local library, for the "In Library" badge.
    @State private var installedWorkshopIDs: Set<String> = []
    /// "Hide already-downloaded items" preference — owned by Settings → Steam
    /// Workshop; mirrored here and pushed into the view-model so the grid reacts.
    @AppStorage("loomscreen.workshop.hidesDownloaded.v1") private var hidesDownloadedPref = false

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Stable scroll anchor pinned at the top of the grid (for page steps).
    private static let gridTopAnchor = "workshop.browse.grid.top"

    // Square tiles sized to the ~192px source thumbnails — large enough to read
    // the preview crisply without upscaling into blur, so the window width alone
    // drives how many fit per row (no manual density control).
    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 184, maximum: 220), spacing: DesignTokens.Spacing.lg)]
    }

    var body: some View {
        VStack(spacing: 0) {
            if let creator = viewModel.creatorFilter {
                creatorFilterBanner(creator)
                    .padding(.horizontal, DesignTokens.LibraryFilterBar.horizontalPadding)
                    .padding(.vertical, DesignTokens.LibraryFilterBar.verticalPadding)
            } else if let tag = viewModel.pinnedTag {
                tagFilterBanner(tag)
                    .padding(.horizontal, DesignTokens.LibraryFilterBar.horizontalPadding)
                    .padding(.vertical, DesignTokens.LibraryFilterBar.verticalPadding)
            } else {
                // Ribbon self-pads to match the Installed tab's LibraryFilterBar;
                // no divider below it (the scaffold already draws one under the
                // header), so the bar reads as one row, not a boxed card.
                WorkshopBrowseFilterRibbon(
                    viewModel: viewModel,
                    hasWebAPIKey: services.hasWebAPIKey
                )
            }

            content
                .overlay(alignment: .top) { rateLimitBanner }
        }
        .background(DesignTokens.Colors.pageBackground)
        .onAppear {
            rateLimitRemaining = currentRateLimitRemaining
            reloadInstalledIDs()
            viewModel.hidesDownloadedInBrowse = hidesDownloadedPref
            Task {
                await services.refreshAPIKeyStatus()
                // Only hit Steam once a key is present — avoids a phantom
                // request count + a `missingAPIKey` error on the empty state.
                if services.hasWebAPIKey { viewModel.onAppear() }
            }
        }
        .onChange(of: hidesDownloadedPref) { _, hide in
            viewModel.hidesDownloadedInBrowse = hide
        }
        .onChange(of: services.hasWebAPIKey) { _, hasKey in
            guard hasKey, viewModel.items.isEmpty, !viewModel.isLoading else { return }
            Task { await viewModel.reload() }
        }
        .onReceive(ticker) { _ in
            rateLimitRemaining = currentRateLimitRemaining
        }
        .onReceive(NotificationCenter.default.publisher(for: .wpeHistoryDidChange)) { _ in
            reloadInstalledIDs()
        }
        .onChange(of: viewModel.isLoading) { _, loading in
            if loading { WorkshopRequestCounter.increment() }
        }
        .onChange(of: viewModel.isPaging) { _, paging in
            if paging { WorkshopRequestCounter.increment() }
        }
        .inspector(isPresented: Binding(
            get: { selectedItem != nil },
            set: { presented in if !presented { selectedItem = nil } }
        )) {
            Group {
                if let selectedItem {
                    WorkshopInspectorContent(
                        item: selectedItem,
                        doctor: doctor,
                        onBrowseCreator: { steamID, name in
                            self.selectedItem = nil
                            Task { await viewModel.browseCreator(steamID: steamID, name: name) }
                        },
                        onSelectTag: { tag in
                            self.selectedItem = nil
                            Task { await viewModel.browseTag(tag) }
                        },
                        onClose: { self.selectedItem = nil }
                    )
                } else {
                    inspectorPlaceholder
                }
            }
            .inspectorColumnWidth(min: 300, ideal: 340, max: 440)
        }
    }

    @ViewBuilder
    private var content: some View {
        if !services.hasWebAPIKey {
            apiKeyRequiredState
        } else if let error = viewModel.lastError, viewModel.items.isEmpty, !viewModel.isRateLimited {
            errorState(error)
        } else if viewModel.items.isEmpty, viewModel.isLoading {
            loadingSkeleton
        } else if viewModel.items.isEmpty {
            emptyState
        } else {
            populatedGrid
        }
    }

    private var populatedGrid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    // Top anchor so a page step returns the user to item 1.
                    Color.clear.frame(height: 0).id(Self.gridTopAnchor)

                    if viewModel.displayedItems.isEmpty {
                        // The page loaded, but the All / New / Installed scope hid
                        // every item on it — explain rather than show a blank grid.
                        scopeEmptyNote
                    } else {
                        LazyVGrid(columns: gridColumns, spacing: DesignTokens.Spacing.lg) {
                            ForEach(viewModel.displayedItems) { item in
                                WorkshopBrowseCard(
                                    item: item,
                                    isInLibrary: installedWorkshopIDs.contains(String(item.id)),
                                    isSelected: selectedItem?.id == item.id
                                ) {
                                    // Toggle: clicking the open card again closes the inspector.
                                    selectedItem = selectedItem?.id == item.id ? nil : item
                                }
                                .id(item.id)
                            }
                        }
                        .padding(.horizontal, DesignTokens.Settings.formHorizontalMargin)
                        .padding(.vertical, DesignTokens.Settings.formVerticalMargin)
                    }

                    paginationBar
                }
                .frame(maxWidth: .infinity)
                // Tap any empty area — the gaps between cards, the side margins,
                // below the grid — to close the inspector. This sits BEHIND the
                // cards (Buttons intercept their own taps) and fills the content,
                // so in-grid gaps land here too (a ScrollView-level background
                // missed them). Clicking another card still switches via toggle.
                .background(
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { selectedItem = nil }
                )
            }
            // Opening the inspector narrows the grid and reflows the rows, which
            // can push the selected tile off-screen — re-center it so it stays
            // visible next to the detail panel. The brief delay lets the
            // inspector's width animation settle before we measure.
            .onChange(of: selectedItem?.id) { _, id in
                guard let id else { return }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
            .onChange(of: viewModel.pageIndex) { _, _ in
                proxy.scrollTo(Self.gridTopAnchor, anchor: .top)
            }
        }
    }

    /// Cursor-based prev/next pager. Steam's QueryFiles cursor only walks
    /// forward (no jump-to-page-N), so we step the cursor stack; each page
    /// replaces the previous results, keeping memory flat.
    @ViewBuilder
    private var paginationBar: some View {
        if viewModel.pageIndex > 1 || viewModel.canGoNextPage {
            HStack(spacing: DesignTokens.Spacing.md) {
                Button {
                    Task { await viewModel.goToPrevPage() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Previous")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!viewModel.canGoPrevPage)

                // Editable page number → jump directly to any page (Steam's
                // `page` parameter). Total shown when Steam reports a count.
                HStack(spacing: 4) {
                    if viewModel.isPaging { ProgressView().controlSize(.small) }
                    Text("Page")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    TextField("", text: $pageJumpText)
                        .frame(width: 46)
                        .multilineTextAlignment(.center)
                        .textFieldStyle(.roundedBorder)
                        .monospacedDigit()
                        .disabled(viewModel.isPaging || viewModel.isLoading)
                        .onSubmit { jumpToTypedPage() }
                    if let total = viewModel.totalPages {
                        Text("of \(total)")
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    Task { await viewModel.goToNextPage() }
                } label: {
                    HStack(spacing: 4) {
                        Text("Next")
                        Image(systemName: "chevron.right")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!viewModel.canGoNextPage)
            }
            .padding(.vertical, DesignTokens.Spacing.lg)
            .frame(maxWidth: .infinity)
            .onAppear { pageJumpText = String(viewModel.pageIndex) }
            .onChange(of: viewModel.pageIndex) { _, page in pageJumpText = String(page) }
        }
    }

    private func jumpToTypedPage() {
        guard let page = Int(pageJumpText.trimmingCharacters(in: .whitespaces)) else {
            pageJumpText = String(viewModel.pageIndex)
            return
        }
        Task { await viewModel.goToPage(page) }
    }

    private var loadingSkeleton: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: DesignTokens.Spacing.lg) {
                ForEach(0..<6, id: \.self) { _ in
                    WorkshopSkeletonCard()
                }
            }
            .padding(.horizontal, DesignTokens.Settings.formHorizontalMargin)
            .padding(.vertical, DesignTokens.Settings.formVerticalMargin)
        }
        .accessibilityLabel(Text("Loading Workshop results"))
    }

    private var apiKeyRequiredState: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: "key.fill")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("Set your Steam Web API key to browse online.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text(verbatim: WorkshopAPIKeyOwnershipInfo.passwordReassurance)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button {
                onRequestKeyEntry()
            } label: {
                Label("Set Web API key", systemImage: "key")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DesignTokens.Spacing.xl)
    }

    private var inspectorPlaceholder: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "square.dashed")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("Select a wallpaper to see details.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DesignTokens.Spacing.lg)
    }

    private var emptyState: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(emptyMessage)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if hasActiveFilters {
                Button("Clear filters") { clearFilters() }
                    .buttonStyle(.borderless)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Shown inside the grid when "Hide items already in my library" excludes
    /// every item on the loaded page.
    private var scopeEmptyNote: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "sparkles")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text("Every item on this page is already in your library.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Show downloaded items") { hidesDownloadedPref = false }
                .buttonStyle(.borderless)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignTokens.Spacing.xl)
    }

    private func errorState(_ error: WorkshopQueryError) -> some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text(message(for: error))
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
            HStack(spacing: DesignTokens.Spacing.sm) {
                Button("Retry") { Task { await viewModel.reload() } }
                    .buttonStyle(.borderedProminent)
                if case .missingAPIKey = error {
                    Button("Set Web API key") { onRequestKeyEntry() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DesignTokens.Spacing.xl)
    }

    /// Replaces the filter ribbon while the grid is scoped to one creator —
    /// a "Back" affordance plus the creator's name. Filters don't apply here.
    private func creatorFilterBanner(_ creator: WorkshopBrowseViewModel.CreatorFilter) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Button {
                Task { await viewModel.clearCreatorFilter() }
            } label: {
                Label("Back to Browse", systemImage: "chevron.left")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(viewModel.isLoading || viewModel.isPaging)

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(creator.name.map { String(localized: "Works by \($0)", comment: "Workshop creator-scoped browse header. Placeholder is the creator's name.") }
                     ?? String(localized: "Works by this creator", comment: "Workshop creator-scoped browse header when the name is unknown."))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
    }

    /// Replaces the filter ribbon while the grid is scoped to one tag — a "Back"
    /// affordance plus the tag name. Reached by clicking a tag in the inspector.
    private func tagFilterBanner(_ tag: String) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Button {
                Task { await viewModel.clearPinnedTag() }
            } label: {
                Label("Back to Browse", systemImage: "chevron.left")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(viewModel.isLoading || viewModel.isPaging)

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Image(systemName: "tag")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(String(localized: "Tagged “\(tag)”", comment: "Workshop tag-scoped browse header. Placeholder is the tag."))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var rateLimitBanner: some View {
        if viewModel.isRateLimited {
            HStack(spacing: DesignTokens.Spacing.sm) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text("Steam is rate-limiting — retry in \(Self.countdown(rateLimitRemaining))")
                        .font(.callout.weight(.medium))
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("Steam is rate-limiting. Retry in \(Self.countdown(rateLimitRemaining))."))

                Button("Retry") { Task { await viewModel.reload() } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(rateLimitRemaining > 0)
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.sm)
            // Opaque material backing keeps the copy legible over the grid;
            // the orange tint + stroke read as a warning without bleed-through.
            .background(.regularMaterial, in: Capsule())
            .background(Color.orange.opacity(0.14), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.orange.opacity(0.35), lineWidth: 0.5))
            .padding(DesignTokens.Spacing.md)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - Helpers

    private var hasActiveFilters: Bool {
        // Filters don't apply in creator- or tag-scoped mode, so never offer
        // "Clear filters" there.
        guard viewModel.creatorFilter == nil, viewModel.pinnedTag == nil else { return false }
        return !viewModel.searchInput.isEmpty
            || isNarrowing(viewModel.selectedTypes, total: WorkshopContentTypeFilter.selectableCases.count)
            || isNarrowing(viewModel.selectedAgeRatings, total: WorkshopAgeRatingFilter.allCases.count)
            || isNarrowing(viewModel.selectedResolutions, total: WorkshopResolutionFilter.selectableCases.count)
            || isNarrowing(viewModel.selectedGenres, total: WorkshopGenre.allTags.count)
    }

    private func isNarrowing<T>(_ selected: Set<T>, total: Int) -> Bool {
        !selected.isEmpty && selected.count < total
    }

    private var currentRateLimitRemaining: TimeInterval {
        max(0, viewModel.rateLimitUntil?.timeIntervalSinceNow ?? 0)
    }

    private var emptyMessage: String {
        if let creator = viewModel.creatorFilter {
            if let name = creator.name {
                return String(localized: "\(name) hasn't published any wallpapers here.", comment: "Empty creator-scoped Workshop browse. Placeholder is the creator's name.")
            }
            return String(localized: "This creator hasn't published any wallpapers here.", comment: "Empty creator-scoped Workshop browse, name unknown.")
        }
        if let tag = viewModel.pinnedTag {
            return String(localized: "No results tagged “\(tag)”.", comment: "Empty tag-scoped Workshop browse. Placeholder is the tag.")
        }
        if !viewModel.searchInput.isEmpty {
            return String(localized: "No results for \"\(viewModel.searchInput)\".", comment: "Empty Workshop search result. Placeholder is the query.")
        }
        if hasActiveFilters {
            return String(localized: "No results for these filters.", comment: "Empty Workshop result when type/age filters exclude everything.")
        }
        return String(localized: "No results yet.", comment: "Initial empty Workshop browse state.")
    }

    private func clearFilters() {
        viewModel.searchInput = ""
        viewModel.resetFilters()
        Task { await viewModel.submitSearch() }
    }

    private func reloadInstalledIDs() {
        installedWorkshopIDs = Set(
            SettingsManager.shared.loadGlobalSettings().recentWPEImports.map { $0.origin.workshopID }
        )
        // Hand the set to the view-model so the All / New / Installed scope and
        // the grid's `displayedItems` stay in sync with the local library.
        viewModel.installedWorkshopIDs = installedWorkshopIDs
    }

    private static func countdown(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(ceil(seconds)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func message(for error: WorkshopQueryError) -> String {
        switch error {
        case .missingAPIKey:
            return "Set your Steam Web API key in Settings to browse online."
        case .unauthorized:
            return "Steam rejected the API key. Update it in Settings."
        case .keyDisabled:
            return "Your Steam API key was disabled by Valve. Regenerate one."
        case .rateLimited:
            return "Steam is rate-limiting. Please retry in a moment."
        case .networkUnreachable:
            return "Couldn't reach Steam. Check your connection."
        case .timeout:
            return "Steam took too long to respond. Retry?"
        case .http(let status):
            return "Steam returned HTTP \(status)."
        case .responseParseFailure, .schemaMismatch:
            return "Steam returned an unexpected response."
        case .cancelled:
            return "Cancelled."
        }
    }
}

/// Shimmering placeholder card matching `WorkshopBrowseCard`'s footprint, shown
/// during the first page load (zero layout shift when results arrive).
private struct WorkshopSkeletonCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkshopShimmer()
                .aspectRatio(1, contentMode: .fit)

            // Mirror WorkshopBrowseCard's textInfo footprint (2-line title +
            // type / meta row) so there is no layout shift on load.
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                WorkshopShimmer().frame(height: 13).frame(maxWidth: .infinity)
                WorkshopShimmer().frame(width: 120, height: 13)
                HStack(spacing: 6) {
                    WorkshopShimmer().frame(width: 46, height: 14).clipShape(Capsule())
                    Spacer(minLength: 0)
                    WorkshopShimmer().frame(width: 72, height: 11)
                }
            }
            .padding(DesignTokens.Spacing.md)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Corner.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Corner.lg, style: .continuous)
                .strokeBorder(Color.primary.opacity(DesignTokens.Card.strokeOpacity), lineWidth: DesignTokens.Card.strokeWidth)
        }
        .accessibilityHidden(true)
    }
}

/// Pulsing skeleton fill. Opacity is `Animatable`, so this interpolates
/// smoothly (a moving `LinearGradient` would not — gradients don't animate).
/// Under Reduce Motion it freezes on a static mid-tone.
private struct WorkshopShimmer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsed = false

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(opacity))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulsed = true
                }
            }
    }

    private var opacity: Double {
        if reduceMotion { return 0.08 }
        return pulsed ? 0.14 : 0.05
    }
}
#endif
