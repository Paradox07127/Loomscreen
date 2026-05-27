import Foundation
import CoreGraphics
import Testing
@testable import LiveWallpaperCore

@MainActor
@Suite("ConfigurationStore fingerprint fallback")
struct ConfigurationFingerprintMigrationTests {

    @Test("Direct ID hit returns cached config and back-fills missing fingerprint")
    func directIDHitBackfillsFingerprint() {
        let fakePersistence = InMemoryConfigPersistence()
        let store = WallpaperConfigurationStore(persistence: fakePersistence)

        let original = makeVideoConfig(screenID: 42, fingerprint: nil)
        store.save(original)
        store.clearCache()

        let resolved = store.get(for: 42, fingerprint: "V:M:S")
        #expect(resolved?.screenID == 42)
        #expect(resolved?.displayFingerprint == "V:M:S")
        #expect(fakePersistence.allConfigs[42]?.displayFingerprint == "V:M:S")
    }

    @Test("ID miss + fingerprint hit migrates screenID and persists")
    func fingerprintMigration() {
        let fakePersistence = InMemoryConfigPersistence()
        let store = WallpaperConfigurationStore(persistence: fakePersistence)

        let originalConfig = makeVideoConfig(screenID: 42, fingerprint: "V:M:S")
        store.save(originalConfig)
        store.clearCache()

        let resolved = store.get(for: 999, fingerprint: "V:M:S")

        #expect(resolved?.screenID == 999)
        #expect(resolved?.displayFingerprint == "V:M:S")
        #expect(fakePersistence.allConfigs[42] == nil)
        #expect(fakePersistence.allConfigs[999]?.displayFingerprint == "V:M:S")
        if case .video = fakePersistence.allConfigs[999]?.activeWallpaper {
            // ok
        } else {
            Issue.record("Migrated config lost its wallpaper content")
        }
    }

    @Test("ID miss + fingerprint miss returns nil")
    func bothMissReturnsNil() {
        let fakePersistence = InMemoryConfigPersistence()
        let store = WallpaperConfigurationStore(persistence: fakePersistence)

        store.save(makeVideoConfig(screenID: 42, fingerprint: "V:M:S"))
        store.clearCache()

        let resolved = store.get(for: 999, fingerprint: "OTHER:M:S")
        #expect(resolved == nil)
        #expect(fakePersistence.allConfigs[42]?.screenID == 42)
    }

    @Test("Unknown fingerprint never triggers scan")
    func unknownFingerprintSkipsScan() {
        let fakePersistence = InMemoryConfigPersistence()
        let store = WallpaperConfigurationStore(persistence: fakePersistence)

        store.save(makeVideoConfig(screenID: 42, fingerprint: "V:M:S"))
        store.clearCache()

        let resolved = store.get(for: 999, fingerprint: "unknown:Display 1")
        #expect(resolved == nil)
        #expect(fakePersistence.allConfigs[42]?.screenID == 42)
    }

    @Test("Nil fingerprint skips scan (preserves nil-fallback safety)")
    func nilFingerprintSkipsScan() {
        let fakePersistence = InMemoryConfigPersistence()
        let store = WallpaperConfigurationStore(persistence: fakePersistence)

        store.save(makeVideoConfig(screenID: 42, fingerprint: "V:M:S"))
        store.clearCache()

        let resolved = store.get(for: 999, fingerprint: nil)
        #expect(resolved == nil)
    }

    private func makeVideoConfig(
        screenID: CGDirectDisplayID,
        fingerprint: String?
    ) -> ScreenConfiguration {
        var config = ScreenConfiguration(
            screenID: screenID,
            videoBookmarkData: Data([0x42, 0x42])
        )
        config.displayFingerprint = fingerprint
        return config
    }
}

@MainActor
private final class InMemoryConfigPersistence: ScreenConfigurationPersisting {
    private(set) var allConfigs: [CGDirectDisplayID: ScreenConfiguration] = [:]

    func getConfiguration(for screenID: CGDirectDisplayID) -> ScreenConfiguration? {
        allConfigs[screenID]
    }

    func saveConfiguration(_ configuration: ScreenConfiguration) {
        allConfigs[configuration.screenID] = configuration
    }

    func cleanSettingsForScreen(_ screenID: CGDirectDisplayID) {
        allConfigs.removeValue(forKey: screenID)
    }

    func loadConfigurations() -> [ScreenConfiguration] {
        Array(allConfigs.values)
    }

    func replaceAllConfigurations(_ configurations: [ScreenConfiguration]) {
        allConfigs = Dictionary(uniqueKeysWithValues: configurations.map { ($0.screenID, $0) })
    }
}
