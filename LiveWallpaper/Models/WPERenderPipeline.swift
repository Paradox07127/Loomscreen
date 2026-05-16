#if !LITE_BUILD
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

extension WPEPreparedRenderPipeline {
    /// Phase 2B: returns a copy of the pipeline with per-frame Metal runtime
    /// + camera uniforms merged into every pass's `uniformValues`. Material
    /// uniforms (e.g. `g_Color`) win on key collision so existing tests stay
    /// green; runtime keys (`g_Time`, `g_Daytime`, `g_Brightness`,
    /// `g_PointerPosition`, `g_ViewProjectionMatrix`) only fill in slots the
    /// pass did not already define.
    func addingMetalRuntimeUniforms(
        _ runtimeUniforms: WPEMetalRuntimeUniforms,
        camera: WPEMetalCameraUniforms
    ) -> WPEPreparedRenderPipeline {
        WPEPreparedRenderPipeline(
            layers: layers.map { layer in
                WPEPreparedRenderLayer(
                    graphLayer: layer.graphLayer,
                    passes: layer.passes.map { pass in
                        var values = pass.uniformValues
                        // Runtime uniforms (`g_Time`, `g_Daytime`,
                        // `g_Brightness`, `g_PointerPosition`,
                        // `g_ViewProjectionMatrix`) are reserved names. Always
                        // overwrite so a stale per-load default never wins
                        // over the live frame value.
                        for (key, value) in runtimeUniforms.uniformValues {
                            values[key] = value
                        }
                        for (key, value) in camera.uniformValues {
                            values[key] = value
                        }
                        return WPEPreparedRenderPass(
                            pass: pass.pass,
                            shader: pass.shader,
                            textureBindings: pass.textureBindings,
                            comboValues: pass.comboValues,
                            uniformValues: values
                        )
                    }
                )
            }
        )
    }
}

enum WPERenderPipelineError: Error, Equatable, LocalizedError, Sendable {
    case shaderMissing(name: String, stage: String, path: String)
    case includeMissing(path: String, requestedBy: String)
    case includeCycle(path: String)
    case invalidSourceEncoding(path: String)

    var errorDescription: String? {
        switch self {
        case .shaderMissing(let name, let stage, let path):
            return String(
                localized: "error.render.pipeline.shader_missing",
                defaultValue: "WPE shader \(name) is missing \(stage) source at \(path)",
                comment: "Error shown when a Wallpaper Engine shader source file is missing."
            )
        case .includeMissing(let path, let requestedBy):
            return String(
                localized: "error.render.pipeline.include_missing",
                defaultValue: "WPE shader include \(path) requested by \(requestedBy) is missing",
                comment: "Error shown when a Wallpaper Engine shader include file is missing."
            )
        case .includeCycle(let path):
            return String(
                localized: "error.render.pipeline.include_cycle",
                defaultValue: "WPE shader include cycle detected at \(path)",
                comment: "Error shown when a Wallpaper Engine shader include cycle is detected."
            )
        case .invalidSourceEncoding(let path):
            return String(
                localized: "error.render.pipeline.invalid_source_encoding",
                defaultValue: "WPE shader source is not UTF-8: \(path)",
                comment: "Error shown when a Wallpaper Engine shader source file is not UTF-8."
            )
        }
    }
}
#endif
