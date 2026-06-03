#if !LITE_BUILD
import Foundation
import Metal

/// Boundary type for the WPE → MSL shader pipeline.
///
/// `WPESwiftShaderCompiler` is the only shipping implementation; it wraps
/// the pure-Swift `WPEShaderTranspiler`. Shaders the transpiler can't
/// handle throw `.translationFailed`, which surfaces as
/// `SceneRenderingError.metalRendererUnsupported` (the scene's load error).
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
    /// Texture slots whose bound source is a WPE render target (`previous` or
    /// an FBO/layer composite). Those textures already store premultiplied
    /// RGB, so the transpiler un-premultiplies them before running the
    /// shader's straight-alpha math.
    let premultipliedInputSlots: Set<Int>
    /// Whether the translated fragment should premultiply its straight-alpha
    /// final color before returning, to match a premultiplied render-target
    /// pipeline.
    let premultipliedOutput: Bool

    init(
        shaderName: String,
        processedVertexSource: String,
        processedFragmentSource: String,
        sourceHash: String,
        comboValues: [String: Int],
        textureBindings: [Int: String],
        premultipliedInputSlots: Set<Int> = [],
        premultipliedOutput: Bool = false
    ) {
        self.shaderName = shaderName
        self.processedVertexSource = processedVertexSource
        self.processedFragmentSource = processedFragmentSource
        self.sourceHash = sourceHash
        self.comboValues = comboValues
        self.textureBindings = textureBindings
        self.premultipliedInputSlots = premultipliedInputSlots
        self.premultipliedOutput = premultipliedOutput
    }

    /// Cache key that distinguishes premultiplied-alpha translation variants of
    /// an otherwise identical shader source (same `sourceHash`).
    var translationCacheKey: String {
        var key = sourceHash
        if premultipliedOutput {
            key += "|pma-output"
        }
        if !premultipliedInputSlots.isEmpty {
            key += "|pma-inputs:"
                + premultipliedInputSlots.sorted().map(String.init).joined(separator: ",")
        }
        return key
    }

    func replacingPremultipliedAlphaSettings(
        inputSlots: Set<Int>,
        output: Bool
    ) -> WPEShaderCompileRequest {
        WPEShaderCompileRequest(
            shaderName: shaderName,
            processedVertexSource: processedVertexSource,
            processedFragmentSource: processedFragmentSource,
            sourceHash: sourceHash,
            comboValues: comboValues,
            textureBindings: textureBindings,
            premultipliedInputSlots: inputSlots,
            premultipliedOutput: output
        )
    }
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
    case glslPreprocessFailed(String)
    case translationFailed(String)
    case mslLibraryFailed(String)
}
#endif
