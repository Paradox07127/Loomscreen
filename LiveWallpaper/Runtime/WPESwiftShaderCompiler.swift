#if !LITE_BUILD
import Foundation
import Metal

/// `WPEShaderCompiling` implementation that uses `WPEShaderTranspiler` to
/// emit MSL and `MTLDevice.makeLibrary(source:)` to compile it. Shaders it
/// can't handle throw `.translationFailed`, which `WPEMetalSceneRenderer`
/// surfaces as `SceneRenderingError.metalRendererUnsupported`.
struct WPESwiftShaderCompiler: WPEShaderCompiling {
    let device: MTLDevice
    /// Fragment-only compiler contract: vertex execution always stays on the
    /// built-in fullscreen quad. Model/vertex-domain shaders are never compiled
    /// here — they surface a `.translationFailed`/`.mslLibraryFailed` diagnostic
    /// and fall back (WebGL) rather than crashing Metal.
    static let fixedVertexFunctionName = "wpe_fullscreen_vertex"

    init(device: MTLDevice) {
        self.device = device
    }

    func compile(_ request: WPEShaderCompileRequest) throws -> WPEShaderCompileResult {
        let translation: WPEShaderTranslationResult
        let fragmentSource = Self.fragmentSourceByAddingVertexUniformsIfNeeded(
            fragmentSource: request.processedFragmentSource,
            vertexSource: request.processedVertexSource
        )
        do {
            translation = try WPEShaderTranspiler.translateFragment(
                shaderName: request.shaderName,
                preprocessedSource: fragmentSource,
                comboValues: request.comboValues
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
            vertexFunctionName: Self.fixedVertexFunctionName,
            fragmentFunctionName: "wpe_translated_fragment",
            mslSource: translation.mslSource,
            diagnostics: [],
            uniformLayout: translation.uniformLayout,
            samplerNames: translation.samplers
        )
    }

    private static func fragmentSourceByAddingVertexUniformsIfNeeded(
        fragmentSource: String,
        vertexSource: String
    ) -> String {
        let existing = Set(uniformDeclarations(in: fragmentSource).map(\.name))
        let missing = uniformDeclarations(in: vertexSource).filter { uniform in
            !existing.contains(uniform.name) && shouldExposeVertexUniformToFragment(uniform)
        }
        guard !missing.isEmpty else { return fragmentSource }
        let declarations = missing
            .map { "uniform \($0.type) \($0.name)\(arraySuffix(for: $0));" }
            .joined(separator: "\n")
        return declarations + "\n" + fragmentSource
    }

    private static func uniformDeclarations(in source: String) -> [WPEUniformDecl] {
        source.components(separatedBy: .newlines).compactMap { raw in
            WPEUniformDecl.parse(line: raw.trimmingCharacters(in: .whitespaces))
        }
    }

    private static func shouldExposeVertexUniformToFragment(_ uniform: WPEUniformDecl) -> Bool {
        !uniform.type.hasPrefix("mat") && !uniform.name.hasPrefix("g_Model")
    }

    private static func arraySuffix(for uniform: WPEUniformDecl) -> String {
        guard let arrayLength = uniform.arrayLength else { return "" }
        return "[\(arrayLength)]"
    }
}
#endif
