import Foundation
import Testing
@testable import LiveWallpaper

@Suite("WPE history", .serialized) @MainActor
struct WPEHistoryTests {
    @Test("Record pushes to front")
    func recordPushesToFront() throws {
        withIsolatedGlobalSettings {
            let manager = SettingsManager.shared
            manager.recordWPEImport(makeEntry("1"))
            manager.recordWPEImport(makeEntry("2"))

            let ids = manager.loadGlobalSettings().recentWPEImports.map(\.origin.workshopID)
            #expect(ids == ["2", "1"])
        }
    }

    @Test("Duplicate moves to front")
    func duplicateMovesToFront() throws {
        withIsolatedGlobalSettings {
            let manager = SettingsManager.shared
            let lastUsedAt = Date(timeIntervalSince1970: 50)
            manager.recordWPEImport(makeEntry("1"))
            manager.recordWPEImport(makeEntry("2"))
            manager.recordWPEImport(makeEntry("1", title: "Updated", lastUsedAt: lastUsedAt))

            let recent = manager.loadGlobalSettings().recentWPEImports
            #expect(recent.map(\.origin.workshopID) == ["1", "2"])
            #expect(recent.first?.origin.title == "Updated")
            #expect(recent.first?.lastUsedAt == lastUsedAt)
        }
    }

    @Test("Caps at maxRecentWPEImports, dropping the oldest")
    func capsAtMaxRecentImports() throws {
        withIsolatedGlobalSettings {
            let manager = SettingsManager.shared
            // Cap raised 20 → 200 in 84c1276 (Installed library is the
            // primary managed store now). Overshoot by 5 to exercise it.
            let cap = SettingsManager.maxRecentWPEImports
            let total = cap + 5
            for index in 0..<total {
                manager.recordWPEImport(makeEntry("\(index)"))
            }

            let ids = manager.loadGlobalSettings().recentWPEImports.map(\.origin.workshopID)
            #expect(ids.count == cap)
            #expect(ids.first == "\(total - 1)")
            #expect(ids.last == "5")
        }
    }

    @Test("Round trips through GlobalSettings Codable")
    func roundTripsThroughGlobalSettingsCodable() throws {
        let entry = makeEntry("42", title: "Round Trip", lastUsedAt: Date(timeIntervalSince1970: 123))
        let settings = GlobalSettings(recentWPEImports: [entry])

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: data)

        #expect(decoded.recentWPEImports == [entry])
    }

    private func withIsolatedGlobalSettings(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let keys = [
            "screenConfigurations",
            "globalSettings",
            "AerialsLibrary.DirectoryBookmark",
            "WallpaperBookmarks.v1",
            "TrustedHTMLHosts.v1",
        ]
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

    private func makeEntry(
        _ workshopID: String,
        title: String? = nil,
        lastUsedAt: Date? = nil
    ) -> WPEHistoryEntry {
        let origin = WPEOrigin(
            workshopID: workshopID,
            title: title ?? "Wallpaper \(workshopID)",
            originalType: .video,
            sourceFolderBookmark: Data(workshopID.utf8),
            cacheRelativePath: "wpe-cache/\(workshopID)",
            previewFileName: "preview.gif"
        )
        return WPEHistoryEntry(
            origin: origin,
            importedAt: Date(timeIntervalSince1970: Double(workshopID) ?? 0),
            lastUsedAt: lastUsedAt
        )
    }
}
