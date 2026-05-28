import Foundation
import LiveWallpaperCore
import Testing
@testable import LiveWallpaper

@Suite("WallpaperPolicyEngine thermal state")
struct WallpaperPolicyEngineThermalTests {

    @Test("Thermal state participates in every power and fullscreen profile decision")
    func thermalStatePowerAndFullscreenMatrix() {
        let settings = GlobalSettings(pauseOnFullScreen: true)
        let thermalExpectations: [(state: ProcessInfo.ThermalState, suspends: Bool)] = [
            (.nominal, false),
            (.fair, false),
            (.serious, true),
            (.critical, true),
        ]
        let powerSources: [PowerMonitor.PowerSource] = [
            .external,
            .battery(level: 0.80),
        ]
        let fullscreenStates = [false, true]

        for thermalExpectation in thermalExpectations {
            for powerSource in powerSources {
                for isHiddenByFullScreen in fullscreenStates {
                    let profile = WallpaperPolicyEngine.performanceProfile(
                        globalSettings: settings,
                        powerSource: powerSource,
                        isHiddenByFullScreen: isHiddenByFullScreen,
                        thermalState: thermalExpectation.state,
                        isGameModeActive: false
                    )

                    let expectedProfile: WallpaperPerformanceProfile =
                        (isHiddenByFullScreen || thermalExpectation.suspends) ? .suspended : .quality

                    #expect(
                        profile == expectedProfile,
                        "thermal=\(thermalExpectation.state) power=\(powerSource) fs=\(isHiddenByFullScreen) -> expected \(expectedProfile), got \(profile)"
                    )
                }
            }
        }
    }

    @Test("Game mode suspends every thermal/power/fullscreen combination")
    func gameModeSuspendsMatrix() {
        let settings = GlobalSettings(pauseOnFullScreen: true)
        let thermalStates: [ProcessInfo.ThermalState] = [.nominal, .fair, .serious, .critical]
        let powerSources: [PowerMonitor.PowerSource] = [
            .external,
            .battery(level: 0.80),
        ]
        let fullscreenStates = [false, true]

        for thermalState in thermalStates {
            for powerSource in powerSources {
                for isHiddenByFullScreen in fullscreenStates {
                    let profile = WallpaperPolicyEngine.performanceProfile(
                        globalSettings: settings,
                        powerSource: powerSource,
                        isHiddenByFullScreen: isHiddenByFullScreen,
                        thermalState: thermalState,
                        isGameModeActive: true
                    )

                    #expect(
                        profile == .suspended,
                        "gameMode=true thermal=\(thermalState) power=\(powerSource) fs=\(isHiddenByFullScreen) -> expected suspended, got \(profile)"
                    )
                }
            }
        }
    }

    @Test("pauseInGameMode=false neutralises GameModeDetector at the call site")
    func disabledGameModeSettingDoesNotSuspend() {
        // The setting is enforced at the ScreenManager / PlaybackCoordinator
        // call site (it ANDs `pauseInGameMode` with `GameModeDetector.isActive`),
        // so when the user disables it the policy engine never sees
        // `isGameModeActive: true`. Verify the policy engine itself does NOT
        // treat the setting as an extra knob — it only reacts to the AND'd
        // boolean that callers pass in.
        let settings = GlobalSettings(pauseOnFullScreen: false, pauseInGameMode: false)

        let profile = WallpaperPolicyEngine.performanceProfile(
            globalSettings: settings,
            powerSource: .external,
            isHiddenByFullScreen: false,
            thermalState: .nominal,
            isGameModeActive: false   // caller already AND'd with the setting
        )

        #expect(profile == .quality)
    }
}
