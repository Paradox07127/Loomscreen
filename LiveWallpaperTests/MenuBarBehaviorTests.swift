import Foundation
import Testing
@testable import LiveWallpaper

/// Validates the recents-list behavior the menu-bar surface depends on:
/// WPE history mutation semantics, idempotent removal, and the absence of
/// NSOpenPanel coupling in `MenuBarContent.swift`. These guarantees keep the
/// menu bar a pure shortcut surface backed by `BookmarkStore` + WPE history,
/// rather than triggering Open dialogs from the system menu.
@Suite("MenuBar shortcut + recents behavior", .serialized)
@MainActor
struct MenuBarBehaviorTests {

    // MARK: - WPE history removal semantics

    @Test("Removing a known WPE import drops it from the recents list")
    func removingKnownImportDropsIt() throws {
        withIsolatedGlobalSettings {
            let manager = SettingsManager.shared
            manager.recordWPEImport(makeEntry("alpha"))
            manager.recordWPEImport(makeEntry("beta"))

            manager.removeWPEImport(workshopID: "alpha")

            let ids = manager.loadGlobalSettings().recentWPEImports.map(\.origin.workshopID)
            #expect(ids == ["beta"])
        }
    }

    @Test("Removing an unknown WPE import is a no-op (no notification posted)")
    func removingUnknownImportIsNoOp() throws {
        withIsolatedGlobalSettings {
            let manager = SettingsManager.shared
            manager.recordWPEImport(makeEntry("alpha"))

            let observer = NotificationObserver(name: .wpeHistoryDidChange)
            defer { observer.detach() }

            manager.removeWPEImport(workshopID: "ghost-id")

            #expect(observer.callCount == 0)
            let ids = manager.loadGlobalSettings().recentWPEImports.map(\.origin.workshopID)
            #expect(ids == ["alpha"])
        }
    }

    @Test("Removing every entry leaves the recents list empty")
    func removingAllEntriesEmptiesList() throws {
        withIsolatedGlobalSettings {
            let manager = SettingsManager.shared
            manager.recordWPEImport(makeEntry("one"))
            manager.recordWPEImport(makeEntry("two"))
            manager.removeWPEImport(workshopID: "one")
            manager.removeWPEImport(workshopID: "two")

            #expect(manager.loadGlobalSettings().recentWPEImports.isEmpty)
        }
    }

    @Test("Recording an import posts a wpeHistoryDidChange notification")
    func recordingImportPostsNotification() throws {
        withIsolatedGlobalSettings {
            let observer = NotificationObserver(name: .wpeHistoryDidChange)
            defer { observer.detach() }

            SettingsManager.shared.recordWPEImport(makeEntry("notify"))

            #expect(observer.callCount == 1)
        }
    }

    // MARK: - Structural guarantee: MenuBar surface stays panel-free

    @Test("MenuBarContent does not invoke NSOpenPanel directly")
    func menuBarContentHasNoOpenPanelCoupling() throws {
        let candidates = ["LiveWallpaper/Views/MenuBarContent.swift"]
        let bases = [
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent(),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        ]

        for relative in candidates {
            guard let source = bases
                .lazy
                .map({ $0.appendingPathComponent(relative) })
                .first(where: { FileManager.default.fileExists(atPath: $0.path) })
            else {
                Issue.record("Could not locate \(relative); fix the test path resolver")
                return
            }
            let contents = try String(contentsOf: source, encoding: .utf8)
            #expect(!contents.contains("NSOpenPanel"),
                    "MenuBarContent must stay free of NSOpenPanel — keep it a shortcut surface only")
        }
    }

    @Test("MenuBarContent exposes video volume without opening a panel")
    func menuBarContentExposesVideoVolumeControl() throws {
        let source = try readMenuBarSource()

        #expect(source.contains("Slider("))
        #expect(source.contains("updateVideoVolume"))
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
            importedAt: Date(timeIntervalSince1970: 0),
            lastUsedAt: lastUsedAt
        )
    }

    private func readMenuBarSource() throws -> String {
        let relative = "LiveWallpaper/Views/MenuBarContent.swift"
        let bases = [
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent(),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        ]

        guard let source = bases
            .lazy
            .map({ $0.appendingPathComponent(relative) })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) })
        else {
            Issue.record("Could not locate \(relative); fix the test path resolver")
            return ""
        }
        return try String(contentsOf: source, encoding: .utf8)
    }
}





/// Captures the number of times a notification fires. Synchronous observer
/// keeps the body race-free under Swift 6; the lock guards the count so we
/// can mark the type Sendable without main-actor isolation, which lets
/// `deinit` clean the observer up in any cleanup order the runtime picks.
private final class NotificationObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0
    private var token: NSObjectProtocol?

    init(name: Notification.Name) {
        token = NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.bump()
        }
    }

    deinit {
        detach()
    }

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _callCount
    }

    func detach() {
        if let token {
            NotificationCenter.default.removeObserver(token)
            self.token = nil
        }
    }

    private func bump() {
        lock.lock(); defer { lock.unlock() }
        _callCount += 1
    }
}
