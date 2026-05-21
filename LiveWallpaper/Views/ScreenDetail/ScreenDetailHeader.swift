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
                        Image(systemName: "bookmark.fill")
                    }
                    .adaptiveGlassButton(.regular)
                    .controlSize(.regular)
                    .help(Text("Bookmarks — saved video / HTML / shader shortcuts"))
                    .accessibilityLabel(Text("Bookmarks"))
                    .popover(isPresented: $showBookmarks, arrowEdge: .bottom) {
                        BookmarksPopover(screen: screen)
                            .environment(screenManager)
                    }

                    if showsHeaderWallpaperActions {
                        HStack(spacing: 8) {
                            if draft.selectedWallpaperType == .video {
                                Button(action: onSelectVideo) {
                                    Image(systemName: "folder.badge.plus")
                                }
                                .adaptiveGlassButton(.prominent)
                                .controlSize(.regular)
                                .help(Text("Select Video — choose a video file for this display"))
                                .accessibilityLabel(Text("Select video"))
                                .accessibilityHint(Text("Opens a file picker to choose a wallpaper video"))
                            }

                            Button(role: .destructive, action: onClearWallpaper) {
                                Image(systemName: "trash")
                            }
                            .adaptiveGlassButton(.regular)
                            .destructiveControlTint()
                            .controlSize(.regular)
                            .help(Text("Clear Wallpaper — remove the current wallpaper without deleting source files"))
                            .accessibilityLabel(Text("Clear current wallpaper"))
                            .accessibilityHint(Text("Removes the current wallpaper from this screen without deleting source files or library items"))
                        }
                    }
                }
            }
        )
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
        guard wallpaperSessionSummary.isConfigured else {
            return "Not configured"
        }
        return wallpaperSessionSummary.activity == .active ? "Playing" : "Paused"
    }

    private var sessionStatusColor: Color {
        switch wallpaperSessionSummary.activity {
        case .active:   return .green
        case .paused:   return .orange
        case .inactive: return .secondary
        }
    }
}
