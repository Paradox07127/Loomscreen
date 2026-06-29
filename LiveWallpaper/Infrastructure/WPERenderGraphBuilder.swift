#if !LITE_BUILD
import CoreGraphics
import Foundation
import simd

struct WPERenderGraphBuilder: Sendable {
    private let resolver: WPEMultiRootResourceResolver

    /// Opt-in (default OFF) fix for body-split attachment placement: anchor attached children to the
    /// MDAT bind point on the bone's hierarchy-composed bind-world transform instead of the bone's
    /// skin-weighted vertex centroid. The centroid sat above the true joint, pushing 头部/胸部/脖颈
    /// children up and left relative to the body. When OFF, the legacy centroid path is unchanged.
    /// Enable: `defaults write Taijia.LiveWallpaper WPEPuppetAttachmentBindAnchor -bool YES`.
    private static var useAttachmentBindAnchor: Bool {
        let key = "WPEPuppetAttachmentBindAnchor"
        let suite = UserDefaults.appSuite
        if suite.object(forKey: key) != nil {
            return suite.bool(forKey: key)
        }
        return UserDefaults.standard.bool(forKey: key)
    }

    /// Injects the WPE genericimage4 clip-composite bindings (clip-mask asset on slot 1 +
    /// intermediate clip RT on slot 8) so the executor can occlude an eye puppet's pupil on
    /// blink close. Default OFF; when OFF the graph is byte-identical (no extra texture/FBO).
    /// Frozen read-once to match `WPEMetalRenderExecutor.puppetClipCompositeEnabled` — both
    /// consumers must agree, else a same-process toggle + reload partially applies. Restart to apply.
    private static let puppetClipCompositeEnabled: Bool = {
        let key = "WPEPuppetClipComposite"
        let suite = UserDefaults.appSuite
        if suite.object(forKey: key) != nil {
            return suite.bool(forKey: key)
        }
        return UserDefaults.standard.bool(forKey: key)
    }()

    init(
        cacheRootURL: URL,
        dependencyMounts: [WPEAssetMount] = [],
        engineAssetsRootURL: URL? = nil,
        tracer: WPEResolutionTracer? = nil
    ) {
        self.resolver = WPEMultiRootResourceResolver(
            primaryRootURL: cacheRootURL,
            dependencyMounts: dependencyMounts,
            engineAssetsRootURL: engineAssetsRootURL,
            tracer: tracer
        )
    }

    init(
        primaryProvider: any WPESceneAssetProvider,
        dependencyMounts: [WPEAssetMount] = [],
        engineAssetsRootURL: URL? = nil,
        tracer: WPEResolutionTracer? = nil
    ) {
        self.resolver = WPEMultiRootResourceResolver(
            primaryProvider: primaryProvider,
            dependencyMounts: dependencyMounts,
            engineAssetsRootURL: engineAssetsRootURL,
            tracer: tracer
        )
    }

    func build(document: WPESceneDocument) throws -> WPERenderGraph {
        let sceneSize = CGSize(
            width: CGFloat(document.general.orthogonalProjection.width),
            height: CGFloat(document.general.orthogonalProjection.height)
        )
        var objectByID: [String: WPESceneImageObject] = [:]
        var originalIndexByID: [String: Int] = [:]
        for (index, object) in document.imageObjects.enumerated() where objectByID[object.id] == nil {
            objectByID[object.id] = object
            // Use the GLOBAL scene paint index so layer tie-breaks stay consistent with where
            // particles interleave; fall back to the image-filtered index when absent.
            originalIndexByID[object.id] = document.objectPaintOrder[object.id] ?? index
        }

        // Objects whose visibility a user property can toggle at runtime are
        // kept in the graph (with a scene-target pass) even when authored
        // hidden, so the toggle applies live without a pipeline rebuild. The
        // executor skips the scene draw while `WPERenderLayer.visible` is false.
        let liveVisibilityIDs = Self.userToggleableVisibilityIDs(in: document)
            .union(Self.layerScriptControlledVisibilityIDs(in: document))
        let visibleLayerIDs = Set(document.imageObjects
            .filter { !Self.hasHiddenAncestor($0, objectByID: objectByID, liveVisibilityIDs: liveVisibilityIDs) }
            .filter {
                // Composite normally, OR keep a layer whose only reason for being hidden is a
                // live-toggleable (condition-less) ancestor: it stays in the graph (drawn hidden)
                // so toggling that ancestor back on re-shows it without a pipeline rebuild.
                Self.compositesToScene($0, liveVisibilityIDs: liveVisibilityIDs)
                    || Self.hasLiveToggleableHiddenAncestor($0, objectByID: objectByID, liveVisibilityIDs: liveVisibilityIDs)
            }
            .map(\.id))
        var layerIDsToBuild = visibleLayerIDs
        var pendingIDs = Array(visibleLayerIDs)
        var layerIDsRequiredAsComposite = Set<String>()

        while let id = pendingIDs.popLast(), let object = objectByID[id] {
            for dependencyID in Self.referencedLayerIDs(in: object) where objectByID[dependencyID] != nil {
                layerIDsRequiredAsComposite.insert(dependencyID)
                if layerIDsToBuild.insert(dependencyID).inserted {
                    pendingIDs.append(dependencyID)
                }
            }
        }

        let orderedLayerIDs = Self.topologicallyOrderedLayerIDs(
            layerIDsToBuild,
            objectByID: objectByID,
            originalIndexByID: originalIndexByID
        )

        let layers = try orderedLayerIDs
            .compactMap { objectByID[$0] }
            .map { object in
                try buildLayer(
                    object: object,
                    sceneSize: sceneSize,
                    finalUntargetedPassToScene: visibleLayerIDs.contains(object.id),
                    preserveFinalCompositeForScene: layerIDsRequiredAsComposite.contains(object.id),
                    sortIndex: document.objectPaintOrder[object.id] ?? 0
                )
            }
        let parallaxAligned = Self.propagatingParallaxDepthThroughParents(layers)
        return WPERenderGraph(layers: applyAttachmentAnchorOffsets(to: parallaxAligned))
    }

    /// Camera parallax in WPE propagates DOWN the parent transform: a child layer
    /// is placed relative to its parent, so it inherits the parent's cursor shift.
    /// Scenes therefore put the depth on a ROOT object and parent the rest of a
    /// character to it with no depth of its own — e.g. 3719111841's body (主体) is
    /// parented to the hair root (长发3, depth "0.41 -0.36"), and the head/chest/
    /// hair parts attach under the body, all at depth 0. Our executor applies
    /// parallax per layer from each layer's OWN depth, so without propagation the
    /// depth-0 body and its parts stay still while the root shifts — the character
    /// shears apart ("散架"). Pin every parented layer to its ROOT ancestor's depth
    /// so the whole tree moves as one unit. (Independent parallax is authored as a
    /// SEPARATE root with its own depth — 背景/光束 here — not as a parented child,
    /// so this never suppresses intended motion.) Parallax-off scenes are
    /// unaffected: the per-frame offset is zero regardless of depth.
    static func propagatingParallaxDepthThroughParents(
        _ layers: [WPERenderLayer]
    ) -> [WPERenderLayer] {
        guard layers.contains(where: { $0.parentObjectID != nil }) else { return layers }
        let depthByID = Dictionary(
            layers.map { ($0.objectID, $0.parallaxDepth) },
            uniquingKeysWith: { first, _ in first }
        )
        let parentByID = Dictionary(
            layers.compactMap { layer in layer.parentObjectID.map { (layer.objectID, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        // Walk up to the topmost ancestor still present in the graph; a cycle or a
        // parent that was filtered out stops the walk at the last resolvable node.
        func rootDepth(of id: String) -> SIMD2<Double> {
            var current = id
            var seen: Set<String> = []
            while seen.insert(current).inserted,
                  let parent = parentByID[current],
                  depthByID[parent] != nil {
                current = parent
            }
            return depthByID[current] ?? SIMD2<Double>(0, 0)
        }
        return layers.map { layer in
            guard layer.parentObjectID != nil else { return layer }
            let inherited = rootDepth(of: layer.objectID)
            return inherited == layer.parallaxDepth ? layer : layer.withParallaxDepth(inherited)
        }
    }

    /// Body-split rigs attach face/hair/clothing child layers to a parent puppet's named MDAT anchor
    /// (头部/胸部/脖颈). Parse-time parent composition (`SceneObjectTransform.combining`) places those
    /// children relative to the parent's ORIGIN, ignoring the anchor bone — so the children tear away
    /// from the parent mesh. This second pass adds the missing static anchor-bind offset (in scene
    /// space) to each attached child's origin. Layers without a resolvable attachment are untouched,
    /// so non-attached layers and other scenes are unaffected. The executor's animated attachment
    /// follow adds only the per-frame `currentAnchor - bindAnchor` delta on top of this static bind.
    private func applyAttachmentAnchorOffsets(to layers: [WPERenderLayer]) -> [WPERenderLayer] {
        guard layers.contains(where: { $0.attachment != nil && $0.parentObjectID != nil }) else {
            return layers
        }
        let layersByID = Dictionary(layers.map { ($0.objectID, $0) }, uniquingKeysWith: { first, _ in first })
        var modelCache: [String: WPEPuppetModel?] = [:]
        func parentModel(forPuppetPath path: String) -> WPEPuppetModel? {
            if let cached = modelCache[path] { return cached }
            let model = (try? resolver.data(relativePath: path)).flatMap { try? WPEMdlParser.parse(data: $0) }
            modelCache[path] = model
            return model
        }
        return layers.map { layer in
            guard let attachmentName = layer.attachment,
                  let parentID = layer.parentObjectID,
                  let parent = layersByID[parentID],
                  let puppetPath = parent.puppetPath,
                  let model = parentModel(forPuppetPath: puppetPath),
                  let offset = Self.staticAttachmentOffset(
                      attachmentName: attachmentName,
                      parentGeometry: parent.geometry,
                      parentModel: model
                  ) else {
                return layer
            }
            return layer.replacingGeometryOrigin(addingSceneOffset: offset)
        }
    }

    /// Scene-space offset that moves an attached child from "relative to parent origin" to "relative
    /// to the parent's anchor bone" — using the bone's skinned mesh-frame position (its skin-weighted
    /// vertex centroid), mapped to scene by the parent's mesh-center, scale, and rotation. Returns nil
    /// (no offset) when the anchor or bone cannot be resolved.
    private static func staticAttachmentOffset(
        attachmentName: String,
        parentGeometry: WPERenderLayerGeometry,
        parentModel: WPEPuppetModel
    ) -> SIMD3<Double>? {
        guard let attachment = parentModel.attachments.first(where: { $0.name == attachmentName }) else {
            return nil
        }
        // Anchor point in the parent's MDLV mesh frame (model y is UP). The data-grounded anchor is the
        // bone's hierarchy-composed bind-world transform with the MDAT bind matrix applied —
        // `translation(bindWorld[bone] · attachment.matrix)`. The legacy skin-weighted vertex centroid
        // is a mesh-region statistic that sits ABOVE the true joint for a head bone, so it shifted every
        // 头部/胸部/脖颈 child up and left relative to the body (Windows-trace residual ~−90px x / ~−210px y).
        // Gated while validating; the centroid stays as the fallback when bind data is unavailable.
        let anchorPoint: SIMD2<Double>
        if useAttachmentBindAnchor,
           let bindAnchor = bindAnchorPoint(for: attachment, bones: parentModel.bones) {
            anchorPoint = bindAnchor
        } else if let joint = skinnedJoint(of: attachment.boneIndex, in: parentModel.meshes) {
            anchorPoint = joint
        } else {
            return nil
        }
        // The puppet mesh draws model→scene with no Y flip, so map the anchor with a +Y sign; subtract
        // the parent mesh center so the offset is in the same composite frame the vertex shader uses.
        let local = SIMD2<Double>(
            abs(parentGeometry.scale.x) * (anchorPoint.x - parentGeometry.puppetMeshCenter.x),
            abs(parentGeometry.scale.y) * (anchorPoint.y - parentGeometry.puppetMeshCenter.y)
        )
        let cosine = cos(parentGeometry.angles.z)
        let sine = sin(parentGeometry.angles.z)
        guard local.x.isFinite, local.y.isFinite else { return nil }
        return SIMD3<Double>(
            cosine * local.x - sine * local.y,
            sine * local.x + cosine * local.y,
            0
        )
    }

    /// Weighted centroid of the mesh vertices skinned to `boneIndex` — a robust mesh-frame proxy for
    /// the bone's position. Returns nil when the bone influences no vertices.
    private static func skinnedJoint(of boneIndex: Int, in meshes: [WPEPuppetMesh]) -> SIMD2<Double>? {
        var sumX = 0.0
        var sumY = 0.0
        var sumW = 0.0
        for mesh in meshes {
            for vertex in mesh.vertices {
                let indices = vertex.skinBlendIndices
                let weights = vertex.skinBlendWeights
                func accumulate(_ index: Int32, _ weight: Float) {
                    guard Int(index) == boneIndex, weight > 0, weight.isFinite else { return }
                    sumX += Double(weight) * Double(vertex.position.x)
                    sumY += Double(weight) * Double(vertex.position.y)
                    sumW += Double(weight)
                }
                accumulate(indices.x, weights.x)
                accumulate(indices.y, weights.y)
                accumulate(indices.z, weights.z)
                accumulate(indices.w, weights.w)
            }
        }
        guard sumW > 0 else { return nil }
        return SIMD2<Double>(sumX / sumW, sumY / sumW)
    }

    /// The attachment's anchor point in the parent MDLV mesh frame: the translation of
    /// `bindWorld[boneIndex] · attachment.matrix`, where `bindWorld` composes the bone's parent chain.
    /// This is the WPE attachment pivot (not the skin-region centroid). Returns nil if the bone or its
    /// bind transform is missing/non-finite.
    private static func bindAnchorPoint(
        for attachment: WPEPuppetAttachment,
        bones: [WPEPuppetBone]
    ) -> SIMD2<Double>? {
        guard let boneWorld = bindWorldMatrices(bones: bones)[attachment.boneIndex] else { return nil }
        let anchor = boneWorld * attachment.matrix
        let p = anchor.columns.3
        guard p.x.isFinite, p.y.isFinite else { return nil }
        return SIMD2<Double>(Double(p.x), Double(p.y))
    }

    /// Composes each MDLS bone's parent-local `rawMatrix` down the hierarchy (`world(parent)·local`)
    /// into a model-space bind-world matrix, keyed by bone index. Roots use their local matrix directly.
    /// A missing/unparseable matrix, a missing parent, or a cycle leaves that bone UNRESOLVED (absent
    /// from the result) so `bindAnchorPoint` returns nil and the caller falls back to the legacy
    /// centroid anchor instead of adopting a finite-but-wrong identity-derived anchor.
    ///
    /// NOTE on the composition (do not naively "simplify" to raw): `WPEMdlParser.worldMatrices(bind:)`
    /// uses `rawMatrix` DIRECTLY as the skinning-palette bind-world. For the head attachment anchor,
    /// however, the raw head-bone translation is implausible (≈(221,323)) and did NOT match Windows
    /// ground truth, while the hierarchy-composed value (≈(686,800)) · MDAT did — and is on-device
    /// confirmed for 3719111841. So the attachment path empirically needs composition. This tension
    /// with the palette bind path is unresolved across the corpus → keep this opt-in (default OFF) and
    /// validate on a non-root-anchor rig before widening. FOLLOW-UP: the executor's animated follow
    /// (`layerApplyingAttachmentFollow`) still measures its bind reference from the RAW matrix, so when
    /// skinning is re-enabled it must switch to this composed bind-world to stay consistent with the
    /// static placement here.
    private static func bindWorldMatrices(bones: [WPEPuppetBone]) -> [Int: simd_float4x4] {
        let localByIndex = Dictionary(
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
        
        for _ in 0..<bones.count {
            var progress = false
            for bone in bones {
                let index = bone.index
                if cache[index] != nil { continue }
                guard let local = localByIndex[index] else { continue }
                
                if let parent = parentByIndex[index] ?? nil, parent != index {
                    if let parentWorld = cache[parent] {
                        cache[index] = parentWorld * local
                        progress = true
                    }
                } else {
                    cache[index] = local
                    progress = true
                }
            }
            if !progress { break }
        }
        return cache
    }

    static func compositesToScene(_ object: WPESceneImageObject, liveVisibilityIDs: Set<String>) -> Bool {
        // A fully-transparent base layer with no alpha animation contributes
        // nothing on its own — EXCEPT when it carries a visible effect, which
        // draws its own content with its own alpha (e.g. 3719111841's audio
        // spectrum line: an alpha-0 solidlayer whose `audioline` effect renders
        // the visible curve). Dropping such layers hid the entire effect.
        let hasVisibleEffect = object.effects.contains { $0.visible }
        guard object.alpha > 0.001 || object.alphaAnimation != nil || hasVisibleEffect else {
            return false
        }
        return object.visible || liveVisibilityIDs.contains(object.id)
    }

    /// True when any ancestor up the `parentObjectID` chain is explicitly hidden
    /// (`visible == false`). WPE propagates a parent's visibility to its children, so a
    /// body-split rig's face/mask/body child layers (authored `visible: true`) must inherit
    /// the hidden state of a conditionally-hidden variant parent. Without this, the visible
    /// children of a hidden style variant still composited — 3226487183 drew its 默认/面具/抬头
    /// poses (and their masks) all at once. A container that is merely alpha-0 keeps
    /// `visible == true`, so a transparent grouping layer never suppresses its own subtree.
    static func hasHiddenAncestor(
        _ object: WPESceneImageObject,
        objectByID: [String: WPESceneImageObject],
        liveVisibilityIDs: Set<String>
    ) -> Bool {
        var seen: Set<String> = []
        var current = object.parentObjectID
        while let id = current, seen.insert(id).inserted, let parent = objectByID[id] {
            // A user-toggleable (condition-less) hidden parent stays in the graph so a live
            // visibility toggle can re-show it — its authored-visible children must stay too,
            // or toggling the parent back on would reveal an empty subtree. Only an ancestor
            // that is hidden AND not live-toggleable (e.g. a resolved style-selector variant)
            // suppresses its subtree.
            if !parent.visible && !liveVisibilityIDs.contains(parent.id) { return true }
            current = parent.parentObjectID
        }
        return false
    }

    /// True when some ancestor is hidden via a condition-less live visibility toggle
    /// (`!visible` but in `liveVisibilityIDs`). The subtree stays in the graph — drawn hidden —
    /// so toggling the ancestor back on at runtime re-shows it without a rebuild.
    /// `hasHiddenAncestor` already excludes subtrees under a permanently-hidden ancestor.
    static func hasLiveToggleableHiddenAncestor(
        _ object: WPESceneImageObject,
        objectByID: [String: WPESceneImageObject],
        liveVisibilityIDs: Set<String>
    ) -> Bool {
        var seen: Set<String> = []
        var current = object.parentObjectID
        while let id = current, seen.insert(id).inserted, let parent = objectByID[id] {
            if !parent.visible && liveVisibilityIDs.contains(parent.id) { return true }
            current = parent.parentObjectID
        }
        return false
    }

    /// Image-object IDs that have an incremental (`visible`) property binding —
    /// i.e. their on-screen visibility can be toggled live from project settings.
    private static func userToggleableVisibilityIDs(in document: WPESceneDocument) -> Set<String> {
        var ids = Set<String>()
        for bindings in document.propertyBindings.values {
            // Condition-form (style-selector / combo) visibility is resolved from the combo
            // value at build time, not a live boolean toggle. Treating it as live-toggleable
            // put conditionally-hidden variant layers into the always-composite set, so every
            // style variant (默认/面具/抬头) rendered at once (3226487183). Only simple,
            // condition-less `visible` bindings are genuine live toggles.
            for binding in bindings
            where binding.kind == .visible && binding.action == .incremental && binding.condition == nil {
                if case .imageObject(let id) = binding.target {
                    ids.insert(id)
                }
            }
        }
        return ids
    }

    /// Image-object IDs a layer SceneScript can reveal via `thisScene.getLayer(name)`,
    /// kept in the graph even when authored-hidden behind a condition-form binding —
    /// else the script switches to a layer that isn't there → black background.
    ///
    /// The getLayer argument is usually a variable bound from an array literal
    /// (`["morning","day",...].map(v => getLayer(v))`), so a `getLayer("…")` scan
    /// misses it; match any string literal in the script against a layer name
    /// instead. Names the script never mentions still prune, so this doesn't
    /// reintroduce the all-variants-render regression (3226487183).
    private static func layerScriptControlledVisibilityIDs(in document: WPESceneDocument) -> Set<String> {
        let scripts = document.imageObjects.compactMap(\.visibleScript)
        guard !scripts.isEmpty else { return [] }
        let combined = scripts.joined(separator: "\n")
        var ids = Set<String>()
        for object in document.imageObjects {
            let name = object.name
            guard !name.isEmpty else { continue }
            if combined.contains("\"\(name)\"") || combined.contains("'\(name)'") {
                ids.insert(object.id)
            }
        }
        return ids
    }

    private static func referencedLayerIDs(in object: WPESceneImageObject) -> Set<String> {
        var ids = Set(object.dependencies)
        for effect in object.effects where effect.visible {
            for passOverride in effect.passOverrides {
                for texture in passOverride.textures.values {
                    if let id = layerID(fromCompositeName: texture) {
                        ids.insert(id)
                    }
                }
            }
        }
        return ids
    }

    /// Orders the layers to build so every composite producer is emitted
    /// before any consumer that references its `_rt_imageLayerComposite_*`
    /// target. WPE scenes often author a consumer object ahead of the
    /// producer it samples; the executor walks layers in array order and the
    /// first frame has no previous named-texture bootstrap, so a producer
    /// that runs later would surface as a fatal `missingTexture(.fbo)`.
    ///
    /// Stable topological sort (Kahn) keyed on the original scene index as a
    /// tie-breaker, so unrelated layers keep their authored order. A
    /// dependency cycle is non-fatal: the cyclic remainder is appended in
    /// scene order and a diagnostic is emitted rather than dropping layers.
    private static func topologicallyOrderedLayerIDs(
        _ layerIDs: Set<String>,
        objectByID: [String: WPESceneImageObject],
        originalIndexByID: [String: Int]
    ) -> [String] {
        func originalIndex(_ id: String) -> Int {
            originalIndexByID[id] ?? Int.max
        }

        func originalOrder(_ lhs: String, _ rhs: String) -> Bool {
            let left = originalIndex(lhs)
            let right = originalIndex(rhs)
            if left != right { return left < right }
            return lhs < rhs
        }

        let orderedIDs = layerIDs.sorted(by: originalOrder)
        var inDegree = Dictionary(uniqueKeysWithValues: orderedIDs.map { ($0, 0) })
        var dependentsByID: [String: Set<String>] = [:]

        for consumerID in orderedIDs {
            guard let consumer = objectByID[consumerID] else { continue }
            for dependencyID in referencedLayerIDs(in: consumer)
            where dependencyID != consumerID
                && layerIDs.contains(dependencyID)
                && objectByID[dependencyID] != nil {
                if dependentsByID[dependencyID, default: []].insert(consumerID).inserted {
                    inDegree[consumerID, default: 0] += 1
                }
            }
        }

        var ready = orderedIDs.filter { inDegree[$0, default: 0] == 0 }
        var emitted: [String] = []
        var emittedIDs = Set<String>()

        while !ready.isEmpty {
            ready.sort(by: originalOrder)
            let id = ready.removeFirst()
            guard emittedIDs.insert(id).inserted else { continue }
            emitted.append(id)

            let dependents = (dependentsByID[id] ?? []).sorted(by: originalOrder)
            for dependentID in dependents {
                let nextDegree = max((inDegree[dependentID] ?? 0) - 1, 0)
                inDegree[dependentID] = nextDegree
                if nextDegree == 0 {
                    ready.append(dependentID)
                }
            }
        }

        if emitted.count < orderedIDs.count {
            let cyclicRemainder = orderedIDs.filter { !emittedIDs.contains($0) }
            logCompositeDependencyCycle(cyclicRemainder)
            emitted.append(contentsOf: cyclicRemainder)
        }

        return emitted
    }

    private static func logCompositeDependencyCycle(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let detail = ids.joined(separator: ", ")
        let message = "WPE render graph composite dependency cycle; preserving scene order for: \(detail)"
        Logger.warning(message, category: .wpeRender)
        WPESceneDebugArtifacts.shared.appendLog(
            "[graph.cycle] \(message)",
            level: .warning
        )
    }

    private static func layerID(fromCompositeName name: String) -> String? {
        let prefix = "_rt_imageLayerComposite_"
        guard name.hasPrefix(prefix),
              name.hasSuffix("_a") || name.hasSuffix("_b") else {
            return nil
        }
        let start = name.index(name.startIndex, offsetBy: prefix.count)
        let end = name.index(name.endIndex, offsetBy: -2)
        guard start < end else { return nil }
        return String(name[start..<end])
    }

    private func buildLayer(
        object: WPESceneImageObject,
        sceneSize: CGSize,
        finalUntargetedPassToScene: Bool,
        preserveFinalCompositeForScene: Bool,
        sortIndex: Int
    ) throws -> WPERenderLayer {
        let model = try resolveModelDescriptor(for: object)
        let materialPath = model.materialPath
        let puppetPlacement = model.puppetPlacement(for: object, sceneSize: sceneSize)
        let compositeA = "_rt_imageLayerComposite_\(object.id)_a"
        let compositeB = "_rt_imageLayerComposite_\(object.id)_b"

        var context = LayerBuildContext(
            object: object,
            model: model,
            compositeA: compositeA,
            compositeB: compositeB,
            nextComposite: compositeA,
            source: .image(object.imageRelativePath)
        )

        if let materialPath {
            let material = try builtinMaterial(path: materialPath, object: object) ?? loadMaterial(path: materialPath)
            context.source = material.initialTextureSource(fallback: context.source)
            try appendMaterialPasses(
                material.passes,
                phase: .material,
                override: nil,
                binds: [:],
                explicitTarget: nil,
                to: &context
            )
        }

        for effect in object.effects where effect.visible {
            let asset = try loadEffect(path: effect.fileRelativePath)
            context.localFBOs.append(contentsOf: asset.fbos)
            var overrideIndex = 0
            for effectPass in asset.passes {
                let override = overrideIndex < effect.passOverrides.count
                    ? effect.passOverrides[overrideIndex]
                    : nil
                overrideIndex += 1

                switch effectPass.kind {
                case .material(let materialPath):
                    let material = try loadMaterial(path: materialPath)
                    try appendMaterialPasses(
                        material.passes,
                        phase: .effect(file: effect.fileRelativePath),
                        override: override,
                        binds: effectPass.binds,
                        explicitTarget: effectPass.target.map { .fbo(name: $0) },
                        to: &context
                    )
                case .command(let command, let source, let target):
                    let virtualPass = WPEMaterialPass(
                        shader: "commands/\(command)",
                        textures: [0: source ?? .previous],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                    try appendMaterialPasses(
                        [virtualPass],
                        phase: .command(file: effect.fileRelativePath),
                        override: override,
                        binds: effectPass.binds,
                        explicitTarget: target.map { .fbo(name: $0) },
                        to: &context
                    )
                }
            }
        }

        return WPERenderLayer(
            objectID: object.id,
            objectName: object.name,
            visible: object.visible,
            imagePath: object.imageRelativePath,
            materialPath: materialPath,
            puppetPath: model.puppetPath,
            parentObjectID: object.parentObjectID,
            attachment: object.attachment,
            animationLayers: object.animationLayers,
            geometry: WPERenderLayerGeometry(
                origin: puppetPlacement?.origin ?? object.origin,
                scale: object.scale,
                angles: object.angles,
                alignment: object.alignment,
                size: puppetPlacement?.size ?? object.size,
                puppetMeshCenter: puppetPlacement?.meshCenter ?? SIMD2<Double>(0, 0),
                alpha: object.alpha,
                alphaAnimation: object.alphaAnimation,
                color: object.color,
                brightness: object.brightness
            ),
            localGeometry: WPERenderLayerGeometry(
                origin: object.localOrigin,
                scale: object.localScale,
                angles: object.localAngles,
                alignment: object.alignment,
                size: puppetPlacement?.size ?? object.size,
                puppetMeshCenter: puppetPlacement?.meshCenter ?? SIMD2<Double>(0, 0),
                alpha: object.alpha,
                alphaAnimation: object.alphaAnimation,
                color: object.color,
                brightness: object.brightness
            ),
            compositeA: compositeA,
            compositeB: compositeB,
            localFBOs: context.localFBOs,
            passes: context.finalizedPasses(
                finalUntargetedPassToScene: finalUntargetedPassToScene,
                preserveFinalCompositeForScene: preserveFinalCompositeForScene || model.puppetPath != nil
            ),
            parallaxDepth: object.parallaxDepth,
            sortIndex: sortIndex
        )
    }

    private func appendMaterialPasses(
        _ passes: [WPEMaterialPass],
        phase: WPERenderPassPhase,
        override: WPESceneEffectPassOverride?,
        binds: [Int: WPETextureReference],
        explicitTarget: WPERenderTarget?,
        to context: inout LayerBuildContext
    ) throws {
        for materialPass in passes {
            let target = explicitTarget ?? .layerComposite(name: context.nextComposite)
            var merged = materialPass.merging(override: override)
            merged = materialPassWithPuppetClipCompositeIfNeeded(merged, phase: phase, context: &context)
            let passID = "\(context.object.id).\(context.passes.count)"
            context.passes.append(WPERenderPass(
                id: passID,
                phase: phase,
                shader: merged.shader,
                source: context.source,
                target: target,
                textures: merged.textures,
                binds: binds,
                constants: merged.constants,
                combos: merged.combos,
                blending: merged.blending.premultipliedRenderTargetBlendMode,
                cullMode: merged.cullMode,
                depthTest: merged.depthTest,
                depthWrite: merged.depthWrite
            ))
            context.passTargetsWereExplicit.append(explicitTarget != nil)

            if explicitTarget == nil {
                context.source = .fbo(context.nextComposite)
                context.nextComposite = context.nextComposite == context.compositeA
                    ? context.compositeB
                    : context.compositeA
            }
        }
    }

    private func resolveModelDescriptor(for object: WPESceneImageObject) throws -> WPEModelDescriptor {
        let explicitMaterial = object.materialRelativePath?.isEmpty == false
            ? object.materialRelativePath
            : nil
        if isBuiltinModelPath(object.imageRelativePath) {
            return WPEModelDescriptor(materialPath: explicitMaterial ?? object.imageRelativePath, puppetPath: nil)
        }
        let extensionName = (object.imageRelativePath as NSString).pathExtension.lowercased()
        guard extensionName == "json" else {
            return WPEModelDescriptor(materialPath: explicitMaterial, puppetPath: nil)
        }

        let dict: [String: Any]
        do {
            dict = try readJSONObject(path: object.imageRelativePath)
        } catch {
            guard let explicitMaterial else { throw error }
            return WPEModelDescriptor(materialPath: explicitMaterial, puppetPath: nil)
        }

        guard let material = explicitMaterial ?? (dict["material"] as? String),
              !material.isEmpty else {
            throw WPERenderGraphError.materialUnresolved(object.imageRelativePath)
        }
        let puppetPath = (dict["puppet"] as? String)
            .flatMap { $0.isEmpty ? nil : inheritDependencyPrefix($0, from: object.imageRelativePath) }
        let clipMaskName = (Self.puppetClipCompositeEnabled ? puppetPath : nil)
            .flatMap(loadPuppetClipMaskName(path:))
        return WPEModelDescriptor(
            materialPath: inheritDependencyPrefix(material, from: object.imageRelativePath),
            puppetPath: puppetPath,
            puppetBounds: puppetPath.flatMap(loadPuppetBounds(path:)),
            puppetClipMaskName: clipMaskName
        )
    }

    private func loadPuppetBounds(path: String) -> WPEPuppetBounds? {
        do {
            let data = try resolver.data(relativePath: path)
            let model = try WPEMdlParser.parse(data: data)
            guard model.version >= 21 else { return nil }
            return WPEPuppetBounds(model: model)
        } catch {
            return nil
        }
    }

    /// Clip-mask name from the puppet's MDLV clip section (wires the genericimage4 clip-composite
    /// path). Nil for puppets without a clip section.
    private func loadPuppetClipMaskName(path: String) -> String? {
        guard let data = try? resolver.data(relativePath: path),
              let model = try? WPEMdlParser.parse(data: data) else {
            return nil
        }
        return model.clipMaskName
    }

    /// For a genericimage4 puppet pass with an MDLV clip mask, injects the clip-mask asset (slot 1)
    /// and the intermediate clip render target (slot 8) so the executor runs the clip composite.
    /// No-op when the flag is off, the puppet has no clip mask, or the shader is not genericimage4.
    private func materialPassWithPuppetClipCompositeIfNeeded(
        _ pass: WPEMaterialPass,
        phase: WPERenderPassPhase,
        context: inout LayerBuildContext
    ) -> WPEMaterialPass {
        // Only the base material phase drives the clip composite; effect-chain genericimage4 passes
        // must not receive the clip bindings (the executor clip path only handles `.material`).
        guard case .material = phase,
              Self.puppetClipCompositeEnabled,
              context.model.puppetPath != nil,
              let clipMaskName = context.model.puppetClipMaskName,
              WPEBuiltinShaderName.normalized(pass.shader) == "genericimage4",
              pass.textures[8] == nil else {
            return pass
        }
        // Shared name so the executor's defer routing matches this exact injected RT (no format drift).
        let clipTargetName = WPEMetalRenderExecutor.puppetClipRTName(objectID: context.object.id)
        if !context.localFBOs.contains(where: { $0.name == clipTargetName }) {
            // Half-res clip mask RT, matching WPE (1920×1080 for a 3840×2160 capture).
            context.localFBOs.append(WPERenderFBO(name: clipTargetName, scale: 2, format: "rgba8888"))
        }
        var textures = pass.textures
        // The clip-mask name (e.g. `masks/clipping_mask_39cb32c5`) uses the SAME bare-name convention
        // as a material texture ("眼睛组合"); textureReference + the resolver add `materials/` + `.tex`.
        textures[1] = textures[1] ?? textureReference(clipMaskName, ownerPath: context.object.imageRelativePath)
        textures[8] = .fbo(clipTargetName)
        #if DEBUG
        // Gated behind the scene-debug switch (off by default) so clip-composite
        // injection doesn't log on every load of a genericimage4 puppet scene.
        if UserDefaults.standard.bool(forKey: "WPESceneDebugArtifactsEnabled") {
            Logger.info(
                "[WPE clip] builder injected clip-composite bindings for \(context.model.puppetPath ?? "?") "
                    + "(mask=\(clipMaskName), rt=\(clipTargetName))",
                category: .wpeRender
            )
        }
        #endif
        return pass.replacingTextures(textures)
    }

    private func isBuiltinModelPath(_ path: String) -> Bool {
        Self.builtinSolidLayerDepthTest(forModelPath: path) != nil
    }

    /// The two bundled solid-layer models (`solidlayer.json` and its depth-test
    /// variant) are both `"solidlayer": true`; they differ only in depth-test state.
    private static func builtinSolidLayerDepthTest(forModelPath path: String) -> String? {
        switch path.lowercased() {
        case "models/util/solidlayer.json":
            return "disabled"
        case "models/util/solidlayer_depthtest.json":
            return "enabled"
        default:
            return nil
        }
    }

    private func builtinMaterial(path: String, object: WPESceneImageObject) throws -> WPEMaterialAsset? {
        guard let depthTest = Self.builtinSolidLayerDepthTest(forModelPath: path) else {
            return nil
        }

        let color = object.color * object.brightness
        return WPEMaterialAsset(
            path: path,
            passes: [
                WPEMaterialPass(
                    // Premultiplied render targets: use the `solidlayer` builtin
                    // (outputs rgb*alpha) rather than `solidcolor` (straight), so
                    // a transparent solid layer (alpha 0) composites to NOTHING
                    // under the premultiplied blend the graph routes this pass to
                    // — not an opaque white fill. The `_depthtest` variant only
                    // differs in depth-test state and must take this path too:
                    // routing it to the bundled `solidcolor` material blew out
                    // 3719111841's audio-line base to opaque white, hiding the
                    // whole background behind the (otherwise correct) line.
                    shader: "solidlayer",
                    textures: [:],
                    constants: [
                        "g_Color": .vector([color.x, color.y, color.z, object.alpha])
                    ],
                    combos: [:],
                    blending: object.blendMode.rawValue,
                    cullMode: "nocull",
                    depthTest: depthTest,
                    depthWrite: "disabled"
                )
            ]
        )
    }

    private func loadMaterial(path: String) throws -> WPEMaterialAsset {
        let dict = try readJSONObject(path: path)
        guard let rawPasses = dict["passes"] as? [Any] else {
            throw WPERenderGraphError.malformedMaterial(path)
        }
        let passes = rawPasses.compactMap { parseMaterialPass($0, ownerPath: path) }
        guard !passes.isEmpty else {
            throw WPERenderGraphError.malformedMaterial(path)
        }
        return WPEMaterialAsset(path: path, passes: passes)
    }

    private func loadEffect(path: String) throws -> WPEEffectAsset {
        let dict = try readJSONObject(path: path)
        let fbos = ((dict["fbos"] as? [Any]) ?? []).compactMap(parseFBO)
        let declaredFBONames = Set(fbos.map(\.name))
        guard let rawPasses = dict["passes"] as? [Any] else {
            throw WPERenderGraphError.malformedEffect(path)
        }
        let passes = rawPasses.compactMap {
            parseEffectPass($0, ownerPath: path, declaredFBONames: declaredFBONames)
        }
        guard !passes.isEmpty else {
            throw WPERenderGraphError.malformedEffect(path)
        }
        return WPEEffectAsset(path: path, passes: passes, fbos: fbos)
    }

    private func readJSONObject(path: String) throws -> [String: Any] {
        let data: Data
        do {
            data = try resolver.data(relativePath: path)
        } catch {
            throw WPERenderGraphError.fileMissing(path)
        }
        do {
            guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw WPERenderGraphError.invalidJSON(path)
            }
            return dict
        } catch let error as WPERenderGraphError {
            throw error
        } catch {
            throw WPERenderGraphError.invalidJSON(path)
        }
    }

    private func parseMaterialPass(_ raw: Any, ownerPath: String) -> WPEMaterialPass? {
        guard let dict = raw as? [String: Any],
              let shader = dict["shader"] as? String,
              !shader.isEmpty else {
            return nil
        }
        return WPEMaterialPass(
            shader: shader,
            textures: parseTextureArray(dict["textures"], ownerPath: ownerPath),
            constants: parseShaderConstants(dict["constantshadervalues"]),
            combos: parseComboMap(dict["combos"]),
            blending: (dict["blending"] as? String) ?? "normal",
            cullMode: (dict["cullmode"] as? String) ?? "nocull",
            depthTest: (dict["depthtest"] as? String) ?? "disabled",
            depthWrite: (dict["depthwrite"] as? String) ?? "disabled"
        )
    }

    private func parseEffectPass(
        _ raw: Any,
        ownerPath: String,
        declaredFBONames: Set<String>
    ) -> WPEEffectPass? {
        guard let dict = raw as? [String: Any] else { return nil }
        let binds = parseBinds(
            dict["bind"],
            ownerPath: ownerPath,
            declaredFBONames: declaredFBONames
        )
        let target = dict["target"] as? String
        if let material = dict["material"] as? String, !material.isEmpty {
            return WPEEffectPass(
                kind: .material(inheritDependencyPrefix(material, from: ownerPath)),
                binds: binds,
                target: target
            )
        }
        if let command = dict["command"] as? String, !command.isEmpty {
            return WPEEffectPass(
                kind: .command(
                    command,
                    source: (dict["source"] as? String).map {
                        textureReference($0, ownerPath: ownerPath, declaredFBONames: declaredFBONames)
                    },
                    target: target
                ),
                binds: binds,
                target: target
            )
        }
        return nil
    }

    private func parseFBO(_ raw: Any) -> WPERenderFBO? {
        guard let dict = raw as? [String: Any],
              let name = dict["name"] as? String,
              !name.isEmpty else {
            return nil
        }
        return WPERenderFBO(
            name: name,
            scale: parseDouble(dict["scale"]) ?? 1,
            format: (dict["format"] as? String) ?? "rgba8888",
            unique: parseBool(dict["unique"]) ?? false
        )
    }

    private func parseBinds(
        _ raw: Any?,
        ownerPath: String,
        declaredFBONames: Set<String> = []
    ) -> [Int: WPETextureReference] {
        guard let array = raw as? [Any] else { return [:] }
        var result: [Int: WPETextureReference] = [:]
        for entry in array {
            guard let dict = entry as? [String: Any],
                  let index = parseInt(dict["index"]),
                  let name = dict["name"] as? String,
                  !name.isEmpty else {
                continue
            }
            result[index] = textureReference(name, ownerPath: ownerPath, declaredFBONames: declaredFBONames)
        }
        return result
    }

    private func parseTextureArray(_ raw: Any?, ownerPath: String) -> [Int: WPETextureReference] {
        guard let array = raw as? [Any] else { return [:] }
        var result: [Int: WPETextureReference] = [:]
        for (index, value) in array.enumerated() {
            if let name = Self.parseTexturePath(value) {
                result[index] = textureReference(name, ownerPath: ownerPath)
            }
        }
        return result
    }

    /// Texture arrays mix plain path strings with structured entries
    /// (`{"name": "masks/…"}`, how per-instance effect masks are declared).
    static func parseTexturePath(_ raw: Any?) -> String? {
        if let string = raw as? String {
            // Preserve the name verbatim: WPE matches asset names literally, and
            // a real filename can legitimately end in a space (e.g.
            // `materials/妃咲 60帧 .tex`) — Windows hides the trailing space but
            // the .pkg TOC + every JSON reference keep it. Trimming it mismatched
            // the packaged file (scene 3351072238). Only reject blank entries.
            return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : string
        }
        guard let dict = raw as? [String: Any] else { return nil }
        for key in ["value", "name", "texture", "path", "file"] {
            if let parsed = parseTexturePath(dict[key]) {
                return parsed
            }
        }
        return nil
    }

    private func textureReference(
        _ name: String,
        ownerPath: String,
        declaredFBONames: Set<String> = []
    ) -> WPETextureReference {
        if name == "previous" {
            return .previous
        }
        if declaredFBONames.contains(name) {
            return .fbo(name)
        }
        if name.hasPrefix("_") {
            return .fbo(name)
        }
        return .asset(inheritDependencyPrefix(name, from: ownerPath))
    }

    private func inheritDependencyPrefix(_ path: String, from ownerPath: String) -> String {
        guard !path.hasPrefix("../"),
              let prefix = dependencyPrefix(in: ownerPath) else {
            return path
        }
        return "\(prefix)/\(path)"
    }

    private func dependencyPrefix(in path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] == ".." else { return nil }
        return "../\(parts[1])"
    }

    private func parseShaderConstants(_ raw: Any?) -> [String: WPESceneShaderConstantValue] {
        WPEValueParser.shaderConstants(raw, boolAsNumber: true)
    }

    private func parseComboMap(_ raw: Any?) -> [String: Int] {
        WPEValueParser.comboMap(raw, boolAsNumber: true)
    }

    private func parseDouble(_ raw: Any?) -> Double? {
        WPEValueParser.double(raw, boolAsNumber: true)
    }

    private func parseBool(_ raw: Any?) -> Bool? {
        WPEValueParser.bool(raw)
    }

    private func parseInt(_ raw: Any?) -> Int? {
        WPEValueParser.int(raw, boolAsNumber: true)
    }
}

private struct LayerBuildContext {
    let object: WPESceneImageObject
    let model: WPEModelDescriptor
    let compositeA: String
    let compositeB: String
    var nextComposite: String
    var source: WPETextureReference
    var localFBOs: [WPERenderFBO] = []
    var passes: [WPERenderPass] = []
    var passTargetsWereExplicit: [Bool] = []

    func finalizedPasses(
        finalUntargetedPassToScene: Bool,
        preserveFinalCompositeForScene: Bool
    ) -> [WPERenderPass] {
        guard let lastPass = passes.last,
              finalUntargetedPassToScene,
              passTargetsWereExplicit.indices.contains(passes.count - 1),
              passTargetsWereExplicit[passes.count - 1] == false else {
            return passes.movingFirstBlendModeToFinalPass()
        }

        // Workshop custom effects must NOT be fused into the scene-size pass:
        // WPE renders them at LAYER size and composites separately (oracle:
        // 3554161528 pulse_ eid854@1436×456 + composite eid876; our fused
        // 3840×2160 pass clamp-streaked the small layer across the sky — the
        // "色块" bug). Builtin effects (waterflow/waterwaves) fuse fine and
        // match WPE's own fused passes, so they keep the fast path.
        let lastPassIsWorkshopEffect = lastPass.shader.contains("workshop/")
        if preserveFinalCompositeForScene || lastPassIsWorkshopEffect,
           let sceneSource = lastPass.target.textureReference {
            var finalized = passes
            finalized.append(WPERenderPass(
                id: "\(object.id).\(passes.count)",
                phase: .command(file: "materials/util/copy.json"),
                shader: "materials/util/copy.json",
                source: sceneSource,
                target: .scene,
                textures: [0: sceneSource],
                binds: [:],
                constants: [:],
                combos: [:],
                blending: lastPass.blending,
                cullMode: "nocull",
                depthTest: "disabled",
                depthWrite: "disabled"
            ))
            return finalized.movingFirstBlendModeToFinalPass()
        }

        var finalized = passes
        finalized[finalized.count - 1] = lastPass.replacingTarget(.scene)
        return finalized.movingFirstBlendModeToFinalPass()
    }
}

private struct WPEModelDescriptor {
    let materialPath: String?
    let puppetPath: String?
    let puppetBounds: WPEPuppetBounds?
    /// Clip-mask texture NAME from the puppet's MDLV clip section (e.g.
    /// `masks/clipping_mask_39cb32c5`), resolved like any material texture. Non-nil only when
    /// the puppet is a clip-composite candidate and the feature flag is enabled.
    let puppetClipMaskName: String?

    init(
        materialPath: String?,
        puppetPath: String?,
        puppetBounds: WPEPuppetBounds? = nil,
        puppetClipMaskName: String? = nil
    ) {
        self.materialPath = materialPath
        self.puppetPath = puppetPath
        self.puppetBounds = puppetBounds
        self.puppetClipMaskName = puppetClipMaskName
    }

    /// Re-place a puppet whose raw MDLV mesh bbox is cropped by the declared
    /// object.size local composite. Sizes the composite AND the scene quad to
    /// the mesh bbox (native 1:1, no shrink/stretch), centers the mesh, and
    /// recomputes the origin so the mesh-bbox center keeps its old on-screen
    /// position. Returns nil (no-op) for non-puppets and puppets that already
    /// fit — protecting every working puppet/image layer.
    func puppetPlacement(for object: WPESceneImageObject, sceneSize: CGSize) -> WPEPuppetPlacement? {
        guard puppetPath != nil,
              let puppetBounds,
              let objectSize = object.size else {
            return nil
        }

        let objectWidth = Double(objectSize.width)
        let objectHeight = Double(objectSize.height)
        guard objectWidth > 0, objectHeight > 0 else { return nil }

        let localMinX = objectWidth * 0.5 + puppetBounds.min.x
        let localMaxX = objectWidth * 0.5 + puppetBounds.max.x
        let localMinY = objectHeight * 0.5 - puppetBounds.max.y
        let localMaxY = objectHeight * 0.5 - puppetBounds.min.y

        let epsilon = 1.0
        let isCropped = localMinX < -epsilon
            || localMaxX > objectWidth + epsilon
            || localMinY < -epsilon
            || localMaxY > objectHeight + epsilon
        guard isCropped else { return nil }

        let scaleX = finiteMagnitude(object.scale.x, fallback: 1)
        let scaleY = finiteMagnitude(object.scale.y, fallback: 1)
        let oldWidth = objectWidth * scaleX
        let oldHeight = objectHeight * scaleY
        let oldOffset = alignmentCenterOffset(
            alignment: object.alignment,
            width: oldWidth,
            height: oldHeight
        )
        let sceneHeight = Double(sceneSize.height)
        let oldCenterX = object.origin.x + oldOffset.x
        let oldCenterY = sceneHeight - object.origin.y - oldOffset.y
        let oldLeft = oldCenterX - oldWidth * 0.5
        let oldTop = oldCenterY - oldHeight * 0.5

        let meshWidth = max(ceil(localMaxX - localMinX), 1)
        let meshHeight = max(ceil(localMaxY - localMinY), 1)
        let meshScaledWidth = meshWidth * scaleX
        let meshScaledHeight = meshHeight * scaleY

        let meshCenterX = oldLeft + (localMinX + localMaxX) * 0.5 * scaleX
        // Keep the mesh-bbox center at its original on-screen position — no
        // bottom clamp. WPE puppet art is authored already cropped at the
        // boots, so that natural cut edge must sit flush against the screen
        // bottom; lifting it (to avoid the final ~50px clip) would float the
        // whole character upward, which is wrong.
        let meshCenterY = oldTop + (localMinY + localMaxY) * 0.5 * scaleY

        let newOffset = alignmentCenterOffset(
            alignment: object.alignment,
            width: meshScaledWidth,
            height: meshScaledHeight
        )
        let newOrigin = SIMD3<Double>(
            meshCenterX - newOffset.x,
            sceneHeight - meshCenterY - newOffset.y,
            object.origin.z
        )

        return WPEPuppetPlacement(
            origin: newOrigin,
            size: CGSize(width: CGFloat(meshWidth), height: CGFloat(meshHeight)),
            meshCenter: puppetBounds.center
        )
    }

    private func finiteMagnitude(_ value: Double, fallback: Double) -> Double {
        let magnitude = abs(value)
        return magnitude.isFinite && magnitude > 0 ? magnitude : fallback
    }

    private func alignmentCenterOffset(
        alignment: WPESceneAlignment,
        width: Double,
        height: Double
    ) -> SIMD2<Double> {
        switch alignment {
        case .center:
            return SIMD2<Double>(0, 0)
        case .topLeft:
            return SIMD2<Double>(width * 0.5, -height * 0.5)
        case .topRight:
            return SIMD2<Double>(-width * 0.5, -height * 0.5)
        case .bottomLeft:
            return SIMD2<Double>(width * 0.5, height * 0.5)
        case .bottomRight:
            return SIMD2<Double>(-width * 0.5, height * 0.5)
        case .top:
            return SIMD2<Double>(0, -height * 0.5)
        case .bottom:
            return SIMD2<Double>(0, height * 0.5)
        case .left:
            return SIMD2<Double>(width * 0.5, 0)
        case .right:
            return SIMD2<Double>(-width * 0.5, 0)
        }
    }
}

private struct WPEPuppetPlacement {
    let origin: SIMD3<Double>
    let size: CGSize
    let meshCenter: SIMD2<Double>
}

private struct WPEPuppetBounds {
    let min: SIMD2<Double>
    let max: SIMD2<Double>

    var center: SIMD2<Double> {
        SIMD2<Double>(
            (min.x + max.x) * 0.5,
            (min.y + max.y) * 0.5
        )
    }

    init?(model: WPEPuppetModel) {
        let vertices = model.meshes.flatMap(\.vertices)
        guard let first = vertices.first else { return nil }

        var minX = Double(first.position.x)
        var maxX = minX
        var minY = Double(first.position.y)
        var maxY = minY

        for vertex in vertices.dropFirst() {
            let x = Double(vertex.position.x)
            let y = Double(vertex.position.y)
            minX = Swift.min(minX, x)
            maxX = Swift.max(maxX, x)
            minY = Swift.min(minY, y)
            maxY = Swift.max(maxY, y)
        }

        self.min = SIMD2<Double>(minX, minY)
        self.max = SIMD2<Double>(maxX, maxY)
    }
}

private extension WPERenderLayer {
    func replacingGeometryOrigin(addingSceneOffset offset: SIMD3<Double>) -> WPERenderLayer {
        let g = geometry
        let newGeometry = WPERenderLayerGeometry(
            origin: SIMD3<Double>(g.origin.x + offset.x, g.origin.y + offset.y, g.origin.z + offset.z),
            scale: g.scale,
            angles: g.angles,
            alignment: g.alignment,
            size: g.size,
            puppetMeshCenter: g.puppetMeshCenter,
            alpha: g.alpha,
            alphaAnimation: g.alphaAnimation,
            color: g.color,
            brightness: g.brightness
        )
        return WPERenderLayer(
            objectID: objectID,
            objectName: objectName,
            visible: visible,
            imagePath: imagePath,
            materialPath: materialPath,
            puppetPath: puppetPath,
            parentObjectID: parentObjectID,
            attachment: attachment,
            animationLayers: animationLayers,
            geometry: newGeometry,
            localGeometry: localGeometry,
            compositeA: compositeA,
            compositeB: compositeB,
            localFBOs: localFBOs,
            passes: passes,
            parallaxDepth: parallaxDepth,
            sortIndex: sortIndex
        )
    }

    func withParallaxDepth(_ depth: SIMD2<Double>) -> WPERenderLayer {
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
            parallaxDepth: depth,
            sortIndex: sortIndex
        )
    }
}

private extension WPERenderTarget {
    var textureReference: WPETextureReference? {
        switch self {
        case .layerComposite(let name), .fbo(let name):
            return .fbo(name)
        case .scene:
            return nil
        }
    }
}

private extension String {
    /// Map an authored WPE blend mode onto the premultiplied render-target
    /// variant used by the layer-FBO / effect-chain / composite passes.
    /// Idempotent: already-premultiplied modes are returned unchanged.
    var premultipliedRenderTargetBlendMode: String {
        switch normalizedBlendModeKey {
        case "premultiplied",
             "premultipliednormal",
             "premultipliedtranslucent",
             "premultipliednormalmapped",
             "premultipliedadditive",
             "premultiplieddisabled",
             "premultipliedmultiply":
            return self
        case "disabled":
            return "premultipliedDisabled"
        case "add", "additive", "oneone", "oneoneone":
            return "premultipliedAdditive"
        case "multiply":
            return "premultipliedMultiply"
        default:
            return "premultiplied"
        }
    }

    /// Blend mode for an intermediate FBO pass that simply writes its source
    /// into a freshly-cleared target (plain premultiplied over).
    var premultipliedIntermediateBlendMode: String {
        switch normalizedBlendModeKey {
        case "disabled", "premultiplieddisabled":
            return "premultipliedDisabled"
        default:
            return "premultiplied"
        }
    }

    private var normalizedBlendModeKey: String {
        lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
    }
}

private extension Array where Element == WPERenderPass {
    func movingFirstBlendModeToFinalPass() -> [WPERenderPass] {
        guard count > 1,
              let first = first,
              let last = last else {
            return self
        }

        var result = self
        result[0] = first.replacingBlending(first.blending.premultipliedIntermediateBlendMode)
        result[result.count - 1] = last.replacingBlending(first.blending)
        return result
    }
}

private struct WPEMaterialAsset {
    let path: String
    let passes: [WPEMaterialPass]

    func initialTextureSource(fallback: WPETextureReference) -> WPETextureReference {
        passes.first?.textures[0] ?? fallback
    }
}

private struct WPEEffectAsset {
    let path: String
    let passes: [WPEEffectPass]
    let fbos: [WPERenderFBO]
}

private struct WPEEffectPass {
    let kind: Kind
    let binds: [Int: WPETextureReference]
    let target: String?

    enum Kind {
        case material(String)
        case command(String, source: WPETextureReference?, target: String?)
    }
}

private struct WPEMaterialPass {
    let shader: String
    let textures: [Int: WPETextureReference]
    let constants: [String: WPESceneShaderConstantValue]
    let combos: [String: Int]
    let blending: String
    let cullMode: String
    let depthTest: String
    let depthWrite: String

    func merging(override: WPESceneEffectPassOverride?) -> WPEMaterialPass {
        guard let override else { return self }
        var mergedTextures = textures
        for (index, path) in override.textures {
            if path == "previous" {
                mergedTextures[index] = .previous
            } else if path.hasPrefix("_") {
                mergedTextures[index] = .fbo(path)
            } else {
                mergedTextures[index] = .asset(path)
            }
        }

        return WPEMaterialPass(
            shader: shader,
            textures: mergedTextures,
            constants: constants.merging(override.constants) { _, new in new },
            combos: combos.merging(override.combos) { _, new in new },
            blending: blending,
            cullMode: cullMode,
            depthTest: depthTest,
            depthWrite: depthWrite
        )
    }

    func replacingTextures(_ textures: [Int: WPETextureReference]) -> WPEMaterialPass {
        WPEMaterialPass(
            shader: shader,
            textures: textures,
            constants: constants,
            combos: combos,
            blending: blending,
            cullMode: cullMode,
            depthTest: depthTest,
            depthWrite: depthWrite
        )
    }
}
#endif
