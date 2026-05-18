import SwiftUI

/// Popover surfaced from the inspector header — adds the current wallpaper
/// to bookmarks and lists existing bookmarks so any of them can be re-applied.
struct BookmarksPopover: View {
    let screen: Screen

    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.dismiss) private var dismiss

    @State private var store = BookmarkStore.shared
    @State private var addLabel: String = ""
    @State private var renamingID: UUID? = nil
    @State private var renameDraft: String = ""
    @State private var pendingDestructive: PendingDestructive?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            saveCurrentRow
            Divider()
            list
        }
        .padding(14)
        .frame(width: 340)
        // Cap popover height. macOS 26 `.popover` lets a child without an
        // explicit height grow to fit the entire detail area, which overlaps
        // the inspector and (when sidebar is collapsed) the dashboard column.
        .frame(minHeight: 220, maxHeight: 480)
        .presentationCompactAdaptation(.popover)
        .confirmDestructive($pendingDestructive)
    }

    private var header: some View {
        HStack {
            Label("Bookmarks", systemImage: "bookmark.fill")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Text("\(store.bookmarks.count)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var saveCurrentRow: some View {
        if let content = currentContent() {
            let snapshot = currentPlaybackSettings()
            let duplicate = store.equivalentBookmark(content: content)
            VStack(alignment: .leading, spacing: 6) {
                Text("Save current wallpaper")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    TextField(defaultLabel(for: content), text: $addLabel)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                    Button {
                        store.add(
                            label: addLabel,
                            content: content,
                            sourceDisplayName: sourceDisplayName(for: content),
                            playbackSettings: snapshot
                        )
                        addLabel = ""
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 16))
                    }
                    .buttonStyle(.plain)
                    .disabled(duplicate != nil)
                    .help(duplicate != nil
                        ? Text("Already saved as “\(duplicate?.label ?? "")”", comment: "Tooltip when an identical plan is already bookmarked. The placeholder is the existing bookmark's label.")
                        : Text("Save as bookmark", comment: "Tooltip for the button that saves the current wallpaper as a bookmark."))
                }
            }
        } else {
            Text("Configure a wallpaper first to bookmark it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var list: some View {
        if store.bookmarks.isEmpty {
            IllustratedEmptyState(
                symbol: "bookmark",
                title: "No bookmarks yet",
                message: "Save a wallpaper from the form above and it shows up here.",
                variant: .compact
            )
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(store.bookmarks) { bookmark in
                        BookmarkRow(
                            bookmark: bookmark,
                            isRenaming: renamingID == bookmark.id,
                            renameDraft: $renameDraft,
                            onApply: {
                                apply(bookmark)
                                dismiss()
                            },
                            onStartRename: {
                                renamingID = bookmark.id
                                renameDraft = bookmark.label
                            },
                            onCommitRename: {
                                store.rename(bookmark.id, to: renameDraft)
                                renamingID = nil
                            },
                            onCancelRename: {
                                renamingID = nil
                            },
                            onDelete: {
                                pendingDestructive = PendingDestructive(
                                    .deleteBookmark(bookmarkName: bookmark.label)
                                ) { store.remove(bookmark.id) }
                            }
                        )
                    }
                }
            }
            .frame(maxHeight: 260)
        }
    }

    private func currentContent() -> WallpaperContent? {
        screenManager.getConfiguration(for: screen)?.activeWallpaper
    }

    /// Snapshot the screen's full playback + effect state so the bookmark
    /// captures a complete plan, not just the content pointer.
    private func currentPlaybackSettings() -> BookmarkPlaybackSettings? {
        guard let config = screenManager.getConfiguration(for: screen) else { return nil }
        return BookmarkPlaybackSettings.snapshot(of: config)
    }

    private func defaultLabel(for content: WallpaperContent) -> String {
        BookmarkStore.defaultLabel(
            for: content,
            sourceDisplayName: sourceDisplayName(for: content)
        )
    }

    private func sourceDisplayName(for content: WallpaperContent) -> String? {
        switch content {
        case .video(let bookmarkData):
            return screenManager.bookmarkDisplayName(for: bookmarkData)
        case .html(let source, _):
            return source.displayName
        case .metalShader(let preset):
            return preset.localizedTitle
        case .scene(let descriptor):
            return String(localized: "Scene \(descriptor.workshopID)", comment: "Bookmark source label for a Wallpaper Engine scene. The placeholder is the Workshop ID.")
        }
    }

    private func apply(_ bookmark: WallpaperBookmark) {
        screenManager.applyBookmark(bookmark, to: screen)
    }
}

// MARK: - Row

private struct BookmarkRow: View {
    let bookmark: WallpaperBookmark
    let isRenaming: Bool
    @Binding var renameDraft: String
    let onApply: () -> Void
    let onStartRename: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: bookmark.iconName)
                .font(.system(size: 13))
                .foregroundStyle(bookmark.presentationTint)
                .frame(width: 18)

            if isRenaming {
                TextField("Name", text: $renameDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit(onCommitRename)
                Button("Save", action: onCommitRename)
                    .controlSize(.mini)
                    .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel, action: onCancelRename)
                    .controlSize(.mini)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: bookmark.label)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    bookmark.subtitleText
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                actionButtons
                    .opacity(isHovering ? 1 : 0.55)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? Color.primary.opacity(0.07) : Color.clear)
        )
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Apply", action: onApply)
            Button("Rename", action: onStartRename)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 6) {
            Button(action: onApply) {
                Image(systemName: "play.fill")
                    .font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .help(Text("Apply to this display"))

            Button(action: onStartRename) {
                Image(systemName: "pencil")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help(Text("Rename"))

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .destructiveControlTint()
            .help(Text("Delete bookmark"))
        }
    }

}
