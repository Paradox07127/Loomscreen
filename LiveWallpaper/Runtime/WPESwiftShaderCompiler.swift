#if !LITE_BUILD
import Foundation
import Metal

/// `WPEShaderCompiling` implementation that uses `WPEShaderTranspiler` to
/// emit MSL and `MTLDevice.makeLibrary(source:)` to compile it. Shaders it
/// can't handle throw `.translationFailed`, which `WPEMetalSceneRenderer`
/// surfaces as `SceneRenderingError.metalRendererUnsupported`.
struct WPESwiftShaderCompiler: WPEShaderCompiling {
    let device: MTLDevice

    init(device: MTLDevice) {
        self.device = device
    }

    func compile(_ request: WPEShaderCompileRequest) throws -> WPEShaderCompileResult {
        if let reason = Self.unsupportedVertexVaryingReason(for: request) {
            WPESceneDebugArtifacts.shared.recordShaderFailure(
                shaderName: request.shaderName,
                originalVertex: nil,
                processedVertex: request.processedVertexSource,
                originalFragment: nil,
                processedFragment: request.processedFragmentSource,
                translatedMSL: nil,
                errorText: "translation rejected: \(reason)"
            )
            throw WPEShaderCompilerError.translationFailed(reason)
        }

        let translation: WPEShaderTranslationResult
        do {
            translation = try WPEShaderTranspiler.translateFragment(
                shaderName: request.shaderName,
                preprocessedSource: request.processedFragmentSource
            )
        } catch let err as WPEShaderCompilerError {
            WPESceneDebugArtifacts.shared.recordShaderFailure(
                shaderName: request.shaderName,
                originalVertex: nil,
                processedVertex: request.processedVertexSource,
                originalFragment: nil,
                processedFragment: request.processedFragmentSource,
                translatedMSL: nil,
                errorText: "translation failed: \(String(describing: err))"
            )
            throw err
        } catch {
            WPESceneDebugArtifacts.shared.recordShaderFailure(
                shaderName: request.shaderName,
                originalVertex: nil,
                processedVertex: request.processedVertexSource,
                originalFragment: nil,
                processedFragment: request.processedFragmentSource,
                translatedMSL: nil,
                errorText: "transpiler crashed: \(error)"
            )
            throw WPEShaderCompilerError.translationFailed(
                "transpiler crashed for '\(request.shaderName)': \(error)"
            )
        }

        let library: MTLLibrary
        do {
            let options = MTLCompileOptions()
            options.languageVersion = .version3_0
            library = try device.makeLibrary(source: translation.mslSource, options: options)
        } catch {
            WPESceneDebugArtifacts.shared.recordShaderFailure(
                shaderName: request.shaderName,
                originalVertex: nil,
                processedVertex: request.processedVertexSource,
                originalFragment: nil,
                processedFragment: request.processedFragmentSource,
                translatedMSL: translation.mslSource,
                errorText: "Metal rejected MSL: \(error.localizedDescription)"
            )
            // Don't inline the generated MSL into the thrown reason: it
            // can flow into user-facing diagnostics, and the full source
            // has already been written to `WPESceneDebugArtifacts` above
            // for offline inspection.
            throw WPEShaderCompilerError.mslLibraryFailed(
                "Metal rejected translated MSL for '\(request.shaderName)': \(error.localizedDescription)"
            )
        }

        return WPEShaderCompileResult(
            library: library,
            vertexFunctionName: "wpe_fullscreen_vertex",
            fragmentFunctionName: "wpe_translated_fragment",
            mslSource: translation.mslSource,
            diagnostics: [],
            uniformLayout: translation.uniformLayout,
            samplerNames: translation.samplers
        )
    }

    private static func unsupportedVertexVaryingReason(for request: WPEShaderCompileRequest) -> String? {
        let perspectiveVarying = "v_TexCoordFx"
        guard request.processedVertexSource.contains(perspectiveVarying),
              request.processedFragmentSource.contains(perspectiveVarying) else {
            return nil
        }
        return "perspective vertex varying '\(perspectiveVarying)' requires custom vertex shader translation"
    }
}
#endif
