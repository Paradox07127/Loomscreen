import SwiftUI

struct ColorAdjustmentsView: View {
    @Binding var effectConfig: VideoEffectConfig
    var screen: Screen
    var screenManager: ScreenManager

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 12) {
                effectSlider(title: "Blur", value: $effectConfig.blurRadius, in: 0...30, format: "%.0f")
                effectSlider(title: "Brightness", value: $effectConfig.brightness, in: -0.5...0.5, format: "%.2f")
                effectSlider(title: "Saturation", value: $effectConfig.saturation, in: 0...2, format: "%.1f")
                effectSlider(title: "Warmth", value: $effectConfig.warmth, in: 2500...8000, format: "%.0f")
                effectSlider(title: "Vignette", value: $effectConfig.vignetteIntensity, in: 0...5, format: "%.1f")

                Divider()

                HStack {
                    Text("Auto warm tint by time of day")
                        .font(.system(size: 13, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Toggle("", isOn: $effectConfig.autoTimeTint)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .help(Text("Automatically adjust color temperature by time of day"))
                        .accessibilityLabel(Text("Auto warm tint"))
                        .accessibilityHint(Text("Automatically adjusts color warmth based on time of day"))
                }

                Divider()

                HStack {
                    Text("Glass rain drops (Heavy GPU)")
                        .font(.system(size: 13, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Toggle("", isOn: $effectConfig.glassRainEffect)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .help(Text("Simulate rain drops hitting glass and refracting video (High GPU usage)"))
                        .accessibilityLabel(Text("Glass rain drops"))
                        .accessibilityHint(Text("Adds refractive rain drops over the video"))
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
                    .foregroundStyle(Color.accentColor)
                    .glassEffect(.regular.tint(Color.accentColor.opacity(0.15)).interactive(), in: .capsule)
                    .help(Text("Reset all color adjustments to default values"))
                    Spacer()
                }
            }
        }
        .onChange(of: effectConfig) { _, _ in
            screenManager.updateEffectConfig(effectConfig, for: screen)
        }
    }

    private func resetEffects() {
        effectConfig = .default
        screenManager.updateEffectConfig(effectConfig, for: screen)
    }

    private func effectSlider(
        title: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        format: String
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13))
                .frame(width: 62, alignment: .leading)

            Slider(value: value, in: range)
                .controlSize(.small)
                .accessibilityLabel(title)
                .accessibilityValue(String(format: format, value.wrappedValue))

            Text(String(format: format, value.wrappedValue))
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: 36, alignment: .trailing)
        }
    }
}
