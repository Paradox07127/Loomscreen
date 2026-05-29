import Foundation
import Testing
import simd
@testable import LiveWallpaper

@Suite("WPE puppet bind assembler")
struct WPEPuppetBindAssemblerTests {
    /// Column-major identity rotation with the given translation.
    private func bindMatrix(_ tx: Float, _ ty: Float, _ tz: Float = 0) -> [Float] {
        [1, 0, 0, 0,
         0, 1, 0, 0,
         0, 0, 1, 0,
         tx, ty, tz, 1]
    }

    private func model(
        version: Int,
        bones: [WPEPuppetBone],
        vertices: [WPEPuppetVertex]
    ) -> WPEPuppetModel {
        WPEPuppetModel(
            version: version,
            skeletonVersion: 2,
            meshes: [WPEPuppetMesh(materialPath: "m", vertices: vertices, indices: [0], parts: [])],
            bones: bones
        )
    }

    @Test("v19 single-bone vertex is translated by (target - restWorld)")
    func assemblesSingleBoneByTargetDelta() {
        let bone = WPEPuppetBone(
            index: 0, parentIndex: nil, rawMatrix: bindMatrix(10, 0),
            targetPosition: SIMD3<Float>(100, 0, 0), targetScalePercent: 100, targetRotation: nil
        )
        let vertex = WPEPuppetVertex(
            position: SIMD3<Float>(20, 0, 0), uv: .zero,
            skinBlendIndices: SIMD4<Int32>(0, 0, 0, 0), skinBlendWeights: SIMD4<Float>(1, 0, 0, 0)
        )
        let result = WPEPuppetBindAssembler.assembleIfNeeded(model(version: 19, bones: [bone], vertices: [vertex]))
        // 20 + (100 - 10) = 110
        #expect(result.meshes[0].vertices[0].position == SIMD3<Float>(110, 0, 0))
    }

    @Test("Multi-bone weights blend the per-bone deltas")
    func blendsMultiBoneDeltas() {
        let bones = [
            WPEPuppetBone(index: 0, parentIndex: nil, rawMatrix: bindMatrix(0, 0),
                          targetPosition: SIMD3<Float>(100, 0, 0), targetScalePercent: 100, targetRotation: nil),
            WPEPuppetBone(index: 1, parentIndex: nil, rawMatrix: bindMatrix(0, 0),
                          targetPosition: SIMD3<Float>(0, 100, 0), targetScalePercent: 100, targetRotation: nil)
        ]
        let vertex = WPEPuppetVertex(
            position: SIMD3<Float>(0, 0, 0), uv: .zero,
            skinBlendIndices: SIMD4<Int32>(0, 1, 0, 0), skinBlendWeights: SIMD4<Float>(0.5, 0.5, 0, 0)
        )
        let result = WPEPuppetBindAssembler.assembleIfNeeded(model(version: 19, bones: bones, vertices: [vertex]))
        #expect(result.meshes[0].vertices[0].position == SIMD3<Float>(50, 50, 0))
    }

    @Test("Weights are normalized so a single bone is delta-exact regardless of magnitude")
    func normalizesWeights() {
        let bone = WPEPuppetBone(
            index: 0, parentIndex: nil, rawMatrix: bindMatrix(10, 0),
            targetPosition: SIMD3<Float>(100, 0, 0), targetScalePercent: 100, targetRotation: nil
        )
        let vertex = WPEPuppetVertex(
            position: SIMD3<Float>(20, 0, 0), uv: .zero,
            skinBlendIndices: SIMD4<Int32>(0, 0, 0, 0), skinBlendWeights: SIMD4<Float>(0.25, 0, 0, 0)
        )
        let result = WPEPuppetBindAssembler.assembleIfNeeded(model(version: 19, bones: [bone], vertices: [vertex]))
        #expect(result.meshes[0].vertices[0].position == SIMD3<Float>(110, 0, 0))
    }

    @Test("v23 is left untouched even with the same target metadata")
    func leavesModernGenerationUnchanged() {
        let bone = WPEPuppetBone(
            index: 0, parentIndex: nil, rawMatrix: bindMatrix(10, 0),
            targetPosition: SIMD3<Float>(100, 0, 0), targetScalePercent: 100, targetRotation: nil
        )
        let vertex = WPEPuppetVertex(
            position: SIMD3<Float>(20, 0, 0), uv: .zero,
            skinBlendIndices: SIMD4<Int32>(0, 0, 0, 0), skinBlendWeights: SIMD4<Float>(1, 0, 0, 0)
        )
        let result = WPEPuppetBindAssembler.assembleIfNeeded(model(version: 23, bones: [bone], vertices: [vertex]))
        #expect(result.meshes[0].vertices[0].position == SIMD3<Float>(20, 0, 0))
    }

    @Test("A puppet with no target positions is left raw (simple sway rig)")
    func leavesUntargetedPuppetRaw() {
        let bone = WPEPuppetBone(index: 0, parentIndex: nil, rawMatrix: bindMatrix(10, 0))
        let vertex = WPEPuppetVertex(
            position: SIMD3<Float>(20, 0, 0), uv: .zero,
            skinBlendIndices: SIMD4<Int32>(0, 0, 0, 0), skinBlendWeights: SIMD4<Float>(1, 0, 0, 0)
        )
        let result = WPEPuppetBindAssembler.assembleIfNeeded(model(version: 19, bones: [bone], vertices: [vertex]))
        #expect(result.meshes[0].vertices[0].position == SIMD3<Float>(20, 0, 0))
    }

    @Test("Non-translation bone metadata disables assembly (fail safe to raw)")
    func skipsNonTranslationTransforms() {
        let bones = [
            WPEPuppetBone(index: 0, parentIndex: nil, rawMatrix: bindMatrix(10, 0),
                          targetPosition: SIMD3<Float>(100, 0, 0), targetScalePercent: 100, targetRotation: nil),
            WPEPuppetBone(index: 1, parentIndex: nil, rawMatrix: bindMatrix(0, 0),
                          targetPosition: SIMD3<Float>(0, 50, 0), targetScalePercent: 100,
                          targetRotation: SIMD3<Float>(0, 0, 30))
        ]
        let vertex = WPEPuppetVertex(
            position: SIMD3<Float>(20, 0, 0), uv: .zero,
            skinBlendIndices: SIMD4<Int32>(0, 0, 0, 0), skinBlendWeights: SIMD4<Float>(1, 0, 0, 0)
        )
        let result = WPEPuppetBindAssembler.assembleIfNeeded(model(version: 19, bones: bones, vertices: [vertex]))
        #expect(result.meshes[0].vertices[0].position == SIMD3<Float>(20, 0, 0))
    }

    @Test("restWorld accumulates along the parent chain before subtraction")
    func accumulatesParentChain() {
        // bone0 local (10,0) world; bone1 child local (5,0) -> world (15,0); tp (115,0)
        let bones = [
            WPEPuppetBone(index: 0, parentIndex: nil, rawMatrix: bindMatrix(10, 0),
                          targetPosition: SIMD3<Float>(50, 0, 0), targetScalePercent: 100, targetRotation: nil),
            WPEPuppetBone(index: 1, parentIndex: 0, rawMatrix: bindMatrix(5, 0),
                          targetPosition: SIMD3<Float>(115, 0, 0), targetScalePercent: 100, targetRotation: nil)
        ]
        let vertex = WPEPuppetVertex(
            position: SIMD3<Float>(15, 0, 0), uv: .zero,
            skinBlendIndices: SIMD4<Int32>(1, 0, 0, 0), skinBlendWeights: SIMD4<Float>(1, 0, 0, 0)
        )
        let result = WPEPuppetBindAssembler.assembleIfNeeded(model(version: 19, bones: bones, vertices: [vertex]))
        // restWorld[1] = 10 + 5 = 15; delta = 115 - 15 = 100; 15 + 100 = 115
        #expect(result.meshes[0].vertices[0].position == SIMD3<Float>(115, 0, 0))
    }
}
