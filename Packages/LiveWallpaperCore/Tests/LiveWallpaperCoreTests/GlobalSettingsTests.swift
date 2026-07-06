import Foundation
import Testing
@testable import LiveWallpaperCore

@Suite("GlobalSettings")
struct GlobalSettingsTests {

    @Test("Legacy JSON without globalShortcutsEnabled decodes to true")
    func legacyDecodeDefaultsToTrue() throws {
        // Snapshot from before the flag existed: missing key must default to
        // true so users upgrading from an older build keep their hot keys.
        let legacyJSON = """
        {
          "globalPauseOnBattery": false,
          "preservePlaybackOnLock": false,
          "startOnLogin": false,
          "defaultFrameRateLimit": 60,
          "pauseOnFullScreen": true,
          "showInDock": false
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: legacyJSON)

        #expect(decoded.globalShortcutsEnabled == true)
        #expect(decoded.globalShortcuts.isEmpty)
    }

    @Test("Round-trip preserves globalShortcutsEnabled when explicitly disabled")
    func roundTripDisabled() throws {
        var settings = GlobalSettings()
        settings.globalShortcutsEnabled = false

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: data)

        #expect(decoded.globalShortcutsEnabled == false)
    }

    @Test("Default initializer enables the global shortcut surface")
    func defaultInitEnablesSurface() {
        let settings = GlobalSettings()
        #expect(settings.globalShortcutsEnabled == true)
    }

    @Test("Import bundle preserves the imported globalShortcutsEnabled value")
    func importPreservesDisabledFlag() throws {
        // Real user preference (unlike developerModeEnabled, which we scrub):
        // a backup with the surface disabled must restore disabled.
        var snapshot = GlobalSettings()
        snapshot.globalShortcutsEnabled = false

        let data = try JSONEncoder().encode(snapshot)
        let restored = try JSONDecoder().decode(GlobalSettings.self, from: data)

        #expect(restored.globalShortcutsEnabled == false)
    }

    @Test("Default initializer enables window-occlusion pause")
    func defaultInitEnablesOcclusionPause() {
        #expect(GlobalSettings().pauseOnWindowOcclusion == true)
    }

    @Test("Legacy JSON without the occlusion key defaults to true (power-saving)")
    func legacyOcclusionKeyDefaultsToTrue() throws {
        let legacyJSON = """
        {
          "globalPauseOnBattery": false,
          "pauseOnFullScreen": true,
          "showInDock": false
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: legacyJSON)

        #expect(decoded.pauseOnWindowOcclusion == true)
    }

    @Test("An explicitly stored occlusion=false still round-trips as false")
    func explicitOcclusionFalseSurvivesRoundTrip() throws {
        var settings = GlobalSettings()
        settings.pauseOnWindowOcclusion = false

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: data)

        #expect(decoded.pauseOnWindowOcclusion == false)
    }

    @Test("A malformed history row drops only that row, not the whole import list")
    func lossyDecodeSalvagesGoodHistoryEntries() throws {
        let good = makeHistoryEntry("100")
        let alsoGood = makeHistoryEntry("200")
        var settings = GlobalSettings()
        settings.recentWPEImports = [good, alsoGood]

        // Encode, corrupt the FIRST history element into an object missing the
        // required WPEOrigin fields, then re-encode and decode.
        let data = try JSONEncoder().encode(settings)
        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var imports = try #require(object["recentWPEImports"] as? [[String: Any]])
        try #require(imports.count == 2)
        imports[0] = ["origin": ["not": "a valid origin"]]  // malformed row
        object["recentWPEImports"] = imports
        let corrupted = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: corrupted)

        // The good row survives; only the malformed one is dropped.
        #expect(decoded.recentWPEImports.map(\.origin.workshopID) == ["200"])
    }

    @Test("A completely malformed history array decodes to empty, not a throw")
    func lossyDecodeHandlesFullyBrokenArray() throws {
        let brokenJSON = """
        {
          "recentWPEImports": [ {"bad": 1}, "junk", 42, null ]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: brokenJSON)

        #expect(decoded.recentWPEImports.isEmpty)
    }

    // MARK: - Helpers

    private func makeHistoryEntry(_ workshopID: String) -> WPEHistoryEntry {
        WPEHistoryEntry(
            origin: WPEOrigin(
                workshopID: workshopID,
                title: "Wallpaper \(workshopID)",
                originalType: .video,
                sourceFolderBookmark: Data(workshopID.utf8),
                cacheRelativePath: "wpe-cache/\(workshopID)",
                previewFileName: "preview.gif"
            ),
            importedAt: Date(timeIntervalSince1970: Double(workshopID) ?? 0)
        )
    }
}
