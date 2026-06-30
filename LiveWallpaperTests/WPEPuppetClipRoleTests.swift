import Foundation
import Testing
import simd
@testable import LiveWallpaper

/// Covers the WPE clip-role detection: a clip silhouette squishes shut, while one or more clipped
/// targets stay full inside it. The relationship is validated by squish geometry, so a layout that
/// doesn't prove source/target roles emits no clip pair instead of mis-clipping.
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

    private func channel(bone: Int, closedScaleY: Float, frameCount: Int, closedFrame: Int? = nil) -> WPEPuppetAnimChannel {
        let closed = closedFrame ?? frameCount / 2
        let keyframes = (0..<frameCount).map { frame -> WPEPuppetAnimKey in
            let scaleY = frame == closed ? closedScaleY : 1
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

    @Test("Most-closed pose on the final loop frame is still detected (no duration wrap-around)")
    func detectsFinalFrameClosure() {
        let frameCount = 16
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
        // Eye-white squishes ONLY on the last frame; with time-based sampling that frame would wrap to 0.
        let animation = WPEPuppetAnimation(
            id: 1, name: "blink", mode: "loop", fps: 30, frameCount: frameCount,
            channels: [
                channel(bone: 0, closedScaleY: 0.18, frameCount: frameCount, closedFrame: frameCount - 1),
                channel(bone: 1, closedScaleY: 1, frameCount: frameCount)
            ]
        )
        let bones = (0..<2).map { WPEPuppetBone(index: $0, parentIndex: nil, rawMatrix: identityColumnMajor()) }
        let layers = [WPEPuppetAnimationLayer(animation: animation, rate: 1, additive: false, blend: 1)]

        let pairs = WPEMetalRenderExecutor._testDetectClipPairs(mesh: mesh, animationLayers: layers, bones: bones)
        #expect(pairs.count == 1)
        #expect(pairs.first?.source == 1)
        #expect(pairs.first?.target == 2)
    }

    @Test("Multiple closing eye silhouettes clip later open targets enclosed by each silhouette")
    func detectsMultipleSourcesWithLaterTargets() {
        // Mirrors scene 3558034522 / 13眼组: the first two parts both blink closed, while later
        // pupil/highlight parts stay open inside their respective eye silhouettes.
        let vertices = quad(bone: 0, minX: 20, maxX: 60, minY: -5, maxY: 5)
            + quad(bone: 1, minX: -60, maxX: -20, minY: -5, maxY: 5)
            + quad(bone: 2, minX: -45, maxX: -35, minY: -3, maxY: 3)
            + quad(bone: 3, minX: 35, maxX: 45, minY: -3, maxY: 3)
            + quad(bone: 4, minX: 70, maxX: 90, minY: 10, maxY: 15)
        let indices = quadIndices(base: 0) + quadIndices(base: 4) + quadIndices(base: 8)
            + quadIndices(base: 12) + quadIndices(base: 16)
        let mesh = WPEPuppetMesh(
            materialPath: "eye",
            vertices: vertices,
            indices: indices,
            parts: [
                WPEPuppetMeshPart(id: 1, start: 0, count: 6),
                WPEPuppetMeshPart(id: 2, start: 6, count: 6),
                WPEPuppetMeshPart(id: 3, start: 12, count: 6),
                WPEPuppetMeshPart(id: 4, start: 18, count: 6),
                WPEPuppetMeshPart(id: 5, start: 24, count: 6)
            ],
            clipMaskName: "masks/clipping_mask_test"
        )
        let frameCount = 12
        let animation = WPEPuppetAnimation(
            id: 1, name: "blink", mode: "loop", fps: 30, frameCount: frameCount,
            channels: [
                channel(bone: 0, closedScaleY: 0.02, frameCount: frameCount),
                channel(bone: 1, closedScaleY: 0.04, frameCount: frameCount),
                channel(bone: 2, closedScaleY: 1, frameCount: frameCount),
                channel(bone: 3, closedScaleY: 1, frameCount: frameCount),
                channel(bone: 4, closedScaleY: 1, frameCount: frameCount)
            ]
        )
        let bones = (0..<5).map { WPEPuppetBone(index: $0, parentIndex: nil, rawMatrix: identityColumnMajor()) }
        let layers = [WPEPuppetAnimationLayer(animation: animation, rate: 1, additive: false, blend: 1)]

        let pairs = WPEMetalRenderExecutor._testDetectClipPairs(mesh: mesh, animationLayers: layers, bones: bones)
        #expect(pairs.count == 2)
        #expect(pairs.contains { $0.source == 1 && $0.target == 4 })
        #expect(pairs.contains { $0.source == 2 && $0.target == 3 })
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

    @Test("Later enclosed open targets are clipped to the same silhouette")
    func emitsLaterEnclosedTargets() {
        // Three parts that all match target criteria spatially; both open targets should be clipped.
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
        #expect(pairs.count == 2)
        #expect(pairs.contains { $0.source == 1 && $0.target == 2 })
        #expect(pairs.contains { $0.source == 1 && $0.target == 5 })
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
