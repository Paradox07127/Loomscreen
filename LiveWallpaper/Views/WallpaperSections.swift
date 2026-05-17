import SwiftUI

// MARK: - Wallpaper Type Picker

struct WallpaperTypePicker: View {
    var screen: Screen
    @Binding var selectedWallpaperType: WallpaperType
    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.featureCatalog) private var featureCatalog

    var body: some View {
        Picker("Wallpaper Type", selection: $selectedWallpaperType) {
            ForEach(featureCatalog.capabilities.selectableWallpaperTypes) { type in
                Label(type.titleKey, systemImage: type.iconName).tag(type)
            }
        }
        .pickerStyle(.segmented)
        .padding(.bottom, 4)
        .onChange(of: selectedWallpaperType) { _, newType in
            if newType == .video {
                screenManager.switchToVideoWallpaper(for: screen)
            }
        }
    }
}

// MARK: - Shader Wallpaper Section

struct ShaderWallpaperSection: View {
    var screen: Screen
    @Binding var selectedShaderPreset: MetalShaderPreset
    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Shader Wallpaper", systemImage: "wand.and.stars")
                    .font(.headline)

                Divider()

                Text("GPU-rendered procedural animations")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                AdaptiveGlassContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        ForEach(MetalShaderPreset.allCases) { preset in
                            Button {
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
                                            tint: selectedShaderPreset == preset ? Color.accentColor : nil,
                                            interactive: true
                                        )
                                    Text(preset.titleKey)
                                        .font(.caption2)
                                        .foregroundStyle(selectedShaderPreset == preset ? .primary : .secondary)
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(shaderPresetAccessibilityLabel(preset))
                            .accessibilityHint(selectedShaderPreset == preset
                                ? Text("Currently selected", comment: "A11y hint for the active shader preset button.")
                                : shaderPresetSwitchHint(preset))
                        }
                    }
                }
            }
            .padding(14)
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }

    private func shaderPresetAccessibilityLabel(_ preset: MetalShaderPreset) -> Text {
        switch preset {
        case .waves:
            return Text("Waves shader", comment: "A11y label for the Waves shader preset button.")
        case .plasma:
            return Text("Plasma shader", comment: "A11y label for the Plasma shader preset button.")
        case .gradient:
            return Text("Gradient shader", comment: "A11y label for the Gradient shader preset button.")
        case .noise:
            return Text("Noise shader", comment: "A11y label for the Noise shader preset button.")
        case .aurora:
            return Text("Aurora shader", comment: "A11y label for the Aurora shader preset button.")
        }
    }

    private func shaderPresetSwitchHint(_ preset: MetalShaderPreset) -> Text {
        switch preset {
        case .waves:
            return Text("Switch to Waves shader", comment: "A11y hint for the Waves shader preset button.")
        case .plasma:
            return Text("Switch to Plasma shader", comment: "A11y hint for the Plasma shader preset button.")
        case .gradient:
            return Text("Switch to Gradient shader", comment: "A11y hint for the Gradient shader preset button.")
        case .noise:
            return Text("Switch to Noise shader", comment: "A11y hint for the Noise shader preset button.")
        case .aurora:
            return Text("Switch to Aurora shader", comment: "A11y hint for the Aurora shader preset button.")
        }
    }
}
