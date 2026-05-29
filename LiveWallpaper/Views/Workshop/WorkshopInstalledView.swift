#if !LITE_BUILD && DIRECT_DISTRIBUTION
import LiveWallpaperSharedUI
import SwiftUI

/// The pane's "Installed" tab, backed by the app-managed Wallpaper Engine
/// library (the WPE import history + cache). Everything imported via
/// paste-preview, a SteamCMD download, or "Import from folder…" lands here
/// automatically. Layout mirrors the Bookmarks / Aerials shell: a
/// `LibraryFilterBar` (search + type + sort) over an adaptive gallery, with a
/// per-card Apply control targeting the open displays. Rendered headerless —
/// `WorkshopPaneView` owns the chrome.
struct WorkshopInstalledView: View {
    @Environment(ScreenManager.self) private var screenManager
    @State private var importCoordinator = WorkshopFolderImportCoordinator.shared
    @State private var entries: [WPEHistoryEntry] = []
    @State private var searchText: String = ""
    @State private var typeFilter: WPELibraryTypeFilter = .all
    @State private var sortOrder: WPELibrarySortOrder = .recommended
    @State private var errorMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 14)]

    var body: some View {
        content
            .background(DesignTokens.Colors.pageBackground)
            .onAppear(perform: reload)
            .onReceive(NotificationCenter.default.publisher(for: .wpeHistoryDidChange)) { _ in reload() }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if entries.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                LibraryFilterBar(
                    searchText: $searchText,
                    searchPrompt: "Search library",
                    resultCount: visibleEntries.count,
                    totalCount: entries.count
                ) {
                    Picker("Type", selection: $typeFilter) {
                        ForEach(WPELibraryTypeFilter.allCases) { filter in
                            Text(verbatim: filter.title).tag(filter)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(width: 118)
                    .help(Text("Filter by project type"))

                    Picker("Sort", selection: $sortOrder) {
                        ForEach(WPELibrarySortOrder.allCases) { order in
                            Text(verbatim: order.title).tag(order)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(width: 132)
                    .help(Text("Sort the library"))
                }

                if importCoordinator.isImporting {
                    importingBanner
                }

                gallery
            }
        }
    }

    @ViewBuilder
    private var gallery: some View {
        if visibleEntries.isEmpty {
            IllustratedEmptyState(
                symbol: "magnifyingglass",
                title: "No wallpapers match your filters",
                message: "Try a different keyword, or clear the search and type filter to see your whole library."
            )
        } else {
            ScrollView {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.top, DesignTokens.Spacing.sm)
                }
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(visibleEntries, id: \.id) { entry in
                        WPEHistoryRow(
                            entry: entry,
                            isActive: isActive(entry),
                            allowsInlineApply: true,
                            screens: screenManager.screens,
                            onApply: { screen in apply(entry, to: screen) },
                            onApplyToAll: { applyToAll(entry) },
                            onRemove: { remove(entry) }
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
        }
    }

    private var importingBanner: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            ProgressView().controlSize(.small)
            Text("Importing from folder…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, DesignTokens.Spacing.xs)
    }

    private var emptyState: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("No wallpapers installed yet.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("Download from Browse Online, paste a Workshop URL, or import an existing library folder.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button {
                importCoordinator.presentImportPanel()
            } label: {
                Label("Import from folder…", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.bordered)
            .disabled(importCoordinator.isImporting)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DesignTokens.Spacing.xl)
    }

    // MARK: - Filtering

    private var visibleEntries: [WPEHistoryEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = entries.filter { entry in
            typeFilter.includes(entry) && matchesSearch(entry, query: query)
        }
        switch sortOrder {
        case .recommended:
            return filtered
        case .name:
            return filtered.sorted { compareByTitle($0, $1) }
        case .type:
            return filtered.sorted {
                let lhs = typeSortRank($0.origin.originalType)
                let rhs = typeSortRank($1.origin.originalType)
                if lhs != rhs { return lhs < rhs }
                return compareByTitle($0, $1)
            }
        }
    }

    private func matchesSearch(_ entry: WPEHistoryEntry, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return entry.origin.title.localizedCaseInsensitiveContains(query)
            || entry.origin.workshopID.localizedCaseInsensitiveContains(query)
            || entry.origin.localizedDisplayTypeName.localizedCaseInsensitiveContains(query)
    }

    private func compareByTitle(_ lhs: WPEHistoryEntry, _ rhs: WPEHistoryEntry) -> Bool {
        let order = lhs.origin.title.localizedCaseInsensitiveCompare(rhs.origin.title)
        if order != .orderedSame { return order == .orderedAscending }
        return lhs.origin.workshopID.localizedCaseInsensitiveCompare(rhs.origin.workshopID) == .orderedAscending
    }

    private func typeSortRank(_ type: WPEType) -> Int {
        switch type {
        case .video: return 0
        case .web: return 1
        case .scene: return 2
        case .application: return 3
        case .unknown: return 4
        }
    }

    // MARK: - Actions

    /// "In use" means the entry's project is the active wallpaper on *any* open
    /// display — there is no single target screen in this multi-display library.
    private func isActive(_ entry: WPEHistoryEntry) -> Bool {
        screenManager.screens.contains { screen in
            screenManager.getConfiguration(for: screen)?.wpeOrigin?.workshopID == entry.origin.workshopID
        }
    }

    private func apply(_ entry: WPEHistoryEntry, to screen: Screen) {
        errorMessage = nil
        Task {
            await screenManager.activateWPEHistoryEntry(entry, for: screen)
            if screenManager.wpeImportError(for: screen) != nil {
                errorMessage = String(localized: "Couldn't apply \(entry.origin.title).", comment: "Workshop installed apply failure. Placeholder is the wallpaper title.")
            }
            reload()
        }
    }

    private func applyToAll(_ entry: WPEHistoryEntry) {
        errorMessage = nil
        Task {
            for screen in screenManager.screens {
                await screenManager.activateWPEHistoryEntry(entry, for: screen)
            }
            reload()
        }
    }

    private func remove(_ entry: WPEHistoryEntry) {
        screenManager.removeWPEImport(workshopID: entry.id)
        reload()
    }

    private func reload() {
        entries = SettingsManager.shared.loadGlobalSettings().recentWPEImports
    }
}

// MARK: - Filters

private enum WPELibraryTypeFilter: String, CaseIterable, Identifiable {
    case all, video, web, scene, unsupported

    var id: Self { self }

    var title: String {
        switch self {
        case .all: return String(localized: "All", comment: "Workshop library type filter.")
        case .video: return WPEType.video.localizedDisplayName
        case .web: return WPEType.web.localizedDisplayName
        case .scene: return WPEType.scene.localizedDisplayName
        case .unsupported: return String(localized: "Unsupported", comment: "Workshop library type filter.")
        }
    }

    func includes(_ entry: WPEHistoryEntry) -> Bool {
        switch self {
        case .all: return true
        case .video: return entry.origin.originalType == .video
        case .web: return entry.origin.originalType == .web
        case .scene: return entry.origin.originalType == .scene
        case .unsupported: return entry.origin.originalType == .application || entry.origin.originalType == .unknown
        }
    }
}

private enum WPELibrarySortOrder: String, CaseIterable, Identifiable {
    case recommended, name, type

    var id: Self { self }

    var title: String {
        switch self {
        case .recommended: return String(localized: "Recent", comment: "Workshop library sort order: most recently imported first.")
        case .name: return String(localized: "Name", comment: "Workshop library sort order.")
        case .type: return String(localized: "Type", comment: "Workshop library sort order.")
        }
    }
}
#endif
