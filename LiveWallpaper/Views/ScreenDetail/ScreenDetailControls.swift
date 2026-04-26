import SwiftUI

struct InfoBadge: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(text)
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
        GlassEffectContainer(spacing: 2) {
            HStack(spacing: 2) {
                ForEach(speeds, id: \.self) { speed in
                    Button(action: {
                        withAnimation(.snappy(duration: 0.2)) {
                            selectedSpeed = speed
                        }
                        onChange(speed)
                    }) {
                        Text(speed == 1.0 ? "1.0" : "\(String(format: "%.1f", speed))x")
                            .font(.system(size: 12))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(
                        selectedSpeed == speed
                            ? .regular.tint(Color.accentColor.opacity(0.35)).interactive()
                            : .regular.interactive(),
                        in: .rect(cornerRadius: 6)
                    )
                    .help("Playback speed: \(String(format: "%.1f", speed))x")
                    .accessibilityLabel("Speed \(String(format: "%.1f", speed))x")
                    .accessibilityHint(selectedSpeed == speed ? "Currently selected" : "Set playback speed to \(String(format: "%.1f", speed))x")
                }
            }
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
        .help(isPlaying ? "Pause" : "Play")
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
        .accessibilityHint(isPlaying ? "Pauses video playback" : "Resumes video playback")
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
                Text(mode.rawValue)
                    .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .help(fitModeTooltip)
        .accessibilityLabel("\(mode.rawValue) fit mode")
        .accessibilityHint(isSelected ? "Currently selected" : "Tap to switch to \(mode.rawValue) fit mode")
    }

    private var fitModeTooltip: String {
        switch mode {
        case .aspectFill: return "Fill: crop to fill screen"
        case .aspectFit: return "Fit: show entire video"
        case .stretch: return "Stretch: distort to fill"
        }
    }
}
