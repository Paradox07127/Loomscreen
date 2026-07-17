import Foundation
import LiveWallpaperProWPE
import Metal
import Testing
import simd
@testable import LiveWallpaper

/// Integration coverage for the puppet skinning gate now that skinning is permanently on (the
/// `WPEPuppetEnableSkinning` kill-switch was removed 2026-07-05): a valid pre-assembled puppet must
/// skin, every validation-gate disable reason must fall back to the identity palette (the static
/// assembled rest mesh), and the v19/v20 character-sheet path must skin unconditionally (its bind
/// pose is the exploded split-source).
@Suite("WPE puppet skinning gate")
struct WPEPuppetSkinningGateTests {
    private let identityMatrixFloats: [Float] = [
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1
    ]

    private func translationMatrixFloats(_ x: Float, _ y: Float) -> [Float] {
        [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            x, y, 0, 1
        ]
    }

    private func key(frame: Int, translation: SIMD3<Float> = .zero) -> WPEPuppetAnimKey {
        WPEPuppetAnimKey(frame: frame, translation: translation, euler: .zero, scale: SIMD3<Float>(1, 1, 1))
    }

    /// Frame 0 is the bind pose (identity TRS matching the identity raw bone matrices) so the
    /// pre-assembled identity fast path stays exact; frame 1 carries the motion under test.
    private func channel(bone: Int, frame1Translation: SIMD3<Float> = .zero) -> WPEPuppetAnimChannel {
        WPEPuppetAnimChannel(boneIndex: bone, keyframes: [
            key(frame: 0),
            key(frame: 1, translation: frame1Translation)
        ])
    }

    private func triangleMesh(skinIndices: SIMD4<Int32>) -> WPEPuppetMesh {
        let weights = SIMD4<Float>(1, 0, 0, 0)
        return WPEPuppetMesh(
            materialPath: "materials/base.png",
            vertices: [
                WPEPuppetVertex(position: SIMD3<Float>(-4, -4, 0), uv: SIMD2<Float>(0, 1), skinBlendIndices: skinIndices, skinBlendWeights: weights),
                WPEPuppetVertex(position: SIMD3<Float>(4, -4, 0), uv: SIMD2<Float>(1, 1), skinBlendIndices: skinIndices, skinBlendWeights: weights),
                WPEPuppetVertex(position: SIMD3<Float>(0, 4, 0), uv: SIMD2<Float>(0, 0), skinBlendIndices: skinIndices, skinBlendWeights: weights)
            ],
            indices: [0, 1, 2],
            parts: []
        )
    }

    /// Pre-assembled puppet that passes every gate: 2-bone hierarchy, both bones animated, frame-1
    /// motion far below the displacement bound (`max(256, 1.5×extent)`).
    private func validModel(
        version: Int = 23,
        frame1Translation: SIMD3<Float> = SIMD3<Float>(4, 0, 0),
        skinIndices: SIMD4<Int32> = SIMD4<Int32>(1, 0, 0, 0),
        animations: Int = 1
    ) -> WPEPuppetModel {
        let bones = [
            WPEPuppetBone(index: 0, parentIndex: nil, rawMatrix: identityMatrixFloats),
            WPEPuppetBone(index: 1, parentIndex: 0, rawMatrix: identityMatrixFloats)
        ]
        let animation = WPEPuppetAnimation(
            id: 1, name: "idle", mode: "loop", fps: 30, frameCount: 2,
            channels: [
                channel(bone: 0),
                channel(bone: 1, frame1Translation: frame1Translation)
            ]
        )
        return WPEPuppetModel(
            version: version,
            meshes: [triangleMesh(skinIndices: skinIndices)],
            bones: bones,
            animations: animations > 0 ? [animation] : []
        )
    }

    /// MDLV0019 character sheet: the raw MDLS bind is the exploded layout (bone 1 shifted +100) and
    /// the animation's frame-0 pose is the assembled character, so `baseFrameMatchesRawBind` is false
    /// and the frame-0 palette is what unfolds the sheet — skinning is mandatory.
    private func characterSheetModel(version: Int = 19) -> WPEPuppetModel {
        let bones = [
            WPEPuppetBone(index: 0, parentIndex: nil, rawMatrix: identityMatrixFloats),
            WPEPuppetBone(index: 1, parentIndex: 0, rawMatrix: translationMatrixFloats(100, 0))
        ]
        let animation = WPEPuppetAnimation(
            id: 7, name: "assemble", mode: "loop", fps: 30, frameCount: 2,
            channels: [
                channel(bone: 0),
                // Frame 0 = assembled pose (origin), NOT the exploded raw bind at +100.
                WPEPuppetAnimChannel(boneIndex: 1, keyframes: [
                    key(frame: 0),
                    key(frame: 1, translation: SIMD3<Float>(2, 0, 0))
                ])
            ]
        )
        return WPEPuppetModel(
            version: version,
            meshes: [triangleMesh(skinIndices: SIMD4<Int32>(1, 0, 0, 0))],
            bones: bones,
            animations: [animation]
        )
    }

    /// Character sheet whose only channel's parent bone has no channel: the hierarchy cannot compose,
    /// the evaluator fails closed with an empty palette, and the mandatory path reports it.
    private func unresolvablePaletteSheetModel() -> WPEPuppetModel {
        let bones = [
            WPEPuppetBone(index: 0, parentIndex: nil, rawMatrix: identityMatrixFloats),
            WPEPuppetBone(index: 1, parentIndex: 0, rawMatrix: identityMatrixFloats)
        ]
        let animation = WPEPuppetAnimation(
            id: 3, name: "broken", mode: "loop", fps: 30, frameCount: 2,
            channels: [channel(bone: 1, frame1Translation: SIMD3<Float>(2, 0, 0))]
        )
        return WPEPuppetModel(
            version: 19,
            meshes: [triangleMesh(skinIndices: SIMD4<Int32>(1, 0, 0, 0))],
            bones: bones,
            animations: [animation]
        )
    }

    private func puppetLayer(objectID: String) -> WPERenderLayer {
        WPERenderLayer(
            objectID: objectID,
            objectName: "Puppet \(objectID)",
            imagePath: "models/puppet.mdl",
            materialPath: nil,
            puppetPath: "models/puppet.mdl",
            geometry: .identity,
            compositeA: "_rt_gate_a",
            compositeB: "_rt_gate_b",
            localFBOs: [],
            passes: []
        )
    }

    private func makeExecutor() throws -> WPEMetalRenderExecutor {
        let device = try #require(MTLCreateSystemDefaultDevice())
        return try WPEMetalRenderExecutor(device: device)
    }

    private func expectIdentityFallback(
        _ gate: (enabled: Bool, reason: String, bonePalette: [simd_float4x4], skinningEnabledUniform: Float),
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(!gate.enabled, sourceLocation: sourceLocation)
        #expect(gate.skinningEnabledUniform == 0, sourceLocation: sourceLocation)
        #expect(gate.bonePalette.count == 1, sourceLocation: sourceLocation)
        #expect(
            gate.bonePalette.allSatisfy { simd_equal($0, matrix_identity_float4x4) },
            sourceLocation: sourceLocation
        )
    }

    @Test("A valid pre-assembled puppet skins with no defaults involved")
    func validPreassembledPuppetSkins() throws {
        let executor = try makeExecutor()
        let gate = executor.puppetSkinningGateForTesting(
            layer: puppetLayer(objectID: "valid"),
            model: validModel()
        )
        #expect(gate.enabled)
        #expect(gate.skinningEnabledUniform == 1)
        #expect(!gate.bonePalette.isEmpty)
    }

    @Test("no-animation gates skinning off with the identity palette")
    func noAnimationFallsBackToIdentity() throws {
        let executor = try makeExecutor()
        let gate = executor.puppetSkinningGateForTesting(
            layer: puppetLayer(objectID: "no-animation"),
            model: validModel(animations: 0)
        )
        #expect(gate.reason == "no-animation")
        expectIdentityFallback(gate)
    }

    @Test("unresolved-attachment gates skinning off with the identity palette")
    func unresolvedAttachmentFallsBackToIdentity() throws {
        let executor = try makeExecutor()
        let gate = executor.puppetSkinningGateForTesting(
            layer: puppetLayer(objectID: "unresolved-attachment"),
            model: validModel(),
            attachedChildNames: ["missing_anchor"]
        )
        #expect(gate.reason == "unresolved-attachment")
        expectIdentityFallback(gate)
    }

    @Test("missing-hierarchy gates skinning off with the identity palette")
    func missingHierarchyFallsBackToIdentity() throws {
        let executor = try makeExecutor()
        let boneless = WPEPuppetModel(
            version: 23,
            meshes: [triangleMesh(skinIndices: SIMD4<Int32>(0, 0, 0, 0))],
            bones: [],
            animations: validModel().animations
        )
        let gate = executor.puppetSkinningGateForTesting(
            layer: puppetLayer(objectID: "missing-hierarchy"),
            model: boneless
        )
        #expect(gate.reason == "missing-hierarchy")
        expectIdentityFallback(gate)
    }

    @Test("palette-unresolved gates skinning off with the identity palette")
    func paletteUnresolvedFallsBackToIdentity() throws {
        let executor = try makeExecutor()
        // Sampled off frame 0 so the identity fast path (which would mask the broken hierarchy with
        // a non-empty identity palette) does not run.
        let gate = executor.puppetSkinningGateForTesting(
            layer: puppetLayer(objectID: "palette-unresolved"),
            model: unresolvablePaletteSheetModel(),
            time: 0.05
        )
        #expect(gate.reason == "palette-unresolved")
        expectIdentityFallback(gate)
    }

    @Test("skin-index-out-of-range gates skinning off with the identity palette")
    func skinIndexOutOfRangeFallsBackToIdentity() throws {
        let executor = try makeExecutor()
        let gate = executor.puppetSkinningGateForTesting(
            layer: puppetLayer(objectID: "skin-index"),
            model: validModel(skinIndices: SIMD4<Int32>(7, 0, 0, 0))
        )
        #expect(gate.reason == "skin-index-out-of-range")
        expectIdentityFallback(gate)
    }

    @Test("palette-unbounded gates skinning off with the identity palette")
    func paletteUnboundedFallsBackToIdentity() throws {
        let executor = try makeExecutor()
        // Frame-1 excursion of 10000 dwarfs max(256, 1.5×extent) for the tiny triangle mesh.
        let gate = executor.puppetSkinningGateForTesting(
            layer: puppetLayer(objectID: "palette-unbounded"),
            model: validModel(frame1Translation: SIMD3<Float>(10_000, 0, 0))
        )
        #expect(gate.reason.hasPrefix("palette-unbounded"))
        expectIdentityFallback(gate)
    }

    @Test("v19/v20 character sheets skin mandatorily with the unfolding palette")
    func characterSheetsSkinMandatorily() throws {
        let executor = try makeExecutor()
        for version in [19, 20] {
            let sheet = executor.puppetSkinningGateForTesting(
                layer: puppetLayer(objectID: "sheet-\(version)"),
                model: characterSheetModel(version: version)
            )
            #expect(sheet.enabled, "MDLV\(version) character sheet must skin")
            #expect(sheet.reason.hasPrefix("character-sheet"))
            #expect(sheet.skinningEnabledUniform == 1)
            // The frame-0 palette unfolds the exploded sheet (bone 1: assembled − raw = −100), so it
            // must NOT be identity — identity would leave the sheet exploded.
            #expect(!sheet.bonePalette.allSatisfy { simd_equal($0, matrix_identity_float4x4) })
        }
    }

    @Test("Palette dirty-check is frame-exact and matches the uncached evaluator")
    func paletteCacheMatchesUncachedEvaluation() throws {
        let executor = try makeExecutor()
        let model = validModel()
        let layer = puppetLayer(objectID: "cache-probe")
        let evaluatorLayers = [
            WPEPuppetAnimationLayer(animation: model.animations[0], rate: 1, additive: false, blend: 1)
        ]

        // Two times inside the same sampled frame (30fps → frame 1 spans [1/30, 2/30)): the second
        // call is served by the cache — a genuine hit, not a recompute — and must equal a fresh
        // evaluator run at its own time.
        let first = executor.puppetSkinningGateForTesting(layer: layer, model: model, time: 0.034)
        #expect(executor.puppetPaletteCacheHitsForTesting == 0)
        let second = executor.puppetSkinningGateForTesting(layer: layer, model: model, time: 0.049)
        #expect(executor.puppetPaletteCacheHitsForTesting == 1)
        #expect(first.enabled && second.enabled)
        #expect(first.bonePalette == second.bonePalette)
        let oracleSameFrame = WPEPuppetAnimationEvaluator.paletteEvaluation(
            layers: evaluatorLayers, bones: model.bones, at: 0.049
        )
        #expect(second.bonePalette == oracleSameFrame.palette)

        // Crossing a frame boundary (loop wraps to frame 0) must invalidate the cached palette.
        let wrapped = executor.puppetSkinningGateForTesting(layer: layer, model: model, time: 0.067)
        #expect(executor.puppetPaletteCacheHitsForTesting == 1)
        #expect(wrapped.bonePalette != second.bonePalette)
        let oracleWrapped = WPEPuppetAnimationEvaluator.paletteEvaluation(
            layers: evaluatorLayers, bones: model.bones, at: 0.067
        )
        #expect(wrapped.bonePalette == oracleWrapped.palette)
    }

    @Test("Bound scan memoizes per object across frames")
    func boundScanMemoizedAcrossFrames() throws {
        let executor = try makeExecutor()
        let model = validModel()
        let layer = puppetLayer(objectID: "bound-memo")

        _ = executor.puppetSkinningGateForTesting(layer: layer, model: model, time: 0)
        #expect(executor.puppetBoundScanCacheHitsForTesting == 0)
        // The scan is time-independent given the animation-layer stack: a later frame must reuse it.
        _ = executor.puppetSkinningGateForTesting(layer: layer, model: model, time: 0.5)
        #expect(executor.puppetBoundScanCacheHitsForTesting == 1)
    }
}
