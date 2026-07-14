#if !LITE_BUILD && DIRECT_DISTRIBUTION
import LiveWallpaperSharedUI
import SwiftUI

/// The "Browse Online" tab content, embedded headerless inside `WorkshopPaneView`.
struct WorkshopBrowsePane: View {
    let viewModel: WorkshopBrowseViewModel
    let doctor: SteamCMDDoctorService
    let onRequestKeyEntry: () -> Void
    /// nil when embedded without the tabbed pane chrome (e.g. the standalone
    /// Browse sheet), which then renders no header and contributes no toolbar items.
    var paneHeader: (() -> AnyView)?

    @Environment(WorkshopServices.self) private var services
    @State private var selectedItem: WorkshopQueryItem?
    /// User collapsed the detail panel via the header toggle while keeping the
    /// card selected. Reset whenever a new card is picked so selecting always
    /// reveals the panel.
    @State private var inspectorHidden = false
    @State private var rateLimitRemaining: TimeInterval = 0
    @State private var pageJumpText: String = "1"
    /// Workshop ids already in the local library, for the "In Library" badge.
    @State private var installedWorkshopIDs: Set<String> = []
    /// "Hide already-downloaded items" preference — owned by Settings → Steam
    /// Workshop; mirrored here and pushed into the view-model so the grid reacts.
    @AppStorage("loomscreen.workshop.hidesDownloaded.v1") private var hidesDownloadedPref = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Persisted detail-panel width + the transient width during a drag-resize.
    /// Shares the screen-detail inspector's width tokens so the panel reads as
    /// the same sidebar across the app.
    @AppStorage("Workshop.Browse.InspectorWidth") private var inspectorWidth = Double(DesignTokens.Inspector.defaultWidth)
    @State private var liveInspectorWidth: Double?

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
        // `isMounted` stays true so the collapse animates (never compresses the
        // sidebar/toolbar, only the grid).
        ResizableInspectorSplit(
            isMounted: true,
            isVisible: isInspectorVisible,
            animationTrigger: AnyHashable(isInspectorVisible),
            reduceMotion: reduceMotion,
            storedWidth: $inspectorWidth,
            liveWidth: $liveInspectorWidth,
            minWidth: DesignTokens.Inspector.minWidth,
            maxWidth: DesignTokens.Inspector.maxWidth,
            // Dragging the handle past the panel's minimum collapses it — the
            // direct-manipulation mirror of the toolbar toggle.
            onClose: { inspectorHidden = true },
            main: { mainColumn },
            inspector: { width in inspectorColumn(width: width) }
        )
        .background(DesignTokens.Colors.pageBackground)
        // Only contributed when hosted in the tabbed pane (the standalone Browse
        // sheet has no window toolbar) and only while a card is selected.
        .toolbar {
            if paneHeader != nil, selectedItem != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        inspectorHidden.toggle()
                    } label: {
                        Image(systemName: "sidebar.right")
                    }
                    .help(Text(inspectorHidden ? "Show details" : "Hide details"))
                    .accessibilityLabel(Text("Toggle details panel"))
                }
            }
        }
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
    }

    private var isInspectorVisible: Bool { selectedItem != nil && !inspectorHidden }

    /// Header hosted here so the panel runs full-height alongside it; absent when
    /// embedded without the tabbed pane chrome.
    private var mainColumn: some View {
        VStack(spacing: 0) {
            if let paneHeader {
                paneHeader()
                Divider()
            }
            gridColumn
        }
    }

    private var gridColumn: some View {
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
    }

    private func inspectorColumn(width: CGFloat) -> some View {
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
                    }
                )
            } else {
                inspectorPlaceholder
            }
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
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
                        // Page loaded but the All/New/Installed scope hid every
                        // item on it — explain rather than show a blank grid.
                        scopeEmptyNote
                    } else {
                        LazyVGrid(columns: gridColumns, spacing: DesignTokens.Spacing.lg) {
                            ForEach(viewModel.displayedItems) { item in
                                WorkshopBrowseCard(
                                    item: item,
                                    isInLibrary: installedWorkshopIDs.contains(String(item.id)),
                                    isSelected: selectedItem?.id == item.id
                                ) {
                                    // Clicking the open card closes the inspector;
                                    // picking a new card reveals the (possibly
                                    // collapsed) panel.
                                    if selectedItem?.id == item.id {
                                        selectedItem = nil
                                    } else {
                                        selectedItem = item
                                        inspectorHidden = false
                                    }
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
                // Tap any empty area to close the inspector. Sits BEHIND the cards
                // (Buttons intercept their own taps) and fills the content, so
                // in-grid gaps land here too (a ScrollView-level background missed them).
                .background(
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { selectedItem = nil }
                )
            }
            // Opening the inspector reflows rows and can push the selected tile
            // off-screen — re-center it. The delay lets the inspector's width
            // animation settle before we measure.
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

                // Editable page number → jump via Steam's `page` parameter.
                HStack(spacing: 4) {
                    if viewModel.isPaging { ProgressView().controlSize(.small) }
                    Text("Page")
                        .font(DesignTokens.Typography.body)
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
                            .font(DesignTokens.Typography.metric)
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
                .font(DesignTokens.Typography.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // Same copy/links as the entry sheet (one shared, already-localized
            // source) so nothing new needs translating.
            Text(verbatim: WorkshopAPIKeyOwnershipInfo.prerequisitesLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Text("[Get a key](https://steamcommunity.com/dev/apikey)  ·  [Steam Web API TOU](https://steamcommunity.com/dev/apiterms)  ·  [About Limited Accounts](https://help.steampowered.com/en/faqs/view/71D3-35C2-AD96-AA3A)")
                .font(.caption)
                .tint(Color.accentColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            Button {
                onRequestKeyEntry()
            } label: {
                Label("Set Web API key", systemImage: "key")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, DesignTokens.Spacing.xs)

            Text(verbatim: WorkshopAPIKeyOwnershipInfo.passwordReassurance)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
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
                .font(DesignTokens.Typography.body)
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
                .font(DesignTokens.Typography.body)
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
                .font(DesignTokens.Typography.body)
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
                .foregroundStyle(DesignTokens.Colors.Status.warning)
            Text(message(for: error))
                .font(DesignTokens.Typography.body)
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

    private func creatorFilterBanner(_ creator: WorkshopBrowseViewModel.CreatorFilter) -> some View {
        scopeBanner(
            icon: "person.crop.circle",
            label: Text(creator.name.map { String(localized: "Works by \($0)", comment: "Workshop creator-scoped browse header. Placeholder is the creator's name.") }
                        ?? String(localized: "Works by this creator", comment: "Workshop creator-scoped browse header when the name is unknown.")),
            clear: { await viewModel.clearCreatorFilter() }
        )
    }

    private func tagFilterBanner(_ tag: String) -> some View {
        scopeBanner(
            icon: "tag",
            label: Text(String(localized: "Tagged “\(tag)”", comment: "Workshop tag-scoped browse header. Placeholder is the tag.")),
            clear: { await viewModel.clearPinnedTag() }
        )
    }

    /// Shown in place of the filter ribbon while the grid is scoped to one
    /// creator or tag. Filters are intentionally absent (the scoped Steam query
    /// can't honor them), so the banner is the whole top row.
    private func scopeBanner(icon: String, label: Text, clear: @escaping () async -> Void) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Button {
                Task { await clear() }
            } label: {
                Label("Back to Browse", systemImage: "chevron.left")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(viewModel.isLoading || viewModel.isPaging)

            Spacer(minLength: 0)
        }
        // Center the scope label across the full banner, independent of the
        // leading Back button's width.
        .overlay {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                label
                    .font(DesignTokens.Typography.bodyEmphasized)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, DesignTokens.Spacing.sm)
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background(
            Color.accentColor.opacity(0.10),
            in: RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.22), lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var rateLimitBanner: some View {
        if viewModel.isRateLimited {
            HStack(spacing: DesignTokens.Spacing.sm) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(DesignTokens.Colors.Status.warning)
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
            // Native Liquid Glass (orange-tinted) over the grid; the orange
            // stroke still reads as a warning. Material fallback pre-26.
            .adaptiveGlassSurface(.capsule, tint: DesignTokens.Colors.Status.warning)
            .overlay(Capsule().strokeBorder(DesignTokens.Colors.Status.warning.opacity(0.35), lineWidth: 0.5))
            .padding(DesignTokens.Spacing.md)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - Helpers

    private var hasActiveFilters: Bool {
        // Filters don't apply in creator- or tag-scoped mode.
        guard viewModel.creatorFilter == nil, viewModel.pinnedTag == nil else { return false }
        return !viewModel.searchInput.isEmpty
            || WorkshopFilterMath.isNarrowing(viewModel.selectedTypes, total: WorkshopContentTypeFilter.selectableCases.count)
            || WorkshopFilterMath.isNarrowing(viewModel.selectedAgeRatings, total: WorkshopAgeRatingFilter.allCases.count)
            || WorkshopFilterMath.isNarrowing(viewModel.selectedResolutions, total: WorkshopResolutionFilter.selectableCases.count)
            || WorkshopFilterMath.isNarrowing(viewModel.selectedGenres, total: WorkshopGenre.allTags.count)
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
        // Keeps the All/New/Installed scope and the grid's `displayedItems` in
        // sync with the local library.
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

/// Shimmering placeholder matching `WorkshopBrowseCard`'s footprint — zero
/// layout shift when results arrive.
private struct WorkshopSkeletonCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkshopShimmer()
                .aspectRatio(1, contentMode: .fit)

            // Mirror WorkshopBrowseCard's textInfo footprint so there is no
            // layout shift on load.
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
