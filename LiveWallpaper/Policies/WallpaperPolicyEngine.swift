import CoreGraphics
import Foundation

/// Converts global settings, per-screen configuration, and system state into
/// runtime actions. ScreenManager owns wiring; this type owns the decisions.
enum WallpaperPolicyEngine {
    static func performanceProfile(
        globalSettings: GlobalSettings,
        powerSource: PowerMonitor.PowerSource,
        isHiddenByFullScreen: Bool
    ) -> WallpaperPerformanceProfile {
        if globalSettings.pauseOnFullScreen && isHiddenByFullScreen {
            return .suspended
        }

        // Battery-induced pause is applied explicitly by ScreenManager —
        // see `shouldPauseForPower` (video) and the ambient-session branch
        // in `handlePowerStateChange`. The profile itself encodes no
        // intermediate "battery saver" state; the UX is static-on-battery,
        // not degraded animation.
        return .quality
    }

    static func shouldPauseForPower(
        globalSettings: GlobalSettings,
        configuration: ScreenConfiguration?,
        powerSource: PowerMonitor.PowerSource
    ) -> Bool {
        guard powerSource.isOnBattery else { return false }

        let shouldPauseOnBattery = globalSettings.globalPauseOnBattery || configuration?.pauseOnBattery == true
        if shouldPauseOnBattery {
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

    static func shouldApplyFullScreenPolicy(
        globalSettings: GlobalSettings,
        isHiddenByFullScreen: Bool
    ) -> Bool {
        globalSettings.pauseOnFullScreen && isHiddenByFullScreen
    }

    static func shouldEnableFullScreenFallbackPolling(
        globalSettings: GlobalSettings,
        hasConfiguredWallpaperSessions: Bool
    ) -> Bool {
        globalSettings.pauseOnFullScreen && hasConfiguredWallpaperSessions
    }
}
