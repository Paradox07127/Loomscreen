import Foundation
import LiveWallpaperCore
import Testing
@testable import LiveWallpaper

/// UI-08 E1 behavior lock. These tests intentionally characterize the current
/// General Settings ownership surface before any page-specific state owners are
/// extracted. The mount counters are source-level call-site counts because the
/// current view constructs ServiceManagement/CoreLocation/audio singletons
/// directly and therefore has no runtime spy seam yet.
@Suite("UI-08: General Settings ownership characterization", .serialized)
@MainActor
struct GeneralSettingsOwnershipCharacterizationTests {
    @Test("The root state inventory is fully assigned to candidate domain owners")
    func rootStateInventoryMatchesOwnershipFixture() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/GeneralSettingsView.swift")
        let actual = try Self.storedPropertyNames(in: source)
        let fixtureValues = OwnershipFixture.fieldsByDomain.values.flatMap(Array.init)

        #expect(fixtureValues.count == Set(fixtureValues).count, "A state field must have exactly one candidate owner")
        #expect(actual == Set(fixtureValues))
        #expect(actual.count == 37, "Changing the root state surface requires explicitly re-approving the UI-08 lock")
    }

    @Test("Each page mounts only its own system-capability probe")
    func eachPageMountsOnlyItsOwnSystemCapabilityProbe() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/GeneralSettingsView.swift")
        let propertyDefaults = try Self.slice(
            source,
            from: "struct GeneralSettingsView: View {",
            until: "private let page"
        )
        let initializer = try Self.slice(source, from: "init(page: GeneralSettingsPage = .general) {", until: "var body: some View")
        let scopes = try Self.slice(
            source,
            from: "private var systemStatusScopes: [SystemStatusScope] {",
            until: "private static func initialLoginItemStatus"
        )

        #expect(!propertyDefaults.contains("SMAppService.mainApp.status"))
        #expect(!propertyDefaults.contains("SystemAudioCaptureManager.shared.state"))
        #expect(!propertyDefaults.contains("CLLocationManager().authorizationStatus"))
        #expect(initializer.contains("Self.initialLoginItemStatus(for: page)"))
        #expect(initializer.contains("Self.initialAudioCaptureState(for: page)"))
        #expect(initializer.contains("Self.initialLocationAuthorizationStatus(for: page)"))
        #expect(Self.occurrences(".onAppear { refreshSystemStatusIndicators() }", in: source) == 1)

        for page in [.general, .audioResponse, .weather] as [OwnershipFixture.Page] {
            #expect(
                scopes.contains("case .\(page.rawValue):"),
                "Every Settings page needs an explicit system-probe ownership decision"
            )
            #expect(
                OwnershipFixture.mountCalls(for: page, sku: .pro).settingsReads == 1,
                "All pages still load the shared GlobalSettings snapshot exactly once"
            )
        }

        #expect(scopes.contains("case .general:\n            [.loginItem]"))
        #expect(scopes.contains("case .audioResponse:\n            #if !LITE_BUILD\n            [.audioCapture]"))
        #expect(scopes.contains("case .weather:\n            [.weatherLocation]"))
        #expect(scopes.contains("case .performancePower, .backupRestore, .advanced, .about:\n            []"))

        #expect(OwnershipFixture.mountCalls(for: .general, sku: .pro) == MountCalls(settingsReads: 1, loginStatusReads: 2, audioStateReads: 0, locationStatusReads: 0))
        #expect(OwnershipFixture.mountCalls(for: .audioResponse, sku: .pro) == MountCalls(settingsReads: 1, loginStatusReads: 0, audioStateReads: 2, locationStatusReads: 0))
        #expect(OwnershipFixture.mountCalls(for: .weather, sku: .pro) == MountCalls(settingsReads: 1, loginStatusReads: 0, audioStateReads: 0, locationStatusReads: 2))
        #expect(OwnershipFixture.mountCalls(for: .backupRestore, sku: .lite) == MountCalls(settingsReads: 1, loginStatusReads: 0, audioStateReads: 0, locationStatusReads: 0))
    }

    @Test("Mirrored and unrelated global settings survive a durable manager restart")
    func settingsRoundTripSurvivesManagerRestart() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GeneralSettingsOwnership-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let directory = ConfigurationDirectory(root: root)
        let manager = SettingsManager(directory: directory)
        let existingStartOnLogin = manager.loadGlobalSettings().startOnLogin
        let manualLocation = WeatherLocationPreference.ManualLocation(
            latitude: 40.7128,
            longitude: -74.0060,
            name: "UI-08 Fixture"
        )
        let history = WPEHistoryEntry(
            origin: WPEOrigin(
                workshopID: "ui-08-history",
                title: "Ownership Fixture",
                originalType: .video,
                sourceFolderBookmark: Data([0x08]),
                cacheRelativePath: "wpe-cache/ui-08-history",
                previewFileName: "preview.jpg"
            ),
            importedAt: Date(timeIntervalSince1970: 1_700_000_008),
            lastUsedAt: Date(timeIntervalSince1970: 1_700_000_108)
        )
        let displayDefaults = DisplayDefaults(
            video: DisplayPlaybackDefaults(
                playbackSpeed: 1.25,
                frameRateLimit: .fps24,
                muted: false,
                videoVolume: 0.25
            )
        )
        let expected = GlobalSettings(
            globalPauseOnBattery: true,
            preservePlaybackOnLock: true,
            startOnLogin: existingStartOnLogin,
            pauseOnFullScreen: false,
            pauseInGameMode: false,
            pauseOnWindowOcclusion: false,
            showInDock: true,
            weatherLocation: WeatherLocationPreference(source: .manual, manual: manualLocation),
            globalShortcutsEnabled: false,
            recentWPEImports: [history],
            deletedWorkshopIDs: ["ui-08-deleted"],
            applicationPerformanceRules: [
                ApplicationPerformanceRule(
                    bundleID: "com.example.ui08",
                    displayName: "UI-08 Fixture",
                    trigger: .neverPause
                ),
            ],
            videoCacheMaxBytesPerScreen: 320 * 1024 * 1024,
            displayDefaults: displayDefaults,
            developerModeEnabled: false,
            audioResponseEnabled: true,
            adaptiveFrameRateEnabled: true
        )

        manager.saveGlobalSettings(expected)
        await manager.flushPendingConfigurationWrites()

        let persistedURL = directory.url(for: .globalSettings)
        #expect(FileManager.default.fileExists(atPath: persistedURL.path))

        let restarted = SettingsManager(directory: directory).loadGlobalSettings()
        #expect(restarted.globalPauseOnBattery == expected.globalPauseOnBattery)
        #expect(restarted.preservePlaybackOnLock == expected.preservePlaybackOnLock)
        #expect(restarted.startOnLogin == expected.startOnLogin)
        #expect(restarted.pauseOnFullScreen == expected.pauseOnFullScreen)
        #expect(restarted.pauseInGameMode == expected.pauseInGameMode)
        #expect(restarted.pauseOnWindowOcclusion == expected.pauseOnWindowOcclusion)
        #expect(restarted.showInDock == expected.showInDock)
        #expect(restarted.weatherLocation == expected.weatherLocation)
        #expect(restarted.applicationPerformanceRules == expected.applicationPerformanceRules)
        #expect(restarted.videoCacheMaxBytesPerScreen == expected.videoCacheMaxBytesPerScreen)
        #expect(restarted.developerModeEnabled == expected.developerModeEnabled)
        #expect(restarted.audioResponseEnabled == expected.audioResponseEnabled)
        #expect(restarted.adaptiveFrameRateEnabled == expected.adaptiveFrameRateEnabled)

        // Unrelated values are the read-modify-write canaries: a page owner may
        // not rebuild GlobalSettings from only its own controls.
        #expect(restarted.globalShortcutsEnabled == false)
        #expect(restarted.recentWPEImports == [history])
        #expect(restarted.deletedWorkshopIDs == ["ui-08-deleted"])
        #expect(restarted.displayDefaults == displayDefaults)
    }

    @Test("Settings navigation visibility follows the capability and SKU matrix")
    func settingsNavigationVisibilityMatchesCapabilities() {
        let common: [SettingsNavigation] = [
            .general,
            .displayDefaults,
            .performancePower,
            .audioResponse,
            .weather,
            .shortcuts,
            .backupRestore,
            .advanced,
            .about,
        ]
        let shippingPro = SettingsNavigation.availableItems(
            capabilities: .pro,
            includeWorkshopOnline: false
        ).map(\.destination)
        let directPro = SettingsNavigation.availableItems(
            capabilities: .pro.withWorkshopOnline(),
            includeWorkshopOnline: true
        ).map(\.destination)
        let localDebugPro = SettingsNavigation.availableItems(
            capabilities: .pro.withLocalDeveloperTools(),
            includeWorkshopOnline: false
        ).map(\.destination)

        #expect(SettingsNavigation.availableItems(capabilities: .lite).map(\.destination) == common)
        #expect(SettingsNavigation.availableItems(capabilities: .unconfigured).map(\.destination) == common)
        #expect(shippingPro == [
            .general,
            .displayDefaults,
            .performancePower,
            .audioResponse,
            .weather,
            .shortcuts,
            .storage,
            .backupRestore,
            .advanced,
            .about,
        ])
        #expect(directPro == [
            .general,
            .displayDefaults,
            .performancePower,
            .audioResponse,
            .weather,
            .shortcuts,
            .storage,
            .backupRestore,
            .workshopSetup,
            .advanced,
            .about,
        ])
        #expect(localDebugPro == shippingPro, "Developer Tools is a separate local-debug surface, not a Settings page")
    }

    @Test("Persistence and import keep the current cross-domain semantics")
    func persistenceAndImportSourceContracts() throws {
        let rootSource = try RepositoryRoot.source("LiveWallpaper/Views/GeneralSettingsView.swift")
        let update = try Self.slice(
            rootSource,
            from: "func updateGlobalSettings() {",
            until: "/// Defers the post"
        )
        let expectedAssignments = [
            "settings.globalPauseOnBattery = globalPauseOnBattery",
            "settings.preservePlaybackOnLock = preservePlaybackOnLock",
            "settings.startOnLogin = startOnLogin",
            "settings.pauseOnFullScreen = pauseOnFullScreen",
            "settings.pauseInGameMode = pauseInGameMode",
            "settings.pauseOnWindowOcclusion = pauseOnWindowOcclusion",
            "settings.applicationPerformanceRules = applicationRules",
            "settings.showInDock = showInDock",
            "settings.videoCacheMaxBytesPerScreen = Int(videoCacheBudgetMB) * 1024 * 1024",
            "settings.developerModeEnabled = developerModeEnabled",
            "settings.audioResponseEnabled = audioResponseEnabled",
            "settings.adaptiveFrameRateEnabled = adaptiveFrameRateEnabled",
            "settings.weatherLocation = weatherLocation",
        ]

        #expect(update.contains("var settings = SettingsManager.shared.loadGlobalSettings()"))
        #expect(update.contains("SettingsManager.shared.saveGlobalSettings(settings)"))
        #expect(
            !update.contains("var settings = GlobalSettings("),
            "Page writes must remain read-modify-write"
        )
        for assignment in expectedAssignments {
            #expect(update.contains(assignment), "Missing persistence mapping: \(assignment)")
        }
        #expect(update.contains("if dockChanged"))
        #expect(update.contains("if developerModeChanged"))
        #expect(update.contains("if weatherChanged"))

        let backup = try RepositoryRoot.source("LiveWallpaper/Views/GeneralSettingsBackupSection.swift")
        #expect(backup.contains("let summary = ConfigurationPorter.apply(bundle)"))
        #expect(backup.contains("screenManager.handleGlobalSettingsChanged()"))
        #expect(backup.contains("screenManager.resetAllWallpaperSessions()"))
        #expect(backup.contains("screenManager.refreshScreens(preserveRuntimeSessions: false)"))
        #expect(backup.contains("applyAudioResponseEnabled(settings.audioResponseEnabled)"))
        #expect(backup.contains("postSettingsNotificationAsync(.weatherLocationPreferenceDidChange)"))
        #expect(backup.contains("postSettingsNotificationAsync(.globalShortcutsDidChange)"))
    }

    @Test("SKU-specific controls stay behind compile and capability gates")
    func skuSpecificControlSourceContracts() throws {
        let root = try RepositoryRoot.source("LiveWallpaper/Views/GeneralSettingsView.swift")
        let audio = try RepositoryRoot.source("LiveWallpaper/Views/GeneralSettingsAudioSection.swift")
        let performance = try RepositoryRoot.source("LiveWallpaper/Views/GeneralSettingsPerformanceSection.swift")
        let advanced = try RepositoryRoot.source("LiveWallpaper/Views/GeneralSettingsAdvancedSection.swift")
        let about = try RepositoryRoot.source("LiveWallpaper/Views/GeneralSettingsAboutTab.swift")
        let detail = try RepositoryRoot.source("LiveWallpaper/Views/Settings/SettingsDetailContent.swift")

        #expect(root.contains("#if !LITE_BUILD\n    @State var audioCaptureState"))
        #expect(audio.contains("#if !LITE_BUILD\n        Section"))
        #expect(performance.contains("#if !LITE_BUILD\n            SettingRow("))
        #expect(advanced.contains("#if DEBUG && !LITE_BUILD"))
        #expect(about.contains("#if LITE_BUILD\n                UpdateBannerView()"))
        #expect(detail.contains("if featureCatalog.isEnabled(.wpeImport)"))
        #expect(detail.contains("if featureCatalog.isEnabled(.workshopOnline)"))
    }
}

private extension GeneralSettingsOwnershipCharacterizationTests {
    enum FixtureError: Error {
        case missingBoundary(String)
    }

    static func storedPropertyNames(in source: String) throws -> Set<String> {
        let regex = try NSRegularExpression(
            pattern: #"(?m)^\s*@(State|AppStorage)[^\n]*\bvar\s+([A-Za-z_][A-Za-z0-9_]*)"#
        )
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return Set(regex.matches(in: source, range: range).compactMap { match in
            guard let nameRange = Range(match.range(at: 2), in: source) else { return nil }
            return String(source[nameRange])
        })
    }

    static func slice(_ source: String, from start: String, until end: String) throws -> String {
        guard let startRange = source.range(of: start) else {
            throw FixtureError.missingBoundary(start)
        }
        guard let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
            throw FixtureError.missingBoundary(end)
        }
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    static func occurrences(_ needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}
