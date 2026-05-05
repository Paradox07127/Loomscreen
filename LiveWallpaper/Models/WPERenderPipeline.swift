import Foundation

/// Prepared, renderer-facing WPE pipeline.
///
/// This sits between the JSON render graph and the Metal executor: graph
/// passes are preserved exactly, while shader-backed passes carry expanded
/// GLSL sources with combo defines and includes resolved.
struct WPEPreparedRenderPipeline: Equatable, Sendable {
    let layers: [WPEPreparedRenderLayer]
}

struct WPEPreparedRenderLayer: Equatable, Sendable, Identifiable {
    var id: String { graphLayer.id }

    let graphLayer: WPERenderLayer
    let passes: [WPEPreparedRenderPass]
}

struct WPEPreparedRenderPass: Equatable, Sendable, Identifiable {
    var id: String { pass.id }

    let pass: WPERenderPass
    let shader: WPEShaderProgram?
    let textureBindings: [Int: WPETextureReference]
    let comboValues: [String: Int]
    let uniformValues: [String: WPESceneShaderConstantValue]
}

struct WPEShaderProgram: Equatable, Sendable {
    let name: String
    let vertexSource: String
    let fragmentSource: String
    let isBuiltin: Bool
}

enum WPERenderPipelineError: Error, Equatable, LocalizedError, Sendable {
    case shaderMissing(name: String, stage: String, path: String)
    case includeMissing(path: String, requestedBy: String)
    case includeCycle(path: String)
    case invalidSourceEncoding(path: String)

    var errorDescription: String? {
        switch self {
        case .shaderMissing(let name, let stage, let path):
            return "WPE shader \(name) is missing \(stage) source at \(path)"
        case .includeMissing(let path, let requestedBy):
            return "WPE shader include \(path) requested by \(requestedBy) is missing"
        case .includeCycle(let path):
            return "WPE shader include cycle detected at \(path)"
        case .invalidSourceEncoding(let path):
            return "WPE shader source is not UTF-8: \(path)"
        }
    }
}
