import SwiftUI
import AppKit

/// Menu-bar window content. Intentionally minimal: one row per display showing
/// the current wallpaper plus the two actions a user actually needs from the
/// menu bar (toggle playback, jump into Settings). Anything richer — effects,
/// bookmarks, snooze, system monitor — lives inside the main Settings window
/// where there's room for it.
struct MenuBarContent: View {
    let openSettings: () -> Void
    let openSettingsForScreen: (CGDirectDisplayID) -> Void
    let promptAddWallpaper: (String) -> Void

    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            header
            Divider()
            screenList
            Divider()
            footer
        }
        .padding(DesignTokens.Spacing.md)
        .frame(width: 300)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "play.rectangle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.accentColor)
                .font(.system(size: 16))
                .accessibilityHidden(true)

            Text("LiveWallpaper")
                .font(.system(size: 13, weight: .semibold))

            Spacer()

            Text(versionString)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Screen list

    @ViewBuilder
    private var screenList: some View {
        if screenManager.screens.isEmpty {
            emptyDisplaysState
        } else {
            VStack(spacing: DesignTokens.Spacing.sm) {
                ForEach(screenManager.screens, id: \.id) { screen in
                    MenuBarScreenRow(
                        screen: screen,
                        onConfigure: { invokeOpenSettingsForScreen(screen.id) }
                    )
                }
            }
        }
    }

    private var emptyDisplaysState: some View {
        VStack(spacing: 6) {
            Image(systemName: "display.trianglebadge.exclamationmark")
                .font(.system(size: 18))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            Text("No displays detected")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Button(action: invokeOpenSettings) {
                Label {
                    Text("Settings")
                } icon: {
                    Image(systemName: "gearshape")
                        .symbolRenderingMode(.hierarchical)
                }
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .keyboardShortcut(",", modifiers: .command)
            .help(Text("Open settings"))

            Button(action: { screenManager.reloadAllScreens() }) {
                Label {
                    Text("Reload")
                } icon: {
                    Image(systemName: "arrow.clockwise")
                        .symbolRenderingMode(.hierarchical)
                }
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .keyboardShortcut("r", modifiers: .command)
            .help(Text("Reload all wallpapers"))

            Spacer(minLength: 0)

            Button(role: .destructive, action: { NSApp.terminate(nil) }) {
                Label {
                    Text("Quit")
                } icon: {
                    Image(systemName: "power")
                        .symbolRenderingMode(.hierarchical)
                }
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .keyboardShortcut("q", modifiers: .command)
            .help(Text("Quit LiveWallpaper"))
        }
    }

    // MARK: - Helpers

    private func invokeOpenSettings() {
        dismiss()
        openSettings()
    }

    private func invokeOpenSettingsForScreen(_ id: CGDirectDisplayID) {
        dismiss()
        openSettingsForScreen(id)
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        return "v\(version)"
    }
}

// MARK: - Per-screen row

/// One row per display. Configured screens show the wallpaper name + state
/// plus play/pause + configure buttons. Unconfigured screens show a single
/// prominent CTA so the user always knows where to start.
private struct MenuBarScreenRow: View {
    let screen: Screen
    let onConfigure: () -> Void

    @Environment(ScreenManager.self) private var screenManager

    var body: some View {
        let summary = screenManager.wallpaperSummary(for: screen)
        VStack(alignment: .leading, spacing: 6) {
            titleRow(summary: summary)
            actionRow(summary: summary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: DesignTokens.Corner.md))
    }

    // MARK: Title + status

    private func titleRow(summary: WallpaperSessionSummary) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: deviceIcon)
                .font(.system(size: 13))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(statusColor(summary: summary))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(screen.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(subtitle(summary: summary))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Actions

    @ViewBuilder
    private func actionRow(summary: WallpaperSessionSummary) -> some View {
        if summary.isConfigured {
            HStack(spacing: 6) {
                if summary.supportsPlaybackControl {
                    Button(action: togglePlayback) {
                        Label {
                            Text(summary.activity == .active ? "Pause" : "Play")
                        } icon: {
                            Image(systemName: summary.activity == .active ? "pause.fill" : "play.fill")
                                .symbolRenderingMode(.hierarchical)
                                .contentTransition(.symbolEffect(.replace))
                        }
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .help(summary.activity == .active
                          ? Text("Pause this display")
                          : Text("Play this display"))
                }

                Spacer(minLength: 0)

                Button(action: onConfigure) {
                    Label {
                        Text("Configure")
                    } icon: {
                        Image(systemName: "slider.horizontal.3")
                            .symbolRenderingMode(.hierarchical)
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help(Text("Open settings for this display"))
            }
        } else {
            Button(action: onConfigure) {
                Label {
                    Text("Choose a wallpaper…")
                } icon: {
                    Image(systemName: "plus.rectangle.on.rectangle")
                        .symbolRenderingMode(.hierarchical)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.small)
            .help(Text("Open settings to set a wallpaper for this display"))
        }
    }

    // MARK: Helpers

    private func togglePlayback() {
        guard let playback = screen.playbackController else { return }
        PlaybackToggle.toggle(playback)
    }

    private var deviceIcon: String {
        CGDisplayIsBuiltin(screen.id) != 0 ? "laptopcomputer" : "display"
    }

    private func subtitle(summary: WallpaperSessionSummary) -> String {
        switch (summary.wallpaperType, summary.activity) {
        case (nil, _):
            return String(localized: "No wallpaper yet")
        case (.video, .active):
            return wallpaperName() ?? String(localized: "Playing video")
        case (.video, .paused):
            return wallpaperName().map { String(localized: "Paused — \($0)") } ?? String(localized: "Paused")
        case (.video, .inactive):
            return String(localized: "Not playing")
        case (.html, .active):
            return wallpaperName() ?? String(localized: "Web page")
        case (.html, .paused), (.html, .inactive):
            return wallpaperName() ?? String(localized: "Web page")
        case (.metalShader, _):
            return wallpaperName() ?? String(localized: "Shader")
        case (.scene, _):
            return wallpaperName() ?? String(localized: "Scene")
        }
    }

    private func wallpaperName() -> String? {
        guard let cfg = screenManager.getConfiguration(for: screen) else { return nil }
        switch cfg.activeWallpaper {
        case .video:
            let cursor = cfg.playlistCursorIndex ?? 0
            let combined = [cfg.savedVideoBookmarkData].compactMap { $0 } + (cfg.playlistBookmarks ?? [])
            if cursor < combined.count {
                return ResourceUtilities.resolveBookmarkName(combined[cursor])
            }
            return cfg.savedVideoBookmarkData.flatMap { ResourceUtilities.resolveBookmarkName($0) }
        case .html(let source, _):
            return source.displayName
        case .metalShader(let preset):
            return preset.rawValue
        case .scene(let descriptor):
            return "Scene \(descriptor.workshopID)"
        }
    }

    private func statusColor(summary: WallpaperSessionSummary) -> Color {
        switch summary.activity {
        case .active: return .accentColor
        case .paused: return .orange
        case .inactive: return .secondary
        }
    }
}

// MARK: - Shared playback toggle

@MainActor
enum PlaybackToggle {
    static func toggle(_ playback: any WallpaperPlaybackControllable) {
        if playback.isPlaying {
            playback.pause()
        } else {
            playback.play()
        }
    }
}
