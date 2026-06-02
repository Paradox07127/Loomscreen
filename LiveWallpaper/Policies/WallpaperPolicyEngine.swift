import CoreGraphics
import Foundation

/// Converts settings and system state into runtime decisions.
enum WallpaperPolicyEngine {
    static func performanceProfile(
        globalSettings: GlobalSettings,
        powerSource: PowerMonitor.PowerSource,
        isHiddenByFullScreen: Bool,
        isWindowOccluding: Bool,
        isApplicationRuleActive: Bool,
        thermalState: ProcessInfo.ThermalState,
        isGameModeActive: Bool
    ) -> WallpaperPerformanceProfile {
        let shouldSuspend = isGameModeActive ||
            isApplicationRuleActive ||
            shouldPauseForPower(globalSettings: globalSettings, powerSource: powerSource) ||
            shouldSuspendForThermal(thermalState) ||
            shouldApplyFullScreenPolicy(
                globalSettings: globalSettings,
                isHiddenByFullScreen: isHiddenByFullScreen
            ) ||
            shouldApplyWindowOcclusionPolicy(
                globalSettings: globalSettings,
                isWindowOccluding: isWindowOccluding
            )

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
        guard powerSource.isOnBattery else { return false }

        if globalSettings.globalPauseOnBattery {
            return true
        }

        guard let minimumBatteryLevel = globalSettings.minimumBatteryLevel,
              case .battery(let level) = powerSource else {
            return false
        }

        return level < minimumBatteryLevel
    }

    static func shouldResumeFromPower(
        powerSource: PowerMonitor.PowerSource,
        wasPausedByPower: Bool
    ) -> Bool {
        !powerSource.isOnBattery && wasPausedByPower
    }

    static func shouldStartVideoPaused(
        globalSettings: GlobalSettings,
        powerSource: PowerMonitor.PowerSource,
        isHiddenByFullScreen: Bool
    ) -> Bool {
        shouldPauseForPower(globalSettings: globalSettings, powerSource: powerSource) ||
            shouldApplyFullScreenPolicy(
                globalSettings: globalSettings,
                isHiddenByFullScreen: isHiddenByFullScreen
            )
    }

    static func shouldResumeFromFullScreen(
        globalSettings: GlobalSettings,
        powerSource: PowerMonitor.PowerSource,
        wasPausedByFullScreen: Bool
    ) -> Bool {
        wasPausedByFullScreen &&
            !shouldPauseForPower(globalSettings: globalSettings, powerSource: powerSource)
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
