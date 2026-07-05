import Foundation
import Testing
@testable import LiveWallpaper

/// Regression: layers with script-driven alpha must never be admitted by the
/// static-layer cache. `applyingLayerAlpha` bakes the script value into
/// `geometry.alpha` and clears `alphaAnimation` before classification, so the
/// classifier alone cannot see them — they must arrive via `dynamicLayerIDs`.
/// The original bug omitted `layerAlphaScriptInstances` from that union: an
/// alpha-scripted layer with ≥2 composite passes and builtin-only shaders
/// classified as static and froze at its first-cached alpha.
struct WPEStaticCacheExclusionTests {
    @Test("Alpha-script layers are excluded from static caching")
    func alphaScriptLayersExcluded() {
        let ids = WPEMetalSceneRenderer.staticCacheExcludedLayerIDs(
            originScriptIDs: [],
            scaleScriptIDs: [],
            anglesScriptIDs: [],
            liveCreatedLayerIDs: [],
            layerScriptIDs: [],
            alphaScriptIDs: ["7", "9"],
            scriptAlphaOverriddenIDs: []
        )
        #expect(ids == ["7", "9"])
    }

    @Test("General layer scripts are excluded (they can drive own alpha/visibility)")
    func layerScriptLayersExcluded() {
        let ids = WPEMetalSceneRenderer.staticCacheExcludedLayerIDs(
            originScriptIDs: [],
            scaleScriptIDs: [],
            anglesScriptIDs: [],
            liveCreatedLayerIDs: [],
            layerScriptIDs: ["intro"],
            alphaScriptIDs: [],
            scriptAlphaOverriddenIDs: []
        )
        #expect(ids.contains("intro"))
    }

    @Test("Cross-layer alpha writes exclude the TARGET layer once written")
    func crossLayerAlphaWriteExcludesTarget() {
        // A layer script can set another named layer's alpha via its `others`
        // output; the target has no script of its own, so it is only knowable
        // from the live alpha override map.
        let ids = WPEMetalSceneRenderer.staticCacheExcludedLayerIDs(
            originScriptIDs: [],
            scaleScriptIDs: [],
            anglesScriptIDs: [],
            liveCreatedLayerIDs: [],
            layerScriptIDs: ["controller"],
            alphaScriptIDs: [],
            scriptAlphaOverriddenIDs: ["victim"]
        )
        #expect(ids.contains("victim"))
    }

    @Test("Geometry-script and live-created exclusions still union in")
    func geometryExclusionsRetained() {
        let ids = WPEMetalSceneRenderer.staticCacheExcludedLayerIDs(
            originScriptIDs: ["o"],
            scaleScriptIDs: ["s"],
            anglesScriptIDs: ["a"],
            liveCreatedLayerIDs: ["c"],
            layerScriptIDs: [],
            alphaScriptIDs: [],
            scriptAlphaOverriddenIDs: []
        )
        #expect(ids == ["o", "s", "a", "c"])
    }

    @Test("No script sources → no exclusions")
    func emptySourcesYieldEmptySet() {
        let ids = WPEMetalSceneRenderer.staticCacheExcludedLayerIDs(
            originScriptIDs: [],
            scaleScriptIDs: [],
            anglesScriptIDs: [],
            liveCreatedLayerIDs: [],
            layerScriptIDs: [],
            alphaScriptIDs: [],
            scriptAlphaOverriddenIDs: []
        )
        #expect(ids.isEmpty)
    }
}
