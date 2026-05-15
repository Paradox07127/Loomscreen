import Foundation
import Metal

/// Boundary type for the WPE → MSL shader pipeline.
///
/// The runtime calls a `WPEShaderCompiling` to convert a preprocessed WPE
/// shader pair into a Metal library. Swap implementations to stage the
/// rollout: today the only shipping implementation is `WPEStubShaderCompiler`
/// which fails with `.backendUnavailable` — that keeps the dispatch path
/// intact so the executor can route custom shaders here without crashing
/// while the C++ backend (glslang + SPIRV-Cross) is being vendored.
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
    /// Raised by `WPEStubShaderCompiler` until the C++ backend lands.
    /// Phase 2 unblocker: vendor glslang + SPIRV-Cross, add a Swift wrapper
    /// that conforms to `WPEShaderCompiling`, and swap it in via
    /// `WPEMetalSceneRenderer`'s init seam. The dispatcher already routes
    /// custom shaders through this path, so the change becomes a one-line
    /// swap once the toolchain is integrated.
    case backendUnavailable(String)
    case glslPreprocessFailed(String)
    case translationFailed(String)
    case mslLibraryFailed(String)
}

/// Default shipping implementation. Always fails — the executor catches the
/// failure and downgrades the pass to a placeholder visual, surfacing a
/// diagnostic so the UI can show "needs shader translation". The non-throwing
/// init means the renderer can construct one in any environment, including
/// tests, without dragging in C++ symbols.
struct WPEStubShaderCompiler: WPEShaderCompiling {
    init() {}

    func compile(_ request: WPEShaderCompileRequest) throws -> WPEShaderCompileResult {
        throw WPEShaderCompilerError.backendUnavailable(
            "WPE shader translator not vendored yet — '\(request.shaderName)' deferred. See ThirdParty/WPEShaderToolchain (planned)."
        )
    }
}
