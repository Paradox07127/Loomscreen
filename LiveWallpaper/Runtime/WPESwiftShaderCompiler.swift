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
    /// rather than crashing Metal.
    static let fixedVertexFunctionName = "wpe_fullscreen_vertex"

    func compile(_ request: WPEShaderCompileRequest, recordFailure: Bool) throws -> WPEShaderCompileResult {
        let translation: WPEShaderTranslationResult
        let fragmentSource = Self.fragmentSourceByAddingVertexUniformsIfNeeded(
            fragmentSource: request.processedFragmentSource,
            vertexSource: request.processedVertexSource
        )
        do {
            translation = try WPEMetalTranspileTimer.measure {
                try WPEShaderTranspiler.translateFragment(
                    shaderName: request.shaderName,
                    preprocessedSource: fragmentSource,
                    comboValues: request.comboValues,
                    premultipliedInputSlots: request.premultipliedInputSlots,
                    premultipliedOutput: request.premultipliedOutput
                )
            }
        } catch let err as WPEShaderCompilerError {
            if recordFailure {
                WPESceneDebugArtifacts.shared.recordShaderFailure(
                    shaderName: request.shaderName,
                    originalVertex: nil,
                    processedVertex: request.processedVertexSource,
                    originalFragment: nil,
                    processedFragment: request.processedFragmentSource,
                    translatedMSL: nil,
                    errorText: "translation failed: \(String(describing: err))"
                )
            }
            throw err
        } catch {
            if recordFailure {
                WPESceneDebugArtifacts.shared.recordShaderFailure(
                    shaderName: request.shaderName,
                    originalVertex: nil,
                    processedVertex: request.processedVertexSource,
                    originalFragment: nil,
                    processedFragment: request.processedFragmentSource,
                    translatedMSL: nil,
                    errorText: "transpiler crashed: \(error)"
                )
            }
            throw WPEShaderCompilerError.translationFailed(
                "transpiler crashed for '\(request.shaderName)': \(error)"
            )
        }

        let library: MTLLibrary
        do {
            let options = MTLCompileOptions()
            options.languageVersion = .version3_0
            library = try WPEMetalCompileTimer.measure { try device.makeLibrary(source: translation.mslSource, options: options) }
        } catch {
            if recordFailure {
                WPESceneDebugArtifacts.shared.recordShaderFailure(
                    shaderName: request.shaderName,
                    originalVertex: nil,
                    processedVertex: request.processedVertexSource,
                    originalFragment: nil,
                    processedFragment: request.processedFragmentSource,
                    translatedMSL: translation.mslSource,
                    errorText: "Metal rejected MSL: \(error.localizedDescription)"
                )
            }
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
        // Scan the fragment AFTER branch stripping: a uniform declared only in an
        // inactive `#if` (auto_sway's g_Speed/g_Inertia/g_SigmentCount under
        // AA_VERSION == 1) would otherwise count as existing, get skipped here,
        // and then vanish with its branch — leaving the active code without it.
        let activeFragment = WPEShaderTranspiler.sourceWithInactiveBranchesStripped(fragmentSource)
        let existing = Set(uniformDeclarations(in: activeFragment).map(\.name))
        let activeVertex = WPEShaderTranspiler.sourceWithInactiveBranchesStripped(vertexSource)
        var seen = Set<String>()
        // Inject the ORIGINAL declaration lines: the trailing `// {"material":…}`
        // annotation is what binds the scene's constantshadervalues (and carries
        // the shader default) — a bare re-declaration would silently unbind them.
        let missingLines = activeVertex.components(separatedBy: .newlines).compactMap { raw -> String? in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard let uniform = WPEUniformDecl.parse(line: trimmed),
                  !existing.contains(uniform.name),
                  seen.insert(uniform.name).inserted,
                  shouldExposeVertexUniformToFragment(uniform) else { return nil }
            return trimmed
        }
        guard !missingLines.isEmpty else { return fragmentSource }
        return missingLines.joined(separator: "\n") + "\n" + fragmentSource
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
