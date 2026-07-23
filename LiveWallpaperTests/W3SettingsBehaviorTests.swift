#if DEBUG && !LITE_BUILD
import Foundation
import Testing
@testable import LiveWallpaper

@Suite("W3: Developer Tools reset covers every diagnostic key") @MainActor
struct W3DeveloperToolsResetTests {
    @Test("Oracle and diagnostic keys are all in the single reset list")
    func allKnownKeysInResetList() {
        let keys = Set(DeveloperToolsView.allDiagnosticDefaultsKeys)
        let expected: Set<String> = [
            "WPESceneDebugArtifactsEnabled",
            "WPEParticlePrewarmEnabled",
            "WPEAudioDebugLog",
            "WPEPuppetDeferMeshWarp",
            "WPEDumpScenePasses",
            "WPEDumpScenePassesAtTime",
            "WPEMetalCaptureScene",
            "WPEOracleEnabled",
            "WPEOracleFreezeTime",
        ]
        #expect(keys.isSuperset(of: expected))
    }

    @Test("clearAllDiagnosticDefaults removes every listed key")
    func clearRemovesEveryKey() throws {
        let suiteName = "W3DeveloperToolsResetTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for key in DeveloperToolsView.allDiagnosticDefaultsKeys {
            defaults.set(true, forKey: key)
        }
        defaults.set(12.5, forKey: DeveloperToolsView.oracleFreezeTimeKey)

        DeveloperToolsView.clearAllDiagnosticDefaults(in: defaults)

        for key in DeveloperToolsView.allDiagnosticDefaultsKeys {
            #expect(defaults.object(forKey: key) == nil, "\(key) must be cleared by Reset all")
        }
    }

}
#endif
