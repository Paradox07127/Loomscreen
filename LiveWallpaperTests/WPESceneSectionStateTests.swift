import Foundation
import SwiftUI
import Testing
@testable import LiveWallpaper

/// Phase 2.0 Day 5 lock: SceneRenderState transitions and SceneRenderingError
/// → FallbackReason mapping. Pure value-level tests so they don't pull in
/// renderer/UI dependencies and stay snappy in CI.
@Suite("WPESceneSection state machine")
struct WPESceneSectionStateTests {

    @Test("idle and loading states compare independently of associated values")
    func idleLoadingEquality() {
        #expect(SceneRenderState.idle == SceneRenderState.idle)
        #expect(SceneRenderState.loading == SceneRenderState.loading)
        #expect(SceneRenderState.idle != SceneRenderState.loading)
    }

    @Test("loading distinguishes nil vs progress text payloads")
    func loadingPayloadDifferentiates() {
        let plain = SceneRenderState.loading(progress: nil)
        let labelled = SceneRenderState.loading(progress: "Decoding 3/12 textures…")
        #expect(plain != labelled)
        #expect(plain == SceneRenderState.loading)
        #expect(plain.isLoading)
        #expect(labelled.isLoading)
    }

    @MainActor
    @Test("Texture decoder error → FallbackReason mapping is precise")
    func textureFallbackMapping() {
        let unsupportedFormat: SceneLoadDiagnostic = .texture(
            layer: "background",
            error: .unsupportedFormat(code: 8)
        )
        let unsupportedContainer: SceneLoadDiagnostic = .texture(
            layer: "fg",
            error: .unsupportedContainer(magic: "TEXV9999")
        )
        let truncated: SceneLoadDiagnostic = .texture(
            layer: "fg",
            error: .truncatedBlock(block: "TEXB", offset: 42)
        )
        #expect(WPESceneDetailView.fallbackReason(for: unsupportedFormat) == .texUnsupportedFormat(code: 8))
        #expect(WPESceneDetailView.fallbackReason(for: unsupportedContainer) == .texContainerUnsupported(magic: "TEXV9999"))
        if case .texDecodeFailed = WPESceneDetailView.fallbackReason(for: truncated) {
        } else {
            Issue.record("Truncated tex should map to .texDecodeFailed")
        }
    }

    @Test("FallbackReason severity tint distinguishes warn vs hard block")
    func severityTintIsHonest() {
        // Recoverable/actionable failures use the caution token, permanent
        // blockers the warning token (Status tokens since 2b11734).
        let caution = DesignTokens.Colors.Status.caution
        let warning = DesignTokens.Colors.Status.warning
        #expect(FallbackReason.missingDependency(workshopIDs: ["1"]).severityTint == caution)
        #expect(FallbackReason.sceneResourceMissing.severityTint == caution)
        #expect(FallbackReason.texDecodeFailed(detail: "x").severityTint == caution)
        #expect(FallbackReason.requiresWindowsPlugin.severityTint == warning)
        #expect(FallbackReason.texContainerUnsupported(magic: "X").severityTint == warning)
        #expect(FallbackReason.texUnsupportedFormat(code: 8).severityTint == warning)
        #expect(caution != warning)
    }

    @Test("isActionable matches the Retry button visibility policy")
    func isActionableMatchesRetry() {
        #expect(FallbackReason.missingDependency(workshopIDs: []).isActionable)
        #expect(FallbackReason.texDecodeFailed(detail: "x").isActionable)
        #expect(!FallbackReason.requiresWindowsPlugin.isActionable)
        #expect(!FallbackReason.texContainerUnsupported(magic: "X").isActionable)
        #expect(!FallbackReason.texUnsupportedFormat(code: 8).isActionable)
    }

    @Test("error state carries the FallbackReason")
    func errorKeepsFallbackReason() {
        let parse = SceneRenderState.error(.sceneParseFailed("boom"))
        let resource = SceneRenderState.error(.sceneResourceMissing)
        #expect(parse != resource)
        #expect(parse == SceneRenderState.error(.sceneParseFailed("boom")))
    }

    @MainActor
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
