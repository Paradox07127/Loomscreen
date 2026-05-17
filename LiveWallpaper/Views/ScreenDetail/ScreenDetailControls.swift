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

    var body: some View {
        Picker(selection: speedBinding) {
            ForEach(speeds, id: \.self) { speed in
                Text(label(for: speed)).tag(speed)
            }
        } label: {
            Text("Playback speed", comment: "A11y label for the playback speed picker.")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help(Text("Playback speed", comment: "Tooltip for the playback speed picker."))
        .accessibilityLabel(Text("Playback speed", comment: "A11y label for the playback speed picker."))
        .accessibilityValue(Text(label(for: selectedSpeed)))
    }

    private var speedBinding: Binding<Double> {
        Binding(
            get: { selectedSpeed },
            set: { newValue in
                selectedSpeed = newValue
                onChange(newValue)
            }
        )
    }

    private func label(for speed: Double) -> String {
        switch speed {
        case 0.75: return "0.75x"
        case 1.0:  return "1x"
        case 2.0:  return "2x"
        default:   return "\(String(format: "%.1f", speed))x"
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
                    .adaptiveGlassSurface(
                        .circle,
                        tint: isSelected ? Color.accentColor : nil,
                        interactive: true
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
