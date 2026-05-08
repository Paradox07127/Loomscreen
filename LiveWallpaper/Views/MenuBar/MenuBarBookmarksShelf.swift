import SwiftUI

/// Small caption above each section. macOS 26 typography: secondary, 11pt
/// medium, no ALL CAPS / no tracking — matches the rest of the app.
struct MenuBarSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Horizontal shelf of bookmark tiles. Tapping any tile applies that
/// wallpaper to the selected screen using the existing dispatch logic shared
/// with `BookmarksPopover`. Empty state nudges the user toward saving the
/// current wallpaper from the inspector header.
struct MenuBarBookmarksShelf: View {
    let screen: Screen

    @Environment(ScreenManager.self) private var screenManager
    @State private var store = BookmarkStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            MenuBarSectionHeader(title: "Bookmarks")
            if store.bookmarks.isEmpty {
                emptyState
            } else {
                shelf
            }
        }
    }

    private var shelf: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(store.bookmarks.prefix(12)) { bookmark in
                    BookmarkTile(bookmark: bookmark) {
                        apply(bookmark)
                    }
                }
            }
            .padding(.vertical, 1)
        }
    }

    private var emptyState: some View {
        HStack(spacing: 6) {
            Image(systemName: "bookmark")
                .font(.system(size: 11))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            Text("Save bookmarks from a display's inspector to apply them here.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: DesignTokens.Corner.md))
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
                Logger.warning(
                    "Bookmark video unresolvable from menu bar shelf",
                    category: .fileAccess
                )
                return
            }
            screenManager.setVideo(url: url, bookmarkData: bookmarkData, for: screen)
        case .html(let source, _):
            // Preserve the screen's existing HTMLConfig — applying a saved
            // source should not silently flip mute / JS / overscroll knobs
            // the user customised on this display.
            screenManager.setHTMLWallpaperPreservingConfig(source: source, for: screen)
        case .metalShader(let preset):
            screenManager.setShaderWallpaper(preset: preset, for: screen)
        case .scene:
            Logger.warning("Scene bookmarks are not yet user-applicable", category: .screenManager)
        }
    }
}

private struct BookmarkTile: View {
    let bookmark: WallpaperBookmark
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: bookmark.iconName)
                    .font(.system(size: 16))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(iconColor)
                Text(bookmark.label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(width: 80, height: 50)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: DesignTokens.Corner.sm))
        .help("Apply \(bookmark.label)")
        .accessibilityLabel("Apply bookmark \(bookmark.label)")
    }

    private var iconColor: Color {
        switch bookmark.content {
        case .video: return .blue
        case .html: return .green
        case .metalShader: return .purple
        case .scene: return .orange
        }
    }
}
