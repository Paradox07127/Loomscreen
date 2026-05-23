import LiveWallpaperCore
import LiveWallpaperSharedUI
import SwiftUI

struct ScreenDetailHeader: View {
    let screen: Screen
    @Binding var draft: ScreenDetailDraftState
    let screenManager: ScreenManager
    let wallpaperSessionSummary: WallpaperSessionSummary
    let reduceMotion: Bool
    let showsHeaderWallpaperActions: Bool
    @Binding var showBookmarks: Bool
    let onReload: () -> Void
    let onApplyToAll: () -> Void
    let onSelectVideo: () -> Void
    let onClearWallpaper: () -> Void

    var body: some View {
        DetailHeaderBar(
            systemImage: "display",
            title: {
                HStack(spacing: 8) {
                    Text(verbatim: screen.name)
                        .help(Text(verbatim: screen.name))

                    Button(action: onReload) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(Text("Reload display content"))
                    .accessibilityLabel(Text("Reload display"))
                    .accessibilityHint(Text("Reloads the wallpaper content for this screen"))
                }
            },
            metadata: {
                HStack(spacing: DesignTokens.DetailHeader.metadataSpacing) {
                    InfoBadge(icon: "arrow.up.left.and.arrow.down.right", text: "\(Int(screen.frame.width))×\(Int(screen.frame.height))")
                    InfoBadge(icon: "gauge.medium", text: "\(screenManager.getScreenRefreshRate(for: screen.id)) Hz")
                    if wallpaperSessionSummary.isConfigured {
                        HStack(spacing: 4) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 6))
                                .foregroundStyle(sessionStatusColor)
                                .symbolEffect(
                                    .pulse,
                                    options: .continuouslyRepeating,
                                    isActive: !reduceMotion && wallpaperSessionSummary.activity == .active
                                )
                            Text(sessionStatusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            },
            actions: {
                HStack(spacing: 8) {
                    applyToAllButton

                    Button {
                        showBookmarks = true
                    } label: {
                        Image(systemName: isCurrentBookmarked ? "bookmark.fill" : "bookmark")
                    }
                    .adaptiveGlassButton(isCurrentBookmarked ? .prominent : .regular)
                    .controlSize(.regular)
                    .help(Text(isCurrentBookmarked
                        ? "Bookmarked — click to rename or remove"
                        : "Bookmark this wallpaper"))
                    .accessibilityLabel(Text(isCurrentBookmarked ? "Bookmarked" : "Bookmark"))
                    .popover(isPresented: $showBookmarks, arrowEdge: .bottom) {
                        BookmarksPopover(screen: screen, candidateContent: inspectorContent)
                            .environment(screenManager)
                    }

                    if showsHeaderWallpaperActions {
                        overflowMenu
                    }
                }
            }
        )
    }

    private var overflowMenu: some View {
        Menu {
            if draft.selectedWallpaperType == .video {
                Button(action: onSelectVideo) {
                    Label("Select Video File…", systemImage: "folder.badge.plus")
                }
                Divider()
            }

            Button(role: .destructive, action: onClearWallpaper) {
                Label("Clear Wallpaper", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .adaptiveGlassButton(.regular)
        .controlSize(.regular)
        .help(Text("More actions for this display"))
        .accessibilityLabel(Text("More display actions"))
    }

    @ViewBuilder
    private var applyToAllButton: some View {
        if screenManager.screens.count > 1 && screenManager.getConfiguration(for: screen) != nil {
            Button(action: onApplyToAll) {
                Image(systemName: "square.on.square")
            }
            .help(Text("Apply to All — copy this display's wallpaper and settings to every other display"))
            .accessibilityLabel(Text("Apply to all displays"))
            .accessibilityHint(Text("Copies the current wallpaper and settings to every other connected display"))
            .adaptiveGlassButton(.regular)
            .controlSize(.regular)
        }
    }

    private var sessionStatusText: LocalizedStringKey {
        switch wallpaperSessionSummary.activity {
        case .active:   return "Playing"
        case .paused:   return "Paused"
        case .off:      return "Off"
        case .error:    return "Error"
        case .inactive: return "Not configured"
        }
    }

    private var sessionStatusColor: Color {
        switch wallpaperSessionSummary.activity {
        case .active:   return .green
        case .paused:   return .orange
        case .off:      return .secondary
        case .error:    return .red
        case .inactive: return .secondary
        }
    }

    /// Bookmarkable content for the inspector tab currently in view — not
    /// the committed `activeWallpaper`. Switching the inspector to a tab
    /// that has no content (e.g. HTML tab when no source has been set yet)
    /// returns nil, so the bookmark icon doesn't bleed state across types.
    private var inspectorContent: WallpaperContent? {
        let config = screenManager.getConfiguration(for: screen)
        switch draft.selectedWallpaperType {
        case .video:
            if case .video(let bookmark)? = config?.activeWallpaper {
                return .video(bookmarkData: bookmark)
            }
            if let saved = config?.savedVideoBookmarkData {
                return .video(bookmarkData: saved)
            }
            return nil
        case .html:
            guard let source = draft.htmlSource else { return nil }
            return .html(source: source, config: draft.htmlConfig)
        case .metalShader:
            return .metalShader(draft.selectedShaderSource)
        case .scene:
            if case .scene(let descriptor)? = config?.activeWallpaper {
                return .scene(descriptor)
            }
            return nil
        }
    }

    /// True when the inspector's current tab content matches an existing
    /// bookmark. Drives the bookmark.fill ↔ bookmark icon swap and the
    /// .prominent ↔ .regular glass-button chrome toggle.
    private var isCurrentBookmarked: Bool {
        guard let content = inspectorContent else { return false }
        return BookmarkStore.shared.equivalentBookmark(content: content) != nil
    }
}
