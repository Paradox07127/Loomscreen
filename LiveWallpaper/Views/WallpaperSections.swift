import SwiftUI

// MARK: - Wallpaper Type Picker

struct WallpaperTypePicker: View {
    var screen: Screen
    @Binding var selectedWallpaperType: WallpaperType
    @Environment(ScreenManager.self) private var screenManager

    var body: some View {
        Picker("Wallpaper Type", selection: $selectedWallpaperType) {
            ForEach(WallpaperType.allCases) { type in
                Label(type.rawValue, systemImage: type.iconName).tag(type)
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

// MARK: - HTML Wallpaper Section

struct HTMLWallpaperSection: View {
    var screen: Screen
    @Binding var htmlContent: String
    @Environment(ScreenManager.self) private var screenManager

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Web / HTML Wallpaper", systemImage: "globe")
                    .font(.headline)

                Divider()

                HStack {
                    TextField("Enter URL (https://...) or local HTML path", text: $htmlContent)
                        .textFieldStyle(.roundedBorder)

                    Button("Load") {
                        guard !htmlContent.isEmpty else { return }
                        screenManager.setHTMLWallpaper(url: htmlContent, for: screen)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(htmlContent.isEmpty)
                }

                Text("Supports web URLs, local .html files, or inline HTML code")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }
}

// MARK: - Shader Wallpaper Section

struct ShaderWallpaperSection: View {
    var screen: Screen
    @Binding var selectedShaderPreset: MetalShaderPreset
    @Environment(ScreenManager.self) private var screenManager

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Shader Wallpaper", systemImage: "wand.and.stars")
                    .font(.headline)

                Divider()

                Text("GPU-rendered procedural animations")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                GlassEffectContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        ForEach(MetalShaderPreset.allCases) { preset in
                            Button {
                                withAnimation(.snappy(duration: 0.2)) {
                                    selectedShaderPreset = preset
                                }
                                screenManager.setShaderWallpaper(preset: preset, for: screen)
                            } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: preset.iconName)
                                        .font(.title2)
                                        .frame(width: 44, height: 44)
                                        .glassEffect(
                                            selectedShaderPreset == preset
                                                ? .regular.tint(Color.accentColor.opacity(0.35)).interactive()
                                                : .regular.interactive(),
                                            in: .circle
                                        )
                                    Text(preset.rawValue)
                                        .font(.caption2)
                                        .foregroundStyle(selectedShaderPreset == preset ? .primary : .secondary)
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(preset.rawValue) shader")
                            .accessibilityHint(selectedShaderPreset == preset ? "Currently selected" : "Switch to \(preset.rawValue) shader")
                        }
                    }
                }
            }
            .padding(14)
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }
}
