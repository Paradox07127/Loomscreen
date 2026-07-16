import AppKit
import Foundation
import Testing
@testable import LiveWallpaper

/// Validates the per-screen primitives that the onboarding multi-screen apply
/// flow depends on: configuration cloning across screen IDs, persistence
/// round-trips for multiple screens, and the early-exit guard on
/// `applyConfigurationToAllDisplays` when only one screen is registered.
///
/// The full multi-NSScreen apply path is not covered here because `Screen`
/// derives its `id` from `NSScreen` and CI hosts only expose one display;
/// instead, the underlying primitives are validated end-to-end so any
/// regression in the cloning / persistence layer surfaces here first.
@Suite("Onboarding multi-screen primitives")
@MainActor
struct OnboardingMultiScreenTests {

    @Test("Unsupported import recovery copy follows the catalog's scene capability")
    func unsupportedImportCopyFollowsSceneCapability() {
        let liteCatalog = FeatureCatalog(capabilities: .lite)
        let proCatalog = FeatureCatalog(capabilities: .pro)
        let liteSceneCapable = OnboardingImportCopy.sceneCapable(in: liteCatalog)
        let proSceneCapable = OnboardingImportCopy.sceneCapable(in: proCatalog)
        let lite = OnboardingImportCopy.unsupportedFileTypeVariant(sceneCapable: liteSceneCapable)
        let pro = OnboardingImportCopy.unsupportedFileTypeVariant(sceneCapable: proSceneCapable)
        let liteMessage = OnboardingImportCopy.unsupportedFileTypeMessage(sceneCapable: liteSceneCapable)
        let proMessage = OnboardingImportCopy.unsupportedFileTypeMessage(sceneCapable: proSceneCapable)

        #expect(!liteSceneCapable)
        #expect(proSceneCapable)
        #expect(lite == .videoAndWeb)
        #expect(pro == .videoWebAndScene)
        #expect(liteMessage == LocalizedStringResource("That file type isn't supported. Pick a video or web page."))
        #expect(proMessage == LocalizedStringResource("That file type isn't supported. Pick a video, web page, or scene."))
    }

    // MARK: - ScreenConfiguration cloning

    @Test("Cloning a video configuration onto another screen ID preserves every field")
    func cloningVideoConfigurationPreservesAllFields() {
        let template = ScreenConfiguration(
            screenID: 1001,
            wallpaper: .video(bookmarkData: Data([0x01, 0x02, 0x03])),
            playbackSpeed: 1.5,
            fitMode: .aspectFit,
            frameRateLimit: .fps30,
            particleEffect: .snow,
            effectConfig: .default,
            scheduleSlots: nil,
            playlistBookmarks: [Data([0xAA, 0xBB])],
            shufflePlaylist: true,
            playlistRotationMinutes: 15,
            playlistCursorIndex: 0,
            setAsLockScreen: true,
            savedVideoBookmarkData: Data([0x99])
        )

        var clone = template
        clone.screenID = 2002

        #expect(clone.screenID == 2002)
        #expect(clone.activeWallpaper == template.activeWallpaper)
        #expect(clone.playbackSpeed == template.playbackSpeed)
        #expect(clone.fitMode == template.fitMode)
        #expect(clone.frameRateLimit == template.frameRateLimit)
        #expect(clone.particleEffect == template.particleEffect)
        #expect(clone.playlistBookmarks == template.playlistBookmarks)
        #expect(clone.shufflePlaylist == template.shufflePlaylist)
        #expect(clone.playlistRotationMinutes == template.playlistRotationMinutes)
        #expect(clone.playlistCursorIndex == template.playlistCursorIndex)
        #expect(clone.setAsLockScreen == template.setAsLockScreen)
        #expect(clone.savedVideoBookmarkData == template.savedVideoBookmarkData)
    }

    @Test("Cloning an HTML configuration preserves the source + saved metadata")
    func cloningHTMLConfigurationPreservesSource() {
        let source = HTMLSource.url(URL(string: "https://example.com/wallpaper")!)
        let template = ScreenConfiguration(
            screenID: 3003,
            wallpaper: .html(source: source, config: .default)
        )

        var clone = template
        clone.screenID = 4004

        #expect(clone.screenID == 4004)
        if case .html(let cloneSource, _) = clone.activeWallpaper {
            #expect(cloneSource == source)
        } else {
            Issue.record("Clone lost the HTML wallpaper case")
        }
    }

    // MARK: - Persistence round-trips for multiple screens

    @Test("WallpaperConfigurationStore writes and reads multiple per-screen configurations")
    func configurationStoreSupportsMultipleScreens() {
        let store = WallpaperConfigurationStore()
        let originalSettings = SettingsManager.shared.loadConfigurations()
        defer { SettingsManager.shared.replaceAllConfigurations(originalSettings) }
        SettingsManager.shared.replaceAllConfigurations([])
        store.clearCache()

        let firstID: CGDirectDisplayID = 5005
        let secondID: CGDirectDisplayID = 6006
        let firstConfig = ScreenConfiguration(
            screenID: firstID,
            wallpaper: .metalShader(.aurora)
        )
        var secondConfig = firstConfig
        secondConfig.screenID = secondID

        store.save(firstConfig)
        store.save(secondConfig)

        #expect(store.get(for: firstID)?.screenID == firstID)
        #expect(store.get(for: secondID)?.screenID == secondID)
        let loaded = store.loadAll().map(\.screenID).sorted()
        #expect(loaded == [firstID, secondID].sorted())
    }

    @Test("Removing a screen's configuration leaves siblings intact")
    func removingOneScreenConfigurationLeavesOthersIntact() {
        let store = WallpaperConfigurationStore()
        let originalSettings = SettingsManager.shared.loadConfigurations()
        defer { SettingsManager.shared.replaceAllConfigurations(originalSettings) }
        SettingsManager.shared.replaceAllConfigurations([])
        store.clearCache()

        let primaryID: CGDirectDisplayID = 7007
        let secondaryID: CGDirectDisplayID = 8008
        store.save(ScreenConfiguration(screenID: primaryID, wallpaper: .metalShader(.waves)))
        store.save(ScreenConfiguration(screenID: secondaryID, wallpaper: .metalShader(.plasma)))

        store.remove(for: primaryID)

        #expect(store.get(for: primaryID) == nil)
        #expect(store.get(for: secondaryID)?.screenID == secondaryID)
    }

    // MARK: - applyConfigurationToAllDisplays single-screen guard

    @Test("applyConfigurationToAllDisplays is a no-op when only one screen is registered")
    func applyToAllNoOpsForSingleScreen() {
        guard let screen = NSScreen.screens.first.map(Screen.init(nsScreen:)) else {
            Issue.record("No NSScreen available for single-screen guard test")
            return
        }
        let originalConfigurations = SettingsManager.shared.loadConfigurations()
        defer { SettingsManager.shared.replaceAllConfigurations(originalConfigurations) }

        SettingsManager.shared.saveConfiguration(
            ScreenConfiguration(screenID: screen.id, wallpaper: .metalShader(.gradient))
        )

        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry(screens: [screen]),
            featureCatalog: FeatureCatalog(capabilities: .pro)
        ))

        let countBefore = SettingsManager.shared.loadConfigurations().count
        manager.applyConfigurationToAllDisplays(from: screen)
        let countAfter = SettingsManager.shared.loadConfigurations().count

        #expect(countBefore == countAfter, "Single-screen apply must not duplicate the configuration")
    }
}
