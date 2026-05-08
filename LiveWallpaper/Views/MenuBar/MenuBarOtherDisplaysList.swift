import SwiftUI

/// Compact rows for every other (non-selected) display. Surfaces only when
/// 3 or more displays are connected — with two displays the segmented tab
/// bar already reveals the second screen.
struct MenuBarOtherDisplaysList: View {
    let screens: [Screen]
    let selectedScreenID: CGDirectDisplayID
    let openSettingsForScreen: (CGDirectDisplayID) -> Void

    @Environment(ScreenManager.self) private var screenManager

    var body: some View {
        let others = screens.filter { $0.id != selectedScreenID }
        if !others.isEmpty {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                MenuBarSectionHeader(title: "Other Displays")
                ForEach(others, id: \.id) { screen in
                    OtherDisplayRow(
                        screen: screen,
                        summary: screenManager.wallpaperSummary(for: screen),
                        openSettingsForScreen: openSettingsForScreen
                    )
                }
            }
        }
    }
}

private struct OtherDisplayRow: View {
    let screen: Screen
    let summary: WallpaperSessionSummary
    let openSettingsForScreen: (CGDirectDisplayID) -> Void

    @Environment(ScreenManager.self) private var screenManager

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: screen.isBuiltin ? "laptopcomputer" : "display")
                .font(.system(size: 12))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(screen.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Text(activityLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if summary.supportsPlaybackControl {
                Button(action: togglePlayback) {
                    Image(systemName: summary.activity == .active ? "pause.fill" : "play.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .frame(width: 22, height: 22)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .help(summary.activity == .active
                    ? Text("Pause", comment: "Tooltip for pausing wallpaper on a secondary display.")
                    : Text("Play", comment: "Tooltip for resuming wallpaper on a secondary display."))
                .accessibilityLabel(summary.activity == .active
                    ? Text("Pause \(screen.name)", comment: "A11y label to pause wallpaper on a specific display; %@ is display name.")
                    : Text("Play \(screen.name)", comment: "A11y label to resume wallpaper on a specific display; %@ is display name."))
            }

            Button {
                openSettingsForScreen(screen.id)
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 10))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(Text("Configure \(screen.name)"))
            .accessibilityLabel(Text("Open settings for \(screen.name)"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: DesignTokens.Corner.md))
    }

    private var activityLabel: String {
        switch summary.activity {
        case .active: return "Playing"
        case .paused: return "Paused"
        case .inactive: return "Not configured"
        }
    }

    private func togglePlayback() {
        guard let playback = screen.playbackController else { return }
        PlaybackToggle.toggle(playback)
    }
}
