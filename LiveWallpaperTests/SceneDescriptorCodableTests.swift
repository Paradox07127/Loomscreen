import Foundation
import Testing
@testable import LiveWallpaper

/// Phase 2.0 Day 1 lock: Codable contracts for `SceneDescriptor`,
/// `WallpaperContent.scene`, and the legacy-`.scene` backfill that lets
/// `ScreenConfiguration` reload data written before the descriptor existed.
@Suite("SceneDescriptor / WallpaperContent.scene persistence")
struct SceneDescriptorCodableTests {

    // MARK: - SceneDescriptor

    @Test("SceneDescriptor round-trips through JSON")
    func sceneDescriptorRoundTrips() throws {
        let descriptor = SceneDescriptor(
            workshopID: "3351072238",
            cacheRelativePath: "wpe-cache/3351072238",
            entryFile: "scene.json",
            capabilityTier: .imageOnly
        )

        let data = try JSONEncoder().encode(descriptor)
        let decoded = try JSONDecoder().decode(SceneDescriptor.self, from: data)

        #expect(decoded == descriptor)
    }

    @Test("Unknown capabilityTier decodes lossily as .unsupported")
    func sceneDescriptorTierFallsBack() throws {
        // Future Phase 2.x might add a new tier (e.g. `.fxOnly`); an old build
        // shouldn't crash on the next launch.
        let payload: [String: Any] = [
            "workshopID": "abc",
            "cacheRelativePath": "wpe-cache/abc",
            "entryFile": "scene.json",
            "capabilityTier": "fxOnly"
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)

        let decoded = try JSONDecoder().decode(SceneDescriptor.self, from: data)

        #expect(decoded.capabilityTier == .unsupported)
        #expect(decoded.workshopID == "abc")
    }

    @Test("SceneDescriptor decodes missing dependencyWorkshopIDs as empty")
    func sceneDescriptorMissingDependenciesDecodeAsEmpty() throws {
        let payload: [String: Any] = [
            "workshopID": "abc",
            "cacheRelativePath": "wpe-cache/abc",
            "entryFile": "scene.json",
            "capabilityTier": "imageOnly"
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)

        let decoded = try JSONDecoder().decode(SceneDescriptor.self, from: data)

        #expect(decoded.dependencyWorkshopIDs == [])
    }

    @Test("SceneDescriptor round-trips dependencyWorkshopIDs")
    func sceneDescriptorDependenciesRoundTrip() throws {
        let descriptor = SceneDescriptor(
            workshopID: "main",
            cacheRelativePath: "wpe-cache/main",
            entryFile: "scene.json",
            capabilityTier: .degraded,
            dependencyWorkshopIDs: ["111", "222"]
        )

        let data = try JSONEncoder().encode(descriptor)
        let decoded = try JSONDecoder().decode(SceneDescriptor.self, from: data)

        #expect(decoded == descriptor)
    }

    // MARK: - WallpaperContent.scene

    @Test("WallpaperContent.scene round-trips through ScreenConfiguration")
    func wallpaperContentSceneRoundTrips() throws {
        let descriptor = SceneDescriptor(
            workshopID: "rt",
            cacheRelativePath: "wpe-cache/rt",
            entryFile: "scene.json",
            capabilityTier: .imageOnly
        )
        let config = ScreenConfiguration(
            screenID: 42,
            wallpaper: .scene(descriptor)
        )

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ScreenConfiguration.self, from: data)

        #expect(decoded.activeWallpaper == .scene(descriptor))
        #expect(decoded.wallpaperType == .scene)
    }

    // MARK: - Legacy backfill

    @Test("Legacy ScreenConfiguration with wallpaperType=scene + matching wpeOrigin backfills SceneDescriptor")
    func legacySceneBackfillsFromOrigin() throws {
        let origin = WPEOrigin(
            workshopID: "legacy-id",
            title: "Legacy Scene",
            originalType: .scene,
            sourceFolderBookmark: Data([0x01]),
            cacheRelativePath: "wpe-cache/legacy-id",
            previewFileName: "preview.gif",
            entryFile: "scene.json",
            resourceLocation: .cache
        )

        // Build a legacy-shaped JSON: no `activeWallpaper`, just the old
        // `wallpaperType` key, plus the wpeOrigin we want backfilled.
        let payload: [String: Any] = [
            "screenID": 7,
            "wallpaperType": "Scene",
            "videoBookmarkData": Data().base64EncodedString(),
            "playbackSpeed": 1.0,
            "fitMode": VideoFitMode.aspectFill.rawValue,
            "frameRateLimit": FrameRateLimit.fps60.rawValue,
            "particleEffect": ParticleEffect.none.rawValue,
            "effectConfig": try JSONSerialization.jsonObject(with: JSONEncoder().encode(VideoEffectConfig.default)),
            "shufflePlaylist": false,
            "setAsLockScreen": false,
            "wallpaperMode": "single",
            "muted": true,
            "wpeOrigin": try JSONSerialization.jsonObject(with: JSONEncoder().encode(origin))
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)

        let decoded = try JSONDecoder().decode(ScreenConfiguration.self, from: data)

        #expect(decoded.wallpaperType == .scene)
        guard case .scene(let descriptor) = decoded.activeWallpaper else {
            Issue.record("Expected .scene case after backfill")
            return
        }
        #expect(descriptor.workshopID == "legacy-id")
        #expect(descriptor.cacheRelativePath == "wpe-cache/legacy-id")
        #expect(descriptor.entryFile == "scene.json")
        #expect(descriptor.capabilityTier == .imageOnly)
        #expect(descriptor.dependencyWorkshopIDs == [])
    }

    @Test("Legacy scene backfill rejects unsafe persisted origin paths")
    func legacySceneBackfillRejectsUnsafeOriginPaths() throws {
        let origin = WPEOrigin(
            workshopID: "legacy-unsafe",
            title: "Legacy Unsafe",
            originalType: .scene,
            sourceFolderBookmark: Data([0x01]),
            cacheRelativePath: "wpe-cache/legacy-unsafe",
            previewFileName: nil,
            entryFile: "../scene.json",
            resourceLocation: .cache
        )

        let payload: [String: Any] = [
            "screenID": 17,
            "wallpaperType": "Scene",
            "videoBookmarkData": Data().base64EncodedString(),
            "playbackSpeed": 1.0,
            "fitMode": VideoFitMode.aspectFill.rawValue,
            "frameRateLimit": FrameRateLimit.fps60.rawValue,
            "particleEffect": ParticleEffect.none.rawValue,
            "effectConfig": try JSONSerialization.jsonObject(with: JSONEncoder().encode(VideoEffectConfig.default)),
            "shufflePlaylist": false,
            "setAsLockScreen": false,
            "wallpaperMode": "single",
            "muted": true,
            "wpeOrigin": try JSONSerialization.jsonObject(with: JSONEncoder().encode(origin))
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)

        let decoded = try JSONDecoder().decode(ScreenConfiguration.self, from: data)

        guard case .video(let bookmarkData) = decoded.activeWallpaper else {
            Issue.record("Expected unsafe legacy scene backfill to fall back to empty video")
            return
        }
        #expect(bookmarkData.isEmpty)
    }

    @Test("Legacy ScreenConfiguration with wallpaperType=scene but no wpeOrigin falls back to empty video")
    func legacySceneWithoutOriginFallsBackToEmptyVideo() throws {
        let payload: [String: Any] = [
            "screenID": 8,
            "wallpaperType": "Scene",
            "videoBookmarkData": Data().base64EncodedString(),
            "playbackSpeed": 1.0,
            "fitMode": VideoFitMode.aspectFill.rawValue,
            "frameRateLimit": FrameRateLimit.fps60.rawValue,
            "particleEffect": ParticleEffect.none.rawValue,
            "effectConfig": try JSONSerialization.jsonObject(with: JSONEncoder().encode(VideoEffectConfig.default)),
            "shufflePlaylist": false,
            "setAsLockScreen": false,
            "wallpaperMode": "single",
            "muted": true
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)

        let decoded = try JSONDecoder().decode(ScreenConfiguration.self, from: data)

        // Without origin context the descriptor cannot be reconstructed safely,
        // so the persisted blob degrades to an empty video. ScreenManager's
        // restore path then mounts the not-configured Scene tab placeholder.
        #expect(decoded.activeWallpaper == .video(bookmarkData: Data()))
    }

    @Test("Reconcile keeps wpeOrigin when scene descriptor matches workshopID + cacheRelativePath")
    func reconcileKeepsOriginWhenSceneMatches() throws {
        let descriptor = SceneDescriptor(
            workshopID: "match",
            cacheRelativePath: "wpe-cache/match",
            entryFile: "scene.json",
            capabilityTier: .imageOnly
        )
        var config = ScreenConfiguration(screenID: 9, wallpaper: .scene(descriptor))
        config.wpeOrigin = WPEOrigin(
            workshopID: "match",
            title: "Match",
            originalType: .scene,
            sourceFolderBookmark: Data([0x01]),
            cacheRelativePath: "wpe-cache/match",
            previewFileName: nil,
            entryFile: "scene.json",
            resourceLocation: .cache
        )

        config.reconcileWPEOrigin()

        #expect(config.wpeOrigin != nil)
    }

    @Test("Reconcile drops wpeOrigin when scene descriptor disagrees with origin workshopID")
    func reconcileDropsOriginOnSceneMismatch() throws {
        let descriptor = SceneDescriptor(
            workshopID: "current",
            cacheRelativePath: "wpe-cache/current",
            entryFile: "scene.json",
            capabilityTier: .imageOnly
        )
        var config = ScreenConfiguration(screenID: 10, wallpaper: .scene(descriptor))
        config.wpeOrigin = WPEOrigin(
            workshopID: "stale",
            title: "Stale",
            originalType: .scene,
            sourceFolderBookmark: Data([0x01]),
            cacheRelativePath: "wpe-cache/stale",
            previewFileName: nil,
            entryFile: "scene.json",
            resourceLocation: .cache
        )

        config.reconcileWPEOrigin()

        #expect(config.wpeOrigin == nil)
    }
}
