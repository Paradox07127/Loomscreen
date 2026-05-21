import SwiftUI

struct InfoBadge: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(verbatim: text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct PlaybackToggleButton: View {
    var isPlaying: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                .resizable()
                .frame(width: 32, height: 32)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help(isPlaying
            ? Text("Pause", comment: "Tooltip for the playback toggle when video is playing.")
            : Text("Play", comment: "Tooltip for the playback toggle when video is paused."))
        .accessibilityLabel(isPlaying
            ? Text("Pause", comment: "A11y label for playback toggle when playing.")
            : Text("Play", comment: "A11y label for playback toggle when paused."))
        .accessibilityHint(isPlaying
            ? Text("Pauses video playback", comment: "A11y hint for playback toggle when playing.")
            : Text("Resumes video playback", comment: "A11y hint for playback toggle when paused."))
    }
}

