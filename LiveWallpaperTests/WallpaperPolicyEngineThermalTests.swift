import Foundation
import LiveWallpaperCore
import Testing
@testable import LiveWallpaper

extension WallpaperPolicyInputs {
    /// Test factory with "nothing suspends" defaults so each test only sets the
    /// signal under exercise.
    static func test(
        powerSource: PowerMonitor.PowerSource = .external,
        isHiddenByFullScreen: Bool = false,
        isWindowOccluding: Bool = false,
        isApplicationRuleActive: Bool = false,
        thermalState: ProcessInfo.ThermalState = .nominal,
        isGameModeActive: Bool = false,
        isUserAbsent: Bool = false,
        isUnderMemoryPressure: Bool = false,
        isFrontmostExcludedByRule: Bool = false
    ) -> WallpaperPolicyInputs {
        WallpaperPolicyInputs(
            powerSource: powerSource,
            isHiddenByFullScreen: isHiddenByFullScreen,
            isWindowOccluding: isWindowOccluding,
            isApplicationRuleActive: isApplicationRuleActive,
            thermalState: thermalState,
            isGameModeActive: isGameModeActive,
            isUserAbsent: isUserAbsent,
            isUnderMemoryPressure: isUnderMemoryPressure,
            isFrontmostExcludedByRule: isFrontmostExcludedByRule
        )
    }
}

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
                        inputs: .test(
                            powerSource: powerSource,
                            isHiddenByFullScreen: isHiddenByFullScreen,
                            thermalState: thermalExpectation.state
                        ),
                        settings: settings
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
                        inputs: .test(
                            powerSource: powerSource,
                            isHiddenByFullScreen: isHiddenByFullScreen,
                            thermalState: thermalState,
                            isGameModeActive: true
                        ),
                        settings: settings
                    )

                    #expect(
                        profile == .suspended,
                        "gameMode=true thermal=\(thermalState) power=\(powerSource) fs=\(isHiddenByFullScreen) -> expected suspended, got \(profile)"
                    )
                }
            }
        }
    }

    @Test("pauseInGameMode=false neutralises an active game-mode signal in the engine")
    func disabledGameModeSettingDoesNotSuspend() {
        // The engine owns the setting gating now: even with a live game-mode
        // signal, `pauseInGameMode: false` must not suspend.
        let settings = GlobalSettings(pauseOnFullScreen: false, pauseInGameMode: false)

        let profile = WallpaperPolicyEngine.performanceProfile(
            inputs: .test(isGameModeActive: true),
            settings: settings
        )

        #expect(profile == .quality)
    }

    @Test("Memory pressure suspends regardless of other signals")
    func memoryPressureSuspends() {
        let settings = GlobalSettings(pauseOnFullScreen: false, pauseInGameMode: false)

        let profile = WallpaperPolicyEngine.performanceProfile(
            inputs: .test(isUnderMemoryPressure: true),
            settings: settings
        )

        #expect(profile == .suspended)
    }
}
