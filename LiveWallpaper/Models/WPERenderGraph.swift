import Foundation

/// Renderer-neutral IR for Wallpaper Engine scene execution.
///
/// The graph deliberately models WPE's material/effect/pass/FBO structure
/// instead of individual named effects. Metal execution can consume this IR
/// without knowing whether a pass came from blur, shake, water ripple, or a
/// workshop-specific effect.
struct WPERenderGraph: Equatable, Sendable {
    let layers: [WPERenderLayer]
}

struct WPERenderLayer: Equatable, Sendable, Identifiable {
    var id: String { objectID }

    let objectID: String
    let objectName: String
    let imagePath: String
    let materialPath: String?
    let compositeA: String
    let compositeB: String
    let localFBOs: [WPERenderFBO]
    let passes: [WPERenderPass]
}

struct WPERenderFBO: Equatable, Sendable {
    let name: String
    let scale: Double
    let format: String
    let unique: Bool

    init(name: String, scale: Double, format: String, unique: Bool = false) {
        self.name = name
        self.scale = scale
        self.format = format
        self.unique = unique
    }
}

struct WPERenderPass: Equatable, Sendable, Identifiable {
    let id: String
    let phase: WPERenderPassPhase
    let shader: String
    let source: WPETextureReference
    let target: WPERenderTarget
    let textures: [Int: WPETextureReference]
    let binds: [Int: WPETextureReference]
    let constants: [String: WPESceneShaderConstantValue]
    let combos: [String: Int]
    let blending: String
    let cullMode: String
    let depthTest: String
    let depthWrite: String

    func replacingTarget(_ target: WPERenderTarget) -> WPERenderPass {
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

    func replacingBlending(_ blending: String) -> WPERenderPass {
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

enum WPERenderPassPhase: Equatable, Sendable {
    case material
    case effect(file: String)
    case command(file: String)
}

enum WPETextureReference: Equatable, Sendable {
    case image(String)
    case asset(String)
    case fbo(String)
    case previous
}

enum WPERenderTarget: Equatable, Sendable {
    case layerComposite(name: String)
    case fbo(name: String)
    case scene
}

enum WPERenderGraphError: Error, Equatable, LocalizedError, Sendable {
    case fileMissing(String)
    case invalidJSON(String)
    case malformedMaterial(String)
    case malformedEffect(String)
    case materialUnresolved(String)

    var errorDescription: String? {
        switch self {
        case .fileMissing(let path):
            return "WPE graph asset missing: \(path)"
        case .invalidJSON(let path):
            return "WPE graph asset is not valid JSON: \(path)"
        case .malformedMaterial(let path):
            return "WPE material has no renderable passes: \(path)"
        case .malformedEffect(let path):
            return "WPE effect has no renderable passes: \(path)"
        case .materialUnresolved(let imagePath):
            return "Could not resolve WPE material for image reference: \(imagePath)"
        }
    }
}
