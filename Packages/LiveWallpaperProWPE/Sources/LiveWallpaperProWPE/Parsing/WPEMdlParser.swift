import Foundation
import LiveWallpaperCore
import simd

public struct WPEPuppetModel: Equatable, Sendable {
    public let version: Int
    public let meshes: [WPEPuppetMesh]
    public let bones: [WPEPuppetBone]
    public let animations: [WPEPuppetAnimation]
    /// MDAT anchors mapping a named scene attachment (e.g. 头部/脖颈/胸部) to a bone + bind transform.
    public let attachments: [WPEPuppetAttachment]

    public init(
        version: Int,
        meshes: [WPEPuppetMesh],
        bones: [WPEPuppetBone] = [],
        animations: [WPEPuppetAnimation] = [],
        attachments: [WPEPuppetAttachment] = []
    ) {
        self.version = version
        self.meshes = meshes
        self.bones = bones
        self.animations = animations
        self.attachments = attachments
    }

    /// Clip-mask texture name if any mesh declares an MDLV clip section (genericimage4 clipping).
    public var clipMaskName: String? {
        meshes.lazy.compactMap(\.clipMaskName).first
    }
}

public struct WPEMdlParseAudit: Equatable, Sendable {
    public enum SectionKind: Equatable, Sendable {
        case mdlvHeader
        case mdlvMesh
        case mdls
        case mdat
        case mdla
    }

    public struct KnownSkip: Equatable, Sendable {
        public let label: String
        public let range: Range<Int>
    }

    public struct SectionRecord: Equatable, Sendable {
        public let kind: SectionKind
        public let label: String
        public let range: Range<Int>
        public let intentionallySkippedRanges: [KnownSkip]
    }

    public struct Gap: Equatable, Sendable {
        public let range: Range<Int>
    }

    public let sections: [SectionRecord]
    public let unexplainedGaps: [Gap]
    public let trailingLeftover: Range<Int>?
}

public struct WPEPuppetMesh: Equatable, Sendable {
    public let materialPath: String
    public let vertices: [WPEPuppetVertex]
    public let indices: [UInt16]
    public let parts: [WPEPuppetMeshPart]
    /// Clip-mask texture name from the MDLV clip section that follows the part table
    /// (e.g. `masks/clipping_mask_39cb32c5`), used by the genericimage4 clip-composite path.
    public let clipMaskName: String?

    public init(
        materialPath: String,
        vertices: [WPEPuppetVertex],
        indices: [UInt16],
        parts: [WPEPuppetMeshPart],
        clipMaskName: String? = nil
    ) {
        self.materialPath = materialPath
        self.vertices = vertices
        self.indices = indices
        self.parts = parts
        self.clipMaskName = clipMaskName
    }
}

public struct WPEPuppetVertex: Hashable, Sendable {
    /// Object-local target geometry. Do not derive this from `uv`: puppet textures can be atlases.
    public let position: SIMD3<Float>
    public let uv: SIMD2<Float>
    public let skinBlendIndices: SIMD4<Int32>
    public let skinBlendWeights: SIMD4<Float>

    public init(
        position: SIMD3<Float>,
        uv: SIMD2<Float>,
        skinBlendIndices: SIMD4<Int32> = SIMD4<Int32>(0, 0, 0, 0),
        skinBlendWeights: SIMD4<Float> = SIMD4<Float>(1, 0, 0, 0)
    ) {
        self.position = position
        self.uv = uv
        self.skinBlendIndices = skinBlendIndices
        self.skinBlendWeights = skinBlendWeights
    }
}

public struct WPEPuppetBone: Equatable, Sendable {
    public let index: Int
    public let parentIndex: Int?
    /// Raw MDLS metadata retained for future runtime animation. Parser must not bake it into MDLV vertices.
    public let rawMatrix: [Float]
    /// Raw MDLS bone-name cstring (often a rig-physics JSON blob). Stored verbatim; not parsed here.
    public let name: String

    public init(index: Int, parentIndex: Int?, rawMatrix: [Float], name: String = "") {
        self.index = index
        self.parentIndex = parentIndex
        self.rawMatrix = rawMatrix
        self.name = name
    }
}

public struct WPEPuppetAttachment: Equatable, Sendable {
    public let name: String
    public let boneIndex: Int
    /// MDAT0001 bind transform in the parent puppet's model space, stored as 16 little-endian
    /// f32 in column-major simd/Metal order.
    public let bindMatrix: [Float]

    public init(name: String, boneIndex: Int, bindMatrix: [Float]) {
        self.name = name
        self.boneIndex = boneIndex
        self.bindMatrix = bindMatrix
    }

    public var matrix: simd_float4x4 {
        WPEMdlParser.matrix(fromColumnMajorFloats: bindMatrix) ?? matrix_identity_float4x4
    }
}

public struct WPEPuppetMeshPart: Hashable, Sendable {
    public let id: UInt32
    public let start: Int
    public let count: Int

    public init(id: UInt32, start: Int, count: Int) {
        self.id = id
        self.start = start
        self.count = count
    }
}

/// Baked skeletal animation from the MDLA section. Channels are stored in MDLS bone
/// order; each keyframe is a per-frame TRS transform (no curve interpolation in the file).
public struct WPEPuppetAnimation: Equatable, Sendable {
    public let id: Int
    public let name: String
    /// Playback mode from the file; "loop" drives the wrap in `sampledFrameIndex`.
    public let mode: String
    public let fps: Float
    public let frameCount: Int
    public let channels: [WPEPuppetAnimChannel]

    public init(id: Int, name: String, mode: String, fps: Float, frameCount: Int, channels: [WPEPuppetAnimChannel]) {
        self.id = id
        self.name = name
        self.mode = mode
        self.fps = fps
        self.frameCount = frameCount
        self.channels = channels
    }
}

public struct WPEPuppetAnimChannel: Equatable, Sendable {
    /// Skin-bone/channel index from MDLA (channels appear in bone order; no explicit id in
    /// the file). Usually matches MDLS bone order, but `WPEPuppetModel.bones` may be empty or
    /// malformed while channels stay usable — channels double as the skin skeleton (channel
    /// index == skin-blend index), with keyframe 0 as the bind pose.
    public let boneIndex: Int
    public let keyframes: [WPEPuppetAnimKey]

    public init(boneIndex: Int, keyframes: [WPEPuppetAnimKey]) {
        self.boneIndex = boneIndex
        self.keyframes = keyframes
    }
}

public struct WPEPuppetAnimKey: Equatable, Sendable {
    public let frame: Int
    /// Baked PARENT-LOCAL transform. Frame 0 is the bind local transform for the matching
    /// MDLS bone; world space is recovered by composing the parent channels' transforms.
    public let translation: SIMD3<Float>
    public let euler: SIMD3<Float>
    public let scale: SIMD3<Float>

    public init(frame: Int, translation: SIMD3<Float>, euler: SIMD3<Float>, scale: SIMD3<Float>) {
        self.frame = frame
        self.translation = translation
        self.euler = euler
        self.scale = scale
    }
}

/// One resolved puppet animation layer: an animation plus its playback `rate`, `blend` weight,
/// and whether it composes additively over the base layer (e.g. a blink/face layer over idle sway).
public struct WPEPuppetAnimationLayer: Equatable, Sendable {
    public let animation: WPEPuppetAnimation
    public let rate: Double
    public let additive: Bool
    public let blend: Float

    public init(animation: WPEPuppetAnimation, rate: Double, additive: Bool, blend: Float) {
        self.animation = animation
        self.rate = rate
        self.additive = additive
        self.blend = blend
    }
}

/// Skinning `palette` plus the diagnostics the render gate uses to decide whether skinning is
/// safe to enable for this puppet.
public struct WPEPuppetPaletteEvaluation: Equatable, Sendable {
    public enum TransformSpace: String, Equatable, Sendable {
        case parentLocal
    }

    public let palette: [simd_float4x4]
    public let paletteCount: Int
    public let transformSpace: TransformSpace?
    public let parentChannelMapSucceeded: Bool

    static let empty = WPEPuppetPaletteEvaluation(
        palette: [],
        paletteCount: 0,
        transformSpace: nil,
        parentChannelMapSucceeded: false
    )
}

/// Evaluates puppet animation layers into a per-bone skinning palette indexed by skin-blend (bone)
/// index. MDLS raw matrices are the inverse-bind ground truth; MDLS raw + MDLA channels are always
/// parent-local and composed down the hierarchy. `palette[boneIndex] = worldCurrent · worldBind⁻¹`.
/// The first non-additive layer is the base pose; additive layers add their per-bone
/// delta-from-bind on top in TRS space (translation/euler added, scale multiplied), weighted by
/// `blend`. Frame 0 of every layer is the bind pose, so the palette is identity there (regression
/// guard against the P0 static draw).
public enum WPEPuppetAnimationEvaluator {
    public static func palette(
        for animation: WPEPuppetAnimation,
        bones: [WPEPuppetBone] = [],
        at time: Double
    ) -> [simd_float4x4] {
        palette(
            layers: [WPEPuppetAnimationLayer(animation: animation, rate: 1, additive: false, blend: 1)],
            bones: bones,
            at: time
        )
    }

    public static func palette(
        layers: [WPEPuppetAnimationLayer],
        bones: [WPEPuppetBone],
        at time: Double
    ) -> [simd_float4x4] {
        evaluate(layers: layers, bones: bones, at: time).palette
    }

    public static func paletteEvaluation(
        layers: [WPEPuppetAnimationLayer],
        bones: [WPEPuppetBone],
        at time: Double
    ) -> WPEPuppetPaletteEvaluation {
        evaluate(layers: layers, bones: bones, at: time)
    }

    private static func evaluate(
        layers: [WPEPuppetAnimationLayer],
        bones: [WPEPuppetBone],
        at time: Double
    ) -> WPEPuppetPaletteEvaluation {
        guard let baseIndex = layers.indices.first(where: { !layers[$0].additive }) ?? layers.indices.first else {
            return .empty
        }
        let base = layers[baseIndex]
        let baseChannels = base.animation.channels
        guard !baseChannels.isEmpty else { return .empty }
        let requiredPaletteCount = paletteCount(for: baseChannels)

        let baseFrame = sampledFrameIndex(for: base.animation, at: time * base.rate)
        // Exclude the base layer by index (not by predicate): an all-additive stack must not
        // re-apply its own base layer's animation as an additive delta on top of itself.
        let additiveLayers: [(frame: Int, channelForBone: [Int: Int], channels: [WPEPuppetAnimChannel], weight: Float)] =
            layers.indices.compactMap { index in
                let layer = layers[index]
                guard index != baseIndex, layer.additive, !layer.animation.channels.isEmpty else { return nil }
                var channelForBone: [Int: Int] = [:]
                for (position, channel) in layer.animation.channels.enumerated() {
                    channelForBone[channel.boneIndex] = position
                }
                return (
                    sampledFrameIndex(for: layer.animation, at: time * layer.rate),
                    channelForBone,
                    layer.animation.channels,
                    max(0, min(Float(layer.blend), 1))
                )
            }

        // Every layer at its bind frame → identity palette (exact, no FP drift through the inverse),
        // but ONLY when the bind frame IS the MDLS raw bind (pre-assembled MDLV0021/0023). A
        // character-sheet puppet (MDLV0019/0020) ships an exploded MDLS bind whose frame-0 pose is the
        // *assembled* character, so its frame-0 palette (`assembled · exploded⁻¹`) is NOT identity — it
        // is what unfolds the sheet. Short-circuiting to identity there leaves the sheet exploded, so
        // fall through to the general hierarchy path for that case.
        if baseFrame == 0, additiveLayers.allSatisfy({ $0.frame == 0 }),
           baseFrameMatchesRawBind(channels: baseChannels, bones: bones) {
            return WPEPuppetPaletteEvaluation(
                palette: identityPalette(count: requiredPaletteCount),
                paletteCount: requiredPaletteCount,
                transformSpace: nil,
                parentChannelMapSucceeded: parentChannelMap(channels: baseChannels, bones: bones) != nil
            )
        }

        // Combined parent-LOCAL transform for a base channel: base pose plus each additive layer's
        // delta-from-its-own-bind in TRS space. `bind == true` yields the rest pose.
        func localMatrix(_ channelPosition: Int, bind: Bool) -> simd_float4x4 {
            let channel = baseChannels[channelPosition]
            guard let bindKey = channel.keyframes.first else { return matrix_identity_float4x4 }
            let baseKey = bind ? bindKey : channel.keyframes[min(baseFrame, channel.keyframes.count - 1)]
            var translation = baseKey.translation
            var euler = baseKey.euler
            var scale = baseKey.scale
            if !bind {
                for additive in additiveLayers {
                    guard let position = additive.channelForBone[channel.boneIndex],
                          let additiveBind = additive.channels[position].keyframes.first else { continue }
                    let keyframes = additive.channels[position].keyframes
                    let additiveCurrent = keyframes[min(additive.frame, keyframes.count - 1)]
                    translation += (additiveCurrent.translation - additiveBind.translation) * additive.weight
                    euler += (additiveCurrent.euler - additiveBind.euler) * additive.weight
                    scale *= additiveScaleRatio(
                        current: additiveCurrent.scale,
                        bind: additiveBind.scale,
                        base: scale,
                        weight: additive.weight
                    )
                }
            }
            return matrix(translation: translation, euler: euler, scale: scale)
        }

        guard let parentChannel = parentChannelMap(channels: baseChannels, bones: bones) else {
            // No usable skeleton hierarchy. A genuinely bone-less model (flat single-root rig or a
            // unit test) is correctly skinned by the independent path — each channel is its own root.
            // But a puppet that DOES ship bones whose hierarchy we could not reconstruct must fail
            // closed rather than mis-compose a partial skeleton (the old "torso perturbed" scatter);
            // the render gate additionally refuses to skin when `parentChannelMapSucceeded` is false.
            let palette = bones.isEmpty
                ? independentPalette(channels: baseChannels, localMatrix: localMatrix)
                : []
            return WPEPuppetPaletteEvaluation(
                palette: palette,
                paletteCount: requiredPaletteCount,
                transformSpace: nil,
                parentChannelMapSucceeded: false
            )
        }
        // MDLS raw + MDLA channels are always parent-local (oracle-confirmed); the previous
        // translation-only world/local auto-detect was refuted and removed.
        let space: WPEPuppetPaletteEvaluation.TransformSpace = .parentLocal
        let palette = hierarchyPalette(
            channels: baseChannels,
            bones: bones,
            parentChannel: parentChannel,
            localMatrix: localMatrix
        )
        return WPEPuppetPaletteEvaluation(
            palette: palette,
            paletteCount: requiredPaletteCount,
            transformSpace: space,
            parentChannelMapSucceeded: true
        )
    }

    private static func additiveScaleRatio(
        current: SIMD3<Float>,
        bind: SIMD3<Float>,
        base: SIMD3<Float>,
        weight: Float
    ) -> SIMD3<Float> {
        func axis(_ current: Float, _ bind: Float, _ base: Float) -> Float {
            guard abs(bind) > 1e-6 else {
                // Zero authored bind scale = a collapsed-at-rest bone (e.g. 3226487183's eyelids,
                // which inflate 0→1 over the blink). A delta ratio is undefined there, so lerp the
                // running scale toward the layer's ABSOLUTE authored scale: weight 1 reproduces
                // `current` exactly; the old `return 1` froze the bone at the base scale and tore
                // the mixed-weight eye vertices against their normally-squishing neighbours.
                guard abs(base) > 1e-6 else { return 1 }
                return 1 + (current / base - 1) * weight
            }
            return 1 + (current / bind - 1) * weight
        }
        return SIMD3<Float>(
            axis(current.x, bind.x, base.x),
            axis(current.y, bind.y, base.y),
            axis(current.z, bind.z, base.z)
        )
    }

    public static func identityPalette(count: Int) -> [simd_float4x4] {
        Array(repeating: matrix_identity_float4x4, count: max(count, 1))
    }

    /// True when every base channel's frame-0 keyframe reproduces its bone's MDLS raw bind matrix —
    /// i.e. the file ships pre-assembled (MDLV0021/0023) so the frame-0 palette is exactly identity.
    /// False for a character-sheet puppet (MDLV0019/0020) whose frame-0 pose is the assembled character
    /// atop an exploded MDLS bind, where the frame-0 palette must instead unfold the sheet.
    /// A channel lacking a raw bone matrix or a frame-0 key counts as NOT matching: the identity
    /// fast path must be proven for every channel, never assumed on missing data.
    public static func baseFrameMatchesRawBind(channels: [WPEPuppetAnimChannel], bones: [WPEPuppetBone]) -> Bool {
        let rawByBone = rawMatricesByBone(bones)
        guard !rawByBone.isEmpty else { return true }
        for channel in channels {
            guard let raw = rawByBone[channel.boneIndex], let key = channel.keyframes.first else { return false }
            let frame0 = matrix(translation: key.translation, euler: key.euler, scale: key.scale)
            if !simd_almost_equal_elements(frame0, raw, 1e-3) { return false }
        }
        return true
    }

    /// Bone-index → assembled bind-WORLD matrix, for the attachment anchor pivot and the skinning
    /// bind basis. Composes each bone's parent-local bind down the hierarchy. For a PRE-ASSEMBLED
    /// puppet (MDLV0021/0023) the local bind is the raw MDLS matrix. For a CHARACTER-SHEET puppet
    /// (MDLV0019/0020) the raw MDLS bind is the EXPLODED source-sheet layout, so the assembled anchor
    /// comes from the base animation's frame-0 keyframe pose (the same frame-0 that unfolds the mesh).
    /// The two are identical for pre-assembled puppets, so this is a no-op there. A bone whose parent
    /// is missing or is part of a cycle composes to its own local (bounded best-effort on malformed
    /// data). Uses the FIRST animation's frame-0: a character sheet's animations all start from the
    /// same authored reference pose (corpus-verified equal to ~0.05 across a puppet's clips), so the
    /// scene-selected base animation would give the same anchor within authoring noise.
    public static func assembledBindWorldByBone(model: WPEPuppetModel) -> [Int: simd_float4x4] {
        let baseChannels = model.animations.first?.channels ?? []
        let useFrame0 = !baseChannels.isEmpty
            && !baseFrameMatchesRawBind(channels: baseChannels, bones: model.bones)
        var frame0ByBone: [Int: simd_float4x4] = [:]
        if useFrame0 {
            for channel in baseChannels {
                guard let key = channel.keyframes.first else { continue }
                frame0ByBone[channel.boneIndex] = matrix(
                    translation: key.translation, euler: key.euler, scale: key.scale
                )
            }
        }
        let localByIndex = Dictionary(
            model.bones.compactMap { bone -> (Int, simd_float4x4)? in
                if let frame0 = frame0ByBone[bone.index] { return (bone.index, frame0) }
                return WPEMdlParser.matrix(fromColumnMajorFloats: bone.rawMatrix).map { (bone.index, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let parentByIndex = Dictionary(
            model.bones.map { ($0.index, $0.parentIndex) },
            uniquingKeysWith: { first, _ in first }
        )
        // A bone composes through its parent chain only when that chain is acyclic and fully present.
        // Any bone whose ancestry revisits a node resolves to its own local — so a cycle can never be
        // folded into a transform, and the recursion below is guaranteed to terminate.
        func chainIsAcyclic(_ start: Int) -> Bool {
            var seen: Set<Int> = [start]
            var current = parentByIndex[start] ?? nil
            while let bone = current, localByIndex[bone] != nil {
                if !seen.insert(bone).inserted { return false }
                current = parentByIndex[bone] ?? nil
            }
            return true
        }
        var cache: [Int: simd_float4x4] = [:]
        func world(_ index: Int) -> simd_float4x4 {
            if let cached = cache[index] { return cached }
            guard let local = localByIndex[index] else { return matrix_identity_float4x4 }
            let composed: simd_float4x4
            if let parent = parentByIndex[index] ?? nil, parent != index,
               localByIndex[parent] != nil, chainIsAcyclic(index) {
                composed = world(parent) * local
            } else {
                composed = local
            }
            cache[index] = composed
            return composed
        }
        var result: [Int: simd_float4x4] = [:]
        for bone in model.bones where localByIndex[bone.index] != nil {
            result[bone.index] = world(bone.index)
        }
        return result
    }

    /// Palette length must cover every skin-blend index the shader can sample
    /// (`bonePalette[skinBlendIndex]`), which is `maxBoneIndex + 1`, not merely the channel count.
    static func paletteCount(for channels: [WPEPuppetAnimChannel]) -> Int {
        let maxBoneIndex = channels.map(\.boneIndex).max() ?? -1
        return max(channels.count, maxBoneIndex + 1, 1)
    }

    public static func matrixIsFinite(_ matrix: simd_float4x4) -> Bool {
        for column in [matrix.columns.0, matrix.columns.1, matrix.columns.2, matrix.columns.3]
        where !(column.x.isFinite && column.y.isFinite && column.z.isFinite && column.w.isFinite) {
            return false
        }
        return true
    }

    /// Fallback when no usable skeleton hierarchy is supplied (unit tests / bone-less models):
    /// treat each channel as an independent transform. Indexed by bone index, like the hierarchy path.
    private static func independentPalette(
        channels: [WPEPuppetAnimChannel],
        localMatrix: (Int, Bool) -> simd_float4x4
    ) -> [simd_float4x4] {
        var palette = identityPalette(count: paletteCount(for: channels))
        for (position, channel) in channels.enumerated() {
            guard channel.boneIndex >= 0, channel.boneIndex < palette.count else { continue }
            let bind = localMatrix(position, true)
            let determinant = simd_determinant(bind)
            guard determinant.isFinite, abs(determinant) > 1e-6 else { continue }
            let result = localMatrix(position, false) * simd_inverse(bind)
            guard matrixIsFinite(result) else { continue }
            palette[channel.boneIndex] = result
        }
        return palette
    }

    /// Maps each channel to its parent channel index (or `nil` for a root). Returns `nil` when the
    /// supplied skeleton doesn't cover every channel's bone, so the caller falls back to the
    /// no-hierarchy path instead of mis-skinning against a partial skeleton.
    private static func parentChannelMap(
        channels: [WPEPuppetAnimChannel],
        bones: [WPEPuppetBone]
    ) -> [Int?]? {
        guard !bones.isEmpty, !channels.isEmpty else { return nil }
        var channelForBone: [Int: Int] = [:]
        for (position, channel) in channels.enumerated() {
            channelForBone[channel.boneIndex] = position
        }
        var parentByBone: [Int: Int?] = [:]
        for bone in bones {
            parentByBone[bone.index] = bone.parentIndex
        }
        var parentChannel = [Int?](repeating: nil, count: channels.count)
        for (position, channel) in channels.enumerated() {
            guard let parentOptional = parentByBone[channel.boneIndex] else {
                return nil
            }
            if let parentBone = parentOptional {
                guard let parentPosition = channelForBone[parentBone] else {
                    // Parent bone has no animation channel → can't compose a correct world
                    // transform. Bail to the no-hierarchy fallback rather than mis-bind.
                    return nil
                }
                if parentPosition != position {
                    parentChannel[position] = parentPosition
                }
            }
        }
        return parentChannel
    }

    public static func hasUsableHierarchy(layers: [WPEPuppetAnimationLayer], bones: [WPEPuppetBone]) -> Bool {
        guard let base = layers.first(where: { !$0.additive }) ?? layers.first else { return false }
        return parentChannelMap(channels: base.animation.channels, bones: bones) != nil
    }

    private static func rawMatricesByBone(_ bones: [WPEPuppetBone]) -> [Int: simd_float4x4] {
        Dictionary(uniqueKeysWithValues: bones.compactMap { bone -> (Int, simd_float4x4)? in
            guard let raw = WPEMdlParser.matrix(fromColumnMajorFloats: bone.rawMatrix) else { return nil }
            return (bone.index, raw)
        })
    }

    private static func hierarchyPalette(
        channels: [WPEPuppetAnimChannel],
        bones: [WPEPuppetBone],
        parentChannel: [Int?],
        localMatrix: (Int, Bool) -> simd_float4x4
    ) -> [simd_float4x4] {
        let rawByBone = rawMatricesByBone(bones)

        func worldMatrices(bind: Bool) -> [simd_float4x4] {
            // Both the MDLS raw matrices (bind pose) and the MDLA channel keyframes (current pose) are
            // stored PARENT-LOCAL, so a bone's WORLD transform is recovered by composing it onto its
            // parent's world transform. Bind and current are composed identically: the palette
            // (`current · bind⁻¹`) is then exactly identity in the rest pose, and a parent bone's motion
            // flows into every descendant. Without this, a high bone's breathing/sway/blink never
            // reaches the bones it drives and the puppet skins nearly static.
            //
            // Oracle-validated against Wallpaper Engine `g_Bones` (RenderDoc, WPE 2.8.26): scenes
            // 3461168300 (Plana, 53 bones) and 3554161528 (32 bones) match WPE to <0.1 / <6 total
            // Frobenius across all bones, vs ~70–190 with the previous code, which used the raw matrices
            // as world bind directly (uncomposed) and a translation-only `worldAbsolute` auto-detect
            // that always misfired here because each bone's frame-0 local equals its raw local.
            var cache = [simd_float4x4?](repeating: nil, count: channels.count)
            for _ in 0..<channels.count {
                var progress = false
                for index in 0..<channels.count {
                    if cache[index] != nil { continue }
                    
                    let local = bind
                        ? (rawByBone[channels[index].boneIndex] ?? localMatrix(index, true))
                        : localMatrix(index, false)
                    
                    if let parent = parentChannel[index] {
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
            
            for index in 0..<channels.count {
                if cache[index] == nil {
                    cache[index] = matrix_identity_float4x4
                }
            }
            return cache.compactMap { $0 }
        }

        let bindWorld = worldMatrices(bind: true)
        let currentWorld = worldMatrices(bind: false)
        // Output is indexed by skin-blend (bone) index — the shader samples bonePalette[skinIndex],
        // which only equals the channel position under the parser's boneIndex==channelIndex invariant.
        var palette = identityPalette(count: paletteCount(for: channels))
        for position in 0..<channels.count {
            let boneIndex = channels[position].boneIndex
            guard boneIndex >= 0, boneIndex < palette.count else { continue }
            let bind = bindWorld[position]
            let determinant = simd_determinant(bind)
            guard determinant.isFinite, abs(determinant) > 1e-6 else { continue }
            let result = currentWorld[position] * simd_inverse(bind)
            guard matrixIsFinite(result) else { continue }
            palette[boneIndex] = result
        }
        return palette
    }

    public static func sampledFrameIndex(for animation: WPEPuppetAnimation, at time: Double) -> Int {
        let fps = Double(animation.fps)
        guard fps.isFinite, fps > 0 else { return 0 }
        let playableFrameCount = max(animation.frameCount, 1)
        let frameValue = floor(max(time, 0) * fps)
        guard frameValue.isFinite, frameValue < Double(Int.max) else { return 0 }
        let rawFrame = max(Int(frameValue), 0)
        let mode = animation.mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if mode == "loop" {
            return rawFrame % playableFrameCount
        }
        if mode == "mirror" {
            // Ping-pong: 0,1,...,N-1,N-2,...,1,0,1,... — a full period revisits both end frames
            // once each rather than holding on them, so the period is 2*(N-1), not 2*N.
            guard playableFrameCount > 1 else { return 0 }
            let period = 2 * (playableFrameCount - 1)
            let phase = rawFrame % period
            return phase < playableFrameCount ? phase : period - phase
        }
        return min(rawFrame, playableFrameCount - 1)
    }

    private static func matrix(
        translation: SIMD3<Float>,
        euler: SIMD3<Float>,
        scale: SIMD3<Float>
    ) -> simd_float4x4 {
        translationMatrix(translation) * rotationMatrix(euler: euler) * scaleMatrix(scale)
    }

    /// ON-DEVICE VALIDATION POINT: MDLA Euler components are assumed to be radians in
    /// intrinsic XYZ order. With column-vector matrices the transform composes as
    /// `T * Rz * Ry * Rx * S`. Frame 0 is always identity regardless, so only the
    /// inter-frame rotation direction depends on this assumption.
    private static func rotationMatrix(euler: SIMD3<Float>) -> simd_float4x4 {
        rotationZ(euler.z) * rotationY(euler.y) * rotationX(euler.x)
    }

    private static func translationMatrix(_ t: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(t.x, t.y, t.z, 1)
        )
    }

    private static func scaleMatrix(_ s: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(
            SIMD4<Float>(s.x, 0, 0, 0),
            SIMD4<Float>(0, s.y, 0, 0),
            SIMD4<Float>(0, 0, s.z, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
    }

    private static func rotationX(_ angle: Float) -> simd_float4x4 {
        let c = cos(angle), s = sin(angle)
        return simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, c, s, 0),
            SIMD4<Float>(0, -s, c, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
    }

    private static func rotationY(_ angle: Float) -> simd_float4x4 {
        let c = cos(angle), s = sin(angle)
        return simd_float4x4(
            SIMD4<Float>(c, 0, -s, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(s, 0, c, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
    }

    private static func rotationZ(_ angle: Float) -> simd_float4x4 {
        let c = cos(angle), s = sin(angle)
        return simd_float4x4(
            SIMD4<Float>(c, s, 0, 0),
            SIMD4<Float>(-s, c, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
    }
}

private final class WPEMdlParseAuditRecorder {
    fileprivate struct OpenSection {
        let kind: WPEMdlParseAudit.SectionKind
        let label: String
        let start: Int
        var skips: [WPEMdlParseAudit.KnownSkip]
    }

    struct Checkpoint {
        fileprivate let sectionsCount: Int
        fileprivate let openSection: OpenSection?
    }

    private let dataCount: Int
    private var sections: [WPEMdlParseAudit.SectionRecord] = []
    private var openSection: OpenSection?

    init(dataCount: Int) {
        self.dataCount = dataCount
    }

    func beginSection(kind: WPEMdlParseAudit.SectionKind, label: String, start: Int) {
        openSection = OpenSection(kind: kind, label: label, start: start, skips: [])
    }

    func endSection(at end: Int) {
        guard let section = openSection else { return }
        sections.append(WPEMdlParseAudit.SectionRecord(
            kind: section.kind,
            label: section.label,
            range: section.start..<end,
            intentionallySkippedRanges: section.skips
        ))
        openSection = nil
    }

    func recordKnownSkip(label: String, range: Range<Int>) {
        guard !range.isEmpty, var section = openSection else { return }
        section.skips.append(WPEMdlParseAudit.KnownSkip(label: label, range: range))
        openSection = section
    }

    func checkpoint() -> Checkpoint {
        Checkpoint(sectionsCount: sections.count, openSection: openSection)
    }

    func rollback(to checkpoint: Checkpoint) {
        if sections.count > checkpoint.sectionsCount {
            sections.removeSubrange(checkpoint.sectionsCount..<sections.count)
        }
        openSection = checkpoint.openSection
    }

    func makeAudit() -> WPEMdlParseAudit {
        let sortedSections = sections.sorted {
            if $0.range.lowerBound != $1.range.lowerBound {
                return $0.range.lowerBound < $1.range.lowerBound
            }
            return $0.range.upperBound < $1.range.upperBound
        }
        var gaps: [WPEMdlParseAudit.Gap] = []
        var coveredEnd = 0
        for section in sortedSections {
            if section.range.lowerBound > coveredEnd {
                gaps.append(WPEMdlParseAudit.Gap(range: coveredEnd..<section.range.lowerBound))
            }
            coveredEnd = max(coveredEnd, section.range.upperBound)
        }
        let trailingLeftover = coveredEnd < dataCount ? coveredEnd..<dataCount : nil
        return WPEMdlParseAudit(
            sections: sortedSections,
            unexplainedGaps: gaps,
            trailingLeftover: trailingLeftover
        )
    }
}

public enum WPEMdlParser {
    /// Counts come straight from untrusted Workshop bytes: a crafted header claiming up to
    /// 0xFFFFFFFF entries would drive `reserveCapacity` into a multi-GB allocation (OOM trap)
    /// before the read loop could fail naturally on truncation. Caps sit far above the corpus
    /// maxima (dozens of meshes, ≤89 bones observed) — same idea as the MDLA 1024-animation cap.
    private static let maxMeshCount: UInt32 = 4_096
    private static let maxBoneCount: UInt32 = 4_096

    public static func parse(data: Data) throws -> WPEPuppetModel {
        try parse(data: data, auditRecorder: nil)
    }

    public static func parse(data: Data, audit: inout WPEMdlParseAudit?) throws -> WPEPuppetModel {
        audit = nil
        let auditRecorder = WPEMdlParseAuditRecorder(dataCount: data.count)
        let model = try parse(data: data, auditRecorder: auditRecorder)
        audit = auditRecorder.makeAudit()
        return model
    }

    private static func parse(
        data: Data,
        auditRecorder: WPEMdlParseAuditRecorder?
    ) throws -> WPEPuppetModel {
        var reader = WPEMdlBinaryReader(data: data)
        auditRecorder?.beginSection(kind: .mdlvHeader, label: "MDLV header", start: reader.currentOffset)
        let versionTag = try reader.readFixedString(byteCount: 8)
        guard versionTag.hasPrefix("MDLV"),
              let version = Int(versionTag.dropFirst(4)) else {
            throw WPEMdlParserError.invalidHeader
        }

        let headerMeshFlags = try reader.readUInt32()
        let meshCount: UInt32
        // The model header carries a leading byte before `meshCount` for the
        // corpus formats we can render directly (MDLV0016 scene meshes and
        // MDLV0019/0021/0023 puppets all use `u8 + u32 meshCount + u32`). Routing
        // these down the legacy no-leading-byte branch misaligns the cursor by
        // one byte, inflates counts/byte sizes to garbage, and aborts the parse.
        if version == 16 || version >= 19 {
            try readIgnoredUInt8(reader: &reader, auditRecorder: auditRecorder, label: "MDLV header marker")
            meshCount = try reader.readUInt32()
            try readIgnoredUInt32(reader: &reader, auditRecorder: auditRecorder, label: "MDLV header padding")
        } else {
            try readIgnoredUInt32(reader: &reader, auditRecorder: auditRecorder, label: "MDLV header padding")
            meshCount = try reader.readUInt32()
        }
        auditRecorder?.endSection(at: reader.currentOffset)
        guard meshCount <= maxMeshCount else {
            throw WPEMdlParserError.implausibleCount(
                section: "MDLV meshCount", count: meshCount, limit: maxMeshCount
            )
        }
        var meshes: [WPEPuppetMesh] = []
        meshes.reserveCapacity(Int(meshCount))

        for meshIndex in 0..<Int(meshCount) {
            meshes.append(try parseMesh(
                version: version,
                headerMeshFlags: headerMeshFlags,
                meshIndex: meshIndex,
                auditRecorder: auditRecorder,
                reader: &reader
            ))
        }

        // MDLV positions are already the static target geometry. The MDLS skeleton and
        // MDLA animation sections are OPTIONAL metadata the current static draw path does
        // not consume (reserved for future bone skinning). A malformed or edge-case section
        // must never discard the already-parsed, renderable mesh geometry — otherwise the
        // whole puppet collapses to nil and the object degrades to a flat, scattered atlas
        // (observed on MDLV0023 scene 3479521040 "人物"). Parse each defensively on its own
        // cursor and recover the meshes, dropping only the failed section's metadata.
        var metadataReader = reader
        let bones: [WPEPuppetBone]
        let skeletonAuditCheckpoint = auditRecorder?.checkpoint()
        do {
            bones = try parseSkeletonIfPresent(reader: &metadataReader, auditRecorder: auditRecorder)
        } catch {
            if let skeletonAuditCheckpoint {
                auditRecorder?.rollback(to: skeletonAuditCheckpoint)
            }
            Logger.warning(
                "WPE puppet MDL skeleton parse failed; rendering the static mesh without bones: \(error)",
                category: .wpeRender
            )
            bones = []
            metadataReader = reader
        }

        let attachments: [WPEPuppetAttachment]
        let attachmentAuditCheckpoint = auditRecorder?.checkpoint()
        do {
            var attachmentReader = metadataReader
            attachments = try parseAttachmentsIfPresent(reader: &attachmentReader, auditRecorder: auditRecorder)
            metadataReader = attachmentReader
        } catch {
            if let attachmentAuditCheckpoint {
                auditRecorder?.rollback(to: attachmentAuditCheckpoint)
            }
            Logger.warning(
                "WPE puppet MDL attachment parse failed; rendering without MDAT anchors: \(error)",
                category: .wpeRender
            )
            attachments = []
        }

        let animations: [WPEPuppetAnimation]
        let animationAuditCheckpoint = auditRecorder?.checkpoint()
        do {
            animations = try parseAnimationsIfPresent(reader: &metadataReader, auditRecorder: auditRecorder)
        } catch {
            if let animationAuditCheckpoint {
                auditRecorder?.rollback(to: animationAuditCheckpoint)
            }
            Logger.warning(
                "WPE puppet MDL animation parse failed; rendering the static mesh without animations: \(error)",
                category: .wpeRender
            )
            animations = []
        }

        return WPEPuppetModel(
            version: version,
            meshes: meshes,
            bones: bones,
            animations: animations,
            attachments: attachments
        )
    }

    private static func readIgnoredUInt8(
        reader: inout WPEMdlBinaryReader,
        auditRecorder: WPEMdlParseAuditRecorder?,
        label: String
    ) throws {
        let start = reader.currentOffset
        _ = try reader.readUInt8()
        auditRecorder?.recordKnownSkip(label: label, range: start..<reader.currentOffset)
    }

    private static func readIgnoredUInt16(
        reader: inout WPEMdlBinaryReader,
        auditRecorder: WPEMdlParseAuditRecorder?,
        label: String
    ) throws {
        let start = reader.currentOffset
        _ = try reader.readUInt16()
        auditRecorder?.recordKnownSkip(label: label, range: start..<reader.currentOffset)
    }

    private static func readIgnoredUInt32(
        reader: inout WPEMdlBinaryReader,
        auditRecorder: WPEMdlParseAuditRecorder?,
        label: String
    ) throws {
        let start = reader.currentOffset
        _ = try reader.readUInt32()
        auditRecorder?.recordKnownSkip(label: label, range: start..<reader.currentOffset)
    }

    private static func skipKnownBytes(
        byteCount: Int,
        reader: inout WPEMdlBinaryReader,
        auditRecorder: WPEMdlParseAuditRecorder?,
        label: String
    ) throws {
        let start = reader.currentOffset
        try reader.skip(byteCount: byteCount)
        auditRecorder?.recordKnownSkip(label: label, range: start..<reader.currentOffset)
    }

    private static func parseMesh(
        version: Int,
        headerMeshFlags: UInt32,
        meshIndex: Int,
        auditRecorder: WPEMdlParseAuditRecorder?,
        reader: inout WPEMdlBinaryReader
    ) throws -> WPEPuppetMesh {
        auditRecorder?.beginSection(
            kind: .mdlvMesh,
            label: "MDLV mesh \(meshIndex)",
            start: reader.currentOffset
        )
        let materialPath = try reader.readCString()
        let flagA = try reader.readUInt32()
        if flagA == 2 {
            try readIgnoredUInt32(reader: &reader, auditRecorder: auditRecorder, label: "MDLV mesh flag payload")
        }
        if version >= 17 {
            try skipKnownBytes(
                byteCount: 6 * MemoryLayout<Float>.size,
                reader: &reader,
                auditRecorder: auditRecorder,
                label: "MDLV mesh bounds block"
            )
        }
        let meshFlags = version > 14 ? try reader.readUInt32() : headerMeshFlags
        let vertexByteCount = try reader.readUInt32()
        let vertexStride = stride(for: meshFlags)
        guard vertexStride > 0, vertexByteCount % UInt32(vertexStride) == 0 else {
            throw WPEMdlParserError.invalidVertexBuffer(byteCount: vertexByteCount, stride: vertexStride)
        }
        // The declared buffer must fit in the remaining bytes — otherwise a crafted byte count
        // (up to 4 GiB) would size `reserveCapacity` long before the reads hit truncation.
        guard Int(vertexByteCount) <= reader.dataCount - reader.currentOffset else {
            throw WPEMdlParserError.invalidVertexBuffer(byteCount: vertexByteCount, stride: vertexStride)
        }
        let vertexCount = vertexByteCount / UInt32(vertexStride)
        var vertices: [WPEPuppetVertex] = []
        vertices.reserveCapacity(Int(vertexCount))

        for _ in 0..<vertexCount {
            vertices.append(try parseVertex(
                meshFlags: meshFlags,
                auditRecorder: auditRecorder,
                reader: &reader
            ))
        }

        let indexByteCount = try reader.readUInt32()
        guard indexByteCount % UInt32(MemoryLayout<UInt16>.size) == 0,
              Int(indexByteCount) <= reader.dataCount - reader.currentOffset else {
            throw WPEMdlParserError.invalidIndexBuffer(indexByteCount)
        }
        let indexCount = indexByteCount / UInt32(MemoryLayout<UInt16>.size)
        var indices: [UInt16] = []
        indices.reserveCapacity(Int(indexCount))
        for _ in 0..<indexCount {
            indices.append(try reader.readUInt16())
        }

        let parts = version >= 21
            ? try parseVersion21Parts(
                vertexCount: Int(vertexCount),
                auditRecorder: auditRecorder,
                reader: &reader
            )
            : []

        // Optional clip section follows the part table. Read from a COPY so the main reader is
        // untouched — MDLS/MDLA are located by tag search regardless.
        let clipMaskName = version >= 21 ? parseClipMaskName(reader: reader) : nil

        let mesh = WPEPuppetMesh(
            materialPath: materialPath,
            vertices: vertices,
            indices: indices,
            parts: parts,
            clipMaskName: clipMaskName
        )
        auditRecorder?.endSection(at: reader.currentOffset)
        return mesh
    }

    /// Best-effort parse of the MDLV clip section that follows the part table:
    /// `u32 groupCount | per group: u32, u32, cstring maskName, ...`. Returns the clip-mask texture
    /// name (e.g. `masks/clipping_mask_39cb32c5`) or nil. Defensive: bails on implausible data so a
    /// puppet without a clip section (part table directly followed by the next section) degrades to nil.
    private static func parseClipMaskName(reader: WPEMdlBinaryReader) -> String? {
        var r = reader
        guard let groupCount = try? r.readUInt32(), groupCount >= 1, groupCount <= 64,
              (try? r.readUInt32()) != nil, (try? r.readUInt32()) != nil,
              let name = try? r.readCString(),
              !name.isEmpty, name.utf8.count <= 256,
              name.contains("mask") else {
            return nil
        }
        return name
    }

    private static func parseVertex(
        meshFlags: UInt32,
        auditRecorder: WPEMdlParseAuditRecorder?,
        reader: inout WPEMdlBinaryReader
    ) throws -> WPEPuppetVertex {
        let position = SIMD3<Float>(
            try reader.readFloat(),
            try reader.readFloat(),
            try reader.readFloat()
        )

        if meshFlags & WPEMdlMeshFlags.normal != 0 {
            try skipKnownBytes(
                byteCount: 3 * MemoryLayout<Float>.size,
                reader: &reader,
                auditRecorder: auditRecorder,
                label: "MDLV vertex normal"
            )
        }
        if meshFlags & WPEMdlMeshFlags.tangent != 0 {
            try skipKnownBytes(
                byteCount: 4 * MemoryLayout<Float>.size,
                reader: &reader,
                auditRecorder: auditRecorder,
                label: "MDLV vertex tangent"
            )
        }
        if meshFlags & WPEMdlMeshFlags.extra4 != 0 {
            try skipKnownBytes(
                byteCount: 4 * MemoryLayout<Float>.size,
                reader: &reader,
                auditRecorder: auditRecorder,
                label: "MDLV vertex extra4"
            )
        }
        var skinBlendIndices = SIMD4<Int32>(0, 0, 0, 0)
        var skinBlendWeights = SIMD4<Float>(0, 0, 0, 0)
        if meshFlags & WPEMdlMeshFlags.skinBlendIndices != 0 {
            // Skin-blend indices are 4× little-endian Int32 (not floats, which
            // the old decode misread — collapsing every index to bone 0).
            skinBlendIndices = SIMD4<Int32>(
                try reader.readInt32(),
                try reader.readInt32(),
                try reader.readInt32(),
                try reader.readInt32()
            )
        }
        if meshFlags & WPEMdlMeshFlags.skinBlendWeights != 0 {
            skinBlendWeights = SIMD4<Float>(
                try reader.readFloat(),
                try reader.readFloat(),
                try reader.readFloat(),
                try reader.readFloat()
            )
        }

        let uv: SIMD2<Float>
        if meshFlags & WPEMdlMeshFlags.uv != 0 {
            uv = SIMD2<Float>(try reader.readFloat(), try reader.readFloat())
        } else {
            uv = SIMD2<Float>(0, 0)
        }
        if meshFlags & WPEMdlMeshFlags.uv2 != 0 {
            try skipKnownBytes(
                byteCount: 2 * MemoryLayout<Float>.size,
                reader: &reader,
                auditRecorder: auditRecorder,
                label: "MDLV vertex uv2"
            )
        }

        return WPEPuppetVertex(
            position: position,
            uv: uv,
            skinBlendIndices: skinBlendIndices,
            skinBlendWeights: skinBlendWeights
        )
    }

    private static func stride(for meshFlags: UInt32) -> Int {
        var stride = 3 * MemoryLayout<Float>.size
        if meshFlags & WPEMdlMeshFlags.normal != 0 {
            stride += 3 * MemoryLayout<Float>.size
        }
        if meshFlags & WPEMdlMeshFlags.tangent != 0 {
            stride += 4 * MemoryLayout<Float>.size
        }
        if meshFlags & WPEMdlMeshFlags.extra4 != 0 {
            stride += 4 * MemoryLayout<Float>.size
        }
        if meshFlags & WPEMdlMeshFlags.skinBlendIndices != 0 {
            stride += 4 * MemoryLayout<Float>.size
        }
        if meshFlags & WPEMdlMeshFlags.skinBlendWeights != 0 {
            stride += 4 * MemoryLayout<Float>.size
        }
        if meshFlags & WPEMdlMeshFlags.uv != 0 {
            stride += 2 * MemoryLayout<Float>.size
        }
        if meshFlags & WPEMdlMeshFlags.uv2 != 0 {
            stride += 2 * MemoryLayout<Float>.size
        }
        return stride
    }

    private static func parseVersion21Parts(
        vertexCount: Int,
        auditRecorder: WPEMdlParseAuditRecorder?,
        reader: inout WPEMdlBinaryReader
    ) throws -> [WPEPuppetMeshPart] {
        let uv2Marker = try reader.readUInt8()
        if uv2Marker == 1 {
            let hasUV2Payload = try reader.readUInt8()
            if hasUV2Payload != 0 {
                try readIgnoredUInt16(reader: &reader, auditRecorder: auditRecorder, label: "MDLV uv2 payload marker")
                try readIgnoredUInt8(reader: &reader, auditRecorder: auditRecorder, label: "MDLV uv2 payload flag")
                let payloadSize = try reader.readUInt32()
                let expectedSize = UInt32(vertexCount * 12)
                try skipKnownBytes(
                    byteCount: Int(max(payloadSize, expectedSize)),
                    reader: &reader,
                    auditRecorder: auditRecorder,
                    label: "MDLV uv2 payload"
                )
            }
        } else if uv2Marker != 0 {
            throw WPEMdlParserError.unsupportedSectionMarker(uv2Marker)
        }

        let hasParts = try reader.readUInt8()
        guard hasParts != 0 else { return [] }

        let byteCount = try reader.readUInt32()
        guard byteCount % 16 == 0,
              Int(byteCount) <= reader.dataCount - reader.currentOffset else {
            throw WPEMdlParserError.invalidPartTable(byteCount)
        }
        let partCount = Int(byteCount / 16)
        var parts: [WPEPuppetMeshPart] = []
        parts.reserveCapacity(partCount)
        for _ in 0..<partCount {
            let id = try reader.readUInt32()
            try readIgnoredUInt32(reader: &reader, auditRecorder: auditRecorder, label: "MDLV part reserved")
            let start = try reader.readUInt32()
            let count = try reader.readUInt32()
            parts.append(WPEPuppetMeshPart(id: id, start: Int(start), count: Int(count)))
        }
        return parts
    }

    private static func parseSkeletonIfPresent(
        reader: inout WPEMdlBinaryReader,
        auditRecorder: WPEMdlParseAuditRecorder?
    ) throws -> [WPEPuppetBone] {
        guard let skeletonOffset = reader.findTag("MDLS", from: reader.currentOffset) else {
            return []
        }
        try reader.seek(to: skeletonOffset)

        let skeletonTag = try reader.readFixedString(byteCount: 8)
        guard skeletonTag.hasPrefix("MDLS") else { return [] }
        auditRecorder?.beginSection(kind: .mdls, label: skeletonTag, start: skeletonOffset)
        try readIgnoredUInt8(reader: &reader, auditRecorder: auditRecorder, label: "MDLS section flag")
        let declaredSectionEnd = Int(try reader.readUInt32())
        let boneCount = try reader.readUInt32()
        let skeletonSectionEnd = declaredSectionEnd > reader.currentOffset
            ? min(declaredSectionEnd, reader.dataCount)
            : reader.dataCount

        guard boneCount <= maxBoneCount else {
            throw WPEMdlParserError.implausibleCount(
                section: "MDLS boneCount", count: boneCount, limit: maxBoneCount
            )
        }
        var bones: [WPEPuppetBone] = []
        bones.reserveCapacity(Int(boneCount))
        for index in 0..<boneCount {
            try readIgnoredUInt32(reader: &reader, auditRecorder: auditRecorder, label: "MDLS bone id")
            try readIgnoredUInt8(reader: &reader, auditRecorder: auditRecorder, label: "MDLS bone flag")
            let parent = try reader.readInt32()
            let matrixByteCount = try reader.readUInt32()
            guard matrixByteCount >= 16 * UInt32(MemoryLayout<Float>.size),
                  matrixByteCount % UInt32(MemoryLayout<Float>.size) == 0 else {
                throw WPEMdlParserError.invalidSkeletonMatrix(matrixByteCount)
            }

            var matrix: [Float] = []
            matrix.reserveCapacity(16)
            for componentIndex in 0..<Int(matrixByteCount / UInt32(MemoryLayout<Float>.size)) {
                let componentStart = reader.currentOffset
                let value = try reader.readFloat()
                if componentIndex < 16 {
                    matrix.append(value)
                } else {
                    auditRecorder?.recordKnownSkip(
                        label: "MDLS matrix extra component",
                        range: componentStart..<reader.currentOffset
                    )
                }
            }
            let name = try reader.readCString()
            if index + 1 < boneCount {
                if let paddingRange = try reader.consumeOptionalSkeletonTrailingMarker(
                    boneCount: Int(boneCount),
                    sectionEnd: skeletonSectionEnd
                ) {
                    auditRecorder?.recordKnownSkip(label: "MDLS record padding", range: paddingRange)
                }
            }

            bones.append(WPEPuppetBone(
                index: Int(index),
                parentIndex: parent >= 0 ? Int(parent) : nil,
                rawMatrix: matrix,
                name: name
            ))
        }
        if skeletonSectionEnd <= reader.dataCount {
            let paddingStart = reader.currentOffset
            try reader.seek(to: skeletonSectionEnd)
            auditRecorder?.recordKnownSkip(label: "MDLS section padding", range: paddingStart..<reader.currentOffset)
        }
        auditRecorder?.endSection(at: reader.currentOffset)
        return bones
    }

    public static func matrix(fromColumnMajorFloats values: [Float]) -> simd_float4x4? {
        guard values.count >= 16 else { return nil }
        return simd_float4x4(
            SIMD4<Float>(values[0], values[1], values[2], values[3]),
            SIMD4<Float>(values[4], values[5], values[6], values[7]),
            SIMD4<Float>(values[8], values[9], values[10], values[11]),
            SIMD4<Float>(values[12], values[13], values[14], values[15])
        )
    }

    /// MDAT0001 attachment anchors (between MDLS and MDLA). Layout validated against the on-disk
    /// corpus (Kal'tsit 主体: 头部→5/脖颈→3/胸部→1; 长发3: 头发附件→0):
    ///
    /// - Section: tag(8) + flag u8 + sectionEnd u32 + anchorCount **u16**.
    /// - Per anchor: boneIndex **u16**, name cstring (UTF-8), 16 little-endian f32 column-major
    ///   bind matrix (bone-local anchor offset).
    private static func parseAttachmentsIfPresent(
        reader: inout WPEMdlBinaryReader,
        auditRecorder: WPEMdlParseAuditRecorder?
    ) throws -> [WPEPuppetAttachment] {
        guard let attachmentOffset = reader.findTag("MDAT", from: reader.currentOffset) else {
            return []
        }
        // MDAT precedes MDLA in the section order; if the next MDAT lies past MDLA it is a false
        // positive inside the animation payload, so there is no real attachment section to read.
        if let animationOffset = reader.findTag("MDLA", from: reader.currentOffset),
           animationOffset < attachmentOffset {
            return []
        }
        try reader.seek(to: attachmentOffset)
        let tag = try reader.readFixedString(byteCount: 8)
        guard tag == "MDAT0001" else { return [] }
        auditRecorder?.beginSection(kind: .mdat, label: tag, start: attachmentOffset)
        try readIgnoredUInt8(reader: &reader, auditRecorder: auditRecorder, label: "MDAT section flag")
        let declaredSectionEnd = Int(try reader.readUInt32())
        let anchorCount = try reader.readUInt16()
        let sectionEnd = declaredSectionEnd > reader.currentOffset
            ? min(declaredSectionEnd, reader.dataCount)
            : reader.dataCount

        var attachments: [WPEPuppetAttachment] = []
        attachments.reserveCapacity(Int(anchorCount))
        for _ in 0..<anchorCount {
            // Keep every read inside the declared section; a false-positive `MDAT` tag would otherwise
            // read garbage anchors from neighbouring data. On overrun, bail to the no-attachment path.
            guard reader.currentOffset + 2 <= sectionEnd else {
                throw WPEMdlParserError.invalidAttachmentHeader(offset: attachmentOffset)
            }
            let boneIndex = Int(try reader.readUInt16())
            let name = try reader.readCString(sectionEnd: sectionEnd)
            guard reader.currentOffset + 16 * MemoryLayout<Float>.size <= sectionEnd else {
                throw WPEMdlParserError.invalidAttachmentHeader(offset: attachmentOffset)
            }
            var matrix: [Float] = []
            matrix.reserveCapacity(16)
            for _ in 0..<16 { matrix.append(try reader.readFloat()) }
            attachments.append(WPEPuppetAttachment(name: name, boneIndex: boneIndex, bindMatrix: matrix))
        }
        if sectionEnd <= reader.dataCount {
            let paddingStart = reader.currentOffset
            try reader.seek(to: sectionEnd)
            auditRecorder?.recordKnownSkip(label: "MDAT section padding", range: paddingStart..<reader.currentOffset)
        }
        auditRecorder?.endSection(at: reader.currentOffset)
        return attachments
    }

    /// One keyframe = 9 little-endian f32: [Tx,Ty,Tz, Rx,Ry,Rz, Sx,Sy,Sz].
    private static let animationKeyByteCount = 9 * MemoryLayout<Float>.size

    /// MDLA0005 (v19) / MDLA0006 (v21/v23) baked skeletal animation. Layout (read-only
    /// validated against the on-disk corpus: 3479521040/人物 55ch anim 267/777, 3554161528/人物,
    /// 3351072238/伊蕾娜 MDLS0003, 3704273480/身体拆分 89 bones, 2955378002/rennee MDLA0005):
    ///
    /// - Section: tag(8) + flag u8 + sectionEnd u32 + animationCount u32.
    /// - Per animation: id u32, reserved u32(0), name cstring, mode cstring, fps f32,
    ///   frameCount u32, reserved u32(0), channelCount u32, reserved u32(0), channelByteCount u32.
    /// - channelByteCount == (frameCount + 1) * 36. Channel-major; each channel stores frames
    ///   0...frameCount as `animationKeyByteCount` records, then an 8-byte delimiter
    ///   (u32 0 + u32 channelByteCount) before the next channel. Channels map to MDLS bone order.
    /// - A short zero-padding tail separates animations; scan to the next plausible header.
    private static func parseAnimationsIfPresent(
        reader: inout WPEMdlBinaryReader,
        auditRecorder: WPEMdlParseAuditRecorder?
    ) throws -> [WPEPuppetAnimation] {
        guard let animationOffset = reader.findTag("MDLA", from: reader.currentOffset) else {
            return []
        }
        try reader.seek(to: animationOffset)

        let animationTag = try reader.readFixedString(byteCount: 8)
        guard animationTag == "MDLA0005" || animationTag == "MDLA0006" else { return [] }
        auditRecorder?.beginSection(kind: .mdla, label: animationTag, start: animationOffset)
        try readIgnoredUInt8(reader: &reader, auditRecorder: auditRecorder, label: "MDLA section flag")
        let declaredSectionEnd = Int(try reader.readUInt32())
        let animationCount = try reader.readUInt32()
        let sectionEnd = declaredSectionEnd > reader.currentOffset
            ? min(declaredSectionEnd, reader.dataCount)
            : reader.dataCount
        guard animationCount <= 1_024 else {
            throw WPEMdlParserError.invalidAnimationHeader(offset: animationOffset)
        }

        var animations: [WPEPuppetAnimation] = []
        animations.reserveCapacity(Int(animationCount))
        for animationIndex in 0..<animationCount {
            let animationStart = reader.currentOffset
            let id = try reader.readUInt32()
            let reservedID = try reader.readUInt32()
            let name = try reader.readCString()
            let mode = try reader.readCString()
            let fps = try reader.readFloat()
            let frameCount = try reader.readUInt32()
            let reserved0 = try reader.readUInt32()
            let channelCount = try reader.readUInt32()
            let reserved1 = try reader.readUInt32()
            let channelByteCount = try reader.readUInt32()

            guard reservedID == 0, reserved0 == 0, reserved1 == 0,
                  fps.isFinite, fps > 0,
                  frameCount > 0, frameCount < 10_000,
                  channelCount > 0, channelCount < 10_000 else {
                throw WPEMdlParserError.invalidAnimationHeader(offset: animationStart)
            }

            let expectedChannelByteCount = (UInt64(frameCount) + 1) * UInt64(animationKeyByteCount)
            guard expectedChannelByteCount <= UInt64(UInt32.max),
                  channelByteCount == UInt32(expectedChannelByteCount) else {
                throw WPEMdlParserError.invalidAnimationChannelByteCount(
                    animationID: Int(id),
                    byteCount: channelByteCount,
                    expected: expectedChannelByteCount <= UInt64(UInt32.max)
                        ? UInt32(expectedChannelByteCount) : UInt32.max
                )
            }

            let keyframeCount = Int(channelByteCount) / animationKeyByteCount
            let channelCountInt = Int(channelCount)
            let minimumDataByteCount = UInt64(channelCount) * UInt64(channelByteCount)
                + UInt64(max(channelCountInt - 1, 0) * 2 * MemoryLayout<UInt32>.size)
            guard UInt64(reader.currentOffset) + minimumDataByteCount <= UInt64(sectionEnd) else {
                throw WPEMdlParserError.invalidAnimationHeader(offset: animationStart)
            }

            var channels: [WPEPuppetAnimChannel] = []
            channels.reserveCapacity(channelCountInt)
            for channelIndex in 0..<channelCountInt {
                var keyframes: [WPEPuppetAnimKey] = []
                keyframes.reserveCapacity(keyframeCount)
                for frame in 0..<keyframeCount {
                    let translation = SIMD3<Float>(
                        try reader.readFloat(), try reader.readFloat(), try reader.readFloat()
                    )
                    let euler = SIMD3<Float>(
                        try reader.readFloat(), try reader.readFloat(), try reader.readFloat()
                    )
                    let scale = SIMD3<Float>(
                        try reader.readFloat(), try reader.readFloat(), try reader.readFloat()
                    )
                    keyframes.append(WPEPuppetAnimKey(
                        frame: frame,
                        translation: translation,
                        euler: euler,
                        scale: scale
                    ))
                }
                channels.append(WPEPuppetAnimChannel(boneIndex: channelIndex, keyframes: keyframes))

                if channelIndex + 1 < channelCountInt {
                    let delimiterMarker = try reader.readUInt32()
                    let delimiterByteCount = try reader.readUInt32()
                    guard delimiterMarker == 0, delimiterByteCount == channelByteCount else {
                        throw WPEMdlParserError.invalidAnimationChannelDelimiter(
                            animationID: Int(id),
                            channelIndex: channelIndex,
                            marker: delimiterMarker,
                            byteCount: delimiterByteCount,
                            expected: channelByteCount
                        )
                    }
                }
            }

            animations.append(WPEPuppetAnimation(
                id: Int(id),
                name: name,
                mode: mode,
                fps: fps,
                frameCount: Int(frameCount),
                channels: channels
            ))

            if animationIndex + 1 < animationCount {
                guard let nextOffset = reader.findLikelyAnimationRecord(
                    from: reader.currentOffset,
                    sectionEnd: sectionEnd
                ) else {
                    throw WPEMdlParserError.invalidAnimationHeader(offset: reader.currentOffset)
                }
                auditRecorder?.recordKnownSkip(
                    label: "MDLA animation padding",
                    range: reader.currentOffset..<nextOffset
                )
                try reader.seek(to: nextOffset)
            }
        }

        if sectionEnd <= reader.dataCount {
            let paddingStart = reader.currentOffset
            try reader.seek(to: sectionEnd)
            auditRecorder?.recordKnownSkip(label: "MDLA section padding", range: paddingStart..<reader.currentOffset)
        }
        auditRecorder?.endSection(at: reader.currentOffset)
        return animations
    }
}

private enum WPEMdlMeshFlags {
    static let normal: UInt32 = 0x2
    static let tangent: UInt32 = 0x4
    static let uv: UInt32 = 0x8
    static let uv2: UInt32 = 0x20
    static let extra4: UInt32 = 0x10000
    static let skinBlendIndices: UInt32 = 0x800000
    static let skinBlendWeights: UInt32 = 0x1000000
}

public enum WPEMdlParserError: Error, Equatable, Sendable {
    case invalidHeader
    case implausibleCount(section: String, count: UInt32, limit: UInt32)
    case truncated(offset: Int, requested: Int, available: Int)
    case unterminatedString(offset: Int)
    case invalidString(offset: Int)
    case unsupportedSectionMarker(UInt8)
    case invalidPartTable(UInt32)
    case invalidVertexBuffer(byteCount: UInt32, stride: Int)
    case invalidIndexBuffer(UInt32)
    case invalidSkeletonMatrix(UInt32)
    case invalidSkeletonTrailingMarker(offset: Int, value: UInt8)
    case invalidAttachmentHeader(offset: Int)
    case invalidAnimationHeader(offset: Int)
    case invalidAnimationChannelByteCount(animationID: Int, byteCount: UInt32, expected: UInt32)
    case invalidAnimationChannelDelimiter(
        animationID: Int,
        channelIndex: Int,
        marker: UInt32,
        byteCount: UInt32,
        expected: UInt32
    )
}

private struct WPEMdlBinaryReader {
    private let data: Data
    private var offset: Int = 0

    var currentOffset: Int {
        offset
    }

    var dataCount: Int {
        data.count
    }

    init(data: Data) {
        self.data = data
    }

    mutating func readUInt8() throws -> UInt8 {
        guard offset < data.count else {
            throw WPEMdlParserError.truncated(offset: offset, requested: 1, available: data.count)
        }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readUInt16() throws -> UInt16 {
        let b0 = UInt16(try readUInt8())
        let b1 = UInt16(try readUInt8())
        return b0 | (b1 << 8)
    }

    mutating func readUInt32() throws -> UInt32 {
        let b0 = UInt32(try readUInt8())
        let b1 = UInt32(try readUInt8())
        let b2 = UInt32(try readUInt8())
        let b3 = UInt32(try readUInt8())
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    mutating func readInt32() throws -> Int32 {
        Int32(bitPattern: try readUInt32())
    }

    mutating func readFloat() throws -> Float {
        Float(bitPattern: try readUInt32())
    }

    mutating func readFixedString(byteCount: Int) throws -> String {
        let start = offset
        try ensureAvailable(byteCount: byteCount)
        offset += byteCount
        let bytes = data[start..<offset].prefix { $0 != 0 }
        guard let string = String(bytes: bytes, encoding: .utf8) else {
            throw WPEMdlParserError.invalidString(offset: start)
        }
        return string
    }

    mutating func readCString() throws -> String {
        let start = offset
        while offset < data.count, data[offset] != 0 {
            offset += 1
        }
        guard offset < data.count else {
            throw WPEMdlParserError.unterminatedString(offset: start)
        }
        let bytes = data[start..<offset]
        offset += 1
        guard let string = String(bytes: bytes, encoding: .utf8) else {
            throw WPEMdlParserError.invalidString(offset: start)
        }
        return string
    }

    /// Section-bounded `readCString`. A malformed/truncated name whose terminator
    /// lies past `sectionEnd` fails fast on the existing `unterminatedString`
    /// path instead of scanning (and UTF-8 decoding) the rest of the file.
    mutating func readCString(sectionEnd: Int) throws -> String {
        let start = offset
        let limit = min(sectionEnd, data.count)
        while offset < limit, data[offset] != 0 {
            offset += 1
        }
        guard offset < limit else {
            throw WPEMdlParserError.unterminatedString(offset: start)
        }
        let bytes = data[start..<offset]
        offset += 1
        guard let string = String(bytes: bytes, encoding: .utf8) else {
            throw WPEMdlParserError.invalidString(offset: start)
        }
        return string
    }

    mutating func skip(byteCount: Int) throws {
        try ensureAvailable(byteCount: byteCount)
        offset += byteCount
    }

    mutating func seek(to newOffset: Int) throws {
        guard newOffset >= 0, newOffset <= data.count else {
            throw WPEMdlParserError.truncated(
                offset: newOffset,
                requested: 0,
                available: data.count
            )
        }
        offset = newOffset
    }

    /// Some MDLS records carry a short padding run between the bone's trailing JSON
    /// cstring and the next binary record. In MDLS0004 this is a 1–3 byte UTF-8 label
    /// (e.g. `主`, `右眼`, `左眼`), so the old single-marker-byte heuristic failed on
    /// multi-byte CJK labels and dropped the whole skeleton (observed at offset 79286,
    /// value 0xE4 — a CJK lead byte). Scan a bounded window for the next plausible bone
    /// record instead, and fail loud only if none is found.
    mutating func consumeOptionalSkeletonTrailingMarker(
        boneCount: Int,
        sectionEnd: Int
    ) throws -> Range<Int>? {
        guard currentOffset < sectionEnd else { return nil }
        if let nextRecordOffset = nextLikelySkeletonBoneRecordOffset(
            from: currentOffset,
            boneCount: boneCount,
            sectionEnd: sectionEnd
        ) {
            let skippedRange = currentOffset..<nextRecordOffset
            try seek(to: nextRecordOffset)
            return skippedRange.isEmpty ? nil : skippedRange
        }

        throw WPEMdlParserError.invalidSkeletonTrailingMarker(
            offset: currentOffset,
            value: data[currentOffset]
        )
    }

    /// First offset in `[from, from + 64]` whose bytes look like a bone record.
    /// Returns `from` immediately when the cursor already sits on a record (no padding).
    private func nextLikelySkeletonBoneRecordOffset(
        from start: Int,
        boneCount: Int,
        sectionEnd: Int
    ) -> Int? {
        guard start >= 0, start < sectionEnd else { return nil }
        let upperBound = min(sectionEnd, start + 64)
        for candidateOffset in start...upperBound where isLikelySkeletonBoneRecord(
            at: candidateOffset,
            boneCount: boneCount,
            sectionEnd: sectionEnd
        ) {
            return candidateOffset
        }
        return nil
    }

    /// A bone record begins with `id u32, u8, parent i32, matrixByteCount u32`. The parent
    /// may be any valid bone index or -1 — MDLS0004 skeletons contain forward parent
    /// references (e.g. 人物 bone 24's parent is bone 39), so the upper bound is the total
    /// bone count, not the next bone index.
    private func isLikelySkeletonBoneRecord(
        at candidateOffset: Int,
        boneCount: Int,
        sectionEnd: Int
    ) -> Bool {
        guard candidateOffset >= 0,
              candidateOffset + 13 <= sectionEnd,
              let recordFlag = readUInt8(at: candidateOffset + 4),
              recordFlag == 0,
              let parent = readInt32(at: candidateOffset + 5),
              parent >= -1,
              parent < Int32(boneCount),
              let matrixByteCount = readUInt32(at: candidateOffset + 9),
              matrixByteCount >= 16 * UInt32(MemoryLayout<Float>.size),
              matrixByteCount % UInt32(MemoryLayout<Float>.size) == 0 else {
            return false
        }
        return candidateOffset + 13 + Int(matrixByteCount) <= sectionEnd
    }

    private func readUInt8(at absoluteOffset: Int) -> UInt8? {
        guard absoluteOffset >= 0, absoluteOffset < data.count else { return nil }
        return data[absoluteOffset]
    }

    private func readInt32(at absoluteOffset: Int) -> Int32? {
        readUInt32(at: absoluteOffset).map(Int32.init(bitPattern:))
    }

    private func readUInt32(at absoluteOffset: Int) -> UInt32? {
        guard absoluteOffset >= 0, absoluteOffset + 4 <= data.count else { return nil }
        return UInt32(data[absoluteOffset])
            | (UInt32(data[absoluteOffset + 1]) << 8)
            | (UInt32(data[absoluteOffset + 2]) << 16)
            | (UInt32(data[absoluteOffset + 3]) << 24)
    }

    func findTag(_ tag: String, from start: Int) -> Int? {
        let bytes = Data(tag.utf8)
        return data.range(of: bytes, options: [], in: start..<data.count)?.lowerBound
    }

    /// First offset at/after `start` that begins a plausible MDLA animation record.
    /// Used to skip the short zero-padding tail between animations.
    func findLikelyAnimationRecord(from start: Int, sectionEnd: Int) -> Int? {
        guard start >= 0, start < sectionEnd else { return nil }
        for offset in start..<min(sectionEnd, data.count)
        where isLikelyAnimationRecord(at: offset, sectionEnd: sectionEnd) {
            return offset
        }
        return nil
    }

    private func isLikelyAnimationRecord(at absoluteOffset: Int, sectionEnd: Int) -> Bool {
        guard absoluteOffset >= 0,
              absoluteOffset + 8 < sectionEnd,
              let id = readUInt32(at: absoluteOffset), id > 0, id < 1_000_000,
              let reservedID = readUInt32(at: absoluteOffset + 4), reservedID == 0,
              let name = readCString(at: absoluteOffset + 8, sectionEnd: sectionEnd),
              !name.value.isEmpty, name.value.utf8.count <= 128,
              let mode = readCString(at: name.nextOffset, sectionEnd: sectionEnd),
              !mode.value.isEmpty, mode.value.utf8.count <= 32 else {
            return false
        }
        let headerTail = mode.nextOffset + MemoryLayout<Float>.size + 5 * MemoryLayout<UInt32>.size
        guard headerTail <= sectionEnd,
              let fps = readFloat(at: mode.nextOffset), fps.isFinite, fps > 0,
              let frameCount = readUInt32(at: mode.nextOffset + 4), frameCount > 0, frameCount < 10_000,
              let reserved0 = readUInt32(at: mode.nextOffset + 8), reserved0 == 0,
              let channelCount = readUInt32(at: mode.nextOffset + 12), channelCount > 0, channelCount < 10_000,
              let reserved1 = readUInt32(at: mode.nextOffset + 16), reserved1 == 0,
              let channelByteCount = readUInt32(at: mode.nextOffset + 20) else {
            return false
        }
        let expected = (UInt64(frameCount) + 1) * UInt64(9 * MemoryLayout<Float>.size)
        guard expected == UInt64(channelByteCount) else { return false }
        let minimumDataByteCount = UInt64(channelCount) * UInt64(channelByteCount)
            + UInt64(max(Int(channelCount) - 1, 0) * 2 * MemoryLayout<UInt32>.size)
        return UInt64(headerTail) + minimumDataByteCount <= UInt64(sectionEnd)
    }

    private func readCString(at absoluteOffset: Int, sectionEnd: Int) -> (value: String, nextOffset: Int)? {
        guard absoluteOffset >= 0, absoluteOffset < sectionEnd, sectionEnd <= data.count else { return nil }
        var cursor = absoluteOffset
        while cursor < sectionEnd, data[cursor] != 0 {
            cursor += 1
        }
        guard cursor < sectionEnd,
              let string = String(bytes: data[absoluteOffset..<cursor], encoding: .utf8) else {
            return nil
        }
        return (string, cursor + 1)
    }

    private func readFloat(at absoluteOffset: Int) -> Float? {
        readUInt32(at: absoluteOffset).map(Float.init(bitPattern:))
    }

    private func ensureAvailable(byteCount: Int) throws {
        guard byteCount >= 0, offset + byteCount <= data.count else {
            throw WPEMdlParserError.truncated(
                offset: offset,
                requested: byteCount,
                available: data.count
            )
        }
    }
}
