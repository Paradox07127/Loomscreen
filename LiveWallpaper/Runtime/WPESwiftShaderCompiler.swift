import Foundation
import Metal

/// `WPEShaderCompiling` implementation that uses `WPEShaderTranspiler` to
/// emit MSL and `MTLDevice.makeLibrary(source:)` to compile it. Replaces
/// `WPEStubShaderCompiler` as the default the renderer ships with — this
/// is the actual unblocker for the scene corpus that depends on custom
/// effect shaders.
///
/// Falls back to throwing `.translationFailed` for shaders the transpiler
/// can't handle (multi-pass effects, vertex shaders that aren't the
/// fullscreen quad, anything that uses `gl_FragCoord` without a
/// converted equivalent). The dispatcher catches the throw and surfaces
/// the precise reason so the UI can show "needs deeper translator".
struct WPESwiftShaderCompiler: WPEShaderCompiling {
    let device: MTLDevice

    init(device: MTLDevice) {
        self.device = device
    }

    func compile(_ request: WPEShaderCompileRequest) throws -> WPEShaderCompileResult {
        let translation: WPEShaderTranslationResult
        do {
            translation = try WPEShaderTranspiler.translateFragment(
                shaderName: request.shaderName,
                preprocessedSource: request.processedFragmentSource
            )
        } catch let err as WPEShaderCompilerError {
            throw err
        } catch {
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
            throw WPEShaderCompilerError.mslLibraryFailed(
                "Metal rejected translated MSL for '\(request.shaderName)': \(error.localizedDescription). MSL was: \(translation.mslSource.prefix(800))"
            )
        }

        // Transpiler always emits a single fragment named
        // `wpe_translated_fragment` and shares the executor's existing
        // `wpe_fullscreen_vertex` for the vertex stage. That keeps the
        // pipeline cache key compact.
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
}
