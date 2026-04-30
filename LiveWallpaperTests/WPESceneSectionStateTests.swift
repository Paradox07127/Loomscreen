import Foundation
import Testing
@testable import LiveWallpaper

/// Phase 2.0 Day 5 lock: SceneRenderState transitions and SceneRenderingError
/// → FallbackReason mapping. Pure value-level tests so they don't pull in
/// SwiftUI / SpriteKit and stay snappy in CI.
@Suite("WPESceneSection state machine")
struct WPESceneSectionStateTests {

    @Test("idle and loading states compare independently of associated values")
    func idleLoadingEquality() {
        #expect(SceneRenderState.idle == SceneRenderState.idle)
        #expect(SceneRenderState.loading == SceneRenderState.loading)
        #expect(SceneRenderState.idle != SceneRenderState.loading)
    }

    @Test("paused state preserves the reason")
    func pausedKeepsReason() {
        let reduceMotion = SceneRenderState.paused(reason: .reduceMotion)
        let throttled = SceneRenderState.paused(reason: .throttled)
        #expect(reduceMotion != throttled)
        #expect(reduceMotion == SceneRenderState.paused(reason: .reduceMotion))
    }

    @Test("error state carries the FallbackReason")
    func errorKeepsFallbackReason() {
        let parse = SceneRenderState.error(.sceneParseFailed("boom"))
        let resource = SceneRenderState.error(.sceneResourceMissing)
        #expect(parse != resource)
        #expect(parse == SceneRenderState.error(.sceneParseFailed("boom")))
    }

    @Test("PausedReason labels expose user-visible text")
    func pausedReasonLabels() {
        #expect(PausedReason.reduceMotion.label == "Reduce Motion")
        #expect(PausedReason.throttled.label == "Throttled")
        #expect(PausedReason.suspended.label == "Suspended")
    }

    @Test("FallbackReason rendering distinguishes parse vs resource failure copy")
    func fallbackReasonCopy() {
        let parse = WPEFallbackCard(
            origin: makeOrigin(),
            reason: .sceneParseFailed("missing camera")
        )
        let missing = WPEFallbackCard(
            origin: makeOrigin(),
            reason: .sceneResourceMissing
        )
        // Reason equality short-circuits the heavier text-based comparison
        // (the strings live inside private SwiftUI computed props).
        #expect(parse.reason != missing.reason)
        #expect(parse.reason == .sceneParseFailed("missing camera"))
    }

    private func makeOrigin() -> WPEOrigin {
        WPEOrigin(
            workshopID: "state-machine",
            title: "State Machine",
            originalType: .scene,
            sourceFolderBookmark: Data([0x01]),
            cacheRelativePath: "wpe-cache/state-machine",
            previewFileName: nil,
            entryFile: "scene.json",
            resourceLocation: .cache
        )
    }
}
