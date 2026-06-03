import Foundation
import Testing
@testable import LiveWallpaper

/// Locks the targeted delete fix: deleting a downloaded scene must tombstone the
/// workshop id so the auto-import scan can't resurrect it from a still-present
/// SteamCMD download, and a later deliberate re-import must clear that tombstone.
@Suite("WPE delete tombstone lifecycle", .serialized) @MainActor
struct WPEDeleteTombstoneTests {
    @Test("A legacy settings blob without the key decodes to an empty tombstone list")
    func legacyDecodeDefaultsEmpty() throws {
        let settings = try JSONDecoder().decode(GlobalSettings.self, from: Data("{}".utf8))
        #expect(settings.deletedWorkshopIDs.isEmpty)
    }

    @Test("deletedWorkshopIDs round-trips through Codable")
    func roundTripsThroughCodable() throws {
        var settings = GlobalSettings()
        settings.deletedWorkshopIDs = ["123", "456"]
        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.deletedWorkshopIDs == ["123", "456"])
    }

    @Test("Recording a delete tombstone is idempotent; a deliberate re-import clears it")
    func recordThenReimportClears() throws {
        withIsolatedGlobalSettings {
            let manager = SettingsManager.shared

            manager.recordWPEDeleteTombstone(workshopID: "999")
            manager.recordWPEDeleteTombstone(workshopID: "999")
            #expect(manager.loadGlobalSettings().deletedWorkshopIDs.filter { $0 == "999" }.count == 1)

            manager.recordWPEImport(
                WPEHistoryEntry(
                    origin: WPEOrigin(
                        workshopID: "999",
                        title: "Re-added",
                        originalType: .video,
                        sourceFolderBookmark: Data([0xCC]),
                        cacheRelativePath: "wpe-cache/999",
                        previewFileName: nil
                    ),
                    importedAt: Date(timeIntervalSince1970: 1),
                    lastUsedAt: nil
                )
            )

            let after = manager.loadGlobalSettings()
            #expect(!after.deletedWorkshopIDs.contains("999"),
                    "a deliberate re-import must clear the delete tombstone")
            #expect(after.recentWPEImports.first?.origin.workshopID == "999")
        }
    }

    @Test("An empty workshop id is never tombstoned")
    func emptyIDIgnored() throws {
        withIsolatedGlobalSettings {
            let manager = SettingsManager.shared
            manager.recordWPEDeleteTombstone(workshopID: "")
            #expect(manager.loadGlobalSettings().deletedWorkshopIDs.isEmpty)
        }
    }

    private func withIsolatedGlobalSettings(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let keys = ["screenConfigurations", "globalSettings"]
        let previousValues = keys.reduce(into: [String: Any]()) { result, key in
            result[key] = defaults.object(forKey: key)
        }

        SettingsManager.shared.cleanAllSettings(applyLoginSetting: false)
        defer {
            SettingsManager.shared.cleanAllSettings(applyLoginSetting: false)
            for key in keys {
                if let value = previousValues[key] {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        try body()
    }
}
