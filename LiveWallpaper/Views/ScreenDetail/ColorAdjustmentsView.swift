import LiveWallpaperSharedUI
import SwiftUI

struct ColorAdjustmentsView: View {
    @Binding var effectConfig: VideoEffectConfig
    var screen: Screen
    var screenManager: ScreenManager

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 12) {
                effectSlider(title: "Blur", value: effectBinding(\.blurRadius), in: 0...30, format: "%.0f")
                effectSlider(title: "Brightness", value: effectBinding(\.brightness), in: -0.5...0.5, format: "%.2f")
                effectSlider(title: "Saturation", value: effectBinding(\.saturation), in: 0...2, format: "%.1f")
                effectSlider(title: "Warmth", value: effectBinding(\.warmth), in: 2500...8000, format: "%.0f")
                effectSlider(title: "Vignette", value: effectBinding(\.vignetteIntensity), in: 0...5, format: "%.1f")

                Divider()

                HStack(spacing: 4) {
                    Text("Auto warm tint by time of day")
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    InfoTooltipButton(text: "Automatically shifts the wallpaper's warmth across the day — cooler at midday, warmer toward sunset.")
                    Spacer()
                    Toggle("", isOn: effectBinding(\.autoTimeTint))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel(Text("Auto warm tint"))
                }

                Divider()

                HStack {
                    Spacer()
                    Button(action: resetEffects) {
                        Label("Reset to Default", systemImage: "arrow.counterclockwise")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                    .destructiveControlTint()
                    .adaptiveGlassSurface(.capsule, tint: .red, interactive: true)
                    .help(Text("Reset all color adjustments to default values"))
                    Spacer()
                }
            }
        }
    }

    private func resetEffects() {
        effectConfig = .default
        screenManager.updateEffectConfig(effectConfig, for: screen)
    }

    private func effectBinding<Value: Equatable>(
        _ keyPath: WritableKeyPath<VideoEffectConfig, Value>
    ) -> Binding<Value> {
        Binding(
            get: { effectConfig[keyPath: keyPath] },
            set: { newValue in
                guard effectConfig[keyPath: keyPath] != newValue else { return }
                effectConfig[keyPath: keyPath] = newValue
                screenManager.updateEffectConfig(effectConfig, for: screen)
            }
        )
    }

    private func effectSlider(
        title: LocalizedStringKey,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        format: String
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 90, alignment: .leading)

            Slider(value: value, in: range)
                .controlSize(.small)
                .accessibilityLabel(Text(title))
                .accessibilityValue(Text(verbatim: String(format: format, value.wrappedValue)))

            Text(verbatim: String(format: format, value.wrappedValue))
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: 44, alignment: .trailing)
        }
    }
}
