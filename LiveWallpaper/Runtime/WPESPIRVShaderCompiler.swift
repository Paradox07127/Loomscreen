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
        // 1. Pair-compile: glslang links vertex+fragment as one program so
        // their stage_in/out shapes match by construction. SPIRV-Cross then
        // emits both stages into one combined MSL source with renamed
        // entry points (`wpe_spv_vert` / `wpe_spv_frag`). The bridge's
        // default vertex uses `gl_VertexID` — no attribute buffers
        // needed, wire-compatible with the executor's draw setup.
        var mslPtr: UnsafeMutablePointer<CChar>?
        var diag: UnsafeMutablePointer<CChar>?
        let pairResult = request.processedVertexSource.withCString { vertexC in
            request.processedFragmentSource.withCString { fragmentC in
                wpe_shader_compile_pair_to_msl(vertexC, fragmentC, &mslPtr, &diag)
            }
        }
        guard pairResult == 0, let mslChars = mslPtr else {
            let message = Self.consumeDiag(diag)
            throw WPEShaderCompilerError.glslPreprocessFailed(
                "glslang/SPIRV-Cross pair-compile failed for '\(request.shaderName)': \(message)"
            )
        }
        let mslSource = String(cString: mslChars)
        free(mslChars)

        // 2. Reflection for uniform / sampler layout. Run on the fragment
        // SPIR-V only — uniforms/samplers are defined there for our
        // shader shape. Compile the fragment SPIR-V separately for this.
        var spirvBuffer: UnsafeMutablePointer<UInt32>?
        var spirvCount: Int = 0
        diag = nil
        let reflectGlslResult = request.processedVertexSource.withCString { vertexC in
            request.processedFragmentSource.withCString { fragmentC in
                wpe_shader_glsl_to_spirv(vertexC, fragmentC, &spirvBuffer, &spirvCount, &diag)
            }
        }
        var uniformLayout: [WPEUniformSlot] = []
        var samplerNames: [String] = []
        if reflectGlslResult == 0, let spirv = spirvBuffer {
            defer { wpe_shader_free_spirv(spirvBuffer) }
            var reflection = wpe_shader_reflection_result()
            var refDiag: UnsafeMutablePointer<CChar>?
            if wpe_shader_reflect_spirv(spirv, spirvCount, &reflection, &refDiag) == 0 {
                uniformLayout = Self.buildUniformLayout(reflection: reflection)
                samplerNames = Self.buildSamplerNames(reflection: reflection)
                wpe_shader_free_reflection(&reflection)
            } else {
                _ = Self.consumeDiag(refDiag)
            }
        } else {
            _ = Self.consumeDiag(diag)
        }

        // 3. MTLLibrary from the combined MSL source. Both stages compile
        // as one unit; the pipeline picks `wpe_spv_vert` + `wpe_spv_frag`.
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
            vertexFunctionName: "wpe_spv_vert",
            fragmentFunctionName: "wpe_spv_frag",
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
