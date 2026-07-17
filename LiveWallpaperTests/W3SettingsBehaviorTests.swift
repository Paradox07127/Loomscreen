#if DEBUG && !LITE_BUILD
import Foundation
import Testing
@testable import LiveWallpaper

/// W3 finding: "Reset all" in Developer Tools missed the oracle keys because
/// the reset iterated two ad-hoc lists instead of one shared source of truth.
/// These tests lock the unified list: every rendered flag key must be in it,
/// and clearing it must actually remove every key.
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

    @Test("Reset all also disables and clears volatile XPC diagnostics")
    func resetClearsVolatileXPCDiagnostics() throws {
        let suiteName = "W3DeveloperToolsResetTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let wasEnabled = WPESceneScriptXPCDiagnostics.isEnabled
        defer {
            WPESceneScriptXPCDiagnostics.reset()
            WPESceneScriptXPCDiagnostics.setEnabled(wasEnabled)
        }

        WPESceneScriptXPCDiagnostics.setEnabled(true)
        WPESceneScriptXPCDiagnostics.reset()
        let token = try #require(WPESceneScriptXPCDiagnostics.beginAttempt(
            requestedItemCount: 1,
            uniqueSourceCount: 1,
            deadlineMilliseconds: 50,
            startedAtNanoseconds: 1
        ))
        WPESceneScriptXPCDiagnostics.finish(
            token,
            outcome: .completed,
            measurements: .init(),
            finishedAtNanoseconds: 2
        )

        DeveloperToolsView.clearAllDiagnosticDefaults(in: defaults)

        #expect(!WPESceneScriptXPCDiagnostics.isEnabled)
        #expect(WPESceneScriptXPCDiagnostics.snapshot().attempts.isEmpty)
    }
}
#endif
