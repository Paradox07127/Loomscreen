import Foundation
import Testing
import simd
@testable import LiveWallpaper

/// Covers the geometry-driven clip-role detection that generalises the WPE eye-white/pupil
/// clip-composite to any puppet: a clip *target* stays near full height across the blink while an
/// enclosing *source* part squishes shut, so the target must be clipped to the source silhouette.
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

    @Test("Two eyes each get their own source→target clip pair")
    func detectsTwoEyes() {
        // Left eye: white (bone 0) + pupil (bone 1). Right eye: white (bone 2) + pupil (bone 3).
        let vertices = quad(bone: 0, minX: -20, maxX: -2, minY: -5, maxY: 5)
            + quad(bone: 1, minX: -14, maxX: -8, minY: -3, maxY: 3)
            + quad(bone: 2, minX: 2, maxX: 20, minY: -5, maxY: 5)
            + quad(bone: 3, minX: 8, maxX: 14, minY: -3, maxY: 3)
        let indices = quadIndices(base: 0) + quadIndices(base: 4)
            + quadIndices(base: 8) + quadIndices(base: 12)
        let mesh = WPEPuppetMesh(
            materialPath: "eyes",
            vertices: vertices,
            indices: indices,
            parts: [
                WPEPuppetMeshPart(id: 1, start: 0, count: 6),
                WPEPuppetMeshPart(id: 2, start: 6, count: 6),
                WPEPuppetMeshPart(id: 3, start: 12, count: 6),
                WPEPuppetMeshPart(id: 4, start: 18, count: 6)
            ],
            clipMaskName: "masks/clipping_mask_test"
        )
        let frameCount = 12
        let animation = WPEPuppetAnimation(
            id: 1, name: "blink", mode: "loop", fps: 30, frameCount: frameCount,
            channels: [
                channel(bone: 0, closedScaleY: 0.18, frameCount: frameCount),
                channel(bone: 1, closedScaleY: 1, frameCount: frameCount),
                channel(bone: 2, closedScaleY: 0.18, frameCount: frameCount),
                channel(bone: 3, closedScaleY: 1, frameCount: frameCount)
            ]
        )
        let bones = (0..<4).map { WPEPuppetBone(index: $0, parentIndex: nil, rawMatrix: identityColumnMajor()) }
        let layers = [WPEPuppetAnimationLayer(animation: animation, rate: 1, additive: false, blend: 1)]

        let pairs = WPEMetalRenderExecutor._testDetectClipPairs(mesh: mesh, animationLayers: layers, bones: bones)
        let mapping = Dictionary(uniqueKeysWithValues: pairs.map { ($0.target, $0.source) })
        #expect(pairs.count == 2)
        #expect(mapping[2] == 1)
        #expect(mapping[4] == 3)
    }
}
