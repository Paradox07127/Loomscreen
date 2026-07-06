#if !LITE_BUILD
import CoreGraphics
import Foundation
import Metal
import simd

/// Async-path frame skip: every in-flight permit is taken (the GPU hasn't
/// finished a prior frame), so the caller drops this frame. NOT a failure and
/// deliberately kept out of `WPEMetalRenderExecutorError` (which is a
/// user-facing `LocalizedError`) — it's pure flow control that lets the
/// executor poll the in-flight semaphore instead of blocking the @MainActor.
struct WPEMetalFrameInFlightBudgetExhausted: Error {}

enum WPEMetalRenderExecutorError: Error, Equatable, LocalizedError, Sendable {
    case commandQueueUnavailable
    case libraryUnavailable
    case pipelineUnavailable(String)
    case unsupportedShader(String)
    /// Custom shader could not be translated or compiled by the Metal
    /// path. Carries the underlying compiler reason so the diagnostic
    /// surfaced to the UI is precise instead of just "unsupported".
    case shaderTranslatorUnavailable(name: String, reason: String)
    /// Metal refused to build a render pipeline state, most commonly because
    /// the vertex stage's struct doesn't line up with the fragment's
    /// `[[stage_in]]` (the "stage_in mismatch" cluster). Carries the raw
    /// underlying error description so logs name the actual missing field
    /// instead of just the shader name.
    case pipelineStateBuildFailed(name: String, detail: String)
    case unsupportedTarget(WPERenderTarget)
    case missingTexture(WPETextureReference)
    case renderTargetDimensionsExceedDeviceLimit(targetName: String, width: Int, height: Int, limit: Int)
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
                defaultValue: "WPE shader '\(name)' is unsupported by the Metal renderer: \(reason)",
                comment: "Error shown when a custom WPE shader cannot be translated or compiled by the Metal renderer."
            )
        case .pipelineStateBuildFailed(let name, let detail):
            return String(
                localized: "error.render.executor.pipeline_state_build_failed",
                defaultValue: "Metal pipeline build failed for '\(name)': \(detail)",
                comment: "Error shown when Metal refuses to build a render pipeline state (typically a stage_in mismatch between the vertex output and the fragment input)."
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
        case .renderTargetDimensionsExceedDeviceLimit(let targetName, let width, let height, let limit):
            return String(
                localized: "error.render.executor.render_target_dimensions_exceed_device_limit",
                defaultValue: "WPE Metal render target '\(targetName)' is \(width)x\(height), exceeding this device's \(limit)x\(limit) 2D texture limit.",
                comment: "Error shown when a Wallpaper Engine render target is larger than Metal allows on the current GPU."
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

enum WPEMetalTextureLimits {
    /// Mirrors Apple's Metal feature-set table for maximum 2D texture
    /// width/height, so invalid descriptors are rejected before Metal's
    /// Objective-C validation aborts the current test/app process.
    static func maximum2DTextureDimension(for device: MTLDevice) -> Int {
        // arm64-only distribution: every Mac GPU is Apple family with an
        // .apple7 (M1) floor at 16384; .apple10 raises the cap.
        device.supportsFamily(.apple10) ? 32_768 : 16_384
    }
}

struct WPESolidUniforms {
    var color: SIMD4<Float>
}

/// Layout MUST match `WPEComposeLayerUniforms` in `WPEMetalBuiltins.metal`.
/// `flags.x` carries the WPE `CLEARALPHA` combo (1 = clear sampled alpha).
struct WPEComposeLayerUniforms {
    var flags: SIMD4<Float>
}

struct WPECopyUniforms {
    var uvOffset: SIMD2<Float>
    var padding: SIMD2<Float> = SIMD2<Float>(0, 0)
}

/// How the final scene texture maps onto the screen drawable. Renderer-local
/// (no dependency on `VideoFitMode`'s AVFoundation semantics); the session maps
/// `VideoFitMode` onto this. `stretch` = legacy full-bleed (may distort);
/// `contain` = letterbox preserving aspect; `cover` = crop-to-fill preserving
/// aspect; `center` = original source size centered on the drawable.
enum WPEPresentFitMode: Equatable {
    case stretch
    case contain
    case cover
    case center
}

/// Layout MUST match `WPEPresentUniforms` in `WPEMetalBuiltins.metal`. Drives
/// the final on-screen blit's aspect handling: `ndcScale` shrinks the quad for
/// letterboxed `contain` or preserves source pixels for `center`;
/// `uvScale`/`uvOffset` crop the source for `cover`.
/// All-identity reproduces the legacy `stretch` full-bleed.
struct WPEPresentUniforms {
    var ndcScale: SIMD2<Float>
    var uvScale: SIMD2<Float>
    var uvOffset: SIMD2<Float>
    var padding: SIMD2<Float> = SIMD2<Float>(0, 0)

    /// Degenerate sizes fall back to identity (stretch).
    static func make(
        fitMode: WPEPresentFitMode,
        sourceWidth: Int,
        sourceHeight: Int,
        targetWidth: Int,
        targetHeight: Int
    ) -> WPEPresentUniforms {
        var u = WPEPresentUniforms(
            ndcScale: SIMD2<Float>(1, 1),
            uvScale: SIMD2<Float>(1, 1),
            uvOffset: SIMD2<Float>(0, 0)
        )
        guard sourceWidth > 0, sourceHeight > 0, targetWidth > 0, targetHeight > 0 else {
            return u
        }
        let srcAspect = Double(sourceWidth) / Double(sourceHeight)
        let dstAspect = Double(targetWidth) / Double(targetHeight)
        switch fitMode {
        case .stretch:
            break
        case .center:
            u.ndcScale = SIMD2<Float>(
                Float(Double(sourceWidth) / Double(targetWidth)),
                Float(Double(sourceHeight) / Double(targetHeight))
            )
        case .contain:
            // Shrink the quad on the over-long axis; the cleared margin shows
            // through as letterbox bars.
            if srcAspect > dstAspect {
                u.ndcScale.y = Float(dstAspect / srcAspect)
            } else if srcAspect < dstAspect {
                u.ndcScale.x = Float(srcAspect / dstAspect)
            }
        case .cover:
            // Keep the quad full-bleed; crop the source UV on the over-long
            // axis, centered.
            if srcAspect > dstAspect {
                let s = Float(dstAspect / srcAspect)
                u.uvScale.x = s
                u.uvOffset.x = (1 - s) / 2
            } else if srcAspect < dstAspect {
                let s = Float(srcAspect / dstAspect)
                u.uvScale.y = s
                u.uvOffset.y = (1 - s) / 2
            }
        }
        return u
    }
}

// Per-effect uniform structs. Field order MUST match the matching MSL struct
// in `WPEMetalBuiltins.metal` exactly so `setFragmentBytes(...)` lays out correctly.

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

/// Matches WPE's `effects/waterwaves` shader: a time-driven sine wave displaces the sample
/// UV perpendicular to `direction`, scaled by `strength`² and localized by an opacity mask.
struct WPEWaterWavesUniforms {
    var time: Float
    var speed: Float
    var scale: Float
    var strength: Float
    var exponent: Float
    /// Unit wave direction = rotate (0,1) by the `direction` angle (radians).
    var directionX: Float
    var directionY: Float
    /// 1 when an opacity mask is bound in texture slot 1, else 0 (effect applies everywhere).
    var hasMask: Float
    /// WPE packs texture resolution as (textureWidth, textureHeight, imageWidth, imageHeight).
    var texture1Resolution: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)
}

struct WPEShakeUniforms {
    var magnitude: Float
    var time: Float
    var frequency: Float
    var padding: Float = 0
}

// Layout MUST match `WPEGenericImageUniforms` /
// `WPEGenericParticleUniforms` in `WPEMetalBuiltins.metal`.

struct WPEGenericImageUniforms {
    var color: SIMD4<Float>
    /// x = alpha (g_Alpha), y = brightness (g_Brightness), z = hasMask (0/1),
    /// w = padding. Packed as a vec4 because Metal struct alignment on
    /// `constant` buffers rounds up to vec4 boundaries anyway, and a single
    /// vec4 slot is cheaper than three scalars + per-field padding.
    var alphaMaskUV: SIMD4<Float>
    /// xy = texture0 logical/physical UV scale, zw = texture1 logical/physical UV scale.
    var textureUVScale: SIMD4<Float>
}

struct WPEObjectQuadUniforms {
    /// x/y = center in scene-centered pixel space, z/w = width/height in pixels.
    var centerAndSize: SIMD4<Float>
    /// x/y = scene width/height, z = z-axis rotation in radians, w reserved.
    var sceneSizeAndRotation: SIMD4<Float>
    /// x/y = UV sign for preserving negative WPE scale mirroring, z = local capture CLEARALPHA, w reserved.
    var uvSignAndPadding: SIMD4<Float>
}

/// Layout MUST match `WPEBloomUniforms` in `WPEMetalBuiltins.metal`.
struct WPEBloomUniforms {
    /// xy = source texel size, z = strength (prefilter) / source alpha (upsample), w pad.
    var texelAndWeight: SIMD4<Float>
    /// Prefilter soft-knee: (threshold, knee, 2(threshold−knee), 0.25/(threshold−knee)).
    var blendParams: SIMD4<Float>
    var tint: SIMD4<Float>
}

/// Layout MUST match `WPESceneModelGenericUniforms` in `WPEMetalBuiltins.metal`
/// (generic4 scene-model material: tint + emissive map + hemispheric ambient + HDR).
struct WPESceneModelGenericUniforms {
    /// rgb = g_TintColor (raw, WPE uploads unconverted), a = g_TintAlpha × layer alpha.
    var tintColorAlpha: SIMD4<Float>
    /// rgb = g_EmissiveColor, w = g_EmissiveBrightness.
    var emissive: SIMD4<Float>
    /// rgb = mix(g_LightSkylightColor, g_LightAmbientColor, 0.5), w = LIGHTING combo (0/1).
    var ambientLighting: SIMD4<Float>
    /// x = g_Brightness × layer brightness, y = emissive map bound (0/1), z = scene HDR (0/1), w pad.
    var brightnessFlags: SIMD4<Float>
}

/// Layout MUST match `WPEShapeQuadUniforms` in `WPEMetalBuiltins.metal`. Four
/// pre-transformed perspective-quad corners (scene-centered pixels + point UVs)
/// in triangle-strip order (p0, p1, p3, p2).
struct WPEShapeQuadUniforms {
    var corner0: SIMD4<Float>
    var corner1: SIMD4<Float>
    var corner2: SIMD4<Float>
    var corner3: SIMD4<Float>
    /// x/y = half scene width/height, z/w = padding.
    var sceneHalfAndPad: SIMD4<Float>
}

struct WPEMetalPuppetVertex {
    var position: SIMD4<Float>
    var uv: SIMD4<Float>
    var skinBlendIndices: SIMD4<UInt32>
    var skinBlendWeights: SIMD4<Float>
}

struct WPEPuppetMeshUniforms {
    /// x/y = local layer-composite target size, z = bone palette count, w = skinning enabled (1/0).
    var localSizeAndMode: SIMD4<Float>
    /// x/y = raw MDLV mesh center in puppet model coordinates, z/w reserved.
    var meshCenterAndPadding: SIMD4<Float>
}

/// Layout MUST match `WPESceneModelMeshUniforms` in `WPEMetalBuiltins.metal`.
struct WPESceneModelMeshUniforms {
    var modelViewProjectionMatrix: simd_float4x4
    /// x = bone palette count, y = skinning enabled (1/0), z/w reserved.
    var modeAndPadding: SIMD4<Float>
}

/// Layout MUST match `WPEPuppetSceneCompositeUniforms` in `WPEMetalBuiltins.metal`.
/// Placement fields are copied 1:1 from `WPEObjectQuadUniforms` so the deferred-warp
/// composite reproduces the current final object-quad placement exactly:
/// - `objectCenterAndSize`  ← `WPEObjectQuadUniforms.centerAndSize`
/// - `sceneSizeAndRotation` ← `WPEObjectQuadUniforms.sceneSizeAndRotation`
/// - `meshCenterAndScaleSign.zw` ← `WPEObjectQuadUniforms.uvSignAndPadding.xy`
/// The vertex applies that sign to mesh-local positions (mirroring geometry) instead
/// of UVs, equivalent to the old path that mirrored an already-rasterized puppet FBO.
struct WPEPuppetSceneCompositeUniforms {
    /// x/y = atlas/local layer size, z = bone palette count, w = skinning enabled (1/0).
    var localSizeAndMode: SIMD4<Float>
    /// x/y = raw MDLV mesh center, z/w = negative-scale mirror sign from object-quad uniforms.
    var meshCenterAndScaleSign: SIMD4<Float>
    /// Exact copy of `WPEObjectQuadUniforms.centerAndSize`.
    var objectCenterAndSize: SIMD4<Float>
    /// Exact copy of `WPEObjectQuadUniforms.sceneSizeAndRotation`.
    var sceneSizeAndRotation: SIMD4<Float>
}

struct WPEGenericParticleUniforms {
    var color: SIMD4<Float>
    /// x = alpha, y = brightness, z/w = padding (reserved for spectrum
    /// reactivity in Phase 4 audio runtime).
    var sizeAndAge: SIMD4<Float>
}

struct WPEOpacityUniforms {
    var opacity: Float
    var hasMask: Float = 0
    var maskScaleX: Float = 1
    var maskScaleY: Float = 1
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

struct WPEGodraysCombineUniforms {
    var useBase: UInt32 = 1
    var padding0: UInt32 = 0
    var padding1: UInt32 = 0
    var padding2: UInt32 = 0
}

struct WPEIrisUniforms {
    var radius: Float
    var softness: Float
    var padding0: Float = 0
    var padding1: Float = 0
}

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

/// Layout MUST match `WPESkewParams` in WPEMetalBuiltins.metal. Normalized
/// `effects/skew` MODE=1 vertex-displacement params (fractions of the quad
/// extent): x=g_Top, y=g_Bottom, z=g_Left, w=g_Right.
struct WPESkewParams {
    var topBottomLeftRight: SIMD4<Float>
}

/// Layout MUST match `WPETextOverlayUniforms` in WPEMetalBuiltins.metal.
struct WPETextOverlayUniforms {
    var centerAndSize: SIMD4<Float>  // x,y center (pixel space), z,w width,height
    var sceneSize: SIMD4<Float>      // x = scene width, y = scene height, z = z rotation (radians, author CCW)
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
    /// Composed transform-host z rotation (radians, author-space CCW); the
    /// overlay quad rotates about its center. 0 = axis-aligned (the default).
    var rotation: Float = 0
}
#endif
