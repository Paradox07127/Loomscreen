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

    @Test("MenuBarContent is the compact control center, not the legacy dashboard panel")
    func menuBarContentDropsLegacyDashboardPanel() throws {
        let contents = try sourceText(for: "LiveWallpaper/Views/MenuBarContent.swift")

        #expect(!contents.contains("DashboardChip"),
                "The menu bar surface should use a one-line resource strip, not the old expandable dashboard chips")
        #expect(!contents.contains("RAMScopePicker("),
                "The compact control center should not expose dashboard RAM scope controls")
        #expect(!contents.contains("commitWebURLEntry"),
                "Add Wallpaper should route to the main window flow, not keep inline URL entry state")
        #expect(!contents.contains("Pause on Full-Screen Apps"),
                "Full-screen pause belongs in More/settings, not as a primary menu-bar control")
        #expect(contents.contains("arrow.up.right"),
                "Display rows should expose a visible window arrow again for discoverability")
    }

    @Test("MenuBarContent wires every compact control to the owning app interface")
    func menuBarContentWiresCompactControls() throws {
        let contents = try sourceText(for: "LiveWallpaper/Views/MenuBarContent.swift")

        #expect(contents.contains("screenManager.togglePlayback()"),
                "Pause All must call ScreenManager.togglePlayback()")
        #expect(contents.contains("toggleGlobalMute()"),
                "Mute must flip all display audio through the menu-bar helper")
        #expect(contents.contains("commitGlobalToggles()"),
                "Battery policy must preserve GlobalSettings by using the mutate-then-save commit path")
        #expect(contents.contains("openSettingsForScreen(screen.id)"),
                "Clicking a display row must open settings for that display")
        #expect(contents.contains("openAction: { invokeOpenScreenSettings(screen.id) }"),
                "Display-row open affordances must dismiss the menu-bar window before opening settings")
        #expect(contents.contains("private func invokeOpenScreenSettings(_ id: CGDirectDisplayID)"),
                "Display-row settings navigation should share a dismissing helper instead of calling openSettingsForScreen directly")
        #expect(contents.contains("screenManager.regressPlaylist(for: screen)"),
                "Previous playlist control must call ScreenManager.regressPlaylist(for:)")
        #expect(contents.contains("screenManager.advancePlaylist(for: screen)"),
                "Next playlist control must call ScreenManager.advancePlaylist(for:)")
        #expect(contents.contains("invokeAddWallpaperWindow()"),
                "Add Wallpaper should directly open the main settings window instead of asking for a type in the menu bar")
        #expect(contents.contains(".glassEffect("),
                "The menu bar control center should use Liquid Glass surfaces")
        #expect(contents.contains("screenManager.setWallpapersEnabled("),
                "The On/Off switch must call ScreenManager.setWallpapersEnabled(_:)")
    }

    @Test("ScreenManager owns the menu-bar wallpaper enabled switch")
    func screenManagerOwnsWallpaperEnabledSwitch() throws {
        let contents = try sourceText(for: "LiveWallpaper/ScreenManager.swift")

        #expect(contents.contains("func setWallpapersEnabled(_ enabled: Bool)"),
                "The menu bar should not directly manipulate runtime sessions")
    }

    @Test("MenuBarContent uses the larger readable settings surface")
    func menuBarContentUsesLargerReadableSettingsSurface() throws {
        let contents = try sourceText(for: "LiveWallpaper/Views/MenuBarContent.swift")

        #expect(contents.contains("static let popoverWidth: CGFloat = 292"),
                "The control center should be wider again so controls have breathing room")
        #expect(contents.contains("static let outerPadding: CGFloat = 12"),
                "The control center should reserve more outer padding for the Liquid Glass surface")
        #expect(contents.contains("static let rowPaddingVertical: CGFloat = 8"),
                "Display rows should have more vertical padding than the dense pass")
        #expect(contents.contains("sectionLabel(\"SETTINGS\")"),
                "The global controls section should be labeled Settings instead of All Displays")
        #expect(contents.contains("ReadableGlassSurface"),
                "Custom glass buttons should add a readable edge/contrast layer")
        #expect(contents.contains("@State private var activeOverlay: MenuBarOverlay?"),
                "Menu-bar secondary controls should be owned by one in-window overlay state")
        #expect(contents.contains("MenuBarInlineOverlayPanel"),
                "More should use an in-window overlay instead of creating a nested AppKit popover")
    }

    @Test("Menu bar gear opens the general settings page")
    func menuBarGearOpensGeneralSettings() throws {
        let appSource = try sourceText(for: "LiveWallpaper/LiveWallpaperApp.swift")

        #expect(appSource.contains("opensGeneralSettings: Bool = false"),
                "AppDelegate.showSettings should support opening the General settings page directly")
        #expect(appSource.contains("let initialNavigation: Navigation? = opensGeneralSettings ? .general"),
                "A newly-created settings window should land on General when the menu-bar gear is used")
        #expect(appSource.contains("showSettings(opensGeneralSettings: true)"),
                "The menu-bar gear should call the General settings route, not the default preview route")
    }

    @Test("Menu bar footer exposes a dedicated red quit button")
    func menuBarFooterExposesDedicatedRedQuitButton() throws {
        let contents = try sourceText(for: "LiveWallpaper/Views/MenuBarContent.swift")

        #expect(contents.contains("MenuBarQuitButton"),
                "Quit should be a dedicated footer control, not only a nested More item")
        #expect(contents.contains("Button(action: invokeQuit)"),
                "The dedicated quit button should be wired directly from the footer")
        #expect(contents.contains(".readableGlass(radius: 11, tint: .red, interactive: true)"),
                "Quit should use the red danger treatment with the roomier footer control shape")
        #expect(contents.contains("NSApp.terminate(nil)"),
                "Quit should call the standard AppKit terminate action")
    }

    @Test("Menu bar secondary actions stay inside the menu-bar window")
    func menuBarSecondaryActionsStayInsideMenuBarWindow() throws {
        let contents = try sourceText(for: "LiveWallpaper/Views/MenuBarContent.swift")

        #expect(contents.contains("private enum MenuBarOverlay"),
                "More should still use lightweight menu-bar overlay state")
        #expect(contents.contains("private var activeOverlayContent: some View"),
                "The menu-bar window should render secondary actions as inline content")
        #expect(contents.contains(".overlay(alignment: .bottomTrailing)"),
                "Secondary actions should be positioned inside the existing menu-bar window")
        #expect(!contents.contains("toggleOverlay(.addWallpaper)"),
                "Add Wallpaper should no longer open a second-step menu-bar overlay")
        #expect(!contents.contains("case addWallpaper"),
                "The add-wallpaper type picker should be removed from the menu-bar overlay")
        #expect(contents.contains("Button(action: invokeAddWallpaperWindow)"),
                "Add Wallpaper should be a direct one-click route to the main window")
        #expect(contents.contains("toggleOverlay(.more)"),
                "More should use the shared in-window overlay, not a nested popover")
        #expect(!contents.contains(".popover(isPresented: $isMorePopoverPresented"),
                "Nested SwiftUI popovers are a cold-start latency source inside MenuBarExtra windows")
        #expect(!contents.contains("Menu {"),
                "System Menu construction should not be on the hot path for menu-bar footer actions")
    }

    @Test("Settings window can be prewarmed before the first menu-bar click")
    func settingsWindowCanBePrewarmedBeforeFirstMenuBarClick() throws {
        let appSource = try sourceText(for: "LiveWallpaper/LiveWallpaperApp.swift")

        #expect(appSource.contains("scheduleSettingsWindowPrewarm()"),
                "Startup should schedule an idle settings-window prewarm outside tests/onboarding")
        #expect(appSource.contains("func prewarmSettingsWindow()"),
                "AppDelegate should expose a prewarm path that creates the settings window without showing it")
        #expect(appSource.contains("makeSettingsWindowController("),
                "showSettings and prewarmSettingsWindow should share the same window construction path")
        #expect(appSource.contains("postSettingsWindowRequest("),
                "A reused prewarmed window should receive navigation/add requests after being shown")
    }

    @Test("Saving unrelated global settings does not touch login item registration")
    func savingUnrelatedGlobalSettingsDoesNotTouchLoginItemRegistration() throws {
        let settingsSource = try sourceText(for: "LiveWallpaper/SettingsManager.swift")

        #expect(settingsSource.contains("previousStartOnLogin"),
                "SettingsManager should compare the old login-item preference before saving")
        #expect(settingsSource.contains("if previousStartOnLogin != settings.startOnLogin"),
                "ServiceManagement work should run only when startOnLogin actually changes")
    }

    // MARK: - Toggle commit preserves unrelated GlobalSettings fields

    /// Regression for the menu-bar toggle commit path. The old version of
    /// `MenuBarContent.commitGlobalToggles` rebuilt `GlobalSettings(...)`
    /// with only a handful of named arguments, silently dropping every
    /// other field on each toggle press (defaultFrameRateLimit, showInDock,
    /// weatherLocation, globalShortcuts, recentWPEImports, etc.). The fix
    /// is mutate-then-save; this test enforces it stays that way.
    @Test("Mutating only the menu-bar toggles preserves the rest of GlobalSettings")
    func togglesPreserveOtherGlobalSettingsFields() throws {
        withIsolatedGlobalSettings {
            let manager = SettingsManager.shared
            var seed = manager.loadGlobalSettings()
            seed.preservePlaybackOnLock = true
            seed.defaultFrameRateLimit = .fps30
            seed.showInDock = true
            seed.minimumBatteryLevel = 0.42
            manager.saveGlobalSettings(seed)
            manager.recordWPEImport(makeEntry("survives"))

            // Mimic MenuBarContent.commitGlobalToggles using mutate-then-save.
            var settings = manager.loadGlobalSettings()
            settings.globalPauseOnBattery = !settings.globalPauseOnBattery
            settings.pauseOnFullScreen = !settings.pauseOnFullScreen
            manager.saveGlobalSettings(settings)

            let after = manager.loadGlobalSettings()
            #expect(after.preservePlaybackOnLock == true,
                    "preservePlaybackOnLock must survive a toggle commit")
            #expect(after.defaultFrameRateLimit == .fps30,
                    "defaultFrameRateLimit must survive a toggle commit")
            #expect(after.showInDock == true,
                    "showInDock must survive a toggle commit")
            #expect(after.minimumBatteryLevel == 0.42,
                    "minimumBatteryLevel must survive a toggle commit")
            #expect(after.recentWPEImports.map(\.origin.workshopID) == ["survives"],
                    "WPE history must survive a toggle commit")
        }
    }

    // MARK: - Helpers

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

    private func sourceText(for relativePath: String) throws -> String {
        let bases = [
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent(),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        ]

        guard let source = bases
            .lazy
            .map({ $0.appendingPathComponent(relativePath) })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) })
        else {
            throw CocoaError(.fileNoSuchFile)
        }

        return try String(contentsOf: source, encoding: .utf8)
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
