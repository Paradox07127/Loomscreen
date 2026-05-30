#if !LITE_BUILD && DIRECT_DISTRIBUTION
import AppKit
import LiveWallpaperSharedUI
import SwiftUI
import UniformTypeIdentifiers

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
    @State private var bookmarkStore = BookmarkStore.shared
    @State private var entries: [WPEHistoryEntry] = []
    @State private var searchText: String = ""
    @State private var typeFilter: WPELibraryTypeFilter = .all
    @State private var sortOrder: WPELibrarySortOrder = .recommended
    @State private var errorMessage: String?
    /// Drives the drag-to-apply screen bar — set true when a card drag starts,
    /// cleared on drop / mouse-up / Escape. The bar is NOT shown otherwise.
    @State private var isDraggingEntry = false
    @State private var localDragEndMonitor: Any?
    @State private var globalDragEndMonitor: Any?

    // Match the online Browse grid density (square tiles, ~192px source).
    private let columns = [GridItem(.adaptive(minimum: 184, maximum: 220), spacing: DesignTokens.Spacing.lg)]

    var body: some View {
        content
            .background(DesignTokens.Colors.pageBackground)
            .onAppear(perform: reload)
            .onDisappear { removeDragEndMonitors() }
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
                LazyVGrid(columns: columns, spacing: DesignTokens.Spacing.lg) {
                    ForEach(visibleEntries, id: \.id) { entry in
                        let bookmarked = bookmarkStore.containsWPEBookmark(workshopID: entry.origin.workshopID)
                        WPEHistoryRow(
                            entry: entry,
                            isActive: isActive(entry),
                            allowsInlineApply: true,
                            galleryStyle: true,
                            screens: screenManager.screens,
                            onApply: { screen in apply(entry, to: screen) },
                            onApplyToAll: { applyToAll(entry) },
                            onRemove: { remove(entry) },
                            isBookmarked: bookmarked,
                            // Only offer "Add" when the item's content can actually
                            // be rebuilt into a bookmark; "Remove" stays available
                            // for anything already bookmarked.
                            onBookmark: (bookmarked || canAddBookmark(entry)) ? { toggleBookmark(entry) } : nil
                        )
                        .onDrag { beginEntryDrag(entry) }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            .overlay(alignment: .top) {
                if isDraggingEntry, !screenManager.screens.isEmpty {
                    screenDropBar
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isDraggingEntry)
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

    /// Favorite ("收藏") a downloaded item as a real `WallpaperBookmark` — the
    /// unified save mechanism (no separate "like" store). Only downloaded items
    /// can be bookmarked because a bookmark is an applyable wallpaper, so we
    /// rebuild the local content from the cached import via `WPECachedContentResolver`.
    private func toggleBookmark(_ entry: WPEHistoryEntry) {
        errorMessage = nil
        let workshopID = entry.origin.workshopID
        if bookmarkStore.containsWPEBookmark(workshopID: workshopID) {
            bookmarkStore.removeWPEBookmarks(workshopID: workshopID)
            return
        }
        guard let content = WPECachedContentResolver().content(for: entry.origin) else {
            errorMessage = String(localized: "Couldn't add \(entry.origin.title) to Bookmarks.", comment: "Workshop installed bookmark failure. Placeholder is the wallpaper title.")
            return
        }
        _ = bookmarkStore.add(
            label: entry.origin.title,
            content: content,
            sourceDisplayName: workshopID,
            wpeOrigin: entry.origin
        )
    }

    /// A bookmark is an applyable wallpaper, so only items whose content the
    /// `WPECachedContentResolver` can rebuild (cache-backed, supported type) can
    /// be added. Mirrors the resolver's preconditions cheaply (no disk I/O).
    private func canAddBookmark(_ entry: WPEHistoryEntry) -> Bool {
        let origin = entry.origin
        guard origin.resourceLocation == .cache,
              let entryFile = origin.entryFile, !entryFile.isEmpty else { return false }
        switch origin.originalType {
        case .video, .web, .scene: return true
        case .application, .unknown: return false
        }
    }

    // MARK: - Drag-to-apply screen bar

    /// Floats in only while a card is being dragged (not persistent), listing the
    /// open displays as drop targets — drop a wallpaper onto one to apply it there.
    private var screenDropBar: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            Text("Drag onto a display")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            ForEach(screenManager.screens, id: \.id) { screen in
                screenDropTarget(screen)
            }

            Spacer(minLength: 0)

            Button { endEntryDrag() } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(Text("Cancel"))
            .accessibilityLabel(Text("Cancel"))
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func screenDropTarget(_ screen: Screen) -> some View {
        VStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [4]))
                .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .frame(width: 96, height: 54)
                .overlay {
                    Image(systemName: "display")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.accentColor)
                }
            Text(verbatim: screen.name)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: 96)
        }
        .onDrop(of: [.plainText], isTargeted: nil) { providers in
            handleScreenDrop(providers, to: screen)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Apply to \(screen.name)"))
    }

    private func handleScreenDrop(_ providers: [NSItemProvider], to screen: Screen) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
            endEntryDrag()
            return false
        }
        _ = provider.loadObject(ofClass: NSString.self) { value, error in
            // Extract Sendable values (String / Bool) before crossing to the main
            // actor — NSString and Error are not Sendable under Swift 6.
            let workshopID = value as? String
            let loadFailed = error != nil
            Task { @MainActor in
                endEntryDrag()
                guard !loadFailed, let workshopID else { return }
                // Re-resolve the target in case the display topology changed mid-drag.
                guard let target = screenManager.screens.first(where: { $0.id == screen.id }) else { return }
                if let entry = entries.first(where: { $0.origin.workshopID == workshopID }) {
                    apply(entry, to: target)
                }
            }
        }
        return true
    }

    private func beginEntryDrag(_ entry: WPEHistoryEntry) -> NSItemProvider {
        isDraggingEntry = true
        installDragEndMonitors()
        return NSItemProvider(object: entry.origin.workshopID as NSString)
    }

    private func endEntryDrag() {
        isDraggingEntry = false
        removeDragEndMonitors()
    }

    /// SwiftUI's `.onDrag` gives a start signal but no end/cancel signal, so a
    /// drop OUTSIDE every target would leave the bar stuck. Clear it on the next
    /// mouse-up (anywhere) or Escape.
    private func installDragEndMonitors() {
        removeDragEndMonitors()
        localDragEndMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .keyDown]) { event in
            if event.type == .leftMouseUp || (event.type == .keyDown && event.keyCode == 53) {
                Task { @MainActor in endEntryDrag() }
            }
            return event
        }
        globalDragEndMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { _ in
            Task { @MainActor in endEntryDrag() }
        }
    }

    private func removeDragEndMonitors() {
        if let localDragEndMonitor {
            NSEvent.removeMonitor(localDragEndMonitor)
            self.localDragEndMonitor = nil
        }
        if let globalDragEndMonitor {
            NSEvent.removeMonitor(globalDragEndMonitor)
            self.globalDragEndMonitor = nil
        }
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
