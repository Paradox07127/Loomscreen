import CoreGraphics
import Foundation

/// Raw system-state signals that drive the performance policy. Every value is
/// the *ungated* reading (e.g. the detector's raw "is occluded", not already
/// ANDed with a user setting) — `WallpaperPolicyEngine` is the single place
/// that applies the relevant `GlobalSettings` toggle, so callers can't drift
/// by gating one signal and forgetting another.
struct WallpaperPolicyInputs {
    var powerSource: PowerMonitor.PowerSource
    var isHiddenByFullScreen: Bool
    var isWindowOccluding: Bool
    var isApplicationRuleActive: Bool
    var thermalState: ProcessInfo.ThermalState
    var isGameModeActive: Bool
    var isUserAbsent: Bool
    var isUnderMemoryPressure: Bool
    /// Frontmost app carries a `.neverPause` exception — vetoes the
    /// discretionary suspends below (but not the safety ones).
    var isFrontmostExcludedByRule: Bool = false
}

enum WallpaperPolicyEngine {
    /// `inputs` carries raw signals; `settings` gates them here so the rule
    /// table lives in exactly one place.
    static func performanceProfile(
        inputs: WallpaperPolicyInputs,
        settings: GlobalSettings
    ) -> WallpaperPerformanceProfile {
        // Safety suspends: the user isn't watching, memory is under pressure, or
        // the system is hot. No opt-out, and a `.neverPause` exception can't veto
        // them (overriding thermal would risk overheating).
        let safetySuspend = inputs.isUserAbsent ||
            inputs.isUnderMemoryPressure ||
            shouldSuspendForThermal(inputs.thermalState)

        // Discretionary suspends yield the GPU for games / full-screen / battery /
        // app rules. A `.neverPause` exception on the frontmost app vetoes them.
        let discretionarySuspend = inputs.isApplicationRuleActive ||
            (settings.pauseInGameMode && inputs.isGameModeActive) ||
            shouldPauseForPower(globalSettings: settings, powerSource: inputs.powerSource) ||
            shouldApplyFullScreenPolicy(globalSettings: settings, isHiddenByFullScreen: inputs.isHiddenByFullScreen) ||
            shouldApplyWindowOcclusionPolicy(globalSettings: settings, isWindowOccluding: inputs.isWindowOccluding)

        let shouldSuspend = safetySuspend || (discretionarySuspend && !inputs.isFrontmostExcludedByRule)
        return shouldSuspend ? .suspended : .quality
    }

    /// Thermal mapping: `.serious / .critical` suspend playback to bleed
    /// heat; `.fair / .nominal` rely on the user's per-screen frame-rate
    /// cap and on lower-cost paths (VideoToolbox ASIC decode), so we don't
    /// double-control via the profile.
    private static func shouldSuspendForThermal(_ thermalState: ProcessInfo.ThermalState) -> Bool {
        switch thermalState {
        case .critical, .serious:
            return true
        case .fair, .nominal:
            return false
        @unknown default:
            return true
        }
    }

    static func shouldPauseForPower(
        globalSettings: GlobalSettings,
        powerSource: PowerMonitor.PowerSource
    ) -> Bool {
        powerSource.isOnBattery && globalSettings.globalPauseOnBattery
    }

    static func shouldApplyFullScreenPolicy(
        globalSettings: GlobalSettings,
        isHiddenByFullScreen: Bool
    ) -> Bool {
        globalSettings.pauseOnFullScreen && isHiddenByFullScreen
    }

    static func shouldApplyWindowOcclusionPolicy(
        globalSettings: GlobalSettings,
        isWindowOccluding: Bool
    ) -> Bool {
        globalSettings.pauseOnWindowOcclusion && isWindowOccluding
    }

    static func shouldEnableFullScreenFallbackPolling(
        globalSettings: GlobalSettings,
        hasConfiguredWallpaperSessions: Bool
    ) -> Bool {
        // Either window-coverage rule needs the detector polling as a fallback.
        (globalSettings.pauseOnFullScreen || globalSettings.pauseOnWindowOcclusion)
            && hasConfiguredWallpaperSessions
    }
}
