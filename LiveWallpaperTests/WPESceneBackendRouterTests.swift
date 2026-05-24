import Foundation
import Testing
@testable import LiveWallpaper

@Suite("WPESceneBackendRouter — Metal-first heuristic")
struct WPESceneBackendRouterTests {

    @Test("User-pinned Metal bypasses the probe")
    func userPinnedMetal() {
        let routing = WPESceneBackendRouter.resolve(
            userSelection: .metal,
            document: Self.makeDocument(),
            cacheURL: Self.dummyURL
        )
        #expect(routing.backend == .metal)
        #expect(routing.routedBy == .user)
    }

    @Test("User-pinned WebGL bypasses the probe even when BC textures are present")
    func userPinnedWebGL() {
        let routing = WPESceneBackendRouter.resolve(
            userSelection: .webGL,
            document: Self.makeDocument(),
            cacheURL: Self.dummyURL
        )
        #expect(routing.backend == .webGL)
        #expect(routing.routedBy == .user)
    }

    @Test("Automatic mode prefers Metal when any BC texture is detected")
    func automaticPrefersMetalForBC() {
        let profile = WPESceneBackendRouter.SceneProfile(
            totalTextures: 4,
            blockCompressedTextures: 1,
            videoTextures: 0
        )
        let routing = WPESceneBackendRouter.decide(profile: profile)
        #expect(routing.backend == .metal)
        #expect(routing.routedBy == .automatic)
    }

    @Test("Automatic mode picks WebGL when only RGBA textures are present")
    func automaticPicksWebGLForRGBA() {
        let profile = WPESceneBackendRouter.SceneProfile(
            totalTextures: 6,
            blockCompressedTextures: 0,
            videoTextures: 0
        )
        let routing = WPESceneBackendRouter.decide(profile: profile)
        #expect(routing.backend == .webGL)
        #expect(routing.routedBy == .automatic)
    }

    @Test("Automatic mode picks WebGL for video-only scenes")
    func automaticPicksWebGLForVideo() {
        let profile = WPESceneBackendRouter.SceneProfile(
            totalTextures: 1,
            blockCompressedTextures: 0,
            videoTextures: 1
        )
        let routing = WPESceneBackendRouter.decide(profile: profile)
        #expect(routing.backend == .webGL)
        #expect(routing.routedBy == .automatic)
        #expect(routing.reason.contains("video"))
    }

    @Test("Reason string mentions BC count when routing to Metal")
    func automaticMetalReasonMentionsBCCount() {
        let profile = WPESceneBackendRouter.SceneProfile(
            totalTextures: 5,
            blockCompressedTextures: 3,
            videoTextures: 0
        )
        let routing = WPESceneBackendRouter.decide(profile: profile)
        #expect(routing.reason.contains("3"))
        #expect(routing.reason.contains("5"))
    }

    private static let dummyURL = URL(fileURLWithPath: "/tmp/wpe-router-tests")

    private static func makeDocument() -> WPESceneDocument {
        WPESceneDocument(
            camera: .defaultCamera,
            general: .defaultGeneral,
            imageObjects: [],
            diagnostics: []
        )
    }
}
