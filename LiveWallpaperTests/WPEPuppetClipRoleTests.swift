import Foundation
import Testing
import simd
@testable import LiveWallpaper

/// Covers the WPE clip-role detection: parts[0] is the clip silhouette (eye-white) that squishes shut
/// and parts[1] is the clipped target (pupil) that stays full inside it. The convention is validated by
/// squish geometry, so a layout that doesn't match (first part stays open, target collapses, etc.) emits
/// no clip pair instead of mis-clipping.
@Suite("WPE puppet clip-role detection")
struct WPEPuppetClipRoleTests {
    private func identityColumnMajor() -> [Float] {
        [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
    }

    /// Axis-aligned quad in the XY plane, all four corners weighted to a single bone.
    private func quad(bone: Int32, minX: Float, maxX: Float, minY: Float, maxY: Float) -> [WPEPuppetVertex] {
        [
            (minX, minY), (maxX, minY), (maxX, maxY), (minX, maxY)
        ].map { corner in
            WPEPuppetVertex(
                position: SIMD3<Float>(corner.0, corner.1, 0),
                uv: SIMD2<Float>(0, 0),
                skinBlendIndices: SIMD4<Int32>(bone, 0, 0, 0),
                skinBlendWeights: SIMD4<Float>(1, 0, 0, 0)
            )
        }
    }

    private func quadIndices(base: UInt16) -> [UInt16] {
        [base, base + 1, base + 2, base, base + 2, base + 3]
    }

    /// One channel that scales Y from 1 (bind) down to `closedScaleY` at mid-clip and back.
    private func channel(bone: Int, closedScaleY: Float, frameCount: Int) -> WPEPuppetAnimChannel {
        let mid = frameCount / 2
        let keyframes = (0..<frameCount).map { frame -> WPEPuppetAnimKey in
            let scaleY = frame == mid ? closedScaleY : 1
            return WPEPuppetAnimKey(
                frame: frame,
                translation: .zero,
                euler: .zero,
                scale: SIMD3<Float>(1, scaleY, 1)
            )
        }
        return WPEPuppetAnimChannel(boneIndex: bone, keyframes: keyframes)
    }

    @Test("Pupil that stays open is clipped to the enclosing eye-white that squishes shut")
    func detectsEyeWhitePupilPair() {
        // Part 1 = eye-white (squishes), part 2 = pupil inside it (stays open),
        // part 13 = eyebrow above the eye (stays open but is NOT enclosed → never clipped).
        let vertices = quad(bone: 0, minX: -10, maxX: 10, minY: -5, maxY: 5)
            + quad(bone: 1, minX: -3, maxX: 3, minY: -3, maxY: 3)
            + quad(bone: 2, minX: -10, maxX: 10, minY: 8, maxY: 12)
        let indices = quadIndices(base: 0) + quadIndices(base: 4) + quadIndices(base: 8)
        let mesh = WPEPuppetMesh(
            materialPath: "eye",
            vertices: vertices,
            indices: indices,
            parts: [
                WPEPuppetMeshPart(id: 1, start: 0, count: 6),
                WPEPuppetMeshPart(id: 2, start: 6, count: 6),
                WPEPuppetMeshPart(id: 13, start: 12, count: 6)
            ],
            clipMaskName: "masks/clipping_mask_test"
        )
        let frameCount = 12
        let animation = WPEPuppetAnimation(
            id: 1, name: "blink", mode: "loop", fps: 30, frameCount: frameCount,
            channels: [
                channel(bone: 0, closedScaleY: 0.18, frameCount: frameCount), // eye-white squishes
                channel(bone: 1, closedScaleY: 1, frameCount: frameCount),    // pupil stays
                channel(bone: 2, closedScaleY: 1, frameCount: frameCount)     // eyebrow stays
            ]
        )
        let bones = (0..<3).map { WPEPuppetBone(index: $0, parentIndex: nil, rawMatrix: identityColumnMajor()) }
        let layers = [WPEPuppetAnimationLayer(animation: animation, rate: 1, additive: false, blend: 1)]

        let pairs = WPEMetalRenderExecutor._testDetectClipPairs(mesh: mesh, animationLayers: layers, bones: bones)
        #expect(pairs.count == 1)
        #expect(pairs.first?.source == 1)
        #expect(pairs.first?.target == 2)
    }

    @Test("A pure-squish eye (no part stays open) yields no clip pair")
    func pureSquishHasNoPair() {
        let vertices = quad(bone: 0, minX: -10, maxX: 10, minY: -5, maxY: 5)
            + quad(bone: 1, minX: -3, maxX: 3, minY: -3, maxY: 3)
        let indices = quadIndices(base: 0) + quadIndices(base: 4)
        let mesh = WPEPuppetMesh(
            materialPath: "eye",
            vertices: vertices,
            indices: indices,
            parts: [
                WPEPuppetMeshPart(id: 1, start: 0, count: 6),
                WPEPuppetMeshPart(id: 2, start: 6, count: 6)
            ],
            clipMaskName: "masks/clipping_mask_test"
        )
        let frameCount = 12
        let animation = WPEPuppetAnimation(
            id: 1, name: "blink", mode: "loop", fps: 30, frameCount: frameCount,
            channels: [
                channel(bone: 0, closedScaleY: 0.18, frameCount: frameCount), // both parts squish
                channel(bone: 1, closedScaleY: 0.2, frameCount: frameCount)
            ]
        )
        let bones = (0..<2).map { WPEPuppetBone(index: $0, parentIndex: nil, rawMatrix: identityColumnMajor()) }
        let layers = [WPEPuppetAnimationLayer(animation: animation, rate: 1, additive: false, blend: 1)]

        let pairs = WPEMetalRenderExecutor._testDetectClipPairs(mesh: mesh, animationLayers: layers, bones: bones)
        #expect(pairs.isEmpty)
    }

    @Test("No clip when the first part doesn't close (convention guard rejects)")
    func firstPartMustClose() {
        // First part stays open while the second squishes — the opposite of the eye-white/pupil shape,
        // so the convention guard must NOT emit a (parts[0]→parts[1]) clip.
        let vertices = quad(bone: 0, minX: -10, maxX: 10, minY: -5, maxY: 5)
            + quad(bone: 1, minX: -3, maxX: 3, minY: -3, maxY: 3)
        let indices = quadIndices(base: 0) + quadIndices(base: 4)
        let mesh = WPEPuppetMesh(
            materialPath: "eye",
            vertices: vertices,
            indices: indices,
            parts: [
                WPEPuppetMeshPart(id: 1, start: 0, count: 6),
                WPEPuppetMeshPart(id: 2, start: 6, count: 6)
            ],
            clipMaskName: "masks/clipping_mask_test"
        )
        let frameCount = 12
        let animation = WPEPuppetAnimation(
            id: 1, name: "blink", mode: "loop", fps: 30, frameCount: frameCount,
            channels: [
                channel(bone: 0, closedScaleY: 1, frameCount: frameCount),    // first part stays open
                channel(bone: 1, closedScaleY: 0.18, frameCount: frameCount)  // second part squishes
            ]
        )
        let bones = (0..<2).map { WPEPuppetBone(index: $0, parentIndex: nil, rawMatrix: identityColumnMajor()) }
        let layers = [WPEPuppetAnimationLayer(animation: animation, rate: 1, additive: false, blend: 1)]

        let pairs = WPEMetalRenderExecutor._testDetectClipPairs(mesh: mesh, animationLayers: layers, bones: bones)
        #expect(pairs.isEmpty)
    }

    @Test("Only the first→second part pair is emitted; later parts are ignored")
    func emitsSinglePairIgnoringLaterParts() {
        // Three parts that all match target criteria spatially; only parts[0]→parts[1] must be returned.
        let vertices = quad(bone: 0, minX: -10, maxX: 10, minY: -5, maxY: 5)
            + quad(bone: 1, minX: -3, maxX: 3, minY: -3, maxY: 3)
            + quad(bone: 2, minX: -2, maxX: 2, minY: -2, maxY: 2)
        let indices = quadIndices(base: 0) + quadIndices(base: 4) + quadIndices(base: 8)
        let mesh = WPEPuppetMesh(
            materialPath: "eye",
            vertices: vertices,
            indices: indices,
            parts: [
                WPEPuppetMeshPart(id: 1, start: 0, count: 6),
                WPEPuppetMeshPart(id: 2, start: 6, count: 6),
                WPEPuppetMeshPart(id: 5, start: 12, count: 6)
            ],
            clipMaskName: "masks/clipping_mask_test"
        )
        let frameCount = 12
        let animation = WPEPuppetAnimation(
            id: 1, name: "blink", mode: "loop", fps: 30, frameCount: frameCount,
            channels: [
                channel(bone: 0, closedScaleY: 0.18, frameCount: frameCount),
                channel(bone: 1, closedScaleY: 1, frameCount: frameCount),
                channel(bone: 2, closedScaleY: 1, frameCount: frameCount)
            ]
        )
        let bones = (0..<3).map { WPEPuppetBone(index: $0, parentIndex: nil, rawMatrix: identityColumnMajor()) }
        let layers = [WPEPuppetAnimationLayer(animation: animation, rate: 1, additive: false, blend: 1)]

        let pairs = WPEMetalRenderExecutor._testDetectClipPairs(mesh: mesh, animationLayers: layers, bones: bones)
        #expect(pairs.count == 1)
        #expect(pairs.first?.source == 1)
        #expect(pairs.first?.target == 2)
    }
}

/// Covers the per-puppet deferred-warp decision's effect-chain predicate: a puppet defers only when it
/// runs an effect (material-kind `.effect` OR command-kind effect), but never for the synthesized
/// rectangular copy-to-scene command alone.
@Suite("WPE puppet effect-chain detection")
struct WPEPuppetEffectChainTests {
    @Test("Material pass alone is not an effect chain")
    func materialOnly() {
        #expect(WPEMetalRenderExecutor.hasEffectChain(passPhases: [.material]) == false)
    }

    @Test("Material plus the final scene-copy command is not an effect chain")
    func materialPlusSceneCopy() {
        #expect(WPEMetalRenderExecutor.hasEffectChain(
            passPhases: [.material, .command(file: "materials/util/copy.json")]) == false)
    }

    @Test("A material-kind effect pass is an effect chain")
    func materialEffect() {
        #expect(WPEMetalRenderExecutor.hasEffectChain(
            passPhases: [.material, .effect(file: "effects/bloom/effect.json")]) == true)
    }

    @Test("A command-kind effect pass is an effect chain (not just .effect)")
    func commandEffect() {
        #expect(WPEMetalRenderExecutor.hasEffectChain(
            passPhases: [.material, .command(file: "effects/blur/effect.json"),
                         .command(file: "materials/util/copy.json")]) == true)
    }
}
