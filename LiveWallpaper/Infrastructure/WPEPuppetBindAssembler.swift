#if !LITE_BUILD
import Foundation
import simd

/// Re-assembles the exploded older-generation puppet mesh (MDLV0019) into its
/// final pose.
///
/// The modern puppet generation (MDLV0023) ships MDLV vertices already in
/// assembled object space, so the static puppet shader renders them directly.
/// The older generation instead ships each body part at a spread-out *bind*
/// location and carries the assembled target position per bone (`tp` in the
/// MDLS metadata). Rendering those raw positions scatters the character.
///
/// Because the sampled MDLS bind matrices are pure translations (identity
/// rotation, 100% scale), the assembly reduces to a per-vertex translation by
/// the linear-blend-skinning sum of per-bone `(target − restWorld)` deltas:
///
///     assembled = raw + Σ wᵢ · (tp[i] − restWorld[i])
///
/// This is applied once at load (CPU), leaving the Metal shader, pipeline, and
/// the modern generation untouched. Anything that isn't a confirmed exploded,
/// translation-only puppet falls through unchanged — there is no path that can
/// move an already-assembled mesh.
enum WPEPuppetBindAssembler {
    /// MDLV versions known to ship an exploded bind layout that must be
    /// re-assembled. Kept as a hard allowlist: the modern generation (v23)
    /// also carries `tp` metadata but is already assembled, so a version gate
    /// — not `tp` presence alone — is what prevents a regression there.
    private static let assemblyEligibleVersions: Set<Int> = [19, 21]

    static func assembleIfNeeded(_ model: WPEPuppetModel) -> WPEPuppetModel {
        guard shouldAssemble(model), supportsTranslationOnlyAssembly(model) else {
            return model
        }

        let restWorld = restWorldTranslations(for: model.bones)
        var deltaByBoneIndex: [Int: SIMD3<Float>] = [:]
        deltaByBoneIndex.reserveCapacity(model.bones.count)
        for bone in model.bones {
            guard let target = bone.targetPosition, let rest = restWorld[bone.index] else { continue }
            deltaByBoneIndex[bone.index] = target - rest
        }

        let meshes = model.meshes.map { mesh -> WPEPuppetMesh in
            let vertices = mesh.vertices.map { vertex -> WPEPuppetVertex in
                var weightSum: Float = 0
                var blendedDelta = SIMD3<Float>(repeating: 0)
                for slot in 0..<4 {
                    let weight = vertex.skinBlendWeights[slot]
                    guard weight.isFinite, weight > 0 else { continue }
                    weightSum += weight
                    if let delta = deltaByBoneIndex[Int(vertex.skinBlendIndices[slot])] {
                        blendedDelta += weight * delta
                    }
                }
                guard weightSum > 0 else { return vertex }
                return WPEPuppetVertex(
                    position: vertex.position + blendedDelta / weightSum,
                    uv: vertex.uv,
                    skinBlendIndices: vertex.skinBlendIndices,
                    skinBlendWeights: vertex.skinBlendWeights
                )
            }
            return WPEPuppetMesh(
                materialPath: mesh.materialPath,
                vertices: vertices,
                indices: mesh.indices,
                parts: mesh.parts
            )
        }

        return WPEPuppetModel(
            version: model.version,
            skeletonVersion: model.skeletonVersion,
            meshes: meshes,
            bones: model.bones
        )
    }

    static func shouldAssemble(_ model: WPEPuppetModel) -> Bool {
        guard assemblyEligibleVersions.contains(model.version) else { return false }
        // Exploded puppets carry per-bone assembled targets; simple sway rigs
        // on an already-assembled image do not, so they need no assembly.
        guard model.bones.contains(where: { $0.targetPosition != nil }) else { return false }
        // At least one vertex must actually be skinned for the deltas to apply.
        return model.meshes.contains { mesh in
            mesh.vertices.contains { vertex in
                (0..<4).contains { vertex.skinBlendWeights[$0] > 0 }
            }
        }
    }

    /// The translation-only delta is only valid when every bone's bind and
    /// target transforms are pure translations. If any bone introduces
    /// rotation or non-100% scale, skip assembly (render raw) rather than
    /// silently mis-assemble — a later full-matrix path can handle those.
    static func supportsTranslationOnlyAssembly(_ model: WPEPuppetModel) -> Bool {
        model.bones.allSatisfy { bone in
            let scaleOK = bone.targetScalePercent.map { abs($0 - 100) < 0.001 } ?? true
            let rotationOK = bone.targetRotation.map { $0 == SIMD3<Float>(0, 0, 0) } ?? true
            return scaleOK && rotationOK && rawMatrixIsTranslationOnly(bone.rawMatrix)
        }
    }

    private static func rawMatrixIsTranslationOnly(_ matrix: [Float]) -> Bool {
        guard matrix.count >= 16 else { return false }
        // Column-major 4×4: the upper-left 3×3 must be the identity basis.
        let identityBasis: [(index: Int, value: Float)] = [
            (0, 1), (1, 0), (2, 0),
            (4, 0), (5, 1), (6, 0),
            (8, 0), (9, 0), (10, 1)
        ]
        return identityBasis.allSatisfy { abs(matrix[$0.index] - $0.value) < 0.001 }
    }

    /// Accumulated world-space bind translation per bone index, walking the
    /// parent chain. Robust to bones not stored in strict parent-before-child
    /// order and to cycles (depth-bounded).
    private static func restWorldTranslations(for bones: [WPEPuppetBone]) -> [Int: SIMD3<Float>] {
        let bonesByIndex = Dictionary(bones.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })

        func localTranslation(_ bone: WPEPuppetBone) -> SIMD3<Float> {
            guard bone.rawMatrix.count >= 16 else { return .zero }
            return SIMD3<Float>(bone.rawMatrix[12], bone.rawMatrix[13], bone.rawMatrix[14])
        }

        func worldTranslation(_ index: Int, depth: Int) -> SIMD3<Float> {
            guard depth < 256, let bone = bonesByIndex[index] else { return .zero }
            let local = localTranslation(bone)
            if let parent = bone.parentIndex, parent >= 0, parent != index {
                return worldTranslation(parent, depth: depth + 1) + local
            }
            return local
        }

        var result: [Int: SIMD3<Float>] = [:]
        result.reserveCapacity(bones.count)
        for bone in bones {
            result[bone.index] = worldTranslation(bone.index, depth: 0)
        }
        return result
    }
}
#endif
