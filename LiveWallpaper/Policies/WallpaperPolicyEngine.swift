import CoreGraphics
import Foundation

/// Converts settings and system state into runtime decisions.
enum WallpaperPolicyEngine {
    static func performanceProfile(
        globalSettings: GlobalSettings,
        powerSource: PowerMonitor.PowerSource,
        isHiddenByFullScreen: Bool,
        now: Date = Date()
    ) -> WallpaperPerformanceProfile {
        if isSnoozeActive(globalSettings: globalSettings, now: now) {
            return .suspended
        }
        if globalSettings.pauseOnFullScreen && isHiddenByFullScreen {
            return .suspended
        }

        // Battery pause is applied by ScreenManager, not encoded as quality.
        return .quality
    }

    /// True iff the user-driven snooze deadline is in the future. Decision
    /// chain order: snooze > battery > fullscreen > schedule > playlist.
    static func isSnoozeActive(globalSettings: GlobalSettings, now: Date = Date()) -> Bool {
        guard let until = globalSettings.snoozeUntil else { return false }
        return until > now
    }

    static func shouldPauseForPower(
        globalSettings: GlobalSettings,
        powerSource: PowerMonitor.PowerSource,
        now: Date = Date()
    ) -> Bool {
        if isSnoozeActive(globalSettings: globalSettings, now: now) {
            return true
        }

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

    static func shouldEnableFullScreenFallbackPolling(
        globalSettings: GlobalSettings,
        hasConfiguredWallpaperSessions: Bool
    ) -> Bool {
        globalSettings.pauseOnFullScreen && hasConfiguredWallpaperSessions
    }
}
