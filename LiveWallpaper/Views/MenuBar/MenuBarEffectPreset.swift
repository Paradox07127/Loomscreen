import SwiftUI

/// Built-in one-tap effect presets surfaced in the menu-bar Effects section.
/// Each preset bundles VideoEffectConfig + ParticleEffect + density so the
/// caller flips the whole look in one call sequence.
struct MenuBarEffectPreset: Identifiable, Equatable {
    let id: String
    let title: String
    let systemImage: String
    let particles: ParticleEffect
    let particleDensity: Double
    let effects: VideoEffectConfig

    static let none = MenuBarEffectPreset(
        id: "none",
        title: "None",
        systemImage: "xmark.circle",
        particles: .none,
        particleDensity: 1.0,
        effects: .default
    )

    static let cinematic = MenuBarEffectPreset(
        id: "cinematic",
        title: "Cinematic",
        systemImage: "film",
        particles: .none,
        particleDensity: 1.0,
        effects: {
            var c = VideoEffectConfig()
            c.saturation = 1.18
            c.vignetteIntensity = 0.35
            c.warmth = 5800
            return c
        }()
    )

    static let subtleBlur = MenuBarEffectPreset(
        id: "subtle-blur",
        title: "Subtle",
        systemImage: "circle.dashed",
        particles: .bokeh,
        particleDensity: 0.6,
        effects: {
            var c = VideoEffectConfig()
            c.blurRadius = 4
            c.saturation = 0.9
            c.warmth = 6800
            return c
        }()
    )

    static let rainNight = MenuBarEffectPreset(
        id: "rain-night",
        title: "Rain",
        systemImage: "cloud.rain",
        particles: .rain,
        particleDensity: 1.4,
        effects: {
            var c = VideoEffectConfig()
            c.warmth = 5400
            c.saturation = 0.85
            c.vignetteIntensity = 0.2
            c.glassRainEffect = true
            return c
        }()
    )

    static let sakura = MenuBarEffectPreset(
        id: "sakura",
        title: "Sakura",
        systemImage: "camera.macro",
        particles: .sakura,
        particleDensity: 1.2,
        effects: {
            var c = VideoEffectConfig()
            c.saturation = 1.1
            c.warmth = 7200
            return c
        }()
    )

    static let builtIns: [MenuBarEffectPreset] = [
        .none, .cinematic, .subtleBlur, .rainNight, .sakura
    ]

    /// True when the screen's current configuration matches this preset's
    /// signature (particle effect + density + key effect dials). Lets the
    /// chip row paint the active state without exact float comparison.
    func matches(particles: ParticleEffect, density: Double, effects: VideoEffectConfig) -> Bool {
        guard particles == self.particles else { return false }
        guard abs(density - particleDensity) < 0.05 else { return false }
        return abs(effects.saturation - self.effects.saturation) < 0.05
            && abs(effects.warmth - self.effects.warmth) < 50
            && abs(effects.vignetteIntensity - self.effects.vignetteIntensity) < 0.05
            && abs(effects.blurRadius - self.effects.blurRadius) < 0.5
            && effects.glassRainEffect == self.effects.glassRainEffect
    }
}
