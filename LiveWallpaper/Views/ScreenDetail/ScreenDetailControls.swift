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

struct SegmentedSpeedPicker: View {
    @Binding var selectedSpeed: Double
    var onChange: (Double) -> Void
    private let speeds: [Double] = [0.5, 0.75, 1.0, 1.5, 2.0]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GlassEffectContainer(spacing: 2) {
            HStack(spacing: 2) {
                ForEach(speeds, id: \.self) { speed in
                    Button(action: {
                        withAnimation(DesignTokens.motion(reduceMotion, .snappy(duration: 0.2))) {
                            selectedSpeed = speed
                        }
                        onChange(speed)
                    }) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.clear)
                            Text(label(for: speed))
                                .font(.system(size: 12, weight: selectedSpeed == speed ? .semibold : .regular))
                        }
                        .frame(minWidth: 44, maxWidth: .infinity)
                        .frame(height: 28)
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .glassEffect(
                        selectedSpeed == speed
                            ? .regular.tint(Color.accentColor.opacity(0.35)).interactive()
                            : .regular.interactive(),
                        in: .rect(cornerRadius: 6)
                    )
                    .help(Text("Playback speed: \(label(for: speed))", comment: "Tooltip for a playback speed button. %@ is the multiplier."))
                    .accessibilityLabel(Text("Speed \(label(for: speed))", comment: "A11y label for playback speed button. %@ is the multiplier."))
                    .accessibilityHint(selectedSpeed == speed
                        ? Text("Currently selected", comment: "A11y hint when the playback speed button is the active one.")
                        : Text("Set playback speed to \(label(for: speed))", comment: "A11y hint to set playback speed. %@ is the multiplier."))
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func label(for speed: Double) -> String {
        switch speed {
        case 0.75:
            return "0.75x"
        case 1.0:
            return "1x"
        case 2.0:
            return "2x"
        default:
            return "\(String(format: "%.1f", speed))x"
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

struct FitModeButton: View {
    let mode: VideoFitMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: mode.iconName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 40, height: 40)
                    .glassEffect(
                        isSelected
                            ? .regular.tint(Color.accentColor.opacity(0.30)).interactive()
                            : .regular.interactive(),
                        in: .circle
                    )
                            Text(mode.titleKey)
                                .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                                .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .help(fitModeTooltip)
        .accessibilityLabel(Text("\(Text(mode.titleKey)) fit mode", comment: "A11y label for a video fit mode button. The placeholder is the mode name."))
        .accessibilityHint(isSelected
            ? Text("Currently selected", comment: "A11y hint for the active fit mode button.")
            : Text("Tap to switch to \(Text(mode.titleKey)) fit mode", comment: "A11y hint to switch fit mode. The placeholder is the mode name."))
    }

    private var fitModeTooltip: Text {
        Text(mode.tooltipKey)
    }
}
