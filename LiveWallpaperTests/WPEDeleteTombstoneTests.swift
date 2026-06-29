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

    @Test("Recording a delete tombstone is idempotent")
    func recordIsIdempotent() throws {
        withIsolatedGlobalSettings {
            let manager = SettingsManager.shared
            manager.recordWPEDeleteTombstone(workshopID: "999")
            manager.recordWPEDeleteTombstone(workshopID: "999")
            #expect(manager.loadGlobalSettings().deletedWorkshopIDs.filter { $0 == "999" }.count == 1)
        }
    }

    @Test("A passive re-import (apply / auto-scan) leaves the tombstone in place")
    func passiveReimportKeepsTombstone() throws {
        withIsolatedGlobalSettings {
            let manager = SettingsManager.shared
            manager.recordWPEDeleteTombstone(workshopID: "999")

            manager.recordWPEImport(makeReaddedEntry("999"))

            let after = manager.loadGlobalSettings()
            #expect(after.deletedWorkshopIDs.contains("999"),
                    "a passive record must NOT resurrect a deleted item on the next library scan")
            #expect(after.recentWPEImports.first?.origin.workshopID == "999")
        }
    }

    @Test("An explicit re-acquire clears the tombstone")
    func deliberateReimportClears() throws {
        withIsolatedGlobalSettings {
            let manager = SettingsManager.shared
            manager.recordWPEDeleteTombstone(workshopID: "999")

            manager.recordWPEImport(makeReaddedEntry("999"), clearsDeleteTombstone: true)

            let after = manager.loadGlobalSettings()
            #expect(!after.deletedWorkshopIDs.contains("999"),
                    "an explicit re-acquire must clear the delete tombstone")
            #expect(after.recentWPEImports.first?.origin.workshopID == "999")
        }
    }

    private func makeReaddedEntry(_ workshopID: String) -> WPEHistoryEntry {
        WPEHistoryEntry(
            origin: WPEOrigin(
                workshopID: workshopID,
                title: "Re-added",
                originalType: .video,
                sourceFolderBookmark: Data([0xCC]),
                cacheRelativePath: "wpe-cache/\(workshopID)",
                previewFileName: nil
            ),
            importedAt: Date(timeIntervalSince1970: 1),
            lastUsedAt: nil
        )
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
