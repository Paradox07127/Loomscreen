#if !LITE_BUILD
import CoreGraphics
import Foundation
import Metal
import simd

enum WPEMetalRenderExecutorError: Error, Equatable, LocalizedError, Sendable {
    case commandQueueUnavailable
    case libraryUnavailable
    case pipelineUnavailable(String)
    case unsupportedShader(String)
    /// Custom shader needs the WPE→MSL translator but the backend isn't
    /// vendored yet. Carries the underlying compiler reason so the diagnostic
    /// surfaced to the UI is precise instead of "unsupported".
    case shaderTranslatorUnavailable(name: String, reason: String)
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
        case .shaderTranslatorUnavailable(let name, let reason):
            return String(
                localized: "error.render.executor.shader_translator_unavailable",
                defaultValue: "WPE shader '\(name)' needs the GLSL→MSL translator: \(reason)",
                comment: "Error shown when a custom WPE shader needs translation but the backend is not yet integrated."
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

// Phase 2D-D: layout MUST match `WPEGenericImageUniforms` /
// `WPEGenericParticleUniforms` in `WPEMetalBuiltins.metal`.

struct WPEGenericImageUniforms {
    var color: SIMD4<Float>
    /// x = alpha (g_Alpha), y = brightness (g_Brightness), z = hasMask (0/1),
    /// w = padding. Packed as a vec4 because Metal struct alignment on
    /// `constant` buffers rounds up to vec4 boundaries anyway, and a single
    /// vec4 slot is cheaper than three scalars + per-field padding.
    var alphaMaskUV: SIMD4<Float>
}

struct WPEGenericParticleUniforms {
    var color: SIMD4<Float>
    /// x = alpha, y = brightness, z/w = padding (reserved for spectrum
    /// reactivity in Phase 4 audio runtime).
    var sizeAndAge: SIMD4<Float>
}

// Phase 2D-E: native MSL effect uniforms.

struct WPEOpacityUniforms {
    var opacity: Float
    var padding0: Float = 0
    var padding1: Float = 0
    var padding2: Float = 0
}

struct WPEScrollUniforms {
    var speed: SIMD2<Float>
    var time: Float
    var padding: Float = 0
}

struct WPEPulseUniforms {
    var frequency: Float
    var amplitude: Float
    var time: Float
    var padding: Float = 0
}

struct WPEIrisUniforms {
    var radius: Float
    var softness: Float
    var padding0: Float = 0
    var padding1: Float = 0
}

// WaterWaves shares the WPEWaterUniforms layout — declared above near the
// Water effect — to keep MSL/Swift struct alignments in lockstep.

struct WPESpinUniforms {
    var angularSpeed: Float
    var time: Float
    var padding0: Float = 0
    var padding1: Float = 0
}

struct WPETintUniforms {
    var color: SIMD4<Float>
    var intensity: Float
    var padding0: Float = 0
    var padding1: Float = 0
    var padding2: Float = 0
}

struct WPEFoliageSwayUniforms {
    var amplitude: Float
    var frequency: Float
    var speed: Float
    var time: Float
}

struct WPEWaterRippleUniforms {
    var amplitude: Float
    var frequency: Float
    var speed: Float
    var time: Float
}

struct WPEBlendUniforms {
    var color: SIMD4<Float>
    var opacity: Float
    var padding0: Float = 0
    var padding1: Float = 0
    var padding2: Float = 0
}

struct WPEWaterFlowUniforms {
    var direction: SIMD2<Float>
    var speed: Float
    var time: Float
}

struct WPEColorGradingUniforms {
    var lift: SIMD4<Float>
    var gamma: SIMD4<Float>
    var gain: SIMD4<Float>
}

struct WPEShimmerUniforms {
    var speed: Float
    var intensity: Float
    var time: Float
    var padding: Float = 0
}

/// Layout MUST match `WPEParticleProjection` in WPEMetalBuiltins.metal.
struct WPEParticleProjection {
    var sceneSize: SIMD4<Float>   // x = width, y = height (pixels)
    var padding: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 0)
}

/// Layout MUST match `WPETextOverlayUniforms` in WPEMetalBuiltins.metal.
struct WPETextOverlayUniforms {
    var centerAndSize: SIMD4<Float>  // x,y center (pixel space), z,w width,height
    var sceneSize: SIMD4<Float>      // x = scene width, y = scene height
    var color: SIMD4<Float>          // rgb tint, a = effective alpha
}

/// Per-overlay draw payload assembled by the renderer and consumed by
/// `WPEMetalRenderExecutor.drawTextOverlays`. Carries the rasterized
/// MTLTexture along with the geometry the dispatcher needs to project
/// it into NDC over the rendered scene.
struct WPETextOverlayDraw {
    let texture: MTLTexture
    /// Pixel-space center derived from the text object's `origin`,
    /// using the same convention as image layers.
    let centerInScenePixels: SIMD2<Float>
    /// Pixel-space width/height of the rasterized texture (post-CoreText).
    let sizeInScenePixels: CGSize
    /// Effective tint × per-text alpha. We use a separate alpha so the
    /// shader can re-multiply if the rasterizer ever ships unpremultiplied.
    let tint: SIMD3<Float>
    let alpha: Float
}
#endif
