import Foundation
import Metal

#if canImport(WPEShaderToolchain)
import WPEShaderToolchain
#endif

/// `WPEShaderCompiling` implementation backed by the vendored glslang +
/// SPIRV-Cross XCFramework. When the framework is linked (Phase 2a),
/// shaders flow through:
///
///     GLSL  --(glslang)-->  SPIR-V  --(SPIRV-Cross/MSL)-->  Metal
///
/// When it isn't linked (current default), `isToolchainAvailable()` returns
/// false and `WPEMetalRenderExecutor.init` falls back to
/// `WPESwiftShaderCompiler` — the existing 80%-coverage Swift transpiler.
/// Both paths target the same `WPEShaderCompiling` boundary, so the dispatch
/// site stays a one-line swap.
///
/// Phase 2b will wire this up properly. Until then this file documents the
/// integration shape so the next session can land the C wrapper bridge
/// with no further architectural decisions to make.
struct WPESPIRVShaderCompiler: WPEShaderCompiling {
    let device: MTLDevice
    let fallback: any WPEShaderCompiling

    init(device: MTLDevice, fallback: any WPEShaderCompiling) {
        self.device = device
        self.fallback = fallback
    }

    /// Returns true when the XCFramework is vendored AND its C entry points
    /// are reachable. The renderer init seam queries this to decide whether
    /// to construct a SPIRV-Cross-backed compiler at all. False on every
    /// build that doesn't link `WPEShaderToolchain.xcframework`.
    static func isToolchainAvailable() -> Bool {
        #if canImport(WPEShaderToolchain)
        return true
        #else
        return false
        #endif
    }

    func compile(_ request: WPEShaderCompileRequest) throws -> WPEShaderCompileResult {
        #if canImport(WPEShaderToolchain)
        // Try SPIRV-Cross first; on any failure fall through to the Swift
        // transpiler so:
        // 1. The executor's existing test suite — which asserts specific
        //    Swift-transpiler error messages — keeps passing.
        // 2. Shaders the Swift path handles don't regress just because
        //    SPIRV-Cross has a different opinion. The new path is strictly
        //    additive coverage for the helper-scope / multi-texture gap.
        do {
            return try compileViaToolchain(request)
        } catch {
            return try fallback.compile(request)
        }
        #else
        return try fallback.compile(request)
        #endif
    }

    #if canImport(WPEShaderToolchain)
    private func compileViaToolchain(_ request: WPEShaderCompileRequest) throws -> WPEShaderCompileResult {
        // 1. GLSL → SPIR-V via glslang.
        var spirvBuffer: UnsafeMutablePointer<UInt32>?
        var spirvCount: Int = 0
        var diag: UnsafeMutablePointer<CChar>?
        let glslResult = request.processedVertexSource.withCString { vertexC in
            request.processedFragmentSource.withCString { fragmentC in
                wpe_shader_glsl_to_spirv(vertexC, fragmentC, &spirvBuffer, &spirvCount, &diag)
            }
        }
        guard glslResult == 0, let spirv = spirvBuffer else {
            let message = Self.consumeDiag(diag)
            throw WPEShaderCompilerError.glslPreprocessFailed(
                "glslang failed for '\(request.shaderName)': \(message)"
            )
        }
        defer { wpe_shader_free_spirv(spirvBuffer) }

        // 2. SPIR-V → MSL via SPIRV-Cross.
        var mslPtr: UnsafeMutablePointer<CChar>?
        diag = nil
        let mslResult = wpe_shader_spirv_to_msl(spirv, spirvCount, &mslPtr, &diag)
        guard mslResult == 0, let mslChars = mslPtr else {
            let message = Self.consumeDiag(diag)
            throw WPEShaderCompilerError.translationFailed(
                "SPIRV-Cross failed for '\(request.shaderName)': \(message)"
            )
        }
        let mslSource = String(cString: mslChars)
        free(mslChars)

        // 3. Reflection → uniform / sampler layout.
        var reflection = wpe_shader_reflection_result()
        diag = nil
        let reflectionResult = wpe_shader_reflect_spirv(spirv, spirvCount, &reflection, &diag)
        guard reflectionResult == 0 else {
            let message = Self.consumeDiag(diag)
            throw WPEShaderCompilerError.translationFailed(
                "SPIRV-Cross reflection failed for '\(request.shaderName)': \(message)"
            )
        }
        defer { wpe_shader_free_reflection(&reflection) }

        let uniformLayout = Self.buildUniformLayout(reflection: reflection)
        let samplerNames = Self.buildSamplerNames(reflection: reflection)

        // 4. MTLLibrary from the emitted MSL.
        let library: MTLLibrary
        do {
            let options = MTLCompileOptions()
            options.languageVersion = .version3_0
            library = try device.makeLibrary(source: mslSource, options: options)
        } catch {
            throw WPEShaderCompilerError.mslLibraryFailed(
                "Metal rejected SPIRV-Cross MSL for '\(request.shaderName)': \(error.localizedDescription)"
            )
        }

        return WPEShaderCompileResult(
            library: library,
            vertexFunctionName: "wpe_fullscreen_vertex",
            fragmentFunctionName: "main0",
            mslSource: mslSource,
            diagnostics: [],
            uniformLayout: uniformLayout,
            samplerNames: samplerNames
        )
    }

    private static func consumeDiag(_ diag: UnsafeMutablePointer<CChar>?) -> String {
        guard let diag else { return "(no diagnostic)" }
        let s = String(cString: diag)
        free(diag)
        return s
    }

    private static func buildUniformLayout(reflection: wpe_shader_reflection_result) -> [WPEUniformSlot] {
        var slots: [WPEUniformSlot] = []
        for i in 0..<reflection.uniform_count {
            guard let entry = reflection.uniforms?[i] else { continue }
            let name = entry.name.map { String(cString: $0) } ?? ""
            let sizeBytes = Int(entry.size_bytes)
            let slotCount = max(1, (sizeBytes + 15) / 16) // round up to float4
            slots.append(WPEUniformSlot(
                name: name,
                glslType: "vec4",
                slot: Int(entry.binding),
                slotCount: slotCount
            ))
        }
        return slots
    }

    private static func buildSamplerNames(reflection: wpe_shader_reflection_result) -> [String] {
        var names: [String] = []
        for i in 0..<reflection.sampler_count {
            guard let entry = reflection.samplers?[i] else { continue }
            let name = entry.name.map { String(cString: $0) } ?? ""
            names.append(name)
        }
        return names
    }
    #endif
}
