import Foundation
import Metal

/// Dispatches a prepared pass onto the right Metal pipeline state and
/// fragment uniforms. Extracted so the dispatch logic can stay readable
/// while sharing access to the executor's pipeline cache; pure shader-input
/// math and texture resolution live in `WPEMetalShaderInputs`.
struct WPEMetalShaderDispatcher {
    let executor: WPEMetalRenderExecutor

    func dispatch(
        pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        destination: (id: WPEMetalTargetID, texture: MTLTexture),
        textures: [String: MTLTexture],
        frameState: WPEMetalFrameState,
        encoder: MTLRenderCommandEncoder,
        depthPixelFormat: MTLPixelFormat
    ) throws {
        switch WPEMetalShaderInputs.normalizedBuiltinShaderName(pass.pass.shader) {
        case "solidcolor":
            encoder.setRenderPipelineState(try executor.renderPipeline(
                fragmentName: "wpe_solidcolor_fragment",
                blendMode: pass.pass.blending,
                colorPixelFormat: destination.texture.pixelFormat,
                depthPixelFormat: depthPixelFormat
            ))
            var uniforms = WPESolidUniforms(color: WPEMetalShaderInputs.colorVector(for: pass))
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPESolidUniforms>.stride, index: 0)

        case "solidlayer":
            encoder.setRenderPipelineState(try executor.renderPipeline(
                fragmentName: "wpe_solidlayer_fragment",
                blendMode: pass.pass.blending,
                colorPixelFormat: destination.texture.pixelFormat,
                depthPixelFormat: depthPixelFormat
            ))
            var uniforms = WPESolidUniforms(color: WPEMetalShaderInputs.colorVector(for: pass))
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPESolidUniforms>.stride, index: 0)

        case "copy":
            let fragmentName = pass.pass.shader == "commands/copy"
                ? "wpe_copy_fragment"
                : "wpe_util_copy_fragment"
            encoder.setRenderPipelineState(try executor.renderPipeline(
                fragmentName: fragmentName,
                blendMode: pass.pass.blending,
                colorPixelFormat: destination.texture.pixelFormat,
                depthPixelFormat: depthPixelFormat
            ))
            let reference = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
            let texture = try WPEMetalShaderInputs.resolve(
                reference: reference,
                textures: textures,
                frameState: frameState,
                currentTargetID: destination.id
            )
            encoder.setFragmentTexture(texture, index: 0)
            if fragmentName == "wpe_copy_fragment" {
                var uniforms = WPEMetalShaderInputs.copyUniforms(for: pass, layer: layer)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPECopyUniforms>.stride, index: 0)
            }

        case "compose":
            encoder.setRenderPipelineState(try executor.renderPipeline(
                fragmentName: "wpe_compose_fragment",
                blendMode: pass.pass.blending,
                colorPixelFormat: destination.texture.pixelFormat,
                depthPixelFormat: depthPixelFormat
            ))
            let firstReference = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
            let secondReference = pass.textureBindings[1] ?? pass.pass.textures[1] ?? firstReference
            let firstTexture = try WPEMetalShaderInputs.resolve(
                reference: firstReference,
                textures: textures,
                frameState: frameState,
                currentTargetID: destination.id
            )
            let secondTexture = try WPEMetalShaderInputs.resolve(
                reference: secondReference,
                textures: textures,
                frameState: frameState,
                currentTargetID: destination.id
            )
            encoder.setFragmentTexture(firstTexture, index: 0)
            encoder.setFragmentTexture(secondTexture, index: 1)
            var uniforms = WPESolidUniforms(color: WPEMetalShaderInputs.colorVector(for: pass))
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPESolidUniforms>.stride, index: 0)

        case "effect_colorbalance":
            encoder.setRenderPipelineState(try executor.renderPipeline(
                fragmentName: "wpe_effect_colorbalance_fragment",
                blendMode: pass.pass.blending,
                colorPixelFormat: destination.texture.pixelFormat,
                depthPixelFormat: depthPixelFormat
            ))
            let reference = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
            let texture = try WPEMetalShaderInputs.resolve(
                reference: reference,
                textures: textures,
                frameState: frameState,
                currentTargetID: destination.id
            )
            encoder.setFragmentTexture(texture, index: 0)
            var uniforms = WPEColorBalanceUniforms(
                brightness: WPEMetalShaderInputs.floatScalar(
                    named: ["u_Brightness", "brightness", "g_BrightnessOffset"],
                    in: pass,
                    default: 0
                ),
                contrast: WPEMetalShaderInputs.floatScalar(
                    named: ["u_Contrast", "contrast"],
                    in: pass,
                    default: 1
                ),
                saturation: WPEMetalShaderInputs.floatScalar(
                    named: ["u_Saturation", "saturation"],
                    in: pass,
                    default: 1
                )
            )
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPEColorBalanceUniforms>.stride, index: 0)

        case "effect_blur":
            encoder.setRenderPipelineState(try executor.renderPipeline(
                fragmentName: "wpe_effect_blur_fragment",
                blendMode: pass.pass.blending,
                colorPixelFormat: destination.texture.pixelFormat,
                depthPixelFormat: depthPixelFormat
            ))
            let reference = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
            let texture = try WPEMetalShaderInputs.resolve(
                reference: reference,
                textures: textures,
                frameState: frameState,
                currentTargetID: destination.id
            )
            encoder.setFragmentTexture(texture, index: 0)
            var uniforms = WPEBlurUniforms(
                texelSize: SIMD2<Float>(
                    1 / Float(max(texture.width, 1)),
                    1 / Float(max(texture.height, 1))
                ),
                radius: WPEMetalShaderInputs.floatScalar(
                    named: ["u_Radius", "radius", "amount", "strength"],
                    in: pass,
                    default: 1
                )
            )
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPEBlurUniforms>.stride, index: 0)

        case "effect_vignette":
            encoder.setRenderPipelineState(try executor.renderPipeline(
                fragmentName: "wpe_effect_vignette_fragment",
                blendMode: pass.pass.blending,
                colorPixelFormat: destination.texture.pixelFormat,
                depthPixelFormat: depthPixelFormat
            ))
            let reference = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
            let texture = try WPEMetalShaderInputs.resolve(
                reference: reference,
                textures: textures,
                frameState: frameState,
                currentTargetID: destination.id
            )
            encoder.setFragmentTexture(texture, index: 0)
            var uniforms = WPEVignetteUniforms(
                innerRadius: WPEMetalShaderInputs.floatScalar(
                    named: ["u_InnerRadius", "innerRadius", "inner"],
                    in: pass,
                    default: 0.35
                ),
                outerRadius: WPEMetalShaderInputs.floatScalar(
                    named: ["u_OuterRadius", "outerRadius", "outer"],
                    in: pass,
                    default: 0.75
                ),
                intensity: WPEMetalShaderInputs.floatScalar(
                    named: ["u_Intensity", "intensity", "amount", "strength"],
                    in: pass,
                    default: 0.5
                )
            )
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPEVignetteUniforms>.stride, index: 0)

        case "effect_water":
            encoder.setRenderPipelineState(try executor.renderPipeline(
                fragmentName: "wpe_effect_water_fragment",
                blendMode: pass.pass.blending,
                colorPixelFormat: destination.texture.pixelFormat,
                depthPixelFormat: depthPixelFormat
            ))
            let reference = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
            let texture = try WPEMetalShaderInputs.resolve(
                reference: reference,
                textures: textures,
                frameState: frameState,
                currentTargetID: destination.id
            )
            encoder.setFragmentTexture(texture, index: 0)
            var uniforms = WPEWaterUniforms(
                amplitude: WPEMetalShaderInputs.floatScalar(
                    named: ["u_Amplitude", "amplitude", "amount", "strength"],
                    in: pass,
                    default: 0.01
                ),
                frequency: WPEMetalShaderInputs.floatScalar(
                    named: ["u_Frequency", "frequency", "scale"],
                    in: pass,
                    default: 20
                ),
                speed: WPEMetalShaderInputs.floatScalar(
                    named: ["u_Speed", "speed"],
                    in: pass,
                    default: 1
                ),
                time: WPEMetalShaderInputs.floatScalar(
                    named: "g_Time",
                    in: pass,
                    default: 0
                )
            )
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPEWaterUniforms>.stride, index: 0)

        case "effect_shake":
            encoder.setRenderPipelineState(try executor.renderPipeline(
                fragmentName: "wpe_effect_shake_fragment",
                blendMode: pass.pass.blending,
                colorPixelFormat: destination.texture.pixelFormat,
                depthPixelFormat: depthPixelFormat
            ))
            let reference = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
            let texture = try WPEMetalShaderInputs.resolve(
                reference: reference,
                textures: textures,
                frameState: frameState,
                currentTargetID: destination.id
            )
            encoder.setFragmentTexture(texture, index: 0)
            var uniforms = WPEShakeUniforms(
                magnitude: WPEMetalShaderInputs.floatScalar(
                    named: ["u_Magnitude", "magnitude", "amount", "strength"],
                    in: pass,
                    default: 0.01
                ),
                time: WPEMetalShaderInputs.floatScalar(
                    named: "g_Time",
                    in: pass,
                    default: 0
                ),
                frequency: WPEMetalShaderInputs.floatScalar(
                    named: ["u_Frequency", "frequency", "speed"],
                    in: pass,
                    default: 24
                )
            )
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPEShakeUniforms>.stride, index: 0)

        default:
            throw WPEMetalRenderExecutorError.unsupportedShader(pass.pass.shader)
        }
    }
}
