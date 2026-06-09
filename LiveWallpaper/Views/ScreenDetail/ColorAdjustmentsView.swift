import SwiftUI
import LiveWallpaperCore

struct ColorAdjustmentsView: View {
    @Binding var effectConfig: VideoEffectConfig
    /// Per-screen colourspace override. Lives next to the SDR effect sliders
    /// because users mentally group "make the colours look right" together;
    /// the picker covers system-level output, the sliders adjust the image.
    @Binding var videoColorSpace: VideoColorSpace
    var screen: Screen
    var screenManager: ScreenManager

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 12) {
                colorSpaceRow

                Divider()

                effectSlider(title: "Blur", value: effectBinding(\.blurRadius), in: 0...30, format: "%.0f")
                effectSlider(title: "Brightness", value: effectBinding(\.brightness), in: -0.5...0.5, format: "%.2f")
                effectSlider(title: "Saturation", value: effectBinding(\.saturation), in: 0...2, format: "%.1f")
                effectSlider(title: "Warmth", value: effectBinding(\.warmth), in: 2500...8000, format: "%.0f")
                effectSlider(title: "Vignette", value: effectBinding(\.vignetteIntensity), in: 0...5, format: "%.1f")

                Divider()

                HStack {
                    Text("Auto warm tint")
                        .font(DesignTokens.Typography.body)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Toggle("", isOn: effectBinding(\.autoTimeTint))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .help(Text("Automatically adjust color temperature by time of day"))
                        .accessibilityLabel(Text("Auto warm tint"))
                        .accessibilityHint(Text("Automatically adjusts color warmth based on time of day"))
                }

                Divider()

                HStack {
                    Spacer()
                    Button(action: resetEffects) {
                        Label("Reset Color & Filters", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                    .tint(DesignTokens.Colors.Status.danger)
                    .controlSize(.small)
                    .help(Text("Reset blur, brightness, saturation, warmth, vignette, and auto-tint to defaults"))
                    Spacer()
                }
            }
        }
    }

    private var colorSpaceRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Color Management")
                    .font(DesignTokens.Typography.body)
                Spacer()
                Picker("", selection: Binding(
                    get: { videoColorSpace },
                    set: { newValue in
                        guard videoColorSpace != newValue else { return }
                        videoColorSpace = newValue
                        screenManager.updateVideoColorSpace(newValue, for: screen)
                    }
                )) {
                    ForEach(VideoColorSpace.allCases) { space in
                        Text(LocalizedStringKey(space.titleKey)).tag(space)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 160)
                .accessibilityLabel(Text("Color management"))
            }
            Text(LocalizedStringKey(videoColorSpace.descriptionKey))
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
        HStack(spacing: DesignTokens.Inspector.sliderValueSpacing) {
            Text(title)
                .font(DesignTokens.Typography.body)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 90, alignment: .leading)

            Slider(value: value, in: range)
                .controlSize(.small)
                .accessibilityLabel(Text(title))
                .accessibilityValue(Text(verbatim: String(format: format, value.wrappedValue)))

            Text(verbatim: String(format: format, value.wrappedValue))
                .font(DesignTokens.Typography.metric)
                .foregroundStyle(.secondary)
                .frame(width: DesignTokens.Inspector.sliderValueWidth, alignment: .trailing)
        }
    }
}
