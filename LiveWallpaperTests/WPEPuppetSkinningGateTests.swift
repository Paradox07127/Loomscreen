import Foundation
import LiveWallpaperProWPE
import Metal
import Testing
import simd
@testable import LiveWallpaper

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

    private func characterSheetModel(version: Int = 19) -> WPEPuppetModel {
        let bones = [
            WPEPuppetBone(index: 0, parentIndex: nil, rawMatrix: identityMatrixFloats),
            WPEPuppetBone(index: 1, parentIndex: 0, rawMatrix: translationMatrixFloats(100, 0))
        ]
        let animation = WPEPuppetAnimation(
            id: 7, name: "assemble", mode: "loop", fps: 30, frameCount: 2,
            channels: [
                channel(bone: 0),
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
        _ = executor.puppetSkinningGateForTesting(layer: layer, model: model, time: 0.5)
        #expect(executor.puppetBoundScanCacheHitsForTesting == 1)
    }
}
