#if !LITE_BUILD
import Foundation
import Metal

/// Boundary type for the WPE → MSL shader pipeline.
///
/// `WPESwiftShaderCompiler` is the only shipping implementation; it wraps
/// the pure-Swift `WPEShaderTranspiler` (Phase-12 dual-backend strategy
/// retired the SPIRV-Cross/glslang XCFramework). Shaders the transpiler
/// can't handle throw `.translationFailed`, which surfaces as
/// `SceneRenderingError.metalRendererUnsupported`; automatic sessions can
/// use that as the WebGL fallback signal.
protocol WPEShaderCompiling: Sendable {
    func compile(_ request: WPEShaderCompileRequest) throws -> WPEShaderCompileResult
}

/// One compile job. The `processed*Source` strings are already through
/// `WPEShaderPreprocessor` (combos baked in, includes resolved, WPE macros
/// rewritten). The compiler only needs to translate canonical GLSL to MSL.
struct WPEShaderCompileRequest: Sendable, Hashable {
    let shaderName: String
    let processedVertexSource: String
    let processedFragmentSource: String
    /// Stable hash of the (raw vertex source, raw fragment source, combo
    /// values) tuple. Used as the disk-cache key by
    /// `WPEShaderTranslationCache`.
    let sourceHash: String
    /// Raw `// [COMBO]` declarations the preprocessor saw, after combo
    /// values were merged in. Surfaced to the executor so reflection lookups
    /// know which `#define`s shipped to the GPU.
    let comboValues: [String: Int]
    /// Texture binding declarations from `// [BIND]` lines plus material
    /// `textures` array. Index → logical name. The executor maps these to
    /// MTL texture slots.
    let textureBindings: [Int: String]
}

struct WPEShaderCompileResult: @unchecked Sendable {
    let library: MTLLibrary
    let vertexFunctionName: String
    let fragmentFunctionName: String
    /// Generated MSL source, kept for disk caching and snapshot tests.
    let mslSource: String
    /// Diagnostics from the underlying compiler (warnings, info). Empty in
    /// the happy path; surfaced verbatim to make corpus regressions obvious.
    let diagnostics: [String]
    /// Per-uniform float4 slot assignment matching the layout the
    /// transpiler emitted. The dispatcher walks this to pack the runtime
    /// uniform buffer. Empty when the shader took no uniforms.
    let uniformLayout: [WPEUniformSlot]
    /// Names of the texture samplers the shader expects, ordered by slot.
    let samplerNames: [String]
}

enum WPEShaderCompilerError: Error, Sendable, Equatable {
    /// Retained for backwards compatibility on archived diagnostics; the
    /// Phase-12 shipping path never raises this — `WPESwiftShaderCompiler`
    /// throws `.translationFailed` instead when it can't handle a shader.
    case backendUnavailable(String)
    case glslPreprocessFailed(String)
    case translationFailed(String)
    case mslLibraryFailed(String)
}
#endif
