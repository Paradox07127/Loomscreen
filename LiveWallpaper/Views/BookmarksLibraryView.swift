import SwiftUI

/// Sidebar-routed full-page browser for saved wallpaper bookmarks.
struct BookmarksLibraryView: View {
    @Environment(ScreenManager.self) private var screenManager
    @State private var store = BookmarkStore.shared
    @State private var renamingID: UUID? = nil
    @State private var renameDraft: String = ""
    @State private var searchText: String = ""
    @State private var pendingDestructive: PendingDestructive?

    private let columns = [GridItem(.adaptive(minimum: 260), spacing: 12)]

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
            title: {
                Text("Bookmarks")
            },
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
            actions: {
                TextField("Search…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .accessibilityLabel(Text("Search bookmarks"))
            }
        )
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if store.bookmarks.isEmpty {
            emptyState
        } else if filteredBookmarks.isEmpty {
            IllustratedEmptyState(
                symbol: "magnifyingglass",
                title: "No bookmarks match your search",
                message: "Try a different keyword, or clear the search field to see every saved wallpaper."
            )
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(filteredBookmarks) { bookmark in
                        BookmarkCard(
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
                .padding(20)
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

    private var filteredBookmarks: [WallpaperBookmark] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return store.bookmarks }
        return store.bookmarks.filter {
            $0.label.localizedCaseInsensitiveContains(trimmed)
        }
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

// MARK: - Card

private struct BookmarkCard: View {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            footer
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(isHovering ? 0.18 : 0.06), lineWidth: 1)
        )
        .scaleEffect(isHovering ? 1.01 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: isHovering)
        .onHover { isHovering = $0 }
        .contextMenu { contextMenu }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(bookmark.presentationTint.opacity(0.15))
                    .frame(width: 38, height: 38)
                Image(systemName: bookmark.iconName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(bookmark.presentationTint)
            }

            VStack(alignment: .leading, spacing: 2) {
                if isRenaming {
                    TextField("Name", text: $renameDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                        .onSubmit(onCommitRename)
                } else {
                    Text(verbatim: bookmark.label)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
                bookmark.subtitleText
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            applyMenu
            Spacer()
            if isRenaming {
                Button("Save", action: onCommitRename)
                    .controlSize(.mini)
                    .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel, action: onCancelRename)
                    .controlSize(.mini)
            } else {
                Button(action: onStartRename) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help(Text("Rename"))

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .destructiveControlTint()
                .help(Text("Delete bookmark"))
            }
        }
    }

    @ViewBuilder
    private var applyMenu: some View {
        if screens.count <= 1, let only = screens.first {
            Button {
                onApply(only)
            } label: {
                Label("Apply", systemImage: "play.fill")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        } else if !screens.isEmpty {
            Menu {
                ForEach(screens, id: \.id) { screen in
                    Button("Apply to \(screen.name)") { onApply(screen) }
                }
                Divider()
                Button("Apply to All Displays", action: onApplyToAll)
            } label: {
                Label("Apply", systemImage: "play.fill")
                    .font(.system(size: 11, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()
        } else {
            Text("No display").font(.caption2).foregroundStyle(.secondary)
        }
    }

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
