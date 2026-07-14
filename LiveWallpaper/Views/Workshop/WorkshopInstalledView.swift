#if !LITE_BUILD && DIRECT_DISTRIBUTION
import AppKit
import LiveWallpaperSharedUI
import SwiftUI
import UniformTypeIdentifiers

/// The pane's "Installed" tab, backed by the app-managed Wallpaper Engine
/// library (WPE import history + cache). Rendered headerless —
/// `WorkshopPaneView` owns the chrome.
struct WorkshopInstalledView: View {
    /// Tapping a tag in the detail inspector bubbles up here so the pane can
    /// switch to Browse Online and scope the grid to that tag. nil = tags are
    /// shown but inert (e.g. if ever embedded without a Browse tab).
    var onBrowseTag: ((String) -> Void)?
    /// nil renders no header and contributes no toolbar items (keeps the view
    /// embeddable like Browse).
    var paneHeader: (() -> AnyView)?

    @Environment(ScreenManager.self) private var screenManager
    @Environment(SteamCMDDoctorService.self) private var doctor
    @State private var importCoordinator = WorkshopFolderImportCoordinator.shared
    @State private var bookmarkStore = BookmarkStore.shared
    @State private var entries: [WPEHistoryEntry] = []
    @State private var searchText: String = ""
    /// All-or-none selected == no filter; deselect to hide a kind, Option-click
    /// a chip to isolate it.
    @State private var selectedTypes: Set<WPELibraryTypeKind> = Set(WPELibraryTypeKind.allCases)
    /// All-or-none selected == no filter.
    @State private var selectedSources: Set<InstalledSource> = Set(InstalledSource.allCases)
    @State private var selectedStorage: Set<InstalledStorageKind> = Set(InstalledStorageKind.allCases)
    @State private var showFilters = false
    @State private var sortOrder: WPELibrarySortOrder = .recommended
    @State private var errorMessage: String?
    @State private var pendingDelete: WPEHistoryEntry?
    @State private var selectedEntry: WPEHistoryEntry?
    /// User collapsed the detail panel via the header toggle while keeping the
    /// card selected. Reset whenever a new card is picked so selecting always
    /// reveals the panel.
    @State private var inspectorHidden = false
    /// Drives the drag-to-apply screen bar — true while a card drag is in
    /// flight, cleared on drop / mouse-up / Escape.
    @State private var isDraggingEntry = false
    @State private var localDragEndMonitor: Any?
    @State private var globalDragEndMonitor: Any?
    /// Workshop ids whose Steam item is newer than our import (the "Update"
    /// badge), derived from `cachedRemoteUpdateEpochs` vs each entry's import time.
    @State private var updatedWorkshopIDs: Set<String> = []
    /// Cached remote `timeUpdated` (epoch seconds) per workshop id, persisted so
    /// the badge survives relaunches and re-derives after a re-download.
    @State private var cachedRemoteUpdateEpochs: [String: Double] = [:]
    @State private var isCheckingForUpdates = false
    @AppStorage("loomscreen.workshop.updateCheck.epoch.v1") private var lastUpdateCheckEpoch: Double = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Shares the screen-detail inspector's width tokens so the panel reads as
    /// the same sidebar across the app.
    @AppStorage("Workshop.Installed.InspectorWidth") private var inspectorWidth = Double(DesignTokens.Inspector.defaultWidth)
    @State private var liveInspectorWidth: Double?

    // 184…220 matches the online Browse grid density (square tiles, ~192px source).
    private let columns = [GridItem(.adaptive(minimum: 184, maximum: 220), spacing: DesignTokens.Spacing.lg)]

    var body: some View {
        ResizableInspectorSplit(
            isMounted: true,
            isVisible: isInspectorVisible,
            animationTrigger: AnyHashable(isInspectorVisible),
            reduceMotion: reduceMotion,
            storedWidth: $inspectorWidth,
            liveWidth: $liveInspectorWidth,
            minWidth: DesignTokens.Inspector.minWidth,
            maxWidth: DesignTokens.Inspector.maxWidth,
            // Dragging the handle past the panel's minimum collapses it.
            onClose: { inspectorHidden = true },
            main: { mainColumn },
            inspector: { width in installedInspectorColumn(width: width) }
        )
            .background(DesignTokens.Colors.pageBackground)
            // Only contributed when hosted in the tabbed pane and a card is selected.
            .toolbar {
                if paneHeader != nil, selectedEntry != nil {
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
                reload()
                loadUpdateFlags()
            }
            .task { await checkForUpdatesIfNeeded() }
            .onDisappear { removeDragEndMonitors() }
            .onReceive(NotificationCenter.default.publisher(for: .wpeHistoryDidChange)) { _ in
                reload()
                reconcileUpdateFlags()
                refreshSelectedEntry()
            }
            .confirmationDialog(
                Text("Delete this wallpaper?"),
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                presenting: pendingDelete
            ) { entry in
                Button(role: .destructive) {
                    performDelete(entry)
                    pendingDelete = nil
                } label: {
                    Text(deletesFiles(entry) ? "Delete & Free Up Space" : "Remove from Library")
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: { entry in
                if deletesFiles(entry) {
                    Text("“\(entry.origin.title)” will be removed from your library and its downloaded files deleted to free up disk space. This can't be undone, but you can download it again from the Workshop.")
                } else {
                    Text("“\(entry.origin.title)” will be removed from your library. Its original files (imported from your own folder) are left untouched.")
                }
            }
    }

    private func installedInspectorColumn(width: CGFloat) -> some View {
        Group {
            if let entry = selectedEntry {
                WPEInstalledInspectorContent(
                    entry: entry,
                    screens: screenManager.screens,
                    activeScreenIDs: activeScreenIDs(for: entry),
                    state: WPEInstalledInspectorContent.ItemState(
                        isBookmarked: bookmarkStore.containsWPEBookmark(workshopID: entry.origin.workshopID),
                        canBookmark: canAddBookmark(entry),
                        hasUpdate: updatedWorkshopIDs.contains(entry.origin.workshopID),
                        canUpdate: doctor.isDownloadReady
                    ),
                    actions: WPEInstalledInspectorContent.Actions(
                        onApply: { apply(entry, to: $0) },
                        onApplyToAll: { applyToAll(entry) },
                        onUpdate: { updateEntry(entry) },
                        onToggleBookmark: { toggleBookmark(entry) },
                        onShowInFinder: { showInFinder(entry) },
                        onDelete: { pendingDelete = entry },
                        onSelectTag: onBrowseTag.map { browse in
                            { tag in selectedEntry = nil; browse(tag) }
                        }
                    )
                )
            } else {
                installedInspectorPlaceholder
            }
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
    }

    private var installedInspectorPlaceholder: some View {
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


    // MARK: - Main column

    private var isInspectorVisible: Bool { selectedEntry != nil && !inspectorHidden }

    /// Header hosted here so the panel runs full-height alongside it; absent
    /// when embedded without the tabbed pane chrome.
    private var mainColumn: some View {
        VStack(spacing: 0) {
            if let paneHeader {
                paneHeader()
                Divider()
            }
            content
        }
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
                    HStack(spacing: DesignTokens.LibraryFilterBar.contentSpacing) {
                        WorkshopFiltersToggle(isExpanded: $showFilters, activeFilterCount: activeFilterCount)

                        Spacer(minLength: 0)

                        Picker("Sort", selection: $sortOrder) {
                            ForEach(WPELibrarySortOrder.allCases) { order in
                                Text(verbatim: order.title).tag(order)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .fixedSize()
                        .help(Text("Sort the library"))
                    }
                    .frame(maxWidth: .infinity)
                }

                if showFilters {
                    installedFilterPanel
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
            // Filtered to nothing: plain empty area (not the illustrated empty
            // state) so the filter bar above stays put as the in-place way back.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(DesignTokens.Colors.Status.danger)
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
                            isSelected: selectedEntry?.id == entry.id,
                            screens: screenManager.screens,
                            onApply: { screen in apply(entry, to: screen) },
                            onApplyToAll: { applyToAll(entry) },
                            // Clicking the open card again closes the inspector;
                            // a new card always reveals the (possibly collapsed) panel.
                            onTap: {
                                if selectedEntry?.id == entry.id {
                                    selectedEntry = nil
                                } else {
                                    selectedEntry = entry
                                    inspectorHidden = false
                                }
                            },
                            onRemove: { pendingDelete = entry },
                            isBookmarked: bookmarked,
                            // Only offer "Add" when the content can be rebuilt into a
                            // bookmark; "Remove" stays available for anything bookmarked.
                            onBookmark: (bookmarked || canAddBookmark(entry)) ? { toggleBookmark(entry) } : nil,
                            hasUpdate: updatedWorkshopIDs.contains(entry.origin.workshopID),
                            onUpdate: doctor.isDownloadReady ? { updateEntry(entry) } : nil
                        )
                        .onDrag({ beginEntryDrag(entry) }, preview: { dragPreview(entry) })
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                // Tap the gaps/margins to close the inspector. Placed at content
                // level so in-grid gaps land here (a ScrollView-level background
                // missed them); behind the cards so Buttons keep their taps.
                .background(
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { selectedEntry = nil }
                )
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
                .font(DesignTokens.Typography.body)
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
                .font(DesignTokens.Typography.body)
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
            typeMatches(entry)
                && sourceMatches(entry)
                && storageMatches(entry)
                && matchesSearch(entry, query: query)
        }
        return WPEInstalledLibrarySorter.sorted(
            filtered,
            by: sortOrder,
            updatedWorkshopIDs: updatedWorkshopIDs
        )
    }

    private func matchesSearch(_ entry: WPEHistoryEntry, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return entry.origin.title.localizedCaseInsensitiveContains(query)
            || entry.origin.workshopID.localizedCaseInsensitiveContains(query)
            || entry.origin.localizedDisplayTypeName.localizedCaseInsensitiveContains(query)
    }

    // MARK: - Type filter chips (multi-select)

    private var typeChipRow: some View {
        HStack(spacing: 6) {
            ForEach(WPELibraryTypeKind.allCases) { kind in
                WorkshopFilterChip(
                    title: Text(verbatim: kind.title),
                    isSelected: selectedTypes.contains(kind),
                    onIsolate: { selectedTypes = [kind] }
                ) {
                    toggleType(kind)
                }
            }
        }
    }

    private func toggleType(_ kind: WPELibraryTypeKind) {
        if selectedTypes.contains(kind) {
            selectedTypes.remove(kind)
        } else {
            selectedTypes.insert(kind)
        }
    }

    /// All (or none) selected means no filter; deselecting some hides those kinds.
    private func typeMatches(_ entry: WPEHistoryEntry) -> Bool {
        if selectedTypes.isEmpty || selectedTypes.count == WPELibraryTypeKind.allCases.count {
            return true
        }
        return selectedTypes.contains { $0.matches(entry) }
    }

    // MARK: - Filters panel (origin + storage)

    private var installedFilterPanel: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            WorkshopFilterRow("Type") {
                typeChipRow
            }

            WorkshopFilterRow("Source") {
                HStack(spacing: 6) {
                    ForEach(InstalledSource.allCases) { source in
                        WorkshopFilterChip(
                            title: Text(verbatim: source.title),
                            isSelected: selectedSources.contains(source),
                            onIsolate: { selectedSources = [source] }
                        ) {
                            toggle(source, in: &selectedSources)
                        }
                    }
                }
            }

            WorkshopFilterRow("Storage") {
                HStack(spacing: 6) {
                    ForEach(InstalledStorageKind.allCases) { storage in
                        WorkshopFilterChip(
                            title: Text(verbatim: storage.title),
                            isSelected: selectedStorage.contains(storage),
                            onIsolate: { selectedStorage = [storage] }
                        ) {
                            toggle(storage, in: &selectedStorage)
                        }
                    }
                }
            }

            if activeFilterCount > 0 {
                Button("Clear filters") { resetFilters() }
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

    private func toggle<T: Hashable>(_ value: T, in set: inout Set<T>) {
        if set.contains(value) { set.remove(value) } else { set.insert(value) }
    }

    private var activeFilterCount: Int {
        var count = 0
        if WorkshopFilterMath.isNarrowing(selectedTypes, total: WPELibraryTypeKind.allCases.count) { count += 1 }
        if WorkshopFilterMath.isNarrowing(selectedSources, total: InstalledSource.allCases.count) { count += 1 }
        if WorkshopFilterMath.isNarrowing(selectedStorage, total: InstalledStorageKind.allCases.count) { count += 1 }
        return count
    }

    private func resetFilters() {
        selectedTypes = Set(WPELibraryTypeKind.allCases)
        selectedSources = Set(InstalledSource.allCases)
        selectedStorage = Set(InstalledStorageKind.allCases)
    }

    /// All-or-none selected == no filter (mirrors the type chips).
    private func sourceMatches(_ entry: WPEHistoryEntry) -> Bool {
        if selectedSources.isEmpty || selectedSources.count == InstalledSource.allCases.count {
            return true
        }
        return selectedSources.contains { $0.matches(entry) }
    }

    private func storageMatches(_ entry: WPEHistoryEntry) -> Bool {
        if selectedStorage.isEmpty || selectedStorage.count == InstalledStorageKind.allCases.count {
            return true
        }
        return selectedStorage.contains { $0.matches(entry) }
    }

    // MARK: - Actions

    /// "In use" == the entry's project is the active wallpaper on *any* open
    /// display (no single target screen in this multi-display library).
    private func isActive(_ entry: WPEHistoryEntry) -> Bool {
        screenManager.screens.contains { screen in
            screenManager.getConfiguration(for: screen)?.wpeOrigin?.workshopID == entry.origin.workshopID
        }
    }

    /// Displays currently running this entry — drives the green highlight in the
    /// screen-chooser mini-map.
    private func activeScreenIDs(for entry: WPEHistoryEntry) -> Set<CGDirectDisplayID> {
        Set(screenManager.screens
            .filter { screenManager.getConfiguration(for: $0)?.wpeOrigin?.workshopID == entry.origin.workshopID }
            .map(\.id))
    }

    private func showInFinder(_ entry: WPEHistoryEntry) {
        guard let folder = try? SecurityScopedBookmarkResolver.shared
            .resolve(entry.origin.sourceFolderBookmark, target: .transient).get().url
        else { return }
        let didStart = folder.startAccessingSecurityScopedResource()
        defer { if didStart { folder.stopAccessingSecurityScopedResource() } }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
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

    /// Re-download from Steam to pick up the newer Workshop version. On success
    /// the fresher `importedAt` clears the badge via `reconcileUpdateFlags`.
    private func updateEntry(_ entry: WPEHistoryEntry) {
        guard let id = UInt64(entry.origin.workshopID) else { return }
        WorkshopDownloadCoordinator.shared.download(itemID: id, title: entry.origin.title, using: doctor)
    }

    /// Keep the open inspector pointed at the latest entry for its item after a
    /// library change (e.g. an Update re-import); closes it if the item is gone.
    private func refreshSelectedEntry() {
        guard let current = selectedEntry else { return }
        selectedEntry = entries.first { $0.origin.workshopID == current.origin.workshopID }
    }

    /// Whether deleting this entry will actually free disk — true when a copy
    /// lives inside our container (the SteamCMD download at
    /// `…/content/431960/<id>/` or a legacy `wpe-cache/<id>/` extraction). Keyed
    /// on on-disk presence, NOT `resourceLocation`: packaged video/web downloads
    /// are container-internal yet tagged `.sourceFolder`. Folder imports that
    /// point at the user's own files have neither copy, so they free nothing.
    /// Cheap — only evaluated for the single entry the confirm dialog presents.
    private func deletesFiles(_ entry: WPEHistoryEntry) -> Bool {
        let id = entry.origin.workshopID
        guard WPEPathSafety.isSafeWorkshopID(id) else { return false }
        let fm = FileManager.default
        if let contentRoot = WPEStoragePaths.containerWorkshopContentRoot() {
            let download = contentRoot.appendingPathComponent(id, isDirectory: true)
            if fm.fileExists(atPath: download.path(percentEncoded: false)) { return true }
        }
        let cacheItem = WallpaperEngineCache.defaultRootURL.appendingPathComponent(id, isDirectory: true)
        return fm.fileExists(atPath: cacheItem.path(percentEncoded: false))
    }

    /// Always removes the library entry + any bookmark, then reclaims every
    /// managed on-disk copy regardless of the import's `resourceLocation`: a
    /// legacy `…/wpe-cache/<id>/` extraction AND the SteamCMD download at
    /// `…/content/431960/<id>/`. The old `resourceLocation == .cache` gate
    /// skipped packaged video/web downloads (tagged `.sourceFolder`) and leaked
    /// their container folders. Both reclaimers are container/workdir-scoped and
    /// path-validated, so a user's own external library folder is never touched.
    /// We delete rather than Trash because under App Sandbox, trashing a
    /// container file only reaches the invisible per-container `.Trash` and never
    /// frees space.
    private func performDelete(_ entry: WPEHistoryEntry) {
        errorMessage = nil
        if selectedEntry?.id == entry.id { selectedEntry = nil }
        let origin = entry.origin
        let workshopID = origin.workshopID
        let title = origin.title
        let expectedToFree = deletesFiles(entry)

        if bookmarkStore.containsWPEBookmark(workshopID: workshopID) {
            bookmarkStore.removeWPEBookmarks(workshopID: workshopID)
        }
        screenManager.removeWPEImport(workshopID: workshopID)

        if !workshopID.isEmpty {
            Task {
                var cacheDeleted = false
                do {
                    cacheDeleted = try await WallpaperEngineCache.shared.deleteFiles(workshopID: workshopID)
                } catch {
                    cacheDeleted = false
                }
                let downloadsRemoved = await doctor.deleteDownloadedItemFolders(workshopID: workshopID)
                if expectedToFree, !cacheDeleted, downloadsRemoved == 0 {
                    errorMessage = String(
                        localized: "Removed \(title) from the library, but its files couldn't be deleted.",
                        comment: "Workshop delete: history removed but managed files couldn't be deleted."
                    )
                }
            }
        }
        reload()
    }

    /// Favorite a downloaded item as a real `WallpaperBookmark` (no separate
    /// "like" store). A bookmark is an applyable wallpaper, so we rebuild the
    /// local content from the cached import via `WPECachedContentResolver`.
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

    /// Only items whose content `WPECachedContentResolver` can rebuild can be
    /// bookmarked. Mirrors the resolver's preconditions cheaply (no disk I/O).
    private func canAddBookmark(_ entry: WPEHistoryEntry) -> Bool {
        let origin = entry.origin
        guard let entryFile = origin.entryFile, !entryFile.isEmpty else { return false }
        switch origin.resourceLocation {
        case .cache:
            switch origin.originalType {
            case .video, .web, .scene: return true
            case .application, .unknown: return false
            }
        case .sourceFolder:
            // Unpackaged video/web downloads reference files in place (e.g. the
            // SteamCMD workdir); the resolver can rebuild those. Scene needs cache.
            switch origin.originalType {
            case .video, .web: return true
            case .scene, .application, .unknown: return false
            }
        default:
            return false
        }
    }

    // MARK: - Drag-to-apply screen bar

    /// Floats in only while a card is being dragged, listing the open displays
    /// as drop targets. (Click-to-apply lives in the inspector's Apply popover.)
    private var screenDropBar: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Text("Drop onto a display to apply")
                .font(DesignTokens.Typography.body)
                .foregroundStyle(.secondary)

            HStack(spacing: DesignTokens.Spacing.lg) {
                ForEach(screenManager.screens, id: \.id) { screen in
                    screenDropTarget(screen)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.vertical, DesignTokens.Spacing.md)
        // NB: a glassEffect backing here absorbed the children's drop
        // hit-testing, so the drop targets stopped registering. Keep material.
        .background(.regularMaterial)
        .overlay(alignment: .topTrailing) {
            Button { endEntryDrag() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(DesignTokens.Spacing.sm)
            .help(Text("Cancel"))
            .accessibilityLabel(Text("Cancel"))
        }
        .overlay(alignment: .bottom) { Divider() }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func screenDropTarget(_ screen: Screen) -> some View {
        VStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [5]))
                // Opaque fill keeps the tile interior hit-testable for the drop
                // (a glass backing left it a non-hit-testable "hole").
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .frame(width: 150, height: 90)
                .overlay {
                    Image(systemName: "display")
                        .font(.system(size: 30))
                        .foregroundStyle(Color.accentColor)
                }
            Text(verbatim: screen.name)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: 150)
        }
        // Whole target (tile + name + gaps) is a forgiving drop region.
        .contentShape(Rectangle())
        .onDrop(of: [.plainText], isTargeted: nil) { providers in
            handleScreenDrop(providers, to: screen)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Apply to \(screen.name)"))
    }

    /// Small icon shown under the cursor while dragging — deliberately NOT the
    /// preview image, so it doesn't obscure which display you're hovering.
    private func dragPreview(_ entry: WPEHistoryEntry) -> some View {
        Image(systemName: entry.origin.originalType.symbolName)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 54, height: 54)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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

    // MARK: - "Update available" daily check

    private static let remoteUpdateEpochsKey = "loomscreen.workshop.updateCheck.remoteEpochs.v1"

    private func loadUpdateFlags() {
        cachedRemoteUpdateEpochs = UserDefaults.standard.dictionary(forKey: Self.remoteUpdateEpochsKey) as? [String: Double] ?? [:]
        reconcileUpdateFlags()
    }

    /// Derive the visible "Update" set from cached remote timestamps vs each
    /// entry's import time, so a re-download (newer `importedAt`) clears the
    /// badge immediately without waiting for the next daily fetch.
    private func reconcileUpdateFlags() {
        updatedWorkshopIDs = Set(entries.compactMap { entry in
            guard let remoteEpoch = cachedRemoteUpdateEpochs[entry.origin.workshopID],
                  remoteEpoch > entry.importedAt.timeIntervalSince1970 else { return nil }
            return entry.origin.workshopID
        })
    }

    /// Once per day, cache each installed item's remote `timeUpdated`. Runs in
    /// `.task` so it cancels when the tab goes away; single-flight; preserves
    /// prior cache on transient failures and stops early on rate-limit so we
    /// never erase known badges.
    private func checkForUpdatesIfNeeded() async {
        guard !isCheckingForUpdates else { return }
        guard Date().timeIntervalSince1970 - lastUpdateCheckEpoch >= 86_400 else { return }
        let snapshot = entries
        guard !snapshot.isEmpty else { return }
        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }

        let service = SteamWorkshopMetadataService()
        let currentIDs = Set(snapshot.map(\.origin.workshopID))
        var remoteEpochs = cachedRemoteUpdateEpochs.filter { currentIDs.contains($0.key) }

        fetchLoop: for entry in snapshot {
            if Task.isCancelled { return }
            guard let id = UInt64(entry.origin.workshopID) else { continue }
            switch await service.fetch(publishedFileID: id) {
            case .success(let metadata):
                if let remoteUpdated = metadata.timeUpdated {
                    remoteEpochs[entry.origin.workshopID] = remoteUpdated.timeIntervalSince1970
                } else {
                    remoteEpochs.removeValue(forKey: entry.origin.workshopID)
                }
            case .failure(let error):
                if case .rateLimited = error { break fetchLoop }
                continue  // keep prior cached status for this id on transient failure
            }
        }

        cachedRemoteUpdateEpochs = remoteEpochs
        UserDefaults.standard.set(remoteEpochs, forKey: Self.remoteUpdateEpochsKey)
        reconcileUpdateFlags()
        lastUpdateCheckEpoch = Date().timeIntervalSince1970
    }
}

#endif
