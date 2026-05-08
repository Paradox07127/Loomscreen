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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            saveCurrentRow
            Divider()
            list
        }
        .padding(14)
        .frame(width: 340)
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
            VStack(alignment: .leading, spacing: 6) {
                Text("Save current wallpaper")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    TextField(BookmarkStore.defaultLabel(for: content), text: $addLabel)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                    Button {
                        store.add(label: addLabel, content: content)
                        addLabel = ""
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 16))
                    }
                    .buttonStyle(.plain)
                    .disabled(store.contains(content))
                    .help(store.contains(content)
                        ? Text("Already bookmarked", comment: "Tooltip when the current wallpaper is already saved as a bookmark.")
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
            HStack {
                Spacer()
                VStack(spacing: 4) {
                    Image(systemName: "bookmark")
                        .font(.system(size: 22))
                        .foregroundStyle(.tertiary)
                    Text("No bookmarks yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 16)
                Spacer()
            }
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
                            onDelete: { store.remove(bookmark.id) }
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

    private func apply(_ bookmark: WallpaperBookmark) {
        switch bookmark.content {
        case .video(let bookmarkData):
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else {
                Logger.warning("Bookmark video unresolvable; user may need to re-pick", category: .fileAccess)
                return
            }
            screenManager.setVideo(url: url, bookmarkData: bookmarkData, for: screen)
        case .html(let source, let config):
            screenManager.setHTMLWallpaper(source: source, config: config, for: screen)
        case .metalShader(let preset):
            screenManager.setShaderWallpaper(preset: preset, for: screen)
        case .scene:
            // Scene bookmarks are not yet user-applicable from the popover —
            // the import flow owns SceneDescriptor lifecycle. Surface a log
            // for diagnostics and ignore so we never hand a stale descriptor
            // to ScreenManager without going through the import service.
            Logger.warning("Scene bookmark apply is not supported in Phase 2.0", category: .screenManager)
        }
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
                .foregroundStyle(iconColor)
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
                    Text(bookmark.label)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(subtitle)
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
            .help(Text("Delete bookmark"))
        }
    }

    private var iconColor: Color {
        switch bookmark.content {
        case .video: return .blue
        case .html: return .green
        case .metalShader: return .purple
        case .scene: return .orange
        }
    }

    private var subtitle: String {
        switch bookmark.content {
        case .video(let data):
            return ResourceUtilities.resolveBookmarkName(data) ?? "Source missing"
        case .html(let source, _):
            return source.displayName
        case .metalShader(let preset):
            return preset.rawValue
        case .scene(let descriptor):
            return "Workshop \(descriptor.workshopID)"
        }
    }
}
