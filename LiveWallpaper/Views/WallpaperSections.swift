#if !LITE_BUILD
import SwiftUI

/// Shader preset gallery — embedded in `ScreenDetailPreviewArea` when the
/// user picks the shader wallpaper type. Single section so no collapse
/// chrome; presets sit in a `LazyVGrid` so the cards stay readable from the
/// 480pt preview-area minimum up to wide windows.
struct ShaderWallpaperSection: View {
    var screen: Screen
    @Binding var selectedShaderPreset: MetalShaderPreset
    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let presetColumns = [
        GridItem(.adaptive(minimum: 110, maximum: 200), spacing: 12, alignment: .top)
    ]

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Shader Wallpaper", systemImage: "wand.and.stars")
                    .font(.system(size: 13, weight: .semibold))

                Text("GPU-rendered procedural animations")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: Self.presetColumns, spacing: 12) {
                    ForEach(MetalShaderPreset.allCases) { preset in
                        presetButton(preset)
                    }
                }
            }
            .padding(14)
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }

    private func presetButton(_ preset: MetalShaderPreset) -> some View {
        let isSelected = selectedShaderPreset == preset
        return Button {
            withAnimation(DesignTokens.motion(reduceMotion, .snappy(duration: 0.2))) {
                selectedShaderPreset = preset
            }
            screenManager.setShaderWallpaper(preset: preset, for: screen)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: preset.iconName)
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .adaptiveGlassSurface(
                        .circle,
                        tint: isSelected ? Color.accentColor : nil,
                        interactive: true
                    )
                Text(preset.titleKey)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(
            "\(preset.localizedTitle) shader",
            comment: "A11y label for a shader preset button. %@ = preset name (e.g. Waves)."
        ))
        .accessibilityHint(isSelected
            ? Text("Currently selected", comment: "A11y hint for the active shader preset button.")
            : Text(
                "Switch to \(preset.localizedTitle) shader",
                comment: "A11y hint for a shader preset button. %@ = preset name (e.g. Waves)."
            ))
    }
}
#endif
