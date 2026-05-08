import SwiftUI

/// One-tap effect presets, particle density slider, and weather-reactive
/// toggle for the selected screen. Applies to video wallpapers only — the
/// section gracefully hides itself when the active wallpaper is HTML/Shader
/// since the underlying APIs are video-only.
struct MenuBarEffectsSection: View {
    let screen: Screen

    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if screenManager.wallpaperSummary(for: screen).wallpaperType == .video {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                MenuBarSectionHeader(title: "Effects")
                presetRow
                particleDensitySlider
                weatherToggle
            }
        }
    }

    // MARK: - Preset chips

    private var presetRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(MenuBarEffectPreset.builtIns) { preset in
                    EffectChip(
                        preset: preset,
                        isActive: isActive(preset)
                    ) {
                        apply(preset)
                    }
                }
            }
            .padding(.vertical, 1)
        }
    }

    private func isActive(_ preset: MenuBarEffectPreset) -> Bool {
        guard let cfg = screenManager.getConfiguration(for: screen) else { return false }
        return preset.matches(
            particles: cfg.particleEffect,
            density: cfg.effectConfig.particleDensity,
            effects: cfg.effectConfig
        )
    }

    private func apply(_ preset: MenuBarEffectPreset) {
        // Presets and Weather Reactive are mutually exclusive: enabling a
        // preset takes the steering wheel from the weather service so the
        // hand-picked look isn't immediately overwritten.
        screenManager.setWeatherReactive(false, for: screen)
        screenManager.updateEffectConfig(preset.effects, for: screen)
        screenManager.updateParticleEffect(preset.particles, for: screen)
        screenManager.updateParticleDensity(preset.particleDensity, for: screen)
    }

    // MARK: - Density slider

    private var particleDensitySlider: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 11))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)

            Slider(
                value: Binding(
                    get: { screenManager.getConfiguration(for: screen)?.effectConfig.particleDensity ?? 1.0 },
                    set: { screenManager.updateParticleDensity($0, for: screen) }
                ),
                in: 0.2...3.0
            )
            .controlSize(.mini)
            .accessibilityLabel(Text("Particle density"))
        }
    }

    // MARK: - Weather toggle

    private var weatherToggle: some View {
        Toggle(isOn: Binding(
            get: { screenManager.getConfiguration(for: screen)?.effectConfig.weatherReactive ?? false },
            set: { screenManager.setWeatherReactive($0, for: screen) }
        )) {
            Label("Weather Reactive", systemImage: "cloud.sun")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 11))
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
    }
}

// MARK: - Effect chip

private struct EffectChip: View {
    let preset: MenuBarEffectPreset
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: preset.systemImage)
                    .font(.system(size: 11, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                Text(preset.title)
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(isActive ? .primary : .secondary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(
            isActive
                ? .regular.tint(Color.accentColor.opacity(0.35)).interactive()
                : .regular.interactive(),
            in: .capsule
        )
        .accessibilityLabel(Text("\(preset.title) effect"))
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
