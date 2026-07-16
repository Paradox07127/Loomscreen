#if !LITE_BUILD
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
    @State private var model = WorkshopInstalledLibraryModel()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Shares the screen-detail inspector's width tokens so the panel reads as
    /// the same sidebar across the app.
    @AppStorage("Workshop.Installed.InspectorWidth") private var inspectorWidth = Double(DesignTokens.Inspector.defaultWidth)
    @State private var liveInspectorWidth: Double?

    // 184…220 matches the online Browse grid density (square tiles, ~192px source).
    private let columns = [GridItem(.adaptive(minimum: 184, maximum: 220), spacing: DesignTokens.Spacing.lg)]

    var body: some View {
        @Bindable var model = model
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
                onClose: { model.inspectorHidden = true },
                main: { mainColumn },
                inspector: { width in installedInspectorColumn(width: width) }
            )
            .background(DesignTokens.Colors.pageBackground)
            // Only contributed when hosted in the tabbed pane and a card is selected.
            .toolbar {
                if paneHeader != nil, model.selectedEntry != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            model.inspectorHidden.toggle()
                        } label: {
                            Image(systemName: "sidebar.right")
                        }
                        .help(Text(model.inspectorHidden ? "Show details" : "Hide details"))
                        .accessibilityLabel(Text("Toggle details panel"))
                    }
                }
            }
            .onAppear { model.onAppear() }
            .onDisappear { model.onDisappear() }
            .onReceive(NotificationCenter.default.publisher(for: .wpeHistoryDidChange)) { _ in
                model.historyDidChange()
            }
            .confirmationDialog(
                Text("Delete this wallpaper?"),
                isPresented: Binding(
                    get: { model.pendingDelete != nil },
                    set: { if !$0 { model.cancelDelete() } }
                ),
                presenting: model.pendingDelete
            ) { entry in
                Button(role: .destructive) {
                    performDelete(entry)
                } label: {
                    Text(model.deletesFiles(entry) ? "Delete & Free Up Space" : "Remove from Library")
                }
                Button("Cancel", role: .cancel) { model.cancelDelete() }
            } message: { entry in
                if model.deletesFiles(entry) {
                    Text("“\(entry.origin.title)” will be removed from your library and its downloaded files deleted to free up disk space. This can't be undone, but you can download it again from the Workshop.")
                } else {
                    Text("“\(entry.origin.title)” will be removed from your library. Its original files (imported from your own folder) are left untouched.")
                }
            }
    }

    private func installedInspectorColumn(width: CGFloat) -> some View {
        Group {
            if let entry = model.selectedEntry {
                WPEInstalledInspectorContent(
                    entry: entry,
                    screens: screenManager.screens,
                    activeScreenIDs: activeScreenIDs(for: entry),
                    state: WPEInstalledInspectorContent.ItemState(
                        isBookmarked: bookmarkStore.containsWPEBookmark(workshopID: entry.origin.workshopID),
                        canBookmark: model.canAddBookmark(entry),
                        hasUpdate: model.updatedWorkshopIDs.contains(entry.origin.workshopID),
                        canUpdate: doctor.isDownloadReady
                    ),
                    actions: WPEInstalledInspectorContent.Actions(
                        onApply: { apply(entry, to: $0) },
                        onApplyToAll: { applyToAll(entry) },
                        onUpdate: { updateEntry(entry) },
                        onToggleBookmark: { model.toggleBookmark(entry, store: bookmarkStore) },
                        onShowInFinder: { model.showInFinder(entry) },
                        onDelete: { model.requestDelete(entry) },
                        onSelectTag: onBrowseTag.map { browse in
                            { tag in model.clearSelectionAndBrowse(tag: tag, action: browse) }
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

    private var isInspectorVisible: Bool { model.selectedEntry != nil && !model.inspectorHidden }

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
        @Bindable var model = model
        if model.entries.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                LibraryFilterBar(
                    searchText: $model.searchText,
                    searchPrompt: "Search library",
                    resultCount: model.visibleEntries.count,
                    totalCount: model.entries.count
                ) {
                    HStack(spacing: DesignTokens.LibraryFilterBar.contentSpacing) {
                        WorkshopFiltersToggle(isExpanded: $model.showFilters, activeFilterCount: model.activeFilterCount)

                        Spacer(minLength: 0)

                        Picker("Sort", selection: $model.sortOrder) {
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

                if model.showFilters {
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
        if model.visibleEntries.isEmpty {
            // Filtered to nothing: plain empty area (not the illustrated empty
            // state) so the filter bar above stays put as the in-place way back.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(DesignTokens.Colors.Status.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.top, DesignTokens.Spacing.sm)
                }
                LazyVGrid(columns: columns, spacing: DesignTokens.Spacing.lg) {
                    ForEach(model.visibleEntries, id: \.id) { entry in
                        let bookmarked = bookmarkStore.containsWPEBookmark(workshopID: entry.origin.workshopID)
                        WPEHistoryRow(
                            entry: entry,
                            isActive: isActive(entry),
                            allowsInlineApply: true,
                            isSelected: model.selectedEntry?.id == entry.id,
                            screens: screenManager.screens,
                            onApply: { screen in apply(entry, to: screen) },
                            onApplyToAll: { applyToAll(entry) },
                            // Clicking the open card again closes the inspector;
                            // a new card always reveals the (possibly collapsed) panel.
                            onTap: { model.select(entry) },
                            onRemove: { model.requestDelete(entry) },
                            isBookmarked: bookmarked,
                            // Only offer "Add" when the content can be rebuilt into a
                            // bookmark; "Remove" stays available for anything bookmarked.
                            onBookmark: (bookmarked || model.canAddBookmark(entry))
                                ? { model.toggleBookmark(entry, store: bookmarkStore) } : nil,
                            hasUpdate: model.updatedWorkshopIDs.contains(entry.origin.workshopID),
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
                        .onTapGesture { model.clearSelection() }
                )
            }
            .overlay(alignment: .top) {
                if model.isDraggingEntry, !screenManager.screens.isEmpty {
                    screenDropBar
                }
            }
            .animation(.easeInOut(duration: 0.2), value: model.isDraggingEntry)
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

    // MARK: - Type filter chips (multi-select)

    private var typeChipRow: some View {
        HStack(spacing: 6) {
            ForEach(WPELibraryTypeKind.allCases) { kind in
                WorkshopFilterChip(
                    title: Text(verbatim: kind.title),
                    isSelected: model.selectedTypes.contains(kind),
                    onIsolate: { model.isolateType(kind) }
                ) {
                    model.toggleType(kind)
                }
            }
        }
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
                            isSelected: model.selectedSources.contains(source),
                            onIsolate: { model.isolateSource(source) }
                        ) {
                            model.toggleSource(source)
                        }
                    }
                }
            }

            WorkshopFilterRow("Storage") {
                HStack(spacing: 6) {
                    ForEach(InstalledStorageKind.allCases) { storage in
                        WorkshopFilterChip(
                            title: Text(verbatim: storage.title),
                            isSelected: model.selectedStorage.contains(storage),
                            onIsolate: { model.isolateStorage(storage) }
                        ) {
                            model.toggleStorage(storage)
                        }
                    }
                }
            }

            if model.activeFilterCount > 0 {
                Button("Clear filters") { model.resetFilters() }
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

    private func apply(_ entry: WPEHistoryEntry, to screen: Screen) {
        model.startApply(entry: entry) {
            await screenManager.activateWPEHistoryEntry(entry, for: screen)
            return screenManager.wpeImportError(for: screen) != nil
        }
    }

    private func applyToAll(_ entry: WPEHistoryEntry) {
        model.startApply(entry: entry) {
            var failed = false
            for screen in screenManager.screens {
                await screenManager.activateWPEHistoryEntry(entry, for: screen)
                failed = failed || screenManager.wpeImportError(for: screen) != nil
            }
            return failed
        }
    }

    /// Re-download from Steam to pick up the newer Workshop version. On success
    /// the fresher `importedAt` clears the badge via `reconcileUpdateFlags`.
    private func updateEntry(_ entry: WPEHistoryEntry) {
        guard let id = UInt64(entry.origin.workshopID) else { return }
        WorkshopDownloadCoordinator.shared.download(itemID: id, title: entry.origin.title, using: doctor)
    }

    private func performDelete(_ entry: WPEHistoryEntry) {
        model.performDelete(
            entry,
            services: WorkshopInstalledLibraryModel.DeleteServices(
                containsBookmark: { bookmarkStore.containsWPEBookmark(workshopID: $0) },
                removeBookmarks: { bookmarkStore.removeWPEBookmarks(workshopID: $0) },
                removeImportIfMatching: {
                    screenManager.removeWPEImport(
                        workshopID: $0.workshopID,
                        matchingImportedAt: $0.importedAt
                    )
                },
                deleteCacheFiles: { try await WallpaperEngineCache.shared.deleteFiles(workshopID: $0) },
                deleteDownloadedFolders: { await doctor.deleteDownloadedItemFolders(workshopID: $0) }
            )
        )
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
            Button { model.endEntryDrag() } label: {
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
            model.endEntryDrag()
            return false
        }
        let ticket = model.makeDropTicket()
        _ = provider.loadObject(ofClass: NSString.self) { value, error in
            // Extract Sendable values (String / Bool) before crossing to the main
            // actor — NSString and Error are not Sendable under Swift 6.
            let workshopID = value as? String
            let loadFailed = error != nil
            Task { @MainActor in
                guard let entry = model.consumeDrop(
                    ticket,
                    workshopID: workshopID,
                    loadFailed: loadFailed
                ) else { return }
                // Re-resolve the target in case the display topology changed mid-drag.
                guard let target = screenManager.screens.first(where: { $0.id == screen.id }) else { return }
                apply(entry, to: target)
            }
        }
        return true
    }

    private func beginEntryDrag(_ entry: WPEHistoryEntry) -> NSItemProvider {
        NSItemProvider(object: model.beginEntryDrag(entry) as NSString)
    }
}

#endif
