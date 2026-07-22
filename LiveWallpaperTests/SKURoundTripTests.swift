import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import Testing
@testable import LiveWallpaper

@Suite("Cross-SKU Codable round trips")
struct SKURoundTripTests {

    // MARK: - Scene (Pro-only wallpaper type)

    @Test("ScreenConfiguration with .scene + origin + playlist + schedule round-trips losslessly")
    func sceneConfigurationRoundTripsAllFields() throws {
        let descriptor = SceneDescriptor(
            workshopID: "3351072238",
            cacheRelativePath: "wpe-cache/3351072238",
            entryFile: "scene.json",
            capabilityTier: .imageOnly,
            dependencyWorkshopIDs: ["123", "456"]
        )
        let origin = WPEOrigin(
            workshopID: "3351072238",
            title: "Round Trip Scene",
            originalType: .scene,
            sourceFolderBookmark: Data([0x01, 0x02]),
            cacheRelativePath: "wpe-cache/3351072238",
            previewFileName: "preview.gif",
            entryFile: "scene.json",
            dependencyWorkshopIDs: ["123", "456"]
        )
        let scheduleSlot = ScheduleSlot(
            startHour: 6,
            endHour: 12,
            videoBookmarkData: Data([0xAA]),
            label: "Morning"
        )

        var config = ScreenConfiguration(
            screenID: 42,
            wallpaper: .scene(descriptor)
        )
        config.wpeOrigin = origin
        config.playlistBookmarks = [Data([0x02]), Data([0x03])]
        config.scheduleSlots = [scheduleSlot]

        let encoded = try JSONEncoder().encode(config)
        let firstDecode = try JSONDecoder().decode(ScreenConfiguration.self, from: encoded)
        #expect(firstDecode.activeWallpaper == .scene(descriptor))
        #expect(firstDecode.wpeOrigin == origin)
        #expect(firstDecode.playlistBookmarks == [Data([0x02]), Data([0x03])])
        #expect(firstDecode.scheduleSlots == [scheduleSlot])

        let reEncoded = try JSONEncoder().encode(firstDecode)
        let secondDecode = try JSONDecoder().decode(ScreenConfiguration.self, from: reEncoded)
        #expect(secondDecode.activeWallpaper == .scene(descriptor))
        #expect(secondDecode.wpeOrigin == origin)
        #expect(secondDecode.playlistBookmarks == [Data([0x02]), Data([0x03])])
        #expect(secondDecode.scheduleSlots == [scheduleSlot])
    }

    // MARK: - MetalShader (Pro-only wallpaper type)

    @Test("ScreenConfiguration with .metalShader survives Lite re-encode")
    func metalShaderConfigurationRoundTrips() throws {
        var config = ScreenConfiguration(
            screenID: 7,
            wallpaper: .metalShader(.aurora)
        )
        config.playlistBookmarks = [Data([0xDE, 0xAD])]

        let encoded = try JSONEncoder().encode(config)
        let firstDecode = try JSONDecoder().decode(ScreenConfiguration.self, from: encoded)
        #expect(firstDecode.activeWallpaper == .metalShader(.aurora))
        #expect(firstDecode.playlistBookmarks == [Data([0xDE, 0xAD])])

        let reEncoded = try JSONEncoder().encode(firstDecode)
        let secondDecode = try JSONDecoder().decode(ScreenConfiguration.self, from: reEncoded)
        #expect(secondDecode.activeWallpaper == .metalShader(.aurora))
        #expect(secondDecode.playlistBookmarks == [Data([0xDE, 0xAD])])
    }

    // MARK: - GlobalSettings (Pro-only fields)

    @Test("GlobalSettings with weather + shortcuts + WPE history survives Lite re-encode")
    func globalSettingsRoundTripsProOnlyFields() throws {
        let origin = WPEOrigin(
            workshopID: "history-1",
            title: "History Entry",
            originalType: .video,
            sourceFolderBookmark: Data([0x10]),
            cacheRelativePath: "wpe-cache/history-1",
            previewFileName: "preview.jpg"
        )
        let importedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let lastUsedAt = Date(timeIntervalSince1970: 1_700_010_000)
        let history = WPEHistoryEntry(
            origin: origin,
            importedAt: importedAt,
            lastUsedAt: lastUsedAt
        )

        let settings = GlobalSettings(
            globalPauseOnBattery: true,
            preservePlaybackOnLock: true,
            pauseOnFullScreen: false,
            weatherLocation: .default,
            globalShortcuts: [:],
            recentWPEImports: [history]
        )

        let encoded = try JSONEncoder().encode(settings)
        let firstDecode = try JSONDecoder().decode(GlobalSettings.self, from: encoded)
        #expect(firstDecode.recentWPEImports.count == 1)
        #expect(firstDecode.recentWPEImports.first?.origin == origin)
        #expect(firstDecode.recentWPEImports.first?.importedAt == importedAt)
        #expect(firstDecode.recentWPEImports.first?.lastUsedAt == lastUsedAt)
        #expect(firstDecode.globalPauseOnBattery == true)
        #expect(firstDecode.pauseOnFullScreen == false)

        let reEncoded = try JSONEncoder().encode(firstDecode)
        let secondDecode = try JSONDecoder().decode(GlobalSettings.self, from: reEncoded)
        #expect(secondDecode.recentWPEImports.first?.origin == origin)
        #expect(secondDecode.recentWPEImports.first?.importedAt == importedAt)
    }

    // MARK: - Origin reconcilers

    @Test("PreservingOriginReconciler keeps non-unsupported origins intact when the user replaces the wallpaper")
    func preservingReconcilerKeepsOrigin() {
        let origin = WPEOrigin(
            workshopID: "keep-me",
            title: "Keep",
            originalType: .video,
            sourceFolderBookmark: Data([0x01]),
            cacheRelativePath: "wpe-cache/keep-me",
            previewFileName: nil
        )
        var config = ScreenConfiguration(
            screenID: 1,
            wallpaper: .video(bookmarkData: Data([0xFF]))
        )
        config.wpeOrigin = origin

        let reconciler: any OriginReconciler = PreservingOriginReconciler()
        reconciler.reconcile(
            &config,
            event: .userReplacedActiveWallpaper(previous: .video(bookmarkData: Data([0x00])))
        )

        #expect(config.wpeOrigin == origin)
    }

    @Test("PreservingOriginReconciler drops origins whose resourceLocation is .unsupported")
    func preservingReconcilerDropsUnsupportedOrigins() {
        let origin = WPEOrigin(
            workshopID: "drop-me",
            title: "Drop",
            originalType: .application,
            sourceFolderBookmark: Data([0x01]),
            cacheRelativePath: nil,
            previewFileName: nil,
            resourceLocation: .unsupported
        )
        var config = ScreenConfiguration(
            screenID: 1,
            wallpaper: .video(bookmarkData: Data([0xFF]))
        )
        config.wpeOrigin = origin

        PreservingOriginReconciler()
            .reconcile(&config, event: .userReplacedActiveWallpaper(previous: nil))

        #expect(config.wpeOrigin == nil)
    }

    @Test("WPEOriginReconciler is a no-op on .loaded events even when bookmarks do not match")
    func wpeReconcilerIsNoOpOnLoaded() {
        let origin = WPEOrigin(
            workshopID: "loaded",
            title: "Loaded",
            originalType: .video,
            sourceFolderBookmark: Data([0x01]),
            cacheRelativePath: "wpe-cache/loaded",
            previewFileName: nil
        )
        var config = ScreenConfiguration(
            screenID: 1,
            wallpaper: .video(bookmarkData: Data([0xFF]))
        )
        config.wpeOrigin = origin

        WPEOriginReconciler().reconcile(&config, event: .loaded)
        #expect(config.wpeOrigin == origin)
    }
}
