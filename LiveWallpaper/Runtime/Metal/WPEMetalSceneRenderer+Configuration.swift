#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import LiveWallpaperProWPE
import MetalKit

// Static, defaults-backed configuration for the renderer (frame-rate targets,
// texture-cache budget, prewarm/intro/async-tick switches). Split out of the
// base type so the hotspot file stays lean; all members are `static`.
extension WPEMetalSceneRenderer {
    /// Default frame rate target when no user override has been applied.
    /// 30 FPS matches Wallpaper Engine's stock default
    /// (Almamu's reference open-source impl ships `maximumFPS = 30`; the
    /// official Windows app's "Balanced" preset also defaults to 30) —
    /// most published WPE shaders are tuned around a 30 FPS clock, so
    /// running at 60 made their `g_Time`-driven motion look ≈2× too fast.
    /// `MTKView` clamps this to the display's refresh rate.
    static let defaultPreferredFPS = 30
    /// Perspective scenes render at the drawable resolution (capped 4K) instead
    /// of the fixed 1080 fallback, so HUD text is crisp. Default ON; disable with
    /// `defaults write Taijia.LiveWallpaper WPEMetalPerspectiveNativeResolution -bool NO`.
    static let perspectiveNativeResolutionEnabled: Bool =
        (UserDefaults.standard.object(forKey: "WPEMetalPerspectiveNativeResolution") as? Bool) ?? true
    /// Floor for the adaptive "background" throttle — never drop a still-visible
    /// wallpaper below this even when occluded/on battery (15 FPS measured at
    /// ~83 mW vs ~330 mW at 60, a ~75% GPU-power cut, while staying watchable).
    static let adaptiveThrottleFloorFPS = 15
    /// Native vsync cap used when the user picks `.unlimited` — MTKView's
    /// throttle clamps to the display refresh anyway, but we surface a
    /// concrete value here so a `setPreferredFramesPerSecond(0)` doesn't get
    /// interpreted as "as fast as possible" (which on some macOS versions
    /// free-runs well past vsync). Derived from the fastest attached display
    /// so ProMotion panels actually reach 120 instead of a literal 60;
    /// MTKView still clamps per-display, so over-asking on slower screens
    /// is harmless.
    static var unlimitedPreferredFPS: Int {
        let fastest = NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 0
        return fastest > 0 ? fastest : 60
    }
    /// Above this raw-bytes footprint, eager-upload a multi-frame `.tex`
    /// would burn far more VRAM than the runtime needs at any one moment
    /// — route through `WPETexLazyAnimatedTextureSource` instead. Threshold
    /// chosen to keep small (≤2-3 frame) workshop sprite-sheets on the
    /// fast eager path while sending workshop 3725117707-class assets
    /// (60 × 122 MB raw) to the streaming source. Tiered by physical RAM
    /// (halved on 8 GB machines — see `WPEMemoryTier`).
    static let lazyAnimationRawByteThreshold = WPEMemoryTier.current.lazyAnimationRawByteThreshold

    static let textureCacheBudgetMiBDefaultsKey = "WPEMetalTextureCacheBudgetMiB"
    /// VRAM budget for reloadable static source textures. Unset ⇒ the machine's
    /// memory-tier default (8/16 GB Macs bounded, ≥24 GB unbounded — see
    /// `WPEMemoryTier`); explicit 0 or negative ⇒ unbounded (manual opt-out);
    /// positive ⇒ that many MiB. Over-budget inactive (hidden-layer) textures
    /// are LRU-evicted and reloaded on demand. Snapshot per scene load, so
    /// `defaults write Taijia.LiveWallpaper WPEMetalTextureCacheBudgetMiB -int 256`
    /// applies on the next (re)load.
    static var textureCacheBudgetBytes: Int? {
        resolvedTextureCacheBudgetBytes(
            manualValue: UserDefaults.standard.object(forKey: textureCacheBudgetMiBDefaultsKey),
            tier: .current
        )
    }

    static func resolvedTextureCacheBudgetBytes(manualValue: Any?, tier: WPEMemoryTier) -> Int? {
        guard let manualValue else { return tier.defaultTextureCacheBudgetBytes }
        let mib = (manualValue as? NSNumber)?.intValue ?? 0
        guard mib > 0 else { return nil }
        return mib * 1_048_576
    }

    /// When true, emitters with no authored start offset are also pre-populated
    /// to their steady-state spread on load. Emitters with `starttime > 0`
    /// always prewarm because WPE authors use that field as an initial simulation
    /// offset for already-populated first frames.
    static var particlePrewarmEnabled: Bool {
        UserDefaults.standard.bool(forKey: "WPEParticlePrewarmEnabled")
    }

    nonisolated static func particlePrewarmSeconds(
        for definition: WPEParticleDefinition,
        manualPrewarmEnabled: Bool
    ) -> Double? {
        guard definition.rate > 0 || definition.instantaneousCount > 0 else { return nil }
        let authoredStart = max(0, definition.startDelay)
        guard authoredStart > 0 || manualPrewarmEnabled else { return nil }
        let activeSeconds = min(max(definition.lifetimeMax, 2.0), 15.0)
        let seconds = authoredStart + activeSeconds
        return seconds > 0 ? seconds : nil
    }

    /// Slave a revealed loop video's playhead to lead its intro overlay by the
    /// measured phase offset (seamless intro→loop). Default on; `-bool NO` disables.
    static var introPhaseAlignEnabled: Bool {
        UserDefaults.standard.object(forKey: "WPEMetalIntroPhaseAlignEnabled") as? Bool ?? true
    }

    /// ADR-003 step 1 kill-switch: async latest-snapshot script ticks (the frame
    /// path never waits on a script engine queue). Frozen at first use; default
    /// ON. `defaults write <bundle> WPEScriptAsyncTickEnabled -bool NO` restores
    /// the legacy bounded-blocking ticks on the next launch.
    static let scriptAsyncTickEnabled: Bool = resolvedScriptAsyncTickEnabled(
        manualValue: UserDefaults.standard.object(forKey: "WPEScriptAsyncTickEnabled")
    )

    nonisolated static func resolvedScriptAsyncTickEnabled(manualValue: Any?) -> Bool {
        manualValue as? Bool ?? true
    }
}
#endif
