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
    /// Tapping a tag in the detail inspector bubbles up here so the pane can
    /// switch to Browse Online and scope the grid to that tag. nil = tags are
    /// shown but inert (e.g. if ever embedded without a Browse tab).
    var onBrowseTag: ((String) -> Void)? = nil

    @Environment(ScreenManager.self) private var screenManager
    @Environment(SteamCMDDoctorService.self) private var doctor
    @State private var importCoordinator = WorkshopFolderImportCoordinator.shared
    @State private var bookmarkStore = BookmarkStore.shared
    @State private var entries: [WPEHistoryEntry] = []
    @State private var searchText: String = ""
    /// Multi-select type filter — empty means "all". This is a client-side OR
    /// (no API), so multi-select is correct here (an item matches if its kind is
    /// among the selected set), unlike the online Browse type chip.
    @State private var selectedTypes: Set<WPELibraryTypeKind> = []
    @State private var sortOrder: WPELibrarySortOrder = .recommended
    @State private var errorMessage: String?
    /// Set when the user asks to delete an entry — drives the confirmation
    /// dialog before any real file removal.
    @State private var pendingDelete: WPEHistoryEntry?
    /// Card tapped → open the trailing detail inspector (apply happens from
    /// inside it, or by dragging a card onto a display). Mirrors online Browse.
    @State private var selectedEntry: WPEHistoryEntry?
    /// Drives the drag-to-apply screen bar — set true when a card drag starts,
    /// cleared on drop / mouse-up / Escape. The bar is NOT shown otherwise.
    @State private var isDraggingEntry = false
    @State private var localDragEndMonitor: Any?
    @State private var globalDragEndMonitor: Any?
    /// Workshop ids whose Steam item is newer than our import (the "Update"
    /// badge), derived from `cachedRemoteUpdateEpochs` vs each entry's import time.
    @State private var updatedWorkshopIDs: Set<String> = []
    /// Cached remote `timeUpdated` (epoch seconds) per workshop id, persisted so
    /// the badge survives relaunches and re-derives correctly after a re-download.
    @State private var cachedRemoteUpdateEpochs: [String: Double] = [:]
    @State private var isCheckingForUpdates = false
    @AppStorage("loomscreen.workshop.updateCheck.epoch.v1") private var lastUpdateCheckEpoch: Double = 0

    // Match the online Browse grid density (square tiles, ~192px source).
    private let columns = [GridItem(.adaptive(minimum: 184, maximum: 220), spacing: DesignTokens.Spacing.lg)]

    var body: some View {
        content
            .background(DesignTokens.Colors.pageBackground)
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
                    Text(deletesFiles(entry) ? "Delete & Move Files to Trash" : "Remove from Library")
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: { entry in
                if deletesFiles(entry) {
                    Text("“\(entry.origin.title)” will be removed from your library and its downloaded files moved to the Trash. You can restore them from the Trash if needed.")
                } else {
                    Text("“\(entry.origin.title)” will be removed from your library. Its original files (imported from your own folder) are left untouched.")
                }
            }
            .inspector(isPresented: Binding(
                get: { selectedEntry != nil },
                set: { if !$0 { selectedEntry = nil } }
            )) {
                Group {
                    if let entry = selectedEntry {
                        WPEInstalledInspectorContent(
                            entry: entry,
                            screens: screenManager.screens,
                            activeScreenIDs: activeScreenIDs(for: entry),
                            isBookmarked: bookmarkStore.containsWPEBookmark(workshopID: entry.origin.workshopID),
                            canBookmark: canAddBookmark(entry),
                            hasUpdate: updatedWorkshopIDs.contains(entry.origin.workshopID),
                            canUpdate: doctor.isDownloadReady,
                            onApply: { apply(entry, to: $0) },
                            onApplyToAll: { applyToAll(entry) },
                            onUpdate: { updateEntry(entry) },
                            onToggleBookmark: { toggleBookmark(entry) },
                            onShowInFinder: { showInFinder(entry) },
                            onDelete: { pendingDelete = entry },
                            onSelectTag: onBrowseTag.map { browse in
                                { tag in selectedEntry = nil; browse(tag) }
                            },
                            onClose: { selectedEntry = nil }
                        )
                    } else {
                        installedInspectorPlaceholder
                    }
                }
                .inspectorColumnWidth(min: 300, ideal: 340, max: 440)
            }
    }

    private var installedInspectorPlaceholder: some View {
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
                    typeChipRow

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
            // Filtered to nothing (e.g. the "Unsupported" chip when you have no
            // such items). Show a plain empty area rather than a full illustrated
            // page — the filter bar above stays put, so flipping back to "All"
            // (or clearing the search) is the obvious, in-place way back.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                            isSelected: selectedEntry?.id == entry.id,
                            screens: screenManager.screens,
                            onApply: { screen in apply(entry, to: screen) },
                            onApplyToAll: { applyToAll(entry) },
                            // Toggle: clicking the open card again closes the inspector.
                            onTap: { selectedEntry = selectedEntry?.id == entry.id ? nil : entry },
                            onRemove: { pendingDelete = entry },
                            isBookmarked: bookmarked,
                            // Only offer "Add" when the item's content can actually
                            // be rebuilt into a bookmark; "Remove" stays available
                            // for anything already bookmarked.
                            onBookmark: (bookmarked || canAddBookmark(entry)) ? { toggleBookmark(entry) } : nil,
                            hasUpdate: updatedWorkshopIDs.contains(entry.origin.workshopID),
                            onUpdate: doctor.isDownloadReady ? { updateEntry(entry) } : nil
                        )
                        .onDrag({ beginEntryDrag(entry) }, preview: { dragPreview(entry) })
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                // Tap the gaps between cards / the side margins to close the
                // inspector — placed at content level so in-grid gaps land here
                // (a ScrollView-level background missed them). Behind the cards
                // (Buttons keep their taps); clicking another card still switches.
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
            typeMatches(entry) && matchesSearch(entry, query: query)
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

    // MARK: - Type filter chips (multi-select)

    private var typeChipRow: some View {
        HStack(spacing: 6) {
            FilterChip(title: Text("All"), isSelected: selectedTypes.isEmpty) {
                selectedTypes.removeAll()
            }
            .help(Text("Show every installed wallpaper"))

            ForEach(WPELibraryTypeKind.allCases) { kind in
                FilterChip(title: Text(verbatim: kind.title), isSelected: selectedTypes.contains(kind)) {
                    toggleType(kind)
                }
                .help(kind.helpText)
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

    private func typeMatches(_ entry: WPEHistoryEntry) -> Bool {
        guard !selectedTypes.isEmpty else { return true }
        return selectedTypes.contains { $0.matches(entry) }
    }

    // MARK: - Actions

    /// "In use" means the entry's project is the active wallpaper on *any* open
    /// display — there is no single target screen in this multi-display library.
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
        var isStale = false
        guard let folder = try? URL(
            resolvingBookmarkData: entry.origin.sourceFolderBookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return }
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

    /// Re-download the item from Steam to pick up the newer Workshop version
    /// (the "Update available" path). Reuses the same SteamCMD download + import
    /// flow as a fresh download; on success the fresher `importedAt` clears the
    /// badge via `reconcileUpdateFlags`.
    private func updateEntry(_ entry: WPEHistoryEntry) {
        guard let id = UInt64(entry.origin.workshopID) else { return }
        WorkshopDownloadCoordinator.shared.download(itemID: id, title: entry.origin.title, using: doctor)
    }

    /// Keep the open inspector pointed at the latest entry for its item after a
    /// library change (e.g. an Update re-import). Closes the inspector if the
    /// item is gone (deleted).
    private func refreshSelectedEntry() {
        guard let current = selectedEntry else { return }
        selectedEntry = entries.first { $0.origin.workshopID == current.origin.workshopID }
    }

    /// Whether deleting this entry will touch files on disk. Only items we
    /// downloaded/extracted into our managed cache do — folder imports point at
    /// the user's own files, which we must never delete.
    private func deletesFiles(_ entry: WPEHistoryEntry) -> Bool {
        entry.origin.resourceLocation == .cache
    }

    /// Real, confirmed deletion. Always removes the library entry + any bookmark.
    /// For cache-backed items it ALSO moves our managed copy
    /// (`…/wpe-cache/<id>/`) to the Trash — a recoverable, path-validated delete
    /// that can never escape the cache root. User-imported source folders are
    /// never touched.
    private func performDelete(_ entry: WPEHistoryEntry) {
        errorMessage = nil
        // Close the detail inspector if it's showing the item being removed.
        if selectedEntry?.id == entry.id { selectedEntry = nil }
        let origin = entry.origin
        let workshopID = origin.workshopID

        if bookmarkStore.containsWPEBookmark(workshopID: workshopID) {
            bookmarkStore.removeWPEBookmarks(workshopID: workshopID)
        }
        screenManager.removeWPEImport(workshopID: workshopID)

        if origin.resourceLocation == .cache, !workshopID.isEmpty {
            do {
                try WallpaperEngineCache().moveToTrash(workshopID: workshopID)
            } catch {
                errorMessage = String(
                    localized: "Removed \(origin.title) from the library, but its files couldn't be moved to the Trash.",
                    comment: "Workshop delete: history removed but cache files couldn't be trashed."
                )
            }
        }
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

    /// Floats in only while a card is being dragged (not persistent), listing the
    /// open displays as drop targets — drop a wallpaper onto one to apply it there.
    /// (Click-to-apply per display lives in the inspector's Apply popover.)
    private var screenDropBar: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Text("Drop onto a display to apply")
                .font(.system(size: 12, weight: .medium))
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
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .frame(width: 150, height: 90)
                .overlay {
                    Image(systemName: "display")
                        .font(.system(size: 30))
                        .foregroundStyle(Color.accentColor)
                }
            Text(verbatim: screen.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: 150)
        }
        .onDrop(of: [.plainText], isTargeted: nil) { providers in
            handleScreenDrop(providers, to: screen)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Apply to \(screen.name)"))
    }

    /// Small icon shown under the cursor while dragging — deliberately NOT the
    /// preview image, so it doesn't obscure which display you're hovering.
    private func dragPreview(_ entry: WPEHistoryEntry) -> some View {
        Image(systemName: dragIconName(for: entry.origin.originalType))
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 54, height: 54)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func dragIconName(for type: WPEType) -> String {
        switch type {
        case .video: return "play.rectangle.fill"
        case .web: return "globe"
        case .scene: return "cube.transparent.fill"
        case .application: return "app.dashed"
        case .unknown: return "questionmark.square.dashed"
        }
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
    /// entry's current import time — so a re-download (newer `importedAt`) clears
    /// the badge immediately, without waiting for the next daily fetch.
    private func reconcileUpdateFlags() {
        updatedWorkshopIDs = Set(entries.compactMap { entry in
            guard let remoteEpoch = cachedRemoteUpdateEpochs[entry.origin.workshopID],
                  remoteEpoch > entry.importedAt.timeIntervalSince1970 else { return nil }
            return entry.origin.workshopID
        })
    }

    /// Once per day, fetch each installed item's current Workshop metadata and
    /// cache its remote `timeUpdated`. Runs inside `.task` so it's cancelled when
    /// the tab goes away; single-flight; preserves prior cache on transient
    /// failures and stops early on rate-limit (never erases known badges).
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

// MARK: - Filters

/// Concrete library type kinds for the multi-select chip row (no `.all` case —
/// an empty selection means "all"). `.unsupported` collects the project types
/// macOS can't run.
private enum WPELibraryTypeKind: String, CaseIterable, Identifiable {
    case video, web, scene, unsupported

    var id: Self { self }

    var title: String {
        switch self {
        case .video: return WPEType.video.localizedDisplayName
        case .web: return WPEType.web.localizedDisplayName
        case .scene: return WPEType.scene.localizedDisplayName
        case .unsupported: return String(localized: "Unsupported", comment: "Workshop library type filter.")
        }
    }

    var helpText: Text {
        switch self {
        case .video: return Text("Show only video wallpapers")
        case .web: return Text("Show only web / HTML wallpapers")
        case .scene: return Text("Show only scene wallpapers")
        case .unsupported:
            // Explains issue #9's "when does unsupported appear?".
            return Text("Windows-only items — a Windows .exe application wallpaper, or a project type macOS can't recognize. These can't run here.")
        }
    }

    func matches(_ entry: WPEHistoryEntry) -> Bool {
        switch self {
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

// MARK: - Installed detail inspector

/// Trailing detail inspector for an installed item (mirrors the online Browse
/// inspector). Click a card to open it; apply happens HERE (per-display via the
/// mini-map, or "All"), alongside bookmark / Show in Finder / Remove. Dragging a
/// card onto a display remains the quick per-screen path.
private struct WPEInstalledInspectorContent: View {
    let entry: WPEHistoryEntry
    let screens: [Screen]
    let activeScreenIDs: Set<CGDirectDisplayID>
    let isBookmarked: Bool
    let canBookmark: Bool
    let hasUpdate: Bool
    /// SteamCMD is wired up, so the Update (re-download) button can run.
    let canUpdate: Bool
    let onApply: (Screen) -> Void
    let onApplyToAll: () -> Void
    let onUpdate: () -> Void
    let onToggleBookmark: () -> Void
    let onShowInFinder: () -> Void
    let onDelete: () -> Void
    /// Wired when tags should be tappable (jump to Browse Online by tag).
    let onSelectTag: ((String) -> Void)?
    let onClose: () -> Void

    @Environment(\.openURL) private var openURL
    /// Drives the multi-display target popover under the single Apply button.
    @State private var showingApplyPopover = false
    /// Original WPE metadata read straight from the item's local `project.json`
    /// (description / tags / content rating) — no Steam API call. nil until the
    /// off-main read completes; reloaded whenever the inspected entry changes.
    @State private var localInfo: WPELocalProjectInfo?
    /// Collapsed vs. expanded state for a long description.
    @State private var descriptionExpanded = false

    /// Shared singleton (also drives the online Browse download UI) — reading it
    /// here makes this view observe the re-download's phase + progress.
    private var downloadCoordinator: WorkshopDownloadCoordinator { .shared }
    private var itemID: UInt64? { UInt64(entry.origin.workshopID) }
    private var updatePhase: WorkshopDownloadCoordinator.DownloadPhase {
        guard let itemID else { return .idle }
        return downloadCoordinator.phase(for: itemID)
    }
    private var isUpdateRetry: Bool {
        if case .failed = updatePhase { return true }
        return false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                hero
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    Text(verbatim: entry.origin.title)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: DesignTokens.Spacing.xs) {
                        typePill
                        if let rating = localInfo?.contentRating, !rating.isEmpty {
                            contentRatingPill(rating)
                        }
                    }
                    metaRow
                    if hasUpdate { updateSection }
                    unsupportedWarning
                    if !activeScreenIDs.isEmpty { inUseRow }

                    Divider()
                    applySection

                    infoSection

                    Divider()
                    actionsSection
                }
                .padding(.horizontal, DesignTokens.Spacing.lg)
                .padding(.bottom, DesignTokens.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(DesignTokens.Colors.pageBackground)
        .task(id: entry.id) {
            descriptionExpanded = false
            localInfo = await loadWPELocalProjectInfo(for: entry)
        }
    }

    private var hero: some View {
        WPEPreviewView(
            imageURL: entry.origin.sourcePreviewURL,
            securityScopedBookmarkData: entry.origin.sourceFolderBookmark,
            playbackMode: .hoverToPlay
        )
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .overlay(alignment: .topLeading) {
            HeroCloseButton(action: onClose).padding(DesignTokens.Spacing.sm)
        }
        .padding([.horizontal, .top], DesignTokens.Spacing.lg)
    }

    /// Size on disk · date added — both local (no API). Size appears once the
    /// off-main folder scan lands; the date is always available.
    private var metaRow: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            if let bytes = localInfo?.sizeBytes, bytes > 0 {
                Label {
                    Text(verbatim: Self.byteFormatter.string(fromByteCount: bytes))
                } icon: {
                    Image(systemName: "internaldrive")
                }
            }
            Label {
                Text(entry.importedAt, format: .dateTime.year().month().day())
            } icon: {
                Image(systemName: "calendar")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()

    private var typePill: some View {
        Text(verbatim: entry.origin.localizedDisplayTypeName.uppercased(with: .current))
            .font(.system(size: 9, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous))
    }

    @ViewBuilder
    private var updateSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Label("Update available on Steam", systemImage: "arrow.triangle.2.circlepath")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)

            switch updatePhase {
            case .downloading, .importing:
                updateProgressRow
            default:
                Button(action: onUpdate) {
                    Label(isUpdateRetry ? "Retry Update" : "Update", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canUpdate)
                .help(canUpdate
                      ? Text("Re-download the latest version from Steam")
                      : Text("Set up SteamCMD in Settings → Workshop to enable updates."))

                if case .failed(let message) = updatePhase {
                    Text(verbatim: message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !canUpdate {
                    Text("Updates use SteamCMD (Settings → Workshop → SteamCMD Doctor).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var updateProgressRow: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            if let itemID, let fraction = downloadCoordinator.progress[itemID] {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                Text(verbatim: "\(Int((fraction * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
                Text(updatePhase == .importing ? "Importing…" : "Downloading…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button {
                if let itemID { downloadCoordinator.cancel(itemID) }
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(Text("Cancel update"))
            .accessibilityLabel(Text("Cancel update"))
        }
    }

    @ViewBuilder
    private var unsupportedWarning: some View {
        if entry.origin.originalType == .application || entry.origin.originalType == .unknown {
            Label("This is a Windows-only wallpaper and can't run on macOS.", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var inUseRow: some View {
        let names = screens.filter { activeScreenIDs.contains($0.id) }.map(\.name).joined(separator: ", ")
        return Label("In use on \(names)", systemImage: "checkmark.circle.fill")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.green)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var applySection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            if screens.isEmpty {
                Text("Open a display first, then apply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if screens.count == 1, let only = screens.first {
                // Single display: name it in the label ("Apply to Studio Display")
                // so the one button reads unambiguously.
                Button { onApply(only) } label: {
                    Label("Apply to \(only.name)", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            } else {
                // One Apply button → a popover to pick a display or all (same
                // pattern as the online inspector). Drag-to-apply is still there.
                Button { showingApplyPopover = true } label: {
                    Label("Apply", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .popover(isPresented: $showingApplyPopover, arrowEdge: .bottom) {
                    WorkshopApplyTargetPicker(
                        screens: screens,
                        activeScreenIDs: activeScreenIDs,
                        onPick: { onApply($0); showingApplyPopover = false },
                        onAll: { onApplyToAll(); showingApplyPopover = false }
                    )
                }
            }
        }
    }

    /// Icon-only action row: bookmark (when allowed) · Finder · Steam · Remove.
    /// Each keeps its title as the VoiceOver label (`.iconOnly` retains it) and
    /// a hover tooltip, so dropping the visible text costs no clarity.
    private var actionsSection: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            if canBookmark || isBookmarked {
                actionButton(
                    titleKey: isBookmarked ? "Remove Bookmark" : "Add Bookmark",
                    systemImage: isBookmarked ? "bookmark.fill" : "bookmark",
                    tint: isBookmarked ? .yellow : nil,
                    action: onToggleBookmark
                )
            }

            actionButton(titleKey: "Show in Finder", systemImage: "folder", action: onShowInFinder)

            if let url = steamURL {
                actionButton(titleKey: "Steam", systemImage: "arrow.up.forward.app") { openURL(url) }
            }

            actionButton(titleKey: "Remove", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }

    private func actionButton(
        titleKey: LocalizedStringKey,
        systemImage: String,
        role: ButtonRole? = nil,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Label(titleKey, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .tint(tint)
        .help(Text(titleKey))
    }

    /// Original WPE info pulled from the local `project.json` (no API): the
    /// description and tags. Hidden entirely until the read lands / when absent.
    @ViewBuilder
    private var infoSection: some View {
        if let info = localInfo, info.hasContent {
            Divider()
            if let description = info.cleanedDescription, !description.isEmpty {
                descriptionSection(description)
            }
            if !info.tags.isEmpty {
                tagsSection(info.tags)
            }
            if !info.properties.isEmpty {
                customizationSection(info.properties)
            }
        }
    }

    /// Read-only list of the author-defined adjustable settings (colors /
    /// sliders / dropdowns …). The live editor is per-display, in each screen's
    /// settings — surfacing the list here just sets expectations.
    private func customizationSection(_ properties: [WPEPropertySummary]) -> some View {
        let shown = properties.prefix(8)
        let remaining = properties.count - shown.count
        return VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(spacing: 6) {
                Text("Customizable").font(.headline)
                Text(verbatim: "\(properties.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }
            ForEach(shown) { property in
                HStack(spacing: 6) {
                    Image(systemName: property.kind.systemImage)
                        .font(.system(size: 10))
                        .foregroundStyle(.tint)
                        .frame(width: 14)
                        .accessibilityHidden(true)
                    Text(verbatim: property.label)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            if remaining > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .frame(width: 14)
                        .accessibilityHidden(true)
                    Text(verbatim: "+\(remaining)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            Text("Adjust these from a display’s settings after applying.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func descriptionSection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text("Description").font(.headline)
            Text(verbatim: text)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(descriptionExpanded ? nil : 6)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if text.count > 280 {
                Button(descriptionExpanded ? "Show less" : "Show more") {
                    withAnimation(.easeInOut(duration: 0.15)) { descriptionExpanded.toggle() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor)
            }
        }
    }

    private func tagsSection(_ tags: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    tagChip(tag)
                }
            }
        }
    }

    /// Tappable accent chip when `onSelectTag` is wired (jumps to Browse Online
    /// scoped to the tag); otherwise a plain, inert secondary pill.
    @ViewBuilder
    private func tagChip(_ tag: String) -> some View {
        if let onSelectTag {
            Button { onSelectTag(tag) } label: {
                Text(verbatim: tag)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .help(Text("Browse items tagged \(tag)"))
        } else {
            Text(verbatim: tag)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06), in: Capsule())
        }
    }

    private func contentRatingPill(_ rating: String) -> some View {
        let tint = contentRatingTint(rating)
        return Text(verbatim: rating.uppercased(with: .current))
            .font(.system(size: 9, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous))
    }

    private func contentRatingTint(_ rating: String) -> Color {
        switch rating.lowercased() {
        case "everyone": return .green
        case "questionable": return .orange
        case "mature": return .red
        default: return .gray
        }
    }

    private var steamURL: URL? {
        guard UInt64(entry.origin.workshopID) != nil else { return nil }
        return URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(entry.origin.workshopID)")
    }
}

// MARK: - Local project.json metadata (no Steam API)

/// The original Wallpaper Engine fields we surface in the Installed inspector,
/// read directly from the item's bundled `project.json`. Purely local — opening
/// a downloaded item never spends a Steam Web API request to show its details.
private struct WPELocalProjectInfo: Sendable, Equatable {
    var cleanedDescription: String?
    var tags: [String]
    var contentRating: String?
    /// On-disk footprint of the item's folder (recursive sum of file sizes).
    var sizeBytes: Int64?
    /// Author-defined adjustable properties (colors / sliders / dropdowns …)
    /// parsed from the local project.json schema — shown read-only here.
    var properties: [WPEPropertySummary]

    var hasContent: Bool {
        (cleanedDescription?.isEmpty == false) || !tags.isEmpty || !properties.isEmpty
    }
}

/// A single author-defined adjustable property, summarized for read-only
/// display (the live editor lives per-display in the screen's settings).
private struct WPEPropertySummary: Sendable, Equatable, Identifiable {
    let id: String
    let label: String
    let kind: Kind

    enum Kind: Sendable {
        case color, slider, dropdown, toggle, text, file

        init?(_ type: WallpaperEngineProjectPropertySchema.PropertyType) {
            switch type {
            case .color: self = .color
            case .slider: self = .slider
            case .combo: self = .dropdown
            case .bool: self = .toggle
            case .textinput: self = .text
            case .file, .directory: self = .file
            case .text, .group, .unsupported: return nil
            }
        }

        var systemImage: String {
            switch self {
            case .color: return "paintpalette"
            case .slider: return "slider.horizontal.3"
            case .dropdown: return "chevron.up.chevron.down"
            case .toggle: return "switch.2"
            case .text: return "textformat"
            case .file: return "doc"
            }
        }
    }
}

/// Only the display fields — `WallpaperEngineProject` deliberately ignores these
/// (it's the runtime import model); here we just want text to show.
private struct WPEProjectDisplayManifest: Decodable {
    let description: String?
    let tags: [String]?
    let contentrating: String?
}

/// Resolve the item's security-scoped folder and decode its `project.json` off
/// the main actor. Returns nil for items without a manifest (e.g. loose video /
/// web imports), so the inspector simply omits the info block.
private func loadWPELocalProjectInfo(for entry: WPEHistoryEntry) async -> WPELocalProjectInfo? {
    let bookmark = entry.origin.sourceFolderBookmark
    return await Task.detached(priority: .utility) {
        var isStale = false
        guard let folder = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        let didStart = folder.startAccessingSecurityScopedResource()
        defer { if didStart { folder.stopAccessingSecurityScopedResource() } }

        // Footprint + adjustable-property schema are independent of the manifest
        // text fields, so compute them either way.
        let size = directorySize(of: folder)
        let properties = loadEditableProperties(folder: folder)

        let manifestURL = folder.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(WPEProjectDisplayManifest.self, from: data)
        else {
            return (size > 0 || !properties.isEmpty)
                ? WPELocalProjectInfo(cleanedDescription: nil, tags: [], contentRating: nil, sizeBytes: size > 0 ? size : nil, properties: properties)
                : nil
        }

        return WPELocalProjectInfo(
            cleanedDescription: manifest.description.flatMap(strippedWPEMarkup),
            tags: manifest.tags ?? [],
            contentRating: manifest.contentrating?.trimmingCharacters(in: .whitespacesAndNewlines),
            sizeBytes: size > 0 ? size : nil,
            properties: properties
        )
    }.value
}

/// Parse the local project.json property schema and reduce it to the editable
/// controls we surface (purely local — no Steam API, no renderer).
private func loadEditableProperties(folder: URL) -> [WPEPropertySummary] {
    guard let schema = try? WallpaperEngineProjectPropertySchema.read(from: folder, includeSchemeColor: true) else {
        return []
    }
    return schema.properties.compactMap { property in
        guard let kind = WPEPropertySummary.Kind(property.type) else { return nil }
        let trimmed = property.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        return WPEPropertySummary(id: property.key, label: trimmed.isEmpty ? property.key : trimmed, kind: kind)
    }
}

/// Recursively sum the byte size of every regular file under `folder`. Reads
/// only file metadata (no content), so it's cheap even for large scenes.
private func directorySize(of folder: URL) -> Int64 {
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
    guard let enumerator = FileManager.default.enumerator(
        at: folder,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles]
    ) else { return 0 }

    var total: Int64 = 0
    for case let url as URL in enumerator {
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isRegularFile == true else { continue }
        total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
    }
    return total
}

/// WPE descriptions carry Steam BBCode (`[h1]…[/h1]`, `[b]`, `[url=…]`, `[list]`
/// …). Strip the tags for a clean, native text block while keeping the words.
private func strippedWPEMarkup(_ raw: String) -> String? {
    var text = raw.replacingOccurrences(
        of: #"\[/?[^\]]*\]"#, with: "", options: .regularExpression)
    text = text.replacingOccurrences(
        of: #"[\r\n]{3,}"#, with: "\n\n", options: .regularExpression)
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
}

#endif
