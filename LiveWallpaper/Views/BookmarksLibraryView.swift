import SwiftUI
import LiveWallpaperCore

/// Sidebar-routed full-page browser for saved wallpaper bookmarks.
///
/// Layout follows the unified library shell: identity-only `DetailHeaderBar`,
/// `LibraryFilterBar` underneath (search capsule + optional type chips when
/// the library is large), then a dense Apple Music / Photos style gallery.
struct BookmarksLibraryView: View {
    @Environment(ScreenManager.self) private var screenManager
    @State private var store = BookmarkStore.shared
    @State private var renamingID: UUID? = nil
    @State private var renameDraft: String = ""
    @State private var searchText: String = ""
    @State private var typeFilter: BookmarkTypeFilter = .all
    @State private var pendingDestructive: PendingDestructive?

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 14)]

    /// Bookmarks gallery stays clean (no type chips) under this threshold;
    /// once the library outgrows a single screen of cards the chip row earns
    /// its keep. Matches the antigravity "progressive disclosure" guidance.
    private static let typeChipsThreshold = 6

    var body: some View {
        DetailPageScaffold(
            header: { header },
            content: { content }
        )
        .confirmDestructive($pendingDestructive)
    }

    // MARK: - Header

    private var header: some View {
        DetailHeaderBar(
            systemImage: "bookmark.fill",
            title: { Text("Bookmarks") },
            metadata: {
                HStack(spacing: 6) {
                    Text("\(store.bookmarks.count)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    Text("saved wallpapers")
                }
            },
            actions: { EmptyView() }
        )
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if store.bookmarks.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                filterBar
                gallery
            }
        }
    }

    @ViewBuilder
    private var filterBar: some View {
        if showsTypeChips {
            LibraryFilterBar(
                searchText: $searchText,
                searchPrompt: "Search bookmarks",
                resultCount: filteredBookmarks.count,
                totalCount: store.bookmarks.count
            ) {
                typeChipRow
            }
        } else {
            LibraryFilterBar(
                searchText: $searchText,
                searchPrompt: "Search bookmarks",
                resultCount: filteredBookmarks.count,
                totalCount: store.bookmarks.count
            )
        }
    }

    @ViewBuilder
    private var gallery: some View {
        if filteredBookmarks.isEmpty {
            IllustratedEmptyState(
                symbol: "magnifyingglass",
                title: "No bookmarks match your search",
                message: "Try a different keyword, or clear the search field to see every saved wallpaper."
            )
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(filteredBookmarks) { bookmark in
                        BookmarkTile(
                            bookmark: bookmark,
                            screens: screenManager.screens,
                            isRenaming: renamingID == bookmark.id,
                            renameDraft: $renameDraft,
                            onApply: { screen in apply(bookmark, to: screen) },
                            onApplyToAll: { applyToAll(bookmark) },
                            onStartRename: {
                                renamingID = bookmark.id
                                renameDraft = bookmark.label
                            },
                            onCommitRename: {
                                store.rename(bookmark.id, to: renameDraft)
                                renamingID = nil
                            },
                            onCancelRename: { renamingID = nil },
                            onDelete: {
                                pendingDestructive = PendingDestructive(
                                    .deleteBookmark(bookmarkName: bookmark.label)
                                ) { store.remove(bookmark.id) }
                            }
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
        }
    }

    private var typeChipRow: some View {
        HStack(spacing: 6) {
            FilterChip(title: Text("All"),
                       isSelected: typeFilter == .all,
                       action: { typeFilter = .all })

            ForEach(WallpaperType.allCases) { type in
                if availableTypes.contains(type) {
                    FilterChip(title: Text(type.titleKey),
                               isSelected: typeFilter == .type(type),
                               action: { typeFilter = .type(type) })
                }
            }
        }
    }

    private var emptyState: some View {
        IllustratedEmptyState(
            symbol: "bookmark",
            title: "No bookmarks yet",
            message: "Open any display, configure a video / website / shader, then click the bookmark icon in the inspector header to save it here."
        )
    }

    // MARK: - Filtering

    private var showsTypeChips: Bool {
        store.bookmarks.count > Self.typeChipsThreshold && availableTypes.count > 1
    }

    private var availableTypes: Set<WallpaperType> {
        Set(store.bookmarks.map(\.wallpaperType))
    }

    private var filteredBookmarks: [WallpaperBookmark] {
        var result = store.bookmarks
        // Only honor the type filter while the chip row is visible AND that
        // type is still present — otherwise the user can land in an invisible
        // filter (e.g. they pick "HTML", delete bookmarks until count ≤ 6 or
        // until no HTML bookmarks remain, and the grid silently goes blank).
        if showsTypeChips, case .type(let type) = typeFilter, availableTypes.contains(type) {
            result = result.filter { $0.wallpaperType == type }
        }
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            result = result.filter { $0.label.localizedCaseInsensitiveContains(trimmed) }
        }
        return result
    }

    // MARK: - Apply

    private func apply(_ bookmark: WallpaperBookmark, to screen: Screen) {
        screenManager.applyBookmark(bookmark, to: screen)
    }

    private func applyToAll(_ bookmark: WallpaperBookmark) {
        Logger.info("Applying bookmark to all displays: \(bookmark.wallpaperType.rawValue)", category: .ui)
        for screen in screenManager.screens {
            apply(bookmark, to: screen)
        }
    }
}

// MARK: - Type filter

private enum BookmarkTypeFilter: Hashable {
    case all
    case type(WallpaperType)
}

// MARK: - Tile

private struct BookmarkTile: View {
    let bookmark: WallpaperBookmark
    let screens: [Screen]
    let isRenaming: Bool
    @Binding var renameDraft: String
    let onApply: (Screen) -> Void
    let onApplyToAll: () -> Void
    let onStartRename: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            thumbnailTile
            metadata
        }
        .contextMenu { contextMenu }
        .task(id: bookmark.id) { await loadThumbnail() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityActions {
            if screens.count == 1, let only = screens.first {
                Button("Apply") { onApply(only) }
            } else if screens.count > 1 {
                Button("Apply to All Displays", action: onApplyToAll)
            }
            Button("Rename", action: onStartRename)
        }
        .accessibilityAction(.delete, onDelete)
    }

    private var accessibilityLabel: Text {
        // %1$@ bookmark label, %2$@ localized wallpaper type.
        Text("\(bookmark.label), \(Text(bookmark.wallpaperType.titleKey)) wallpaper bookmark",
             comment: "Bookmark tile accessibility label. %1$@ is the bookmark name, %2$@ is the localized wallpaper type (Video / HTML / Shader / Scene).")
    }

    // MARK: Thumbnail tile

    private var thumbnailTile: some View {
        ZStack {
            tileBackground
            tileContent
            typeBadge
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .galleryTileChrome(isHovering: isHovering)
        .onHover { isHovering = $0 }
    }

    private var tileBackground: some View {
        Rectangle()
            .fill(bookmark.presentationTint.opacity(0.12))
    }

    @ViewBuilder
    private var tileContent: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
        } else {
            Image(systemName: bookmark.iconName)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(bookmark.presentationTint.opacity(0.85))
        }
    }

    /// Small icon-only chip in the top-leading corner, only shown when a real
    /// thumbnail is loaded — the SF Symbol fallback already conveys the type
    /// when there's no thumbnail, so the badge would be redundant noise there.
    /// Forced-dark `ultraThinMaterial` mirrors the Photos / Apple TV metadata
    /// chip language so the badge sits on the artwork without competing with it.
    private var typeBadge: some View {
        VStack {
            HStack {
                Image(systemName: bookmark.iconName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(.ultraThinMaterial, in: Circle())
                    .environment(\.colorScheme, .dark)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
                    .padding(7)
                Spacer()
            }
            Spacer()
        }
        .opacity(thumbnail == nil ? 0 : 1)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var applyControl: some View {
        if screens.count == 1, let only = screens.first {
            Button { onApply(only) } label: { applyIcon }
            .buttonStyle(.plain)
            .help(Text("Apply"))
        } else if screens.count > 1 {
            Menu {
                ForEach(screens, id: \.id) { screen in
                    Button("Apply to \(screen.name)") { onApply(screen) }
                }
                Divider()
                Button("Apply to All Displays", action: onApplyToAll)
            } label: { applyIcon }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(Text("Apply"))
        }
    }

    private var applyIcon: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(Circle().fill(bookmark.presentationTint.opacity(0.95)))
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }

    private var deleteButton: some View {
        Button(role: .destructive, action: onDelete) {
            Image(systemName: "trash")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text("Delete bookmark"))
    }

    // MARK: Metadata

    private var metadata: some View {
        HStack(alignment: .center, spacing: 8) {
            textBlock
            Spacer(minLength: 4)
            if !isRenaming {
                HStack(spacing: 4) {
                    applyControl
                    deleteButton
                }
            }
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private var textBlock: some View {
        if isRenaming {
            renameField
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Button(action: onStartRename) {
                    Text(verbatim: bookmark.label)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text("Rename"))
                bookmark.subtitleText
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var renameField: some View {
        HStack(spacing: 4) {
            TextField("Name", text: $renameDraft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .onSubmit(onCommitRename)
                .onExitCommand(perform: onCancelRename)
            Button(action: onCommitRename) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.defaultAction)
            .help(Text("Save"))
            Button(action: onCancelRename) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(Text("Cancel"))
        }
    }

    // MARK: Thumbnail loader

    /// Run via `.task(id: bookmark.id)` — SwiftUI cancels this when the bookmark
    /// id changes or the tile leaves the viewport, freeing the thumbnail decode
    /// work + security-scoped bookmark resolve when the user fast-scrolls the
    /// gallery.
    @MainActor
    private func loadThumbnail() async {
        thumbnail = nil

        if let cached = WallpaperThumbnailService.shared.cachedThumbnail(forKey: bookmarkCacheKey) {
            thumbnail = cached
            return
        }

        switch bookmark.content {
        case .video(let bookmarkData):
            guard case .success(let resolved) = SecurityScopedBookmarkResolver.shared.resolve(
                bookmarkData,
                target: .transient
            ) else { return }
            guard !Task.isCancelled else { return }
            if let image = await WallpaperThumbnailService.shared.videoPosterImage(
                for: resolved.url,
                cacheKey: bookmarkCacheKey
            ), !Task.isCancelled {
                thumbnail = image
            }
        case .html(let source, _):
            if let image = await HTMLPreviewKey.fetchSnapshot(
                for: source,
                cacheKey: bookmarkCacheKey
            ), !Task.isCancelled {
                thumbnail = image
            }
        case .metalShader, .scene:
            break
        }
    }

    private var bookmarkCacheKey: String {
        "bookmark::" + bookmark.id.uuidString
    }

    // MARK: Context menu

    @ViewBuilder
    private var contextMenu: some View {
        if !screens.isEmpty {
            ForEach(screens, id: \.id) { screen in
                Button("Apply to \(screen.name)") { onApply(screen) }
            }
            if screens.count > 1 {
                Button("Apply to All Displays", action: onApplyToAll)
            }
            Divider()
        }
        Button("Rename", action: onStartRename)
        Button("Delete", role: .destructive, action: onDelete)
    }
}
