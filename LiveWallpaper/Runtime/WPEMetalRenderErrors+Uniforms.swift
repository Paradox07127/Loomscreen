import Foundation
import simd

enum WPEMetalRenderExecutorError: Error, Equatable, LocalizedError, Sendable {
    case commandQueueUnavailable
    case libraryUnavailable
    case pipelineUnavailable(String)
    case unsupportedShader(String)
    case unsupportedTarget(WPERenderTarget)
    case missingTexture(WPETextureReference)
    case noRenderablePasses
    case commandBufferFailed

    var errorDescription: String? {
        switch self {
        case .commandQueueUnavailable:
            return String(
                localized: "error.render.executor.command_queue_unavailable",
                defaultValue: "Metal command queue is unavailable.",
                comment: "Error shown when the Metal renderer cannot create or access a command queue."
            )
        case .libraryUnavailable:
            return String(
                localized: "error.render.executor.library_unavailable",
                defaultValue: "WPE Metal built-in shader library is unavailable.",
                comment: "Error shown when the built-in Metal shader library is unavailable."
            )
        case .pipelineUnavailable(let name):
            return String(
                localized: "error.render.executor.pipeline_unavailable",
                defaultValue: "WPE Metal pipeline is unavailable for \(name).",
                comment: "Error shown when the Metal renderer cannot create a render pipeline."
            )
        case .unsupportedShader(let name):
            return String(
                localized: "error.render.executor.unsupported_shader",
                defaultValue: "WPE Metal executor does not support shader \(name).",
                comment: "Error shown when the Metal renderer does not support a shader."
            )
        case .unsupportedTarget(let target):
            let targetDescription = String(describing: target)
            return String(
                localized: "error.render.executor.unsupported_target",
                defaultValue: "WPE Metal executor does not support target \(targetDescription).",
                comment: "Error shown when the Metal renderer does not support a render target."
            )
        case .missingTexture(let reference):
            let referenceDescription = String(describing: reference)
            return String(
                localized: "error.render.executor.missing_texture",
                defaultValue: "WPE Metal executor is missing texture \(referenceDescription).",
                comment: "Error shown when the Metal renderer cannot find a required texture."
            )
        case .noRenderablePasses:
            return String(
                localized: "error.render.executor.no_renderable_passes",
                defaultValue: "WPE Metal pipeline has no renderable passes.",
                comment: "Error shown when the Metal render pipeline has no renderable passes."
            )
        case .commandBufferFailed:
            return String(
                localized: "error.render.executor.command_buffer_failed",
                defaultValue: "WPE Metal command buffer failed.",
                comment: "Error shown when a Metal command buffer reports failure."
            )
        }
    }
}

struct WPESolidUniforms {
    var color: SIMD4<Float>
}

struct WPECopyUniforms {
    var uvOffset: SIMD2<Float>
    var padding: SIMD2<Float> = SIMD2<Float>(0, 0)
}

// Phase 2D-C: per-effect uniform structs. Field order MUST match the
// matching MSL struct in `WPEMetalBuiltins.metal` exactly so that
// `setFragmentBytes(...)` lays out correctly.

struct WPEColorBalanceUniforms {
    var brightness: Float
    var contrast: Float
    var saturation: Float
    var padding: Float = 0
}

struct WPEBlurUniforms {
    var texelSize: SIMD2<Float>
    var radius: Float
    var padding: Float = 0
}

struct WPEVignetteUniforms {
    var innerRadius: Float
    var outerRadius: Float
    var intensity: Float
    var padding: Float = 0
}

struct WPEWaterUniforms {
    var amplitude: Float
    var frequency: Float
    var speed: Float
    var time: Float
}

struct WPEShakeUniforms {
    var magnitude: Float
    var time: Float
    var frequency: Float
    var padding: Float = 0
}
