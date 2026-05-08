import SwiftUI

/// Liquid-Glass transport bar overlaid on the hero card.
/// Bundles play/pause, prev/next (video only), mute, and speed (video only)
/// into one `GlassEffectContainer` so adjacent button presses morph fluidly.
struct MenuBarTransportCapsule: View {
    let screen: Screen

    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    var body: some View {
        let summary = screenManager.wallpaperSummary(for: screen)
        let isVideo = summary.wallpaperType == .video
        let isPlaying = summary.activity == .active

        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 4) {
                if isVideo, hasPlaylist {
                    iconButton("backward.fill", help: "Previous video") {
                        screenManager.regressPlaylist(for: screen)
                    }
                }

                playPauseButton(isPlaying: isPlaying)

                if isVideo, hasPlaylist {
                    iconButton("forward.fill", help: "Next video") {
                        screenManager.advancePlaylist(for: screen)
                    }
                }

                iconButton(
                    isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    help: isMuted ? "Unmute" : "Mute",
                    action: toggleMute
                )

                if isVideo {
                    speedMenu
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Wallpaper transport"))
    }

    // MARK: - Buttons

    @ViewBuilder
    private func iconButton(
        _ name: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 12, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .help(help)
        .accessibilityLabel(help)
    }

    @ViewBuilder
    private func playPauseButton(isPlaying: Bool) -> some View {
        Button(action: togglePlayPause) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 14, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 32, height: 32)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular.tint(Color.accentColor.opacity(0.35)).interactive(),
            in: .circle
        )
        .help(isPlaying
            ? Text("Pause", comment: "Tooltip for the playback toggle when video is playing.")
            : Text("Play", comment: "Tooltip for the playback toggle when video is paused."))
        .accessibilityLabel(isPlaying
            ? Text("Pause", comment: "A11y label for playback toggle when playing.")
            : Text("Play", comment: "A11y label for playback toggle when paused."))
    }

    @ViewBuilder
    private var speedMenu: some View {
        Menu {
            ForEach(Self.speeds, id: \.self) { value in
                Button {
                    screenManager.updatePlaybackSpeed(value, for: screen)
                } label: {
                    Text(formatSpeed(value))
                    if abs(value - currentSpeed) < 0.01 {
                        Image(systemName: "checkmark")
                    }
                }
            }
        } label: {
            Text(formatSpeed(currentSpeed))
                .font(.system(size: 11, design: .rounded))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .glassEffect(.regular.interactive(), in: .capsule)
        .help(Text("Playback speed"))
        .accessibilityLabel(Text("Playback speed \(formatSpeed(currentSpeed))"))
    }

    // MARK: - State

    private var hasPlaylist: Bool {
        guard let cfg = screenManager.getConfiguration(for: screen) else { return false }
        return (cfg.playlistBookmarks?.isEmpty == false)
    }

    private var isMuted: Bool {
        guard let cfg = screenManager.getConfiguration(for: screen) else { return true }
        if let html = cfg.htmlConfig { return html.muteAudio }
        return cfg.muted
    }

    private var currentSpeed: Double {
        screenManager.getConfiguration(for: screen)?.playbackSpeed ?? 1.0
    }

    // MARK: - Actions

    private func togglePlayPause() {
        if let playback = screen.playbackController {
            PlaybackToggle.toggle(playback)
        }
    }

    private func toggleMute() {
        guard let cfg = screenManager.getConfiguration(for: screen) else { return }
        if let html = cfg.htmlConfig {
            var updated = html
            updated.muteAudio.toggle()
            screenManager.updateHTMLConfig(updated, for: screen)
        } else {
            screenManager.updateMuted(!cfg.muted, for: screen)
        }
    }

    private func formatSpeed(_ value: Double) -> String {
        String(format: value.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f×" : "%.2f×", value)
    }
}
