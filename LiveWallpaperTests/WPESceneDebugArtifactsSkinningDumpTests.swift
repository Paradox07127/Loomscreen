import Foundation
import LiveWallpaperProWPE
import Testing
@testable import LiveWallpaper

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
        let artifacts = WPESceneDebugArtifacts()
        artifacts.setEnabledForTesting(true)
        defer { artifacts.setEnabledForTesting(nil) }
        let pipeline = puppetPipeline(objectID: "gen-probe")

        artifacts.recordLayerPlacements(pipeline)
        #expect(artifacts.layerPlacementsContentsForTesting().contains("skinning=pending"))

        artifacts.recordPuppetSkinningStates([("gen-probe", "ENABLED/bind")])
        #expect(artifacts.layerPlacementsContentsForTesting().contains("skinning=ENABLED/bind"))

        artifacts.recordLayerPlacements(pipeline)
        #expect(artifacts.layerPlacementsContentsForTesting().contains("skinning=pending(last=ENABLED/bind)"))

        artifacts.recordPuppetSkinningStates([("gen-probe", "DISABLED/no-animation")])
        #expect(artifacts.layerPlacementsContentsForTesting().contains("skinning=DISABLED/no-animation"))
    }
}
