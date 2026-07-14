#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperProWPE
import Metal
import MetalKit
import os
import simd

extension WPEMetalRenderExecutor {
    /// Release-visible skinning-gate breadcrumb: a gated-off puppet silently renders the static rest
    /// pose (no blink/sway), so surface why in EVERY build — warning for DISABLED (mirrors the
    /// v19/v20 character-sheet path), info for ENABLED — and mirror the state into the scene-debug
    /// layer-placements dump so a bug-report dump carries the gate decision.
    func recordPuppetSkinningBreadcrumbs(
        pipeline: WPEPreparedRenderPipeline,
        skinningByObjectID: [String: PuppetSkinningState]
    ) {
        var states: [(objectID: String, summary: String)] = []
        for layer in pipeline.layers where layer.puppetModel != nil {
            let objectID = layer.graphLayer.objectID
            let state = skinningByObjectID[objectID]
            let enabled = state?.enabled ?? false
            let reason = state?.reason ?? "no-state"
            let summary = "\(enabled ? "ENABLED" : "DISABLED")/\(reason)"
            states.append((objectID, summary))
            guard lastLoggedPuppetSkinningReason[objectID] != summary else { continue }
            lastLoggedPuppetSkinningReason[objectID] = summary
            let message = "🦴 [puppet-skin] obj=\(objectID) name=\(layer.graphLayer.objectName) "
                + "skinning=\(enabled ? "ENABLED" : "DISABLED") reason=\(reason)"
            // "no-animation" = a static mesh (bones=0/animations=0 — e.g. the
            // threebody suns/skybox). Skinning off is the only possible state
            // there, so it's info; warning stays for puppets that silently lose
            // blink/sway.
            if enabled || reason == "no-animation" {
                Logger.info(message, category: .wpeRender)
            } else {
                Logger.warning(message, category: .wpeRender)
            }
        }
        // Full state every frame (not just changes): the artifacts layer stamps entries with its
        // placements generation, so a rebuilt pipeline's dump shows `pending(last=…)` until the next
        // frame re-proves each gate — pushing only changes would leave a stale verdict standing.
        WPESceneDebugArtifacts.shared.recordPuppetSkinningStates(states)
    }

    /// Composes each bone's WORLD bind matrix by walking the MDLS hierarchy (`world(parent) · rawLocal`),
    /// matching the palette's bind basis and the static attachment anchor (WPERenderGraphBuilder).
    /// Bones with a cycle / missing parent / unparseable matrix fall back to identity.
    private static func composedBindWorldByBoneIndex(_ bones: [WPEPuppetBone]) -> [Int: simd_float4x4] {
        let rawByIndex = Dictionary(
            bones.compactMap { bone -> (Int, simd_float4x4)? in
                WPEMdlParser.matrix(fromColumnMajorFloats: bone.rawMatrix).map { (bone.index, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let parentByIndex = Dictionary(
            bones.map { ($0.index, $0.parentIndex) },
            uniquingKeysWith: { first, _ in first }
        )
        var cache: [Int: simd_float4x4] = [:]
        var visiting: Set<Int> = []
        func world(_ index: Int) -> simd_float4x4 {
            if let cached = cache[index] { return cached }
            guard let local = rawByIndex[index] else { return matrix_identity_float4x4 }
            guard !visiting.contains(index) else { return local }
            visiting.insert(index)
            let composed: simd_float4x4
            if let parent = parentByIndex[index] ?? nil {
                composed = world(parent) * local
            } else {
                composed = local
            }
            visiting.remove(index)
            cache[index] = composed
            return composed
        }
        var result: [Int: simd_float4x4] = [:]
        for bone in bones where rawByIndex[bone.index] != nil {
            result[bone.index] = world(bone.index)
        }
        return result
    }

    /// The default-on skinning gate: only enable GPU skinning when the puppet's hierarchy, skin
    /// indices, palette bounds, and attached children are all supported. Otherwise the puppet renders
    /// the static assembled MDLV mesh (the pre-skinning known-good baseline).
    func validatedSkinningState(
        for layer: WPERenderLayer,
        model: WPEPuppetModel,
        attachedChildNames: Set<String>,
        time: Double
    ) -> PuppetSkinningState {
        let attachmentsByName = Dictionary(
            model.attachments.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // Composed (parent-local hierarchy) bind world per bone — MUST match the palette's bind basis
        // (WPEPuppetAnimationEvaluator composes raw MDLS down the hierarchy). Using the raw matrices
        // here desyncs the attachment-follow anchor from `palette[bone] · bind⁻¹`, so a followed face/
        // hair layer drifts/stretches relative to the skinned head. See the palette fix (69ed52b).
        let boneBindByIndex = Self.composedBindWorldByBoneIndex(model.bones)
        // Assembled (frame-0 for character sheets) bind-world for the anchor REST position; raw for the
        // palette basis. Equal for pre-assembled puppets (no-op), so this only affects MDLV0019/0020.
        let assembledBoneBindByIndex = WPEPuppetAnimationEvaluator.assembledBindWorldByBone(model: model)
        func disabled(_ reason: String) -> PuppetSkinningState {
            PuppetSkinningState(
                enabled: false,
                palette: [],
                attachmentsByName: attachmentsByName,
                boneBindByIndex: boneBindByIndex,
                assembledBoneBindByIndex: assembledBoneBindByIndex,
                reason: reason
            )
        }

        // MDLV0019/0020 ship the mesh as a FLAT character sheet: the MDLV bind pose is the exploded
        // split-source, and the assembled character is recovered ONLY by skinning through the MDLA
        // animation pose. Its bind pose is therefore guaranteed-wrong, so skinning is MANDATORY for
        // these generations — the regression carve-outs (which exist to keep pre-assembled v21/v23
        // face/blink puppets static) must not apply, and rejecting on the displacement bound can only
        // make it worse than the already-broken bind. Derived here from the model the executor already
        // holds; no scene-schema threading.
        if model.version >= 19, model.version < 21, !model.bones.isEmpty {
            return mandatorySkinningState(
                for: layer,
                model: model,
                attachmentsByName: attachmentsByName,
                boneBindByIndex: boneBindByIndex,
                assembledBoneBindByIndex: assembledBoneBindByIndex,
                time: time
            )
        }

        // Bone skinning is always enabled for pre-assembled puppets that pass validation. The gates
        // below still reject unresolved attachments, missing hierarchies, out-of-range indices, and
        // unbounded palettes so failing puppets fall back to the static rest mesh.
        let animationLayers = puppetAnimationLayers(for: layer, model: model)
        guard !animationLayers.isEmpty else { return disabled("no-animation") }
        // If a child attaches to an anchor we cannot resolve, refuse to skin this parent so the body
        // never moves out from under a face/hair layer we are unable to follow.
        guard attachedChildNames.allSatisfy({ attachmentsByName[$0] != nil }) else {
            return disabled("unresolved-attachment")
        }
        guard WPEPuppetAnimationEvaluator.hasUsableHierarchy(layers: animationLayers, bones: model.bones) else {
            return disabled("missing-hierarchy")
        }
        let evaluation = cachedPaletteEvaluation(
            objectID: layer.objectID,
            layers: animationLayers,
            bones: model.bones,
            at: time
        )
        guard evaluation.parentChannelMapSucceeded, !evaluation.palette.isEmpty else {
            return disabled("palette-unresolved")
        }
        guard Self.skinBlendIndicesAreInRange(in: model.meshes, paletteCount: evaluation.palette.count) else {
            return disabled("skin-index-out-of-range")
        }
        if let detail = cachedPaletteBoundFailureDetail(objectID: layer.objectID, layers: animationLayers, model: model) {
            return disabled("palette-unbounded[\(detail)]")
        }
        return PuppetSkinningState(
            enabled: true,
            palette: evaluation.palette,
            attachmentsByName: attachmentsByName,
            boneBindByIndex: boneBindByIndex,
            assembledBoneBindByIndex: assembledBoneBindByIndex,
            reason: evaluation.transformSpace?.rawValue ?? "bind"
        )
    }

    /// Test seam: drives the private skinning gate plus the identity-palette fallback without a full
    /// render.
    func puppetSkinningGateForTesting(
        layer: WPERenderLayer,
        model: WPEPuppetModel,
        attachedChildNames: Set<String> = [],
        time: Double = 0
    ) -> (enabled: Bool, reason: String, bonePalette: [simd_float4x4], skinningEnabledUniform: Float) {
        let state = validatedSkinningState(
            for: layer,
            model: model,
            attachedChildNames: attachedChildNames,
            time: time
        )
        let paletteState = puppetBonePalette(for: state)
        return (state.enabled, state.reason, paletteState.bonePalette, paletteState.skinningEnabled)
    }

    /// Time-independent identity of an animation-layer stack: every input `paletteEvaluation` and
    /// the bound scan depend on besides time (and bones/meshes, which are fixed per objectID within
    /// a graph build).
    private static func puppetStackSignature(_ layers: [WPEPuppetAnimationLayer]) -> [UInt64] {
        var signature: [UInt64] = []
        signature.reserveCapacity(layers.count * 4 + 1)
        signature.append(UInt64(layers.count))
        for layer in layers {
            signature.append(UInt64(bitPattern: Int64(layer.animation.id)))
            signature.append(layer.additive ? 1 : 0)
            signature.append(UInt64(layer.blend.bitPattern))
            signature.append(layer.rate.bitPattern)
        }
        return signature
    }

    /// Stack signature plus each layer's sampled frame at `time` — the palette is a pure function
    /// of this (the evaluator reads time only through `sampledFrameIndex(at: time * rate)`).
    private static func puppetFrameSignature(_ layers: [WPEPuppetAnimationLayer], at time: Double) -> [UInt64] {
        var signature = puppetStackSignature(layers)
        for layer in layers {
            let frame = WPEPuppetAnimationEvaluator.sampledFrameIndex(for: layer.animation, at: time * layer.rate)
            signature.append(UInt64(bitPattern: Int64(frame)))
        }
        return signature
    }

    private func cachedPaletteEvaluation(
        objectID: String,
        layers: [WPEPuppetAnimationLayer],
        bones: [WPEPuppetBone],
        at time: Double
    ) -> WPEPuppetPaletteEvaluation {
        let signature = Self.puppetFrameSignature(layers, at: time)
        if let cached = puppetPaletteCacheByObjectID[objectID], cached.frameSignature == signature {
            puppetPaletteCacheHitsForTesting += 1
            return cached.evaluation
        }
        let evaluation = WPEPuppetAnimationEvaluator.paletteEvaluation(layers: layers, bones: bones, at: time)
        puppetPaletteCacheByObjectID[objectID] = PuppetPaletteCacheEntry(
            frameSignature: signature,
            evaluation: evaluation
        )
        return evaluation
    }

    private func cachedPaletteBoundFailureDetail(
        objectID: String,
        layers: [WPEPuppetAnimationLayer],
        model: WPEPuppetModel
    ) -> String? {
        let signature = Self.puppetStackSignature(layers)
        if let cached = puppetBoundScanDetailByObjectID[objectID], cached.stackSignature == signature {
            puppetBoundScanCacheHitsForTesting += 1
            return cached.detail
        }
        let detail = paletteBoundFailureDetail(layers: layers, bones: model.bones, meshes: model.meshes)
        puppetBoundScanDetailByObjectID[objectID] = PuppetBoundScanCacheEntry(
            stackSignature: signature,
            detail: detail
        )
        return detail
    }

    /// Skinning gate for MDLV0019/0020 character-sheet puppets, where skinning is MANDATORY (the bind
    /// pose is the exploded split-source). Bypasses the pre-assembled regression carve-outs
    /// (`unresolved-attachment` / `missing-hierarchy` / `skin-index-out-of-range` / the displacement
    /// bound); keeps only the irreducible precondition — a finite, non-empty palette — so there is
    /// something to skin with. A model that fails even that keeps the (broken) static draw.
    private func mandatorySkinningState(
        for layer: WPERenderLayer,
        model: WPEPuppetModel,
        attachmentsByName: [String: WPEPuppetAttachment],
        boneBindByIndex: [Int: simd_float4x4],
        assembledBoneBindByIndex: [Int: simd_float4x4],
        time: Double
    ) -> PuppetSkinningState {
        let generation = String(format: "MDLV%04d", model.version)
        func disabled(_ reason: String) -> PuppetSkinningState {
            PuppetSkinningState(
                enabled: false,
                palette: [],
                attachmentsByName: attachmentsByName,
                boneBindByIndex: boneBindByIndex,
                assembledBoneBindByIndex: assembledBoneBindByIndex,
                reason: reason
            )
        }
        func warnOnce(_ reason: String, _ message: String) {
            guard characterSheetWarnedReasonByObjectID[layer.objectID] != reason else { return }
            characterSheetWarnedReasonByObjectID[layer.objectID] = reason
            Logger.warning(message, category: .wpeRender)
        }
        let animationLayers = puppetAnimationLayers(for: layer, model: model)
        guard !animationLayers.isEmpty else {
            warnOnce(
                "no-animation",
                "WPE \(generation) character-sheet puppet without animation renders unassembled (bind)."
            )
            return disabled("no-animation")
        }
        let evaluation = cachedPaletteEvaluation(
            objectID: layer.objectID,
            layers: animationLayers,
            bones: model.bones,
            at: time
        )
        guard !evaluation.palette.isEmpty,
              evaluation.palette.allSatisfy(WPEPuppetAnimationEvaluator.matrixIsFinite) else {
            warnOnce(
                "palette-unresolved",
                "WPE \(generation) character-sheet puppet palette unresolved/non-finite; renders "
                    + "unassembled (bind)."
            )
            return disabled("palette-unresolved")
        }
        if let detail = cachedPaletteBoundFailureDetail(objectID: layer.objectID, layers: animationLayers, model: model) {
            warnOnce(
                "bound-exempt",
                "WPE \(generation) character-sheet puppet exceeds the displacement bound (\(detail)); "
                    + "skinning anyway (bind pose is unassembled)."
            )
        }
        return PuppetSkinningState(
            enabled: true,
            palette: evaluation.palette,
            attachmentsByName: attachmentsByName,
            boneBindByIndex: boneBindByIndex,
            assembledBoneBindByIndex: assembledBoneBindByIndex,
            reason: "character-sheet[\(evaluation.transformSpace?.rawValue ?? "bind")]"
        )
    }

    /// Samples the palette across the clip and rejects skinning if any frame is non-finite or moves a
    /// skinned vertex further than a puppet-size-relative bound — the catch for an otherwise "finite"
    /// but exploding palette that frame-0==identity alone would not detect.
    /// Returns nil when every sampled frame's palette is finite and bounded; otherwise a short
    /// failure detail (frame / transform space / vertex-delta vs. allowed) that rides on the
    /// `palette-unbounded` reason so the skinning-gate log shows WHY a puppet was rejected — a near-miss
    /// delta means the threshold is too tight, a huge delta means the palette evaluation is exploding.
    private func paletteBoundFailureDetail(
        layers: [WPEPuppetAnimationLayer],
        bones: [WPEPuppetBone],
        meshes: [WPEPuppetMesh]
    ) -> String? {
        guard let base = layers.first(where: { !$0.additive }) ?? layers.first else { return "no-base-layer" }
        let fps = Double(base.animation.fps)
        guard fps.isFinite, fps > 0 else { return "bad-fps" }
        let last = max(base.animation.frameCount, 1)
        let frames = Array(Set([0, 1, last / 4, last / 2, (last * 3) / 4, last])).sorted()
        let extent = Self.modelExtent(meshes: meshes)
        // This bound only needs to catch a grossly exploding palette: structural failures
        // (non-finite, out-of-range skin indices, unresolved attachments, broken hierarchy) are
        // caught by the other gate conditions. The previous 0.12×extent was far too tight — it
        // rejected legit flowing-hair / gesture motion (e.g. Plana's finite 0.37×-extent swing),
        // leaving the whole puppet static (no blink/sway). A legit pose keeps every skinned vertex
        // within ~1.5 model extents of rest; beyond that the palette is exploding.
        let maxAllowedDelta = max(Float(256), extent * 1.5)
        for frame in frames {
            let time = Double(frame) / fps / max(base.rate, 0.0001)
            let evaluation = WPEPuppetAnimationEvaluator.paletteEvaluation(layers: layers, bones: bones, at: time)
            guard evaluation.parentChannelMapSucceeded,
                  !evaluation.palette.isEmpty,
                  evaluation.palette.allSatisfy(WPEPuppetAnimationEvaluator.matrixIsFinite) else {
                let finite = evaluation.palette.allSatisfy(WPEPuppetAnimationEvaluator.matrixIsFinite)
                return "frame=\(frame) parentMap=\(evaluation.parentChannelMapSucceeded) "
                    + "empty=\(evaluation.palette.isEmpty) finite=\(finite)"
            }
            let delta = Self.maxSkinnedVertexDelta(meshes: meshes, palette: evaluation.palette)
            guard delta <= maxAllowedDelta else {
                return "frame=\(frame) space=\(evaluation.transformSpace?.rawValue ?? "nil") "
                    + "Δ=\(Int(delta))>\(Int(maxAllowedDelta)) extent=\(Int(extent))"
            }
        }
        return nil
    }

    /// Every skin-blend index with positive, finite weight must address a real palette entry. The
    /// shader clamps negatives to bone 0, so a negative index with weight is a malformed mesh we must
    /// reject here rather than skin against the wrong (or out-of-range) bone.
    private static func skinBlendIndicesAreInRange(in meshes: [WPEPuppetMesh], paletteCount: Int) -> Bool {
        guard paletteCount > 0 else { return false }
        for mesh in meshes {
            for vertex in mesh.vertices {
                let weights = vertex.skinBlendWeights
                let indices = vertex.skinBlendIndices
                func valid(_ index: Int32, _ weight: Float) -> Bool {
                    guard weight.isFinite else { return false }
                    guard weight > 0 else { return true }
                    return index >= 0 && Int(index) < paletteCount
                }
                guard valid(indices.x, weights.x), valid(indices.y, weights.y),
                      valid(indices.z, weights.z), valid(indices.w, weights.w) else { return false }
            }
        }
        return true
    }

    private static func modelExtent(meshes: [WPEPuppetMesh]) -> Float {
        var minPoint = SIMD2<Float>(.greatestFiniteMagnitude, .greatestFiniteMagnitude)
        var maxPoint = SIMD2<Float>(-.greatestFiniteMagnitude, -.greatestFiniteMagnitude)
        for mesh in meshes {
            for vertex in mesh.vertices {
                let p = SIMD2<Float>(vertex.position.x, vertex.position.y)
                minPoint = min(minPoint, p)
                maxPoint = max(maxPoint, p)
            }
        }
        guard minPoint.x.isFinite, maxPoint.x.isFinite else { return 1 }
        return max(maxPoint.x - minPoint.x, maxPoint.y - minPoint.y, 1)
    }

    private static func maxSkinnedVertexDelta(meshes: [WPEPuppetMesh], palette: [simd_float4x4]) -> Float {
        var maxDelta: Float = 0
        for mesh in meshes {
            for vertex in mesh.vertices {
                let weights = max(vertex.skinBlendWeights, SIMD4<Float>(repeating: 0))
                let weightSum = weights.x + weights.y + weights.z + weights.w
                guard weightSum > 0.00001 else { continue }
                let source = SIMD4<Float>(vertex.position.x, vertex.position.y, vertex.position.z, 1)
                let indices = vertex.skinBlendIndices
                var skinned = SIMD4<Float>(repeating: 0)
                func add(_ index: Int32, _ weight: Float) {
                    guard weight > 0 else { return }
                    if index >= 0, Int(index) < palette.count {
                        skinned += weight * (palette[Int(index)] * source)
                    } else {
                        skinned += weight * source
                    }
                }
                add(indices.x, weights.x)
                add(indices.y, weights.y)
                add(indices.z, weights.z)
                add(indices.w, weights.w)
                skinned /= weightSum
                let dx = skinned.x - source.x
                let dy = skinned.y - source.y
                maxDelta = max(maxDelta, (dx * dx + dy * dy).squareRoot())
            }
        }
        return maxDelta
    }

    /// Re-derives an attached child's transform from its parent puppet's animated anchor bone. The
    /// child's static (parent-baked) origin already places it correctly at the bind pose, so we add
    /// only the anchor's per-frame scene-space motion; at the bind pose the delta is exactly zero.
    ///
    /// ON-DEVICE VALIDATION POINT: the MDAT bind matrix is treated as a bone-LOCAL anchor offset, so
    /// the model-space anchor is `boneBind · MDAT`. The model→scene mapping (puppetModelPointToScene)
    /// is the convention most worth verifying on-device; both anchor points share it, so any constant
    /// offset cancels and only the parent's scale/rotation shapes the followed motion.
    func layerApplyingAttachmentFollow(
        _ layer: WPERenderLayer,
        context: PuppetAttachmentFrameContext
    ) -> WPERenderLayer {
        guard let parentID = layer.parentObjectID,
              let attachmentName = layer.attachment,
              let parent = context.layersByObjectID[parentID]?.graphLayer,
              let parentState = context.skinningByObjectID[parentID],
              parentState.enabled,
              let attachment = parentState.attachmentsByName[attachmentName],
              attachment.boneIndex >= 0,
              attachment.boneIndex < parentState.palette.count else {
            return layer
        }
        let rawBoneBind = parentState.boneBindByIndex[attachment.boneIndex] ?? matrix_identity_float4x4
        let assembledBoneBind = parentState.assembledBoneBindByIndex[attachment.boneIndex] ?? rawBoneBind
        // CURRENT anchor world: the palette is `currentWorld · rawBind⁻¹`, so multiplying the RAW-basis
        // anchor recovers `currentWorld · MDAT`. REST anchor: the ASSEMBLED bind (frame-0 for character
        // sheets) — the same pose the graph builder placed the child at — so the delta is the animated
        // motion only, zero at rest. For pre-assembled puppets assembled == raw, so this is unchanged.
        let anchorCurrentModel = parentState.palette[attachment.boneIndex] * (rawBoneBind * attachment.matrix)
        let anchorBindModel = assembledBoneBind * attachment.matrix
        let bindPoint = SIMD2<Float>(anchorBindModel.columns.3.x, anchorBindModel.columns.3.y)
        let currentPoint = SIMD2<Float>(anchorCurrentModel.columns.3.x, anchorCurrentModel.columns.3.y)
        let bindScene = puppetModelPointToScene(bindPoint, layer: parent, sceneSize: context.sceneSize)
        let currentScene = puppetModelPointToScene(currentPoint, layer: parent, sceneSize: context.sceneSize)
        let delta = SIMD2<Float>(currentScene.x - bindScene.x, currentScene.y - bindScene.y)
        guard delta.x.isFinite, delta.y.isFinite else { return layer }
        return replacingGeometryOrigin(of: layer, bySceneOffset: delta, sceneSize: context.sceneSize)
    }

    /// A WPE origin component in `0...1` is a normalized fraction of the scene; outside that range it
    /// is already in pixels. Resolve to pixels so an attachment delta (always pixels) can be added.
    private static func scenePixelOrigin(from origin: SIMD3<Double>, sceneSize: CGSize) -> SIMD2<Double> {
        let sceneWidth = max(Double(sceneSize.width), 1)
        let sceneHeight = max(Double(sceneSize.height), 1)
        let x = (origin.x >= 0 && origin.x <= 1) ? origin.x * sceneWidth : origin.x
        let y = (origin.y >= 0 && origin.y <= 1) ? origin.y * sceneHeight : origin.y
        return SIMD2<Double>(x, y)
    }

    private func puppetModelPointToScene(
        _ point: SIMD2<Float>,
        layer: WPERenderLayer,
        sceneSize: CGSize
    ) -> SIMD2<Float> {
        let geometry = layer.geometry
        let sceneWidth = Float(max(sceneSize.width, 1))
        let sceneHeight = Float(max(sceneSize.height, 1))
        let scaleX = max(abs(Float(geometry.scale.x)), 0.0001)
        let scaleY = max(abs(Float(geometry.scale.y)), 0.0001)
        let width = max(Float(geometry.size?.width ?? 1) * scaleX, 0.0001)
        let height = max(Float(geometry.size?.height ?? 1) * scaleY, 0.0001)
        let originX = Float(geometry.origin.x)
        let originY = Float(geometry.origin.y)
        let originXPixels = (originX >= 0 && originX <= 1) ? originX * sceneWidth : originX
        let originYPixels = (originY >= 0 && originY <= 1) ? originY * sceneHeight : originY
        let anchor = SIMD2<Float>(originXPixels - sceneWidth * 0.5, originYPixels - sceneHeight * 0.5)
        let center = anchor + Self.alignmentCenterOffset(alignment: geometry.alignment, width: width, height: height)
        let local = SIMD2<Float>(
            (point.x - Float(geometry.puppetMeshCenter.x)) * scaleX,
            (point.y - Float(geometry.puppetMeshCenter.y)) * scaleY
        )
        let angle = Float(geometry.angles.z)
        let c = cos(angle)
        let s = sin(angle)
        return SIMD2<Float>(
            center.x + c * local.x - s * local.y,
            center.y + s * local.x + c * local.y
        )
    }

    // Internal (not private) so tests can cover the per-frame rewrite: it must
    // carry every geometry field — dropping one (e.g. shapePoints) silently
    // strips it from every rendered frame of an attachment-followed layer.
    func replacingGeometryOrigin(
        of layer: WPERenderLayer,
        bySceneOffset delta: SIMD2<Float>,
        sceneSize: CGSize
    ) -> WPERenderLayer {
        let geometry = layer.geometry
        let originPixels = Self.scenePixelOrigin(from: geometry.origin, sceneSize: sceneSize)
        let adjustedGeometry = WPERenderLayerGeometry(
            origin: SIMD3<Double>(
                originPixels.x + Double(delta.x),
                originPixels.y + Double(delta.y),
                geometry.origin.z
            ),
            scale: geometry.scale,
            angles: geometry.angles,
            alignment: geometry.alignment,
            size: geometry.size,
            puppetMeshCenter: geometry.puppetMeshCenter,
            alpha: geometry.alpha,
            alphaAnimation: geometry.alphaAnimation,
            color: geometry.color,
            brightness: geometry.brightness,
            shapePoints: geometry.shapePoints
        )
        return WPERenderLayer(
            objectID: layer.objectID,
            objectName: layer.objectName,
            visible: layer.visible,
            imagePath: layer.imagePath,
            materialPath: layer.materialPath,
            puppetPath: layer.puppetPath,
            parentObjectID: layer.parentObjectID,
            attachment: layer.attachment,
            animationLayers: layer.animationLayers,
            geometry: adjustedGeometry,
            localGeometry: layer.localGeometry,
            compositeA: layer.compositeA,
            compositeB: layer.compositeB,
            localFBOs: layer.localFBOs,
            passes: layer.passes,
            groupRenderTarget: layer.groupRenderTarget,
            groupLocalGeometry: layer.groupLocalGeometry,
            groupCompositeSource: layer.groupCompositeSource,
            parallaxDepth: layer.parallaxDepth,
            sortIndex: layer.sortIndex
        )
    }

    func layerForDrawing(pass: WPERenderPass, layer: WPERenderLayer) -> WPERenderLayer {
        guard isGroupRenderTarget(pass.target, layer: layer),
              let groupLocalGeometry = layer.groupLocalGeometry else {
            return layer
        }
        return layer.replacingDrawGeometry(groupLocalGeometry, parallaxDepth: SIMD2<Double>(0, 0))
    }

    func encodeSceneModelMaterialPassIfNeeded(
        pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        puppetModel: WPEPuppetModel?,
        skinningState: PuppetSkinningState?,
        destination: (id: WPEMetalTargetID, texture: MTLTexture),
        textures: [String: MTLTexture],
        frameState: WPEMetalFrameState,
        encoder: MTLRenderCommandEncoder,
        depthPixelFormat: MTLPixelFormat
    ) throws -> Bool {
        guard case .material = pass.pass.phase,
              case .scene = pass.pass.target,
              Self.rendersAsSceneModel(layer),
              let model = puppetModel else {
            return false
        }
        let meshes = model.meshes.filter { !$0.vertices.isEmpty && !$0.indices.isEmpty }
        guard !meshes.isEmpty else { return false }

        let normalizedShader = WPEMetalShaderInputs.normalizedBuiltinShaderName(pass.pass.shader)
        guard normalizedShader == BuiltinShaderName.genericImage2
                || normalizedShader == BuiltinShaderName.genericImage4 else {
            return false
        }

        let primaryRef = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
        let primary = try WPEMetalShaderInputs.resolve(
            reference: primaryRef,
            textures: textures,
            frameState: frameState,
            currentTargetID: destination.id
        )
        if normalizedShader == BuiltinShaderName.genericImage4 {
            // generic4 MODEL material semantics differ from the image-layer path:
            // slot 1 is the normal map (unused), slot 2 the PBR component map
            // whose ALPHA is the emissive mask; tint/emissive come from the
            // material constants ("color"/"emissivecolor"…). RenderDoc oracle on
            // 3509243656: the suns are tex0 × g_TintColor with
            // g_EmissiveColor × mask.a × g_EmissiveBrightness — the flat image
            // fragment rendered them plain white.
            encoder.setRenderPipelineState(try renderPipeline(
                vertexName: "wpe_scene_model_mesh_vertex",
                fragmentName: "wpe_scene_model_generic4_fragment",
                blendMode: pass.pass.blending,
                colorPixelFormat: destination.texture.pixelFormat,
                depthPixelFormat: depthPixelFormat
            ))
            encoder.setFragmentTexture(primary, index: 0)

            var componentMap: MTLTexture?
            if let maskRef = pass.textureBindings[2] ?? pass.pass.textures[2] {
                do {
                    componentMap = try WPEMetalShaderInputs.resolve(
                        reference: maskRef,
                        textures: textures,
                        frameState: frameState,
                        currentTargetID: destination.id
                    )
                } catch {
                    // A missing/unresolvable component map silently falls back to
                    // albedo, which drops the emissive mask (flat white suns on
                    // 3509243656). Surface it once so the degrade is diagnosable.
                    if loggedComponentMapResolveFailures.insert(layer.objectID).inserted {
                        Logger.warning(
                            "[WPE.generic4] component-map resolve failed for \(layer.objectName), falling back to albedo: \(error)",
                            category: .wpeRender
                        )
                    }
                }
            }
            encoder.setFragmentTexture(componentMap ?? primary, index: 1)
            var uniforms = sceneModelGenericUniforms(
                for: pass,
                layer: layer,
                hasComponentMap: componentMap != nil
            )
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPESceneModelGenericUniforms>.stride, index: 0)
        } else {
            encoder.setRenderPipelineState(try renderPipeline(
                vertexName: "wpe_scene_model_mesh_vertex",
                fragmentName: "wpe_genericimage2_fragment",
                blendMode: pass.pass.blending,
                colorPixelFormat: destination.texture.pixelFormat,
                depthPixelFormat: depthPixelFormat
            ))
            encoder.setFragmentTexture(primary, index: 0)
            encoder.setFragmentTexture(primary, index: 1)
            var uniforms = genericImageUniforms(
                for: pass,
                layer: layer,
                hasMask: false,
                sourceTexture: primary,
                maskTexture: nil
            )
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPEGenericImageUniforms>.stride, index: 0)
        }

        let paletteState = puppetBonePalette(for: skinningState)
        var meshUniforms = sceneModelMeshUniforms(for: layer, frameState: frameState, paletteState: paletteState)
        try bindPuppetBonePalette(paletteState.bonePalette, encoder: encoder)
        encoder.setVertexBytes(
            &meshUniforms,
            length: MemoryLayout<WPESceneModelMeshUniforms>.stride,
            index: 1
        )

        try drawPuppetMeshes(meshes, encoder: encoder)
        return true
    }

    func encodePuppetMaterialPassIfNeeded(
        pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        puppetModel: WPEPuppetModel?,
        skinningState: PuppetSkinningState?,
        runtimeUniforms: WPEMetalRuntimeUniforms,
        destination: (id: WPEMetalTargetID, texture: MTLTexture),
        textures: [String: MTLTexture],
        frameState: WPEMetalFrameState,
        encoder: MTLRenderCommandEncoder,
        depthPixelFormat: MTLPixelFormat
    ) throws -> Bool {
        guard case .material = pass.pass.phase,
              case .layerComposite = pass.pass.target,
              let model = puppetModel else {
            return false
        }
        if shouldDeferPuppetMeshWarp(for: layer, model: model) {
            // Intentional fallthrough: the dispatcher's genericimage2/4 path resolves
            // texture0 with the SAME atlas precedence used below
            // (`textureBindings[0] ?? textures[0] ?? source`). Because this pass targets
            // `.layerComposite`, `usesObjectQuadGeometry` is false, so it renders the
            // atlas at local UV 1:1 via `wpe_fullscreen_vertex` (no mesh warp). The warp
            // is applied later by `encodePuppetSceneCompositePassIfNeeded`.
            return false
        }
        let meshes = model.meshes.filter { !$0.vertices.isEmpty && !$0.indices.isEmpty }
        guard !meshes.isEmpty else { return false }

        let normalizedShader = WPEMetalShaderInputs.normalizedBuiltinShaderName(pass.pass.shader)
        guard normalizedShader == BuiltinShaderName.genericImage2
                || normalizedShader == BuiltinShaderName.genericImage4 else {
            return false
        }

        let primaryRef = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
        let primary = try WPEMetalShaderInputs.resolve(
            reference: primaryRef,
            textures: textures,
            frameState: frameState,
            currentTargetID: destination.id
        )

        let fragmentName = normalizedShader == BuiltinShaderName.genericImage4
            ? "wpe_genericimage4_fragment"
            : "wpe_genericimage2_fragment"
        encoder.setRenderPipelineState(try renderPipeline(
            vertexName: "wpe_puppet_mesh_vertex",
            fragmentName: fragmentName,
            blendMode: pass.pass.blending,
            colorPixelFormat: destination.texture.pixelFormat,
            depthPixelFormat: depthPixelFormat
        ))
        encoder.setFragmentTexture(primary, index: 0)

        let hasMask: Bool
        let maskForUniforms: MTLTexture?
        #if !LITE_BUILD && DEBUG
        let maskBindingReference: WPETextureReference?
        let maskBindingTexture: MTLTexture?
        let maskBindingName: String?
        let maskFallbackToPrimary: Bool
        #endif
        if normalizedShader == BuiltinShaderName.genericImage4 {
            // A clip-composite binding (slot 8) is consumed by the dedicated clip pass; the
            // injected slot-1 mask must NOT be applied as a flat static mask to every part here.
            let maskRef = hasPuppetClipCompositeBinding(pass, layer: layer)
                ? nil
                : (pass.textureBindings[1] ?? pass.pass.textures[1])
            if let maskRef {
                let mask = try WPEMetalShaderInputs.resolve(
                    reference: maskRef,
                    textures: textures,
                    frameState: frameState,
                    currentTargetID: destination.id
                )
                encoder.setFragmentTexture(mask, index: 1)
                hasMask = true
                maskForUniforms = mask
                #if !LITE_BUILD && DEBUG
                maskBindingReference = maskRef
                maskBindingTexture = mask
                maskBindingName = "g_Texture1"
                maskFallbackToPrimary = false
                #endif
            } else {
                encoder.setFragmentTexture(primary, index: 1)
                hasMask = false
                maskForUniforms = nil
                #if !LITE_BUILD && DEBUG
                maskBindingReference = nil
                maskBindingTexture = primary
                // hasMask == false: texture1 is bound only to satisfy the Metal
                // signature; the fragment never samples it, so leave it unnamed so
                // the oracle diff does not flag it as an asset divergence.
                maskBindingName = nil
                maskFallbackToPrimary = true
                #endif
            }
        } else {
            hasMask = false
            maskForUniforms = nil
            #if !LITE_BUILD && DEBUG
            maskBindingReference = nil
            maskBindingTexture = nil
            maskBindingName = nil
            maskFallbackToPrimary = false
            #endif
        }

        var uniforms = genericImageUniforms(
            for: pass,
            layer: layer,
            hasMask: hasMask,
            sourceTexture: primary,
            maskTexture: maskForUniforms
        )
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPEGenericImageUniforms>.stride, index: 0)

        // Skinning is resolved via `puppetBonePalette` (validated/cached once per frame in
        // `makeAttachmentFrameContext`); the identity-palette fallback reproduces the assembled rest mesh.
        let paletteState = puppetBonePalette(for: skinningState)
        var meshUniforms = WPEPuppetMeshUniforms(
            localSizeAndMode: SIMD4<Float>(
                Float(max(destination.texture.width, 1)),
                Float(max(destination.texture.height, 1)),
                Float(paletteState.bonePalette.count),
                paletteState.skinningEnabled
            ),
            meshCenterAndPadding: SIMD4<Float>(
                Float(layer.geometry.puppetMeshCenter.x),
                Float(layer.geometry.puppetMeshCenter.y),
                0,
                0
            )
        )

        try bindPuppetBonePalette(paletteState.bonePalette, encoder: encoder)
        encoder.setVertexBytes(
            &meshUniforms,
            length: MemoryLayout<WPEPuppetMeshUniforms>.stride,
            index: 1
        )

        #if !LITE_BUILD && DEBUG
        var canonicalTextureBindings = [
            WPECanonicalTraceRecorder.TextureBindingInput(
                slot: 0,
                name: "g_Texture0",
                reference: primaryRef,
                texture: primary,
                fallbackToPrimary: false
            )
        ]
        if let maskBindingTexture {
            canonicalTextureBindings.append(WPECanonicalTraceRecorder.TextureBindingInput(
                slot: 1,
                name: maskBindingName,
                reference: maskBindingReference,
                texture: maskBindingTexture,
                fallbackToPrimary: maskFallbackToPrimary
            ))
        }
        WPECanonicalTraceRecorder.shared.recordPuppetPass(
            pass: pass,
            stage: "material-mesh",
            layer: layer,
            modelPath: layer.puppetPath,
            meshes: meshes,
            destination: destination,
            textureBindings: canonicalTextureBindings,
            vertexShaderName: "wpe_puppet_mesh_vertex",
            fragmentShaderName: fragmentName,
            fragmentUniforms: [
                WPECanonicalTraceRecorder.PuppetUniformInput(name: "color", type: "vec4", value: uniforms.color),
                WPECanonicalTraceRecorder.PuppetUniformInput(name: "alphaMaskUV", type: "vec4", value: uniforms.alphaMaskUV),
                WPECanonicalTraceRecorder.PuppetUniformInput(
                    name: "textureUVScale",
                    type: "vec4",
                    value: uniforms.textureUVScale
                )
            ],
            vertexUniforms: [
                WPECanonicalTraceRecorder.PuppetUniformInput(
                    name: "localSizeAndMode",
                    type: "vec4",
                    value: meshUniforms.localSizeAndMode
                ),
                WPECanonicalTraceRecorder.PuppetUniformInput(
                    name: "meshCenterAndPadding",
                    type: "vec4",
                    value: meshUniforms.meshCenterAndPadding
                )
            ],
            bonePalette: paletteState.bonePalette,
            skinningEnabled: paletteState.skinningEnabled != 0,
            localSize: SIMD2<Float>(meshUniforms.localSizeAndMode.x, meshUniforms.localSizeAndMode.y),
            meshCenter: SIMD2<Float>(meshUniforms.meshCenterAndPadding.x, meshUniforms.meshCenterAndPadding.y),
            objectCenterAndSize: nil
        )
        #endif

        try drawPuppetMeshes(meshes, encoder: encoder)
        return true
    }

    /// Deferred-warp final composite (gated per-puppet by `shouldDeferPuppetMeshWarp`): the base +
    /// effect chain ran in puppet atlas/local UV space; here the skinned mesh warps that result into the
    /// scene, replacing the rectangular `copy`-to-`.scene` pass. Placement is copied 1:1 from
    /// `objectQuadUniforms` so a bind-pose, no-effect puppet stays byte-identical to the current path.
    func encodePuppetSceneCompositePassIfNeeded(
        pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        puppetModel: WPEPuppetModel?,
        skinningState: PuppetSkinningState?,
        destination: (id: WPEMetalTargetID, texture: MTLTexture),
        textures: [String: MTLTexture],
        frameState: WPEMetalFrameState,
        encoder: MTLRenderCommandEncoder,
        depthPixelFormat: MTLPixelFormat
    ) throws -> Bool {
        guard isDeferredWarpTarget(pass.pass.target, layer: layer),
              let model = puppetModel,
              // Mirrors the material-pass deferral decision (clip puppets already warped+clipped at
              // material time → false here → plain rectangular copy; no-effect puppets → false → the
              // material pass already warped directly). Only deferred puppets warp at the scene composite.
              shouldDeferPuppetMeshWarp(for: layer, model: model) else {
            return false
        }
        let meshes = model.meshes.filter { !$0.vertices.isEmpty && !$0.indices.isEmpty }
        guard !meshes.isEmpty else { return false }
        guard WPEMetalShaderInputs.normalizedBuiltinShaderName(pass.pass.shader) == BuiltinShaderName.copy else {
            return false
        }

        let sourceReference = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
        let sourceTexture = try WPEMetalShaderInputs.resolve(
            reference: sourceReference,
            textures: textures,
            frameState: frameState,
            currentTargetID: destination.id
        )
        let quadUniforms = objectQuadUniforms(
            for: layer,
            sceneSize: objectQuadSceneSize(for: pass, layer: layer, destination: destination, frameState: frameState),
            cameraParallax: frameState.cameraParallax,
            sourceTexture: sourceTexture,
            cameraUniforms: objectQuadCameraUniforms(for: pass, layer: layer, frameState: frameState)
        )
        let localSize = puppetCompositeLocalSize(for: layer, sourceTexture: sourceTexture)
        let paletteState = puppetBonePalette(for: skinningState)

        // Placement copied from the current final object-quad path:
        //   centerAndSize        -> objectCenterAndSize
        //   sceneSizeAndRotation -> sceneSizeAndRotation
        //   uvSignAndPadding.xy  -> meshCenterAndScaleSign.zw
        // The vertex uses objectCenterAndSize.zw / localSize to produce the same screen-space scale
        // `wpe_object_quad_vertex` applied to the layer FBO.
        var compositeUniforms = WPEPuppetSceneCompositeUniforms(
            localSizeAndMode: SIMD4<Float>(
                localSize.x,
                localSize.y,
                Float(paletteState.bonePalette.count),
                paletteState.skinningEnabled
            ),
            meshCenterAndScaleSign: SIMD4<Float>(
                Float(layer.geometry.puppetMeshCenter.x),
                Float(layer.geometry.puppetMeshCenter.y),
                quadUniforms.uvSignAndPadding.x,
                quadUniforms.uvSignAndPadding.y
            ),
            objectCenterAndSize: quadUniforms.centerAndSize,
            sceneSizeAndRotation: quadUniforms.sceneSizeAndRotation
        )

        encoder.setRenderPipelineState(try renderPipeline(
            vertexName: "wpe_puppet_scene_composite_vertex",
            fragmentName: "wpe_copy_fragment",
            blendMode: pass.pass.blending,
            colorPixelFormat: destination.texture.pixelFormat,
            depthPixelFormat: depthPixelFormat
        ))
        encoder.setFragmentTexture(sourceTexture, index: 0)
        // Premultiplied alpha (commit 968cf50) stays intact: the source layer/effect FBO is already
        // premultiplied, `wpe_copy_fragment` returns it unchanged, and `pass.pass.blending` is the
        // graph's existing `premultiplied*` final scene blend. The copy fragment takes no fragment
        // uniform buffer.
        try bindPuppetBonePalette(paletteState.bonePalette, encoder: encoder)
        encoder.setVertexBytes(
            &compositeUniforms,
            length: MemoryLayout<WPEPuppetSceneCompositeUniforms>.stride,
            index: 1
        )
        #if !LITE_BUILD && DEBUG
        WPECanonicalTraceRecorder.shared.recordPuppetPass(
            pass: pass,
            stage: "scene-composite-mesh",
            layer: layer,
            modelPath: layer.puppetPath,
            meshes: meshes,
            destination: destination,
            textureBindings: [
                WPECanonicalTraceRecorder.TextureBindingInput(
                    slot: 0,
                    name: "g_Texture0",
                    reference: sourceReference,
                    texture: sourceTexture,
                    fallbackToPrimary: false
                )
            ],
            vertexShaderName: "wpe_puppet_scene_composite_vertex",
            fragmentShaderName: "wpe_copy_fragment",
            // wpe_copy_fragment is a 1:1 copy with no fragment uniform buffer.
            fragmentUniforms: [],
            vertexUniforms: [
                WPECanonicalTraceRecorder.PuppetUniformInput(
                    name: "localSizeAndMode",
                    type: "vec4",
                    value: compositeUniforms.localSizeAndMode
                ),
                WPECanonicalTraceRecorder.PuppetUniformInput(
                    name: "meshCenterAndScaleSign",
                    type: "vec4",
                    value: compositeUniforms.meshCenterAndScaleSign
                ),
                WPECanonicalTraceRecorder.PuppetUniformInput(
                    name: "objectCenterAndSize",
                    type: "vec4",
                    value: compositeUniforms.objectCenterAndSize
                ),
                WPECanonicalTraceRecorder.PuppetUniformInput(
                    name: "sceneSizeAndRotation",
                    type: "vec4",
                    value: compositeUniforms.sceneSizeAndRotation
                )
            ],
            bonePalette: paletteState.bonePalette,
            skinningEnabled: paletteState.skinningEnabled != 0,
            localSize: localSize,
            meshCenter: SIMD2<Float>(
                compositeUniforms.meshCenterAndScaleSign.x,
                compositeUniforms.meshCenterAndScaleSign.y
            ),
            objectCenterAndSize: compositeUniforms.objectCenterAndSize
        )
        #endif
        try drawPuppetMeshes(meshes, encoder: encoder)
        return true
    }

    private func puppetBonePalette(
        for skinningState: PuppetSkinningState?
    ) -> (bonePalette: [simd_float4x4], skinningEnabled: Float) {
        // When the skinning gate rejects (partial hierarchy, out-of-range indices, unbounded palette,
        // unfollowable attached child) the identity palette reproduces the assembled MDLV rest mesh
        // (no-regression guard). Skinning is always on; validation remains the safety net.
        let resolvedPalette = skinningState?.enabled == true ? (skinningState?.palette ?? []) : []
        let bonePalette = resolvedPalette.isEmpty
            ? WPEPuppetAnimationEvaluator.identityPalette(count: 1)
            : resolvedPalette
        let skinningEnabled: Float = resolvedPalette.isEmpty ? 0 : 1
        return (bonePalette, skinningEnabled)
    }

    private func puppetCompositeLocalSize(
        for layer: WPERenderLayer,
        sourceTexture: MTLTexture
    ) -> SIMD2<Float> {
        // Match `objectQuadUniforms`: use authored/resolved geometry size for placement, falling back
        // to the source-texture dimensions only when size is absent.
        let width = Float(layer.geometry.size?.width ?? CGFloat(sourceTexture.width))
        let height = Float(layer.geometry.size?.height ?? CGFloat(sourceTexture.height))
        return SIMD2<Float>(max(width, 1), max(height, 1))
    }

    private static func rendersAsSceneModel(_ layer: WPERenderLayer) -> Bool {
        guard layer.puppetPath != nil else { return false }
        return (layer.imagePath as NSString).pathExtension.lowercased() == "mdl"
    }

    private func sceneModelMeshUniforms(
        for layer: WPERenderLayer,
        frameState: WPEMetalFrameState,
        paletteState: (bonePalette: [simd_float4x4], skinningEnabled: Float)
    ) -> WPESceneModelMeshUniforms {
        let geometry = layer.geometry
        let modelMatrix = Self.modelMatrix(
            translation: SIMD3<Float>(
                Float(geometry.origin.x),
                Float(geometry.origin.y),
                Float(geometry.origin.z)
            ),
            euler: SIMD3<Float>(
                Float(geometry.angles.x),
                Float(geometry.angles.y),
                Float(geometry.angles.z)
            ),
            scale: SIMD3<Float>(
                Float(geometry.scale.x),
                Float(geometry.scale.y),
                Float(geometry.scale.z)
            )
        )
        let viewProjection = Self.matrix(fromColumnMajorDoubles: frameState.cameraUniforms.viewProjectionMatrix)
        return WPESceneModelMeshUniforms(
            modelViewProjectionMatrix: viewProjection * modelMatrix,
            modeAndPadding: SIMD4<Float>(
                Float(paletteState.bonePalette.count),
                paletteState.skinningEnabled,
                0,
                0
            )
        )
    }

    private static func matrix(fromColumnMajorDoubles values: [Double]) -> simd_float4x4 {
        guard values.count >= 16 else { return matrix_identity_float4x4 }
        return simd_float4x4(
            SIMD4<Float>(Float(values[0]), Float(values[1]), Float(values[2]), Float(values[3])),
            SIMD4<Float>(Float(values[4]), Float(values[5]), Float(values[6]), Float(values[7])),
            SIMD4<Float>(Float(values[8]), Float(values[9]), Float(values[10]), Float(values[11])),
            SIMD4<Float>(Float(values[12]), Float(values[13]), Float(values[14]), Float(values[15]))
        )
    }

    private static func modelMatrix(
        translation: SIMD3<Float>,
        euler: SIMD3<Float>,
        scale: SIMD3<Float>
    ) -> simd_float4x4 {
        translationMatrix(translation) * rotationZ(euler.z) * rotationY(euler.y) * rotationX(euler.x) * scaleMatrix(scale)
    }

    private static func translationMatrix(_ translation: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(translation.x, translation.y, translation.z, 1)
        )
    }

    private static func scaleMatrix(_ scale: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(
            SIMD4<Float>(scale.x, 0, 0, 0),
            SIMD4<Float>(0, scale.y, 0, 0),
            SIMD4<Float>(0, 0, scale.z, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
    }

    private static func rotationX(_ angle: Float) -> simd_float4x4 {
        let c = cos(angle)
        let s = sin(angle)
        return simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, c, s, 0),
            SIMD4<Float>(0, -s, c, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
    }

    private static func rotationY(_ angle: Float) -> simd_float4x4 {
        let c = cos(angle)
        let s = sin(angle)
        return simd_float4x4(
            SIMD4<Float>(c, 0, -s, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(s, 0, c, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
    }

    private static func rotationZ(_ angle: Float) -> simd_float4x4 {
        let c = cos(angle)
        let s = sin(angle)
        return simd_float4x4(
            SIMD4<Float>(c, s, 0, 0),
            SIMD4<Float>(-s, c, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
    }

    /// Called once per frame right before commit (completion handlers must be added pre-commit).
    func recyclePaletteBuffersOnCompletion(of commandBuffer: MTLCommandBuffer) {
        guard !bonePaletteBuffersInFlight.isEmpty else { return }
        let batch = PaletteBufferRecycleBatch(buffers: bonePaletteBuffersInFlight)
        bonePaletteBuffersInFlight.removeAll()
        let pool = bonePaletteBufferPool
        commandBuffer.addCompletedHandler { _ in
            pool.recycle(batch.buffers)
        }
    }

    private func bindPuppetBonePalette(
        _ bonePalette: [simd_float4x4],
        encoder: MTLRenderCommandEncoder
    ) throws {
        let byteCount = bonePalette.count * MemoryLayout<simd_float4x4>.stride
        guard let buffer = bonePaletteBufferPool.acquire(byteCount: byteCount, device: device) else {
            throw WPEMetalTextureLoaderError.textureAllocationFailed
        }
        bonePalette.withUnsafeBytes { rawBuffer in
            buffer.contents().copyMemory(from: rawBuffer.baseAddress!, byteCount: rawBuffer.count)
        }
        bonePaletteBuffersInFlight.append(buffer)
        encoder.setVertexBuffer(buffer, offset: 0, index: 2)
    }

    // MARK: - Puppet clip-composite (WPE genericimage4 CLIPPINGTARGET)

    /// Selects which puppet mesh parts a draw should emit.
    private enum PuppetPartSelection {
        case all
        case only(Set<UInt32>)

        var isAll: Bool {
            if case .all = self { return true }
            return false
        }

        func contains(_ part: WPEPuppetMeshPart) -> Bool {
            switch self {
            case .all: return true
            case .only(let ids): return ids.contains(part.id)
            }
        }
    }

    /// `alphaMaskUV.w` modes consumed by `wpe_genericimage4_puppet_clip_fragment`. Only `none`/`target`
    /// are emitted today (the shader also defines compose/both for future use).
    private enum PuppetClipFragmentMode {
        static let none: Float = 0
        static let target: Float = 1
    }

    /// One resolved clip relationship: `target` (e.g. a pupil that does not squish) is clipped to the
    /// silhouette of `source` (e.g. the eye-white that squishes shut), per WPE's first→second-part
    /// convention validated by squish geometry.
    struct PuppetClipPair: Equatable {
        let source: UInt32
        let target: UInt32
    }

    private struct PuppetClipCompositePlan {
        /// Distinct clip-mask source part IDs, in mesh draw order. Each renders to its own clip RT.
        let sourcePartIDs: [UInt32]
        /// Maps a clip-target part ID to the source part whose silhouette clips it.
        let sourceForTarget: [UInt32: UInt32]
        let clipMaskReference: WPETextureReference
        let clipTargetName: String
    }

    /// True only when slot 8 is the EXACT builder-injected clip RT for this object — the same predicate
    /// `puppetUsesClipComposite` uses for defer routing, so the clip encoder and the deferred-warp
    /// decision can never disagree (an authored slot-8 FBO with another name is not a clip pass).
    private func hasPuppetClipCompositeBinding(_ pass: WPEPreparedRenderPass, layer: WPERenderLayer) -> Bool {
        guard Self.puppetClipCompositeEnabled else { return false }
        let slot8 = pass.textureBindings[8] ?? pass.pass.textures[8]
        return slot8 == .fbo(WPERenderTargetNames.PuppetClip.make(objectID: layer.objectID))
    }

    /// Resolves the WPE clip-composite routing for a genericimage4 puppet the builder flagged with a clip
    /// mask (slot 1) + intermediate clip RT (slot 8). Part roles are inferred from geometry: any part
    /// that squishes closed can be a clip silhouette, and later/open parts enclosed by it are clipped.
    /// A puppet whose geometry doesn't prove that relationship yields nil → flat draw.
    private func puppetClipCompositePlan(
        for pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        model: WPEPuppetModel,
        renderableMeshes: [WPEPuppetMesh]
    ) -> PuppetClipCompositePlan? {
        guard Self.puppetClipCompositeEnabled,
              hasPuppetClipCompositeBinding(pass, layer: layer),
              WPEMetalShaderInputs.normalizedBuiltinShaderName(pass.pass.shader) == BuiltinShaderName.genericImage4,
              let clipMaskReference = pass.textureBindings[1] ?? pass.pass.textures[1],
              let clipTargetReference = pass.textureBindings[8] ?? pass.pass.textures[8],
              case .fbo(let clipTargetName) = clipTargetReference,
              renderableMeshes.count == 1,
              let mesh = renderableMeshes.first,
              mesh.parts.filter({ $0.count > 0 }).count >= 2 else {
            return nil
        }
        let pairs = resolvePuppetClipPairs(for: layer, model: model, mesh: mesh)
        guard !pairs.isEmpty else { return nil }

        // Preserve mesh draw order for the source RTs; dedupe shared sources (two targets, one source).
        var sourceIDs: [UInt32] = []
        var sourceForTarget: [UInt32: UInt32] = [:]
        for part in mesh.parts where part.count > 0 {
            for pair in pairs where pair.source == part.id && !sourceIDs.contains(part.id) {
                sourceIDs.append(part.id)
            }
        }
        for pair in pairs where sourceForTarget[pair.target] == nil {
            sourceForTarget[pair.target] = pair.source
        }
        guard !sourceIDs.isEmpty, !sourceForTarget.isEmpty else { return nil }

        return PuppetClipCompositePlan(
            sourcePartIDs: sourceIDs,
            sourceForTarget: sourceForTarget,
            clipMaskReference: clipMaskReference,
            clipTargetName: clipTargetName
        )
    }

    /// Per-puppet deferred-warp decision (replaces the old global flag). The deferred warp only matters
    /// for puppets with an effect chain — running base+effects in atlas/local UV space so effect masks
    /// align with the mesh, then warping at the scene composite. A no-effect puppet renders identically
    /// either way, so it stays on the direct (material-time warp) path and is byte-identical to the
    /// pre-deferral behaviour. Clip-composite puppets warp+clip at material time and never defer. A DEBUG
    /// `WPEPuppetDeferMeshWarp` override forces the decision for non-clip puppets (A/B testing).
    private func shouldDeferPuppetMeshWarp(for layer: WPERenderLayer, model: WPEPuppetModel) -> Bool {
        if puppetUsesClipComposite(layer: layer, model: model) { return false }
        // The deferred warp can only be applied if there's a `.scene` copy pass to land it on; without
        // one, deferring the material-time warp would lose it (the puppet would render unwarped). So even
        // a forced override stays on the direct path when no scene-warp target exists.
        guard layerHasDeferredWarpTarget(layer) else { return false }
        if let forced = Self.deferPuppetMeshWarpOverride { return forced }
        return layerHasEffectChain(layer)
    }

    /// The deferred warp is applied by `encodePuppetSceneCompositePassIfNeeded`, which runs on a
    /// scene-target or composelayer-group-target `copy` pass. A layer without one cannot receive it.
    private func layerHasDeferredWarpTarget(_ layer: WPERenderLayer) -> Bool {
        layer.passes.contains { pass in
            guard isDeferredWarpTarget(pass.target, layer: layer) else { return false }
            return WPEMetalShaderInputs.normalizedBuiltinShaderName(pass.shader) == BuiltinShaderName.copy
        }
    }

    private func isDeferredWarpTarget(_ target: WPERenderTarget, layer: WPERenderLayer) -> Bool {
        if case .scene = target { return true }
        return isGroupRenderTarget(target, layer: layer)
    }

    /// True when the puppet layer runs an effect — a material-kind effect (`.effect`) OR a command-kind
    /// effect (`.command(file:)`, e.g. blur/bloom passes). The synthesized final scene copy is also a
    /// `.command` pass but is the composite itself, not an effect, so it's excluded. Only puppets with an
    /// effect chain benefit from the deferred warp (effect masks align in atlas space).
    private func layerHasEffectChain(_ layer: WPERenderLayer) -> Bool {
        Self.hasEffectChain(passPhases: layer.passes.map(\.phase))
    }

    /// Pure predicate behind `layerHasEffectChain`, extracted for unit testing.
    static func hasEffectChain(passPhases: [WPERenderPassPhase]) -> Bool {
        passPhases.contains { phase in
            switch phase {
            case .effect: return true
            case .command(let file): return file != WPERenderPassPhase.sceneCopyCommandFile
            case .material: return false
            }
        }
    }

    /// True when this puppet actually renders via the clip composite. Gated on the SAME conditions as
    /// `puppetClipCompositePlan`/`encodePuppetClipCompositePassIfNeeded` — clip flag on, a genericimage4
    /// material pass with the builder-injected clip RT (slot 8), and a geometry-confirmed first→second
    /// part pair — so the defer/clip routing can never disagree about whether the clip pass will run.
    private func puppetUsesClipComposite(layer: WPERenderLayer, model: WPEPuppetModel) -> Bool {
        guard Self.puppetClipCompositeEnabled, model.clipMaskName != nil else { return false }
        // Match the EXACT builder-injected clip RT (`WPERenderGraphBuilder` skips injection when slot 8
        // is already authored), not just any non-nil slot 8 — otherwise a pre-existing authored slot 8
        // would falsely suppress the deferred warp for a clip pass that won't actually run.
        let injectedClipRT = WPETextureReference.fbo(WPERenderTargetNames.PuppetClip.make(objectID: layer.objectID))
        let hasInjectedClipPass = layer.passes.contains { pass in
            guard case .material = pass.phase,
                  WPEMetalShaderInputs.normalizedBuiltinShaderName(pass.shader) == BuiltinShaderName.genericImage4 else {
                return false
            }
            return pass.textures[8] == injectedClipRT
        }
        guard hasInjectedClipPass else { return false }
        let meshes = model.meshes.filter { !$0.vertices.isEmpty && !$0.indices.isEmpty }
        guard meshes.count == 1, let mesh = meshes.first else { return false }
        return !resolvePuppetClipPairs(for: layer, model: model, mesh: mesh).isEmpty
    }

    /// Cached clip-role detection. Keyed by `objectID` (not puppet path): detection depends on this
    /// object's animation layers, so two objects reusing the same puppet asset with different anims must
    /// not share a cache entry.
    private func resolvePuppetClipPairs(
        for layer: WPERenderLayer,
        model: WPEPuppetModel,
        mesh: WPEPuppetMesh
    ) -> [PuppetClipPair] {
        let cacheKey = layer.objectID
        if let cached = puppetClipPairsCache[cacheKey] {
            return cached
        }
        let animationLayers = puppetAnimationLayers(for: layer, model: model)
        let pairs = Self.detectClipPairs(mesh: mesh, animationLayers: animationLayers, bones: model.bones)
        puppetClipPairsCache[cacheKey] = pairs
        return pairs
    }

    /// Geometry signature of one mesh part under a given skinning palette: its 2D bounding box.
    private struct PuppetClipPartBox {
        let id: UInt32
        var minX: Float
        var maxX: Float
        var minY: Float
        var maxY: Float
        var width: Float { maxX - minX }
        var height: Float { maxY - minY }
        var centerX: Float { (minX + maxX) * 0.5 }
        var centerY: Float { (minY + maxY) * 0.5 }
    }

    /// Skins a single vertex with the palette exactly as `wpe_skin_puppet_position` does, so detection
    /// matches the rendered geometry. An empty palette returns the bind position.
    private static func skinPuppetVertex(_ vertex: WPEPuppetVertex, palette: [simd_float4x4]) -> SIMD3<Float> {
        let source = SIMD4<Float>(vertex.position.x, vertex.position.y, vertex.position.z, 1)
        guard !palette.isEmpty else { return vertex.position }
        let weights = SIMD4<Float>(
            max(vertex.skinBlendWeights.x, 0), max(vertex.skinBlendWeights.y, 0),
            max(vertex.skinBlendWeights.z, 0), max(vertex.skinBlendWeights.w, 0)
        )
        let weightSum = weights.x + weights.y + weights.z + weights.w
        guard weightSum > 1e-5 else { return vertex.position }
        let indices = [vertex.skinBlendIndices.x, vertex.skinBlendIndices.y,
                       vertex.skinBlendIndices.z, vertex.skinBlendIndices.w]
        let weightLanes = [weights.x, weights.y, weights.z, weights.w]
        var skinned = SIMD4<Float>(0, 0, 0, 0)
        for lane in 0..<4 where weightLanes[lane] > 0 {
            let bone = Int(indices[lane])
            let contribution = (bone >= 0 && bone < palette.count) ? palette[bone] * source : source
            skinned += weightLanes[lane] * contribution
        }
        skinned /= weightSum
        return SIMD3<Float>(skinned.x, skinned.y, skinned.z)
    }

    /// 2D bounding boxes for every non-empty part under `palette` (empty palette → bind pose).
    private static func clipPartBoxes(mesh: WPEPuppetMesh, palette: [simd_float4x4]) -> [PuppetClipPartBox] {
        var boxes: [PuppetClipPartBox] = []
        for part in mesh.parts where part.count > 0 {
            let start = max(part.start, 0)
            let end = min(part.start + part.count, mesh.indices.count)
            guard end > start else { continue }
            var minX = Float.greatestFiniteMagnitude, maxX = -Float.greatestFiniteMagnitude
            var minY = Float.greatestFiniteMagnitude, maxY = -Float.greatestFiniteMagnitude
            var seen = false
            var visited = Set<UInt16>()
            for i in start..<end {
                let vertexIndex = mesh.indices[i]
                guard visited.insert(vertexIndex).inserted, Int(vertexIndex) < mesh.vertices.count else { continue }
                let p = skinPuppetVertex(mesh.vertices[Int(vertexIndex)], palette: palette)
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
                seen = true
            }
            guard seen else { continue }
            boxes.append(PuppetClipPartBox(id: part.id, minX: minX, maxX: maxX, minY: minY, maxY: maxY))
        }
        return boxes
    }

    /// Resolves clip source→target pairs for a clip-mask puppet. The MDLV clip section and material carry
    /// only the mask name, no per-part roles, so animated geometry decides roles: a source squishes shut;
    /// a target stays open and is enclosed by that source in the bind pose. Returns [] when no relationship
    /// is proven, so unfamiliar rigs degrade to a flat draw instead of being mis-clipped.
    private static func detectClipPairs(
        mesh: WPEPuppetMesh,
        animationLayers: [WPEPuppetAnimationLayer],
        bones: [WPEPuppetBone]
    ) -> [PuppetClipPair] {
        let bindBoxes = clipPartBoxes(mesh: mesh, palette: [])
        guard bindBoxes.count >= 2 else { return [] }
        var bindByID: [UInt32: PuppetClipPartBox] = [:]
        var minWidthByID: [UInt32: Float] = [:]
        var minHeightByID: [UInt32: Float] = [:]
        for box in bindBoxes where box.height > 1e-4 && box.width > 1e-4 {
            bindByID[box.id] = box
            minWidthByID[box.id] = box.width
            minHeightByID[box.id] = box.height
        }
        guard bindByID.count >= 2 else { return [] }

        guard let base = animationLayers.first(where: { !$0.additive }) ?? animationLayers.first else { return [] }
        let frameCount = max(base.animation.frameCount, 1)
        let fps = base.animation.fps > 0 ? Double(base.animation.fps) : 30
        // Sample evenly-spaced integer FRAME indices in [0, frameCount-1]. Sampling by time up to the
        // full `duration` would land the last sample on `frameCount/fps`, which a loop animation wraps
        // back to frame 0 — hiding a most-closed eye pose that only occurs on the final frame.
        let sampleCount = min(max(frameCount, 8), 48)
        for sample in 0..<sampleCount {
            let frame = frameCount <= 1 || sampleCount <= 1
                ? 0
                : Int((Double(sample) * Double(frameCount - 1) / Double(sampleCount - 1)).rounded())
            let palette = WPEPuppetAnimationEvaluator.palette(
                layers: animationLayers, bones: bones, at: Double(frame) / fps)
            guard !palette.isEmpty else { continue }
            for box in clipPartBoxes(mesh: mesh, palette: palette) {
                if let w = minWidthByID[box.id] { minWidthByID[box.id] = min(w, box.width) }
                if let h = minHeightByID[box.id] { minHeightByID[box.id] = min(h, box.height) }
            }
        }

        // Min-axis squish ratio over the clip: a part "squishes" when it collapses on EITHER axis
        // (anime eyes usually close vertically, but the test stays axis-agnostic).
        func ratio(_ id: UInt32) -> Float {
            guard let bind = bindByID[id], bind.width > 1e-4, bind.height > 1e-4 else { return 1 }
            let widthRatio = (minWidthByID[id] ?? bind.width) / bind.width
            let heightRatio = (minHeightByID[id] ?? bind.height) / bind.height
            return min(widthRatio, heightRatio)
        }
        let ratioSummary = bindByID.keys.sorted()
            .map { "id\($0)=\(String(format: "%.2f", ratio($0)))" }
            .joined(separator: " ")

        let ordered = mesh.parts.filter { $0.count > 0 }
        guard ordered.count >= 2 else {
            clipDiagnosticLog("[WPE clip] detect: NO PAIR (fewer than 2 parts) minAxisRatios[\(ratioSummary)]")
            return []
        }

        func contains(_ target: PuppetClipPartBox, in source: PuppetClipPartBox) -> Bool {
            let tolerance = max(max(source.width, source.height) * 0.02, 1)
            return target.minX >= source.minX - tolerance
                && target.maxX <= source.maxX + tolerance
                && target.minY >= source.minY - tolerance
                && target.maxY <= source.maxY + tolerance
        }

        func area(_ box: PuppetClipPartBox) -> Float {
            max(box.width, 0) * max(box.height, 0)
        }

        func centerDistanceSquared(_ lhs: PuppetClipPartBox, _ rhs: PuppetClipPartBox) -> Float {
            let dx = lhs.centerX - rhs.centerX
            let dy = lhs.centerY - rhs.centerY
            return dx * dx + dy * dy
        }

        let sourceIDs = ordered.map(\.id).filter { id in
            bindByID[id] != nil && ratio(id) < 0.85
        }
        let targetIDs = Set(ordered.map(\.id).filter { id in
            bindByID[id] != nil && ratio(id) > 0.8
        })

        var pairs: [PuppetClipPair] = []
        for part in ordered where targetIDs.contains(part.id) {
            guard let target = bindByID[part.id] else { continue }
            let targetRatio = ratio(part.id)
            let candidates: [(id: UInt32, box: PuppetClipPartBox)] = sourceIDs.compactMap { sourceID in
                guard sourceID != part.id,
                      let source = bindByID[sourceID],
                      targetRatio > ratio(sourceID) + 0.1,
                      contains(target, in: source) else {
                    return nil
                }
                return (sourceID, source)
            }
            guard let source = candidates.min(by: { lhs, rhs in
                let lhsArea = area(lhs.box)
                let rhsArea = area(rhs.box)
                if lhsArea != rhsArea { return lhsArea < rhsArea }
                return centerDistanceSquared(lhs.box, target) < centerDistanceSquared(rhs.box, target)
            }) else {
                continue
            }
            pairs.append(PuppetClipPair(source: source.id, target: part.id))
        }

        guard !pairs.isEmpty else {
            clipDiagnosticLog(
                "[WPE clip] detect: NO PAIR (no closing source encloses an open target) "
                    + "minAxisRatios[\(ratioSummary)] — if all ~1.0 the mesh isn't deforming (skinning off?)"
            )
            return []
        }
        let pairSummary = pairs.map { "\($0.source)→\($0.target)" }.joined(separator: ",")
        clipDiagnosticLog(
            "[WPE clip] detect: pairs=[\(pairSummary)] minAxisRatios[\(ratioSummary)]"
        )
        return pairs
    }

    /// DEBUG-only `[WPE clip]` diagnostic sink (once-per-puppet/per-build messages); compiled out of
    /// Release so the clip path adds no log noise to shipped builds.
    private static func clipDiagnosticLog(_ message: @autoclosure () -> String) {
        #if DEBUG
        // Gated behind the scene-debug switch (off by default) so genericimage4
        // puppet scenes don't print clip-detection lines on every load.
        guard UserDefaults.standard.bool(forKey: "WPESceneDebugArtifactsEnabled") else { return }
        Logger.info(message(), category: .wpeRender)
        #endif
    }

    #if DEBUG
    /// Test seam for the geometry-driven clip-role detection. Returns (source, target) part-ID pairs
    /// without surfacing the private `PuppetClipPair` type.
    static func _testDetectClipPairs(
        mesh: WPEPuppetMesh,
        animationLayers: [WPEPuppetAnimationLayer],
        bones: [WPEPuppetBone]
    ) -> [(source: UInt32, target: UInt32)] {
        detectClipPairs(mesh: mesh, animationLayers: animationLayers, bones: bones)
            .map { (source: $0.source, target: $0.target) }
    }
    #endif

    /// Encodes the clip composite in place of the flat puppet draw: render each clip-source silhouette to
    /// its own clip-mask RT, then draw all parts in mesh order to the main target (clip targets multiply
    /// alpha by their source silhouette, the rest draw plain). Returns false when the pass is not a
    /// clip-composite puppet so the caller falls through to the legacy path.
    func encodePuppetClipCompositePassIfNeeded(
        pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        puppetModel: WPEPuppetModel?,
        skinningState: PuppetSkinningState?,
        destination: (id: WPEMetalTargetID, texture: MTLTexture),
        shouldLoadDestination: Bool,
        textures: [String: MTLTexture],
        commandBuffer: MTLCommandBuffer,
        frameState: inout WPEMetalFrameState
    ) throws -> Bool {
        // The clip composite draws the warped mesh per-part at material time, so it runs even when
        // WPEPuppetDeferMeshWarp is globally on: a clip puppet bypasses the deferral locally (the
        // deferred scene-composite re-warp is suppressed for it in encodePuppetSceneCompositePassIfNeeded),
        // so deferred warp can stay on for non-clip puppets (e.g. 3461168300's head effect) without
        // breaking clip eyes (e.g. 3719111841).
        guard case .material = pass.pass.phase,
              case .layerComposite = pass.pass.target,
              let model = puppetModel else {
            return false
        }
        let meshes = model.meshes.filter { !$0.vertices.isEmpty && !$0.indices.isEmpty }
        guard let plan = puppetClipCompositePlan(for: pass, layer: layer, model: model, renderableMeshes: meshes) else {
            return false
        }

        let primaryRef = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
        let primary = try WPEMetalShaderInputs.resolve(
            reference: primaryRef,
            textures: textures,
            frameState: frameState,
            currentTargetID: destination.id
        )
        let clipMask = try WPEMetalShaderInputs.resolve(
            reference: plan.clipMaskReference,
            textures: textures,
            frameState: frameState,
            currentTargetID: destination.id
        )

        let paletteState = puppetBonePalette(for: skinningState)
        if loggedClipActivation.insert(layer.objectID).inserted {
            Self.clipDiagnosticLog(
                "[WPE clip] ACTIVE \(layer.puppetPath ?? layer.objectID): "
                    + "skinning=\(paletteState.skinningEnabled > 0.5 ? "ON" : "OFF") "
                    + "sources=\(plan.sourcePartIDs) targets=\(Array(plan.sourceForTarget.keys).sorted()) "
                    + "— if skinning=OFF the eye renders static (no squish), so nothing is clipped"
            )
        }
        // localSizeAndMode is taken from the MAIN destination for ALL draws so the clip mask
        // (rendered to a different-resolution RT) maps to the same NDC and the screen-space UV aligns.
        var meshUniforms = WPEPuppetMeshUniforms(
            localSizeAndMode: SIMD4<Float>(
                Float(max(destination.texture.width, 1)),
                Float(max(destination.texture.height, 1)),
                Float(paletteState.bonePalette.count),
                paletteState.skinningEnabled
            ),
            meshCenterAndPadding: SIMD4<Float>(
                Float(layer.geometry.puppetMeshCenter.x),
                Float(layer.geometry.puppetMeshCenter.y),
                0,
                0
            )
        )

        let transparentClear = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        // 1) Render each clip-source silhouette to its own intermediate clip-mask RT
        //    (clippingmaskimage4). The first source reuses the builder-registered RT (scale 2); any
        //    additional sources (e.g. a second eye) get derived RT names from the same base.
        var clipRTBySource: [UInt32: (id: WPEMetalTargetID, texture: MTLTexture)] = [:]
        for (index, sourceID) in plan.sourcePartIDs.enumerated() {
            let rtName = WPERenderTargetNames.PuppetClip.makeSource(base: plan.clipTargetName, index: index)
            let clipRT = try targetTexture(for: .fbo(name: rtName), layer: layer, frameState: &frameState)
            try encodePuppetClipCompositeDraw(
                pass: pass, layer: layer, meshes: meshes,
                partSelection: .only([sourceID]),
                destination: clipRT, loadAction: .clear, clearColor: transparentClear,
                primary: primary, mask: clipMask, clipTexture: nil,
                vertexName: "wpe_puppet_mesh_clip_vertex", fragmentName: "wpe_puppet_clippingmaskimage4_fragment",
                blendMode: "disabled", hasMask: true, clipMode: PuppetClipFragmentMode.none,
                meshUniforms: &meshUniforms, paletteState: paletteState, commandBuffer: commandBuffer
            )
            frameState.registerWrite(texture: clipRT.texture, targetID: clipRT.id)
            clipRTBySource[sourceID] = clipRT
        }

        // 2) Draw all parts to the main target in mesh draw order. A clip-target part multiplies its
        //    alpha by its source silhouette (screen-space CLIPPINGTARGET); every other part draws plain.
        //    Consecutive plain parts batch into one draw, preserving translucent ordering.
        var didClearMain = false
        func mainLoadAction() -> MTLLoadAction {
            defer { didClearMain = true }
            return (didClearMain || shouldLoadDestination) ? .load : .clear
        }
        var plainRun: [UInt32] = []
        func flushPlainRun() throws {
            guard !plainRun.isEmpty else { return }
            let selection = plainRun
            plainRun.removeAll(keepingCapacity: true)
            try encodePuppetClipCompositeDraw(
                pass: pass, layer: layer, meshes: meshes,
                partSelection: .only(Set(selection)),
                destination: destination, loadAction: mainLoadAction(),
                clearColor: clearColor(for: destination.id),
                primary: primary, mask: primary, clipTexture: nil,
                vertexName: "wpe_puppet_mesh_vertex", fragmentName: "wpe_genericimage4_fragment",
                blendMode: pass.pass.blending, hasMask: false, clipMode: PuppetClipFragmentMode.none,
                meshUniforms: &meshUniforms, paletteState: paletteState, commandBuffer: commandBuffer
            )
        }

        for part in meshes.first?.parts ?? [] where part.count > 0 {
            guard let sourceID = plan.sourceForTarget[part.id],
                  let clipRT = clipRTBySource[sourceID] else {
                plainRun.append(part.id)
                continue
            }
            try flushPlainRun()
            try encodePuppetClipCompositeDraw(
                pass: pass, layer: layer, meshes: meshes,
                partSelection: .only([part.id]),
                destination: destination, loadAction: mainLoadAction(),
                clearColor: clearColor(for: destination.id),
                primary: primary, mask: primary, clipTexture: clipRT.texture,
                vertexName: "wpe_puppet_mesh_clip_vertex", fragmentName: "wpe_genericimage4_puppet_clip_fragment",
                blendMode: pass.pass.blending, hasMask: false, clipMode: PuppetClipFragmentMode.target,
                meshUniforms: &meshUniforms, paletteState: paletteState, commandBuffer: commandBuffer
            )
        }
        try flushPlainRun()
        return true
    }

    private func encodePuppetClipCompositeDraw(
        pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        meshes: [WPEPuppetMesh],
        partSelection: PuppetPartSelection,
        destination: (id: WPEMetalTargetID, texture: MTLTexture),
        loadAction: MTLLoadAction,
        clearColor: MTLClearColor,
        primary: MTLTexture,
        mask: MTLTexture,
        clipTexture: MTLTexture?,
        vertexName: String,
        fragmentName: String,
        blendMode: String,
        hasMask: Bool,
        clipMode: Float,
        meshUniforms: inout WPEPuppetMeshUniforms,
        paletteState: (bonePalette: [simd_float4x4], skinningEnabled: Float),
        commandBuffer: MTLCommandBuffer
    ) throws {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = destination.texture
        descriptor.colorAttachments[0].loadAction = loadAction
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = clearColor

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }
        defer { encoder.endEncoding() }

        encoder.setFrontFacing(.counterClockwise)
        encoder.setCullMode(WPEMetalPipelineCache.cullMode(for: pass.pass.cullMode))
        encoder.setDepthStencilState(depthCache.stencilState(depthTest: "disabled", depthWrite: "disabled"))
        encoder.setRenderPipelineState(try renderPipeline(
            vertexName: vertexName,
            fragmentName: fragmentName,
            blendMode: blendMode,
            colorPixelFormat: destination.texture.pixelFormat,
            depthPixelFormat: .invalid
        ))
        encoder.setFragmentTexture(primary, index: 0)
        encoder.setFragmentTexture(mask, index: 1)
        if let clipTexture {
            encoder.setFragmentTexture(clipTexture, index: 8)
        }

        var uniforms = genericImageUniforms(
            for: pass,
            layer: layer,
            hasMask: hasMask,
            sourceTexture: primary,
            maskTexture: mask
        )
        uniforms.alphaMaskUV.w = clipMode
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPEGenericImageUniforms>.stride, index: 0)
        try bindPuppetBonePalette(paletteState.bonePalette, encoder: encoder)
        encoder.setVertexBytes(&meshUniforms, length: MemoryLayout<WPEPuppetMeshUniforms>.stride, index: 1)
        try drawPuppetMeshes(meshes, encoder: encoder, partSelection: partSelection)
    }

    private func drawPuppetMeshes(
        _ meshes: [WPEPuppetMesh],
        encoder: MTLRenderCommandEncoder,
        partSelection: PuppetPartSelection = .all
    ) throws {
        for mesh in meshes {
            let buffers = try puppetMeshBuffers(for: mesh)
            encoder.setVertexBuffer(buffers.vertex, offset: 0, index: 0)

            let indices = mesh.indices
            let indexBuffer = buffers.index

            if mesh.parts.isEmpty {
                guard partSelection.isAll else { continue }
                encoder.drawIndexedPrimitives(
                    type: .triangle,
                    indexCount: indices.count,
                    indexType: .uint16,
                    indexBuffer: indexBuffer,
                    indexBufferOffset: 0
                )
            } else {
                for part in mesh.parts where part.count > 0 && partSelection.contains(part) {
                    let start = max(part.start, 0)
                    let count = min(part.count, max(indices.count - start, 0))
                    guard count > 0 else { continue }
                    encoder.drawIndexedPrimitives(
                        type: .triangle,
                        indexCount: count,
                        indexType: .uint16,
                        indexBuffer: indexBuffer,
                        indexBufferOffset: start * MemoryLayout<UInt16>.stride
                    )
                }
            }
        }
    }

    private func puppetMeshBuffers(for mesh: WPEPuppetMesh) throws -> PuppetMeshBuffers {
        let key = PuppetMeshBufferKey(
            materialPath: mesh.materialPath,
            clipMaskName: mesh.clipMaskName,
            vertices: mesh.vertices,
            indices: mesh.indices,
            parts: mesh.parts
        )
        if let cached = puppetMeshBufferCache[key] {
            return cached
        }

        let vertices = mesh.vertices.map { vertex in
            WPEMetalPuppetVertex(
                position: SIMD4<Float>(vertex.position.x, vertex.position.y, vertex.position.z, 0),
                uv: SIMD4<Float>(vertex.uv.x, vertex.uv.y, 0, 0),
                skinBlendIndices: SIMD4<UInt32>(
                    UInt32(max(vertex.skinBlendIndices.x, 0)),
                    UInt32(max(vertex.skinBlendIndices.y, 0)),
                    UInt32(max(vertex.skinBlendIndices.z, 0)),
                    UInt32(max(vertex.skinBlendIndices.w, 0))
                ),
                skinBlendWeights: SIMD4<Float>(
                    vertex.skinBlendWeights.x,
                    vertex.skinBlendWeights.y,
                    vertex.skinBlendWeights.z,
                    vertex.skinBlendWeights.w
                )
            )
        }
        let vertexBuffer = vertices.withUnsafeBytes { rawBuffer in
            device.makeBuffer(bytes: rawBuffer.baseAddress!, length: rawBuffer.count, options: [])
        }
        let indexBuffer = mesh.indices.withUnsafeBytes { rawBuffer in
            device.makeBuffer(bytes: rawBuffer.baseAddress!, length: rawBuffer.count, options: [])
        }
        guard let vertexBuffer, let indexBuffer else {
            throw WPEMetalTextureLoaderError.textureAllocationFailed
        }
        vertexBuffer.label = "wpe.puppet.vertices"
        indexBuffer.label = "wpe.puppet.indices"
        let buffers = PuppetMeshBuffers(vertex: vertexBuffer, index: indexBuffer)
        puppetMeshBufferCache[key] = buffers
        return buffers
    }

}

private extension WPERenderLayer {
    func replacingDrawGeometry(
        _ geometry: WPERenderLayerGeometry,
        parallaxDepth: SIMD2<Double>
    ) -> WPERenderLayer {
        WPERenderLayer(
            objectID: objectID,
            objectName: objectName,
            visible: visible,
            imagePath: imagePath,
            materialPath: materialPath,
            puppetPath: puppetPath,
            parentObjectID: parentObjectID,
            attachment: attachment,
            animationLayers: animationLayers,
            geometry: geometry,
            localGeometry: localGeometry,
            compositeA: compositeA,
            compositeB: compositeB,
            localFBOs: localFBOs,
            passes: passes,
            groupRenderTarget: groupRenderTarget,
            groupLocalGeometry: groupLocalGeometry,
            groupCompositeSource: groupCompositeSource,
            parallaxDepth: parallaxDepth,
            sortIndex: sortIndex
        )
    }
}
#endif
