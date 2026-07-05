import Foundation
import Testing
@testable import LiveWallpaper

/// Locks the layer-placements skinning merge semantics: a puppet line reads `pending` before the
/// first frame's gate verdict arrives, shows the verdict once stamped, and demotes to
/// `pending(last=…)` when a new pipeline generation supersedes it — the same objectID may belong to
/// a different puppet after a reload, and a failed first frame must not leave the old verdict
/// standing as current.
@Suite("WPE scene-debug skinning dump")
struct WPESceneDebugArtifactsSkinningDumpTests {
    private func puppetPipeline(objectID: String) -> WPEPreparedRenderPipeline {
        let layer = WPERenderLayer(
            objectID: objectID,
            objectName: "Puppet",
            imagePath: "models/p.mdl",
            materialPath: nil,
            puppetPath: "models/p.mdl",
            geometry: .identity,
            compositeA: "a",
            compositeB: "b",
            localFBOs: [],
            passes: []
        )
        return WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(
                graphLayer: layer,
                puppetModel: WPEPuppetModel(version: 23, meshes: []),
                passes: []
            )
        ])
    }

    @Test("Skinning state renders pending → current → pending(last=…) across generations")
    func skinningStateGenerationLifecycle() {
        // A private instance (not `.shared`) so concurrently running renderer tests that also
        // record pass lists cannot clobber the placements under assertion.
        let artifacts = WPESceneDebugArtifacts()
        artifacts.setEnabledForTesting(true)
        defer { artifacts.setEnabledForTesting(nil) }
        let pipeline = puppetPipeline(objectID: "gen-probe")

        artifacts.recordLayerPlacements(pipeline)
        #expect(artifacts.layerPlacementsContentsForTesting().contains("skinning=pending"))

        artifacts.recordPuppetSkinningStates([("gen-probe", "ENABLED/bind")])
        #expect(artifacts.layerPlacementsContentsForTesting().contains("skinning=ENABLED/bind"))

        // A rebuilt pipeline reusing the objectID must NOT keep the old verdict as current.
        artifacts.recordLayerPlacements(pipeline)
        #expect(artifacts.layerPlacementsContentsForTesting().contains("skinning=pending(last=ENABLED/bind)"))

        // The next frame's full-state push re-proves the gate for the new generation.
        artifacts.recordPuppetSkinningStates([("gen-probe", "DISABLED/no-animation")])
        #expect(artifacts.layerPlacementsContentsForTesting().contains("skinning=DISABLED/no-animation"))
    }
}
