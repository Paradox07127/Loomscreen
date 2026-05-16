import Foundation

/// Renderer-neutral IR for Wallpaper Engine scene execution.
///
/// The graph deliberately models WPE's material/effect/pass/FBO structure
/// instead of individual named effects. Metal execution can consume this IR
/// without knowing whether a pass came from blur, shake, water ripple, or a
/// workshop-specific effect.
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
    public let imagePath: String
    public let materialPath: String?
    public let compositeA: String
    public let compositeB: String
    public let localFBOs: [WPERenderFBO]
    public let passes: [WPERenderPass]
    public let parallaxDepth: Double

    public init(
        objectID: String,
        objectName: String,
        imagePath: String,
        materialPath: String?,
        compositeA: String,
        compositeB: String,
        localFBOs: [WPERenderFBO],
        passes: [WPERenderPass],
        parallaxDepth: Double = 0
    ) {
        self.objectID = objectID
        self.objectName = objectName
        self.imagePath = imagePath
        self.materialPath = materialPath
        self.compositeA = compositeA
        self.compositeB = compositeB
        self.localFBOs = localFBOs
        self.passes = passes
        self.parallaxDepth = parallaxDepth
    }
}

public struct WPERenderFBO: Equatable, Sendable {
    public let name: String
    public let scale: Double
    public let format: String
    public let unique: Bool

    public init(name: String, scale: Double, format: String, unique: Bool = false) {
        self.name = name
        self.scale = scale
        self.format = format
        self.unique = unique
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
}

public enum WPETextureReference: Equatable, Sendable {
    case image(String)
    case asset(String)
    case fbo(String)
    case previous
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
