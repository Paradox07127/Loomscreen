import CoreGraphics
import Foundation

/// Renderer-neutral IR for Wallpaper Engine scene execution.
///
/// Deliberately models WPE's material/effect/pass/FBO structure rather than named
/// effects, so Metal execution can consume a pass without knowing it came from
/// blur, shake, water ripple, or a workshop-specific effect.
public struct WPERenderGraph: Equatable, Sendable {
    public let layers: [WPERenderLayer]

    public init(layers: [WPERenderLayer]) {
        self.layers = layers
    }
}

public struct WPERenderLayer: Equatable, Sendable, Identifiable {
    public var id: String { objectID }

    public let objectID: String
    public let objectName: String
    /// Live scene visibility. Layers always stay in the graph (even when
    /// hidden) so their composites remain available to dependents and so a
    /// settings toggle can be applied without rebuilding the pipeline; the
    /// executor skips the scene-target draw when this is false.
    public let visible: Bool
    public let imagePath: String
    public let materialPath: String?
    public let puppetPath: String?
    /// Object this layer attaches to (the parent puppet for body-split rigs). `nil` for roots.
    public let parentObjectID: String?
    /// Named MDAT anchor on the parent puppet this layer follows. `nil` when unattached.
    public let attachment: String?
    /// Scene `animationlayers` for this object, selecting which puppet MDLA animation(s) play.
    public let animationLayers: [WPESceneAnimationLayer]
    public let geometry: WPERenderLayerGeometry
    /// Pre-inheritance geometry retained so an attached child can re-derive its placement from the
    /// parent puppet's animated anchor bone. `nil` for layers that need no attachment-following.
    public let localGeometry: WPERenderLayerGeometry?
    public let compositeA: String
    public let compositeB: String
    public let localFBOs: [WPERenderFBO]
    public let passes: [WPERenderPass]
    /// Offscreen group target this layer's final scene pass is redirected into. The executor uses
    /// `groupLocalGeometry` when drawing to this target, so child layers are placed inside the
    /// composelayer-local render target instead of the global scene.
    public let groupRenderTarget: String?
    public let groupLocalGeometry: WPERenderLayerGeometry?
    /// For a composelayer that owns a child group, this names the group target sampled by its
    /// material pass before the composelayer's own effects and final scene composite.
    public let groupCompositeSource: String?
    /// Per-axis camera-parallax depth (WPE Vec2). Each axis scales independently;
    /// `.zero` pins the layer. Inherited from the root attachment ancestor by the
    /// graph builder so a rigid puppet subtree shifts as one unit.
    public let parallaxDepth: SIMD2<Double>
    /// Original scene-object paint index. Earlier indices paint behind later
    /// ones; particles interleave against this in the executor.
    public let sortIndex: Int

    public init(
        objectID: String,
        objectName: String,
        visible: Bool = true,
        imagePath: String,
        materialPath: String?,
        puppetPath: String? = nil,
        parentObjectID: String? = nil,
        attachment: String? = nil,
        animationLayers: [WPESceneAnimationLayer] = [],
        geometry: WPERenderLayerGeometry,
        localGeometry: WPERenderLayerGeometry? = nil,
        compositeA: String,
        compositeB: String,
        localFBOs: [WPERenderFBO],
        passes: [WPERenderPass],
        groupRenderTarget: String? = nil,
        groupLocalGeometry: WPERenderLayerGeometry? = nil,
        groupCompositeSource: String? = nil,
        parallaxDepth: SIMD2<Double> = SIMD2<Double>(0, 0),
        sortIndex: Int = 0
    ) {
        self.objectID = objectID
        self.objectName = objectName
        self.visible = visible
        self.imagePath = imagePath
        self.materialPath = materialPath
        self.puppetPath = puppetPath
        self.parentObjectID = parentObjectID
        self.attachment = attachment
        self.animationLayers = animationLayers
        self.geometry = geometry
        self.localGeometry = localGeometry
        self.compositeA = compositeA
        self.compositeB = compositeB
        self.localFBOs = localFBOs
        self.passes = passes
        self.groupRenderTarget = groupRenderTarget
        self.groupLocalGeometry = groupLocalGeometry
        self.groupCompositeSource = groupCompositeSource
        self.parallaxDepth = parallaxDepth
        self.sortIndex = sortIndex
    }
}

public struct WPERenderLayerGeometry: Equatable, Sendable {
    public let origin: SIMD3<Double>
    public let scale: SIMD3<Double>
    public let angles: SIMD3<Double>
    public let alignment: WPESceneAlignment
    public let size: CGSize?
    /// Raw MDLV mesh-bbox center (puppet model coordinates) subtracted in the
    /// puppet vertex shader so the mesh is centered in its mesh-bbox-sized local
    /// composite. Zero for non-puppet layers and puppets that fit `size`.
    public let puppetMeshCenter: SIMD2<Double>
    public let alpha: Double
    public let alphaAnimation: WPESceneAnimatedValue?
    public let color: SIMD3<Double>
    public let brightness: Double
    /// Normalized perspective-quad corners (`point0..3`) for a `shape: "quad"`
    /// DIRECTDRAW effect layer. Non-nil routes the pass through the 4-corner
    /// `wpe_shape_quad_vertex` geometry instead of the axis-aligned object quad.
    public let shapePoints: [SIMD2<Double>]?

    public init(
        origin: SIMD3<Double>,
        scale: SIMD3<Double>,
        angles: SIMD3<Double>,
        alignment: WPESceneAlignment,
        size: CGSize?,
        puppetMeshCenter: SIMD2<Double> = SIMD2<Double>(0, 0),
        alpha: Double,
        alphaAnimation: WPESceneAnimatedValue? = nil,
        color: SIMD3<Double>,
        brightness: Double,
        shapePoints: [SIMD2<Double>]? = nil
    ) {
        self.origin = origin
        self.scale = scale
        self.angles = angles
        self.alignment = alignment
        self.size = size
        self.puppetMeshCenter = puppetMeshCenter
        self.alpha = alpha
        self.alphaAnimation = alphaAnimation
        self.color = color
        self.brightness = brightness
        self.shapePoints = shapePoints
    }

    public func resolved(at time: Double) -> WPERenderLayerGeometry {
        WPERenderLayerGeometry(
            origin: origin,
            scale: scale,
            angles: angles,
            alignment: alignment,
            size: size,
            puppetMeshCenter: puppetMeshCenter,
            alpha: alphaAnimation?.scalar(at: time) ?? alpha,
            alphaAnimation: alphaAnimation,
            color: color,
            brightness: brightness,
            shapePoints: shapePoints
        )
    }

    public static let identity = WPERenderLayerGeometry(
        origin: SIMD3<Double>(0, 0, 0),
        scale: SIMD3<Double>(1, 1, 1),
        angles: SIMD3<Double>(0, 0, 0),
        alignment: .center,
        size: nil,
        puppetMeshCenter: SIMD2<Double>(0, 0),
        alpha: 1,
        alphaAnimation: nil,
        color: SIMD3<Double>(1, 1, 1),
        brightness: 1
    )
}

public struct WPERenderFBO: Equatable, Sendable {
    public let name: String
    public let scale: Double
    public let format: String
    public let unique: Bool
    public let pixelSize: CGSize?

    public init(name: String, scale: Double, format: String, unique: Bool = false, pixelSize: CGSize? = nil) {
        self.name = name
        self.scale = scale
        self.format = format
        self.unique = unique
        self.pixelSize = pixelSize
    }
}

public struct WPERenderPass: Equatable, Sendable, Identifiable {
    public let id: String
    public let phase: WPERenderPassPhase
    public let shader: String
    public let source: WPETextureReference
    public let target: WPERenderTarget
    public let textures: [Int: WPETextureReference]
    public let binds: [Int: WPETextureReference]
    public let constants: [String: WPESceneShaderConstantValue]
    public let combos: [String: Int]
    public let blending: String
    public let cullMode: String
    public let depthTest: String
    public let depthWrite: String

    public init(
        id: String,
        phase: WPERenderPassPhase,
        shader: String,
        source: WPETextureReference,
        target: WPERenderTarget,
        textures: [Int: WPETextureReference],
        binds: [Int: WPETextureReference],
        constants: [String: WPESceneShaderConstantValue],
        combos: [String: Int],
        blending: String,
        cullMode: String,
        depthTest: String,
        depthWrite: String
    ) {
        self.id = id
        self.phase = phase
        self.shader = shader
        self.source = source
        self.target = target
        self.textures = textures
        self.binds = binds
        self.constants = constants
        self.combos = combos
        self.blending = blending
        self.cullMode = cullMode
        self.depthTest = depthTest
        self.depthWrite = depthWrite
    }

    public func replacingTarget(_ target: WPERenderTarget) -> WPERenderPass {
        WPERenderPass(
            id: id,
            phase: phase,
            shader: shader,
            source: source,
            target: target,
            textures: textures,
            binds: binds,
            constants: constants,
            combos: combos,
            blending: blending,
            cullMode: cullMode,
            depthTest: depthTest,
            depthWrite: depthWrite
        )
    }

    public func replacingBlending(_ blending: String) -> WPERenderPass {
        WPERenderPass(
            id: id,
            phase: phase,
            shader: shader,
            source: source,
            target: target,
            textures: textures,
            binds: binds,
            constants: constants,
            combos: combos,
            blending: blending,
            cullMode: cullMode,
            depthTest: depthTest,
            depthWrite: depthWrite
        )
    }
}

public enum WPERenderPassPhase: Equatable, Sendable {
    case material
    case effect(file: String)
    case command(file: String)

    /// WPE's builtin full-frame copy command/material asset. The graph builder
    /// synthesizes a `.command(file:)` pass with this string as both the phase's
    /// file AND the pass's `shader` when relaying a layer's finished composite to
    /// the scene target or a composelayer group buffer (`finalizedPasses`). The
    /// executor's puppet defer-warp effect-chain detector (`hasEffectChain`)
    /// excludes exactly this file so a synthesized copy-only puppet isn't
    /// misclassified as "has an effect". Both sides MUST use this exact string —
    /// ADR-001 appendix A #66.
    public static let sceneCopyCommandFile = "materials/util/copy.json"
}

public enum WPETextureReference: Equatable, Sendable {
    case image(String)
    case asset(String)
    case fbo(String)
    case previous

    /// Canonical classifier for `_rt_*` names WPE's runtime aliases to the LIVE scene
    /// texture rather than a discrete FBO allocation. Single source of truth shared by the
    /// graph builder (Infrastructure) and the executor's shader inputs (Runtime) — both
    /// import this Schema package, so neither crosses the Infra↔Runtime boundary. This list
    /// was previously hand-copied in both places (ADR-001 B1: "应合一,最高优先" — a drift
    /// between the two copies causes PiP / shine-white-out regressions).
    public static func isSceneAliasName(_ name: String) -> Bool {
        switch name {
        case "_rt_FullFrameBuffer",
             "_rt_HalfFrameBuffer",
             "_rt_QuarterFrameBuffer",
             "_rt_imageLayerComposite":
            return true
        default:
            return name.hasPrefix("_rt_EightBuffer")
                || name.hasPrefix("_rt_Mip")
                || name.hasPrefix("_rt_downscaled")
        }
    }
}

public enum WPERenderTarget: Equatable, Sendable {
    case layerComposite(name: String)
    case fbo(name: String)
    case scene
}

public enum WPERenderGraphError: Error, Equatable, LocalizedError, Sendable {
    case fileMissing(String)
    case invalidJSON(String)
    case malformedMaterial(String)
    case malformedEffect(String)
    case materialUnresolved(String)

    public var errorDescription: String? {
        switch self {
        case .fileMissing(let path):
            return String(localized: "error.render.graph.file_missing", defaultValue: "WPE graph asset missing: \(path)", comment: "Error shown when a Wallpaper Engine render graph asset is missing.")
        case .invalidJSON(let path):
            return String(localized: "error.render.graph.invalid_json", defaultValue: "WPE graph asset is not valid JSON: \(path)", comment: "Error shown when a Wallpaper Engine render graph asset is invalid JSON.")
        case .malformedMaterial(let path):
            return String(localized: "error.render.graph.malformed_material", defaultValue: "WPE material has no renderable passes: \(path)", comment: "Error shown when a Wallpaper Engine material has no renderable passes.")
        case .malformedEffect(let path):
            return String(localized: "error.render.graph.malformed_effect", defaultValue: "WPE effect has no renderable passes: \(path)", comment: "Error shown when a Wallpaper Engine effect has no renderable passes.")
        case .materialUnresolved(let imagePath):
            return String(localized: "error.render.graph.material_unresolved", defaultValue: "Could not resolve WPE material for image reference: \(imagePath)", comment: "Error shown when a Wallpaper Engine material cannot be resolved for an image reference.")
        }
    }
}
