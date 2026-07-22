import CoreGraphics
import Foundation
import LiveWallpaperCore

/// Raw system-state signals consumed by the centralized performance policy.
struct WallpaperPolicyInputs {
    var powerSource: PowerMonitor.PowerSource
    var isHiddenByFullScreen: Bool
    var isWindowOccluding: Bool
    var isApplicationRuleActive: Bool
    var thermalState: ProcessInfo.ThermalState
    var isGameModeActive: Bool
    var isUserAbsent: Bool
    var isUnderMemoryPressure: Bool
    /// Vetoes discretionary suspension without overriding safety suspension.
    var isFrontmostExcludedByRule: Bool = false
}

enum WallpaperPolicyEngine {
    /// Resolves raw signals and user settings into a single performance profile.
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
        hasConfiguredWallpaperSessions: Bool,
        hasConfiguredSceneSessions: Bool
    ) -> Bool {
        // The pause rules apply to every wallpaper kind; adaptive frame rate
        // only throttles the scene renderer, so it only needs the poll when a
        // scene session is live (avoids needless 30s CGWindowList scans in
        // video/HTML-only setups carrying a stale-on flag).
        let coverageRule = (globalSettings.pauseOnFullScreen || globalSettings.pauseOnWindowOcclusion)
            && hasConfiguredWallpaperSessions
        let adaptiveRule = globalSettings.adaptiveFrameRateEnabled && hasConfiguredSceneSessions
        return coverageRule || adaptiveRule
    }
}
