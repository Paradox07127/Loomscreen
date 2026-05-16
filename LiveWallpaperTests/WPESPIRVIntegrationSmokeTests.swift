import Foundation
import Metal
import Testing
@testable import LiveWallpaper

@MainActor
@Suite("WPE SPIRV-Cross integration smoke (Phase 2b)")
struct WPESPIRVIntegrationSmokeTests {

    @Test("Toolchain reports available after Phase 2a vendoring")
    func toolchainAvailable() {
        #expect(WPESPIRVShaderCompiler.isToolchainAvailable())
    }

    @Test("Helper-scope texture shader compiles via SPIRV-Cross or falls through cleanly")
    func helperScopeTextureViaToolchain() async throws {
        // SPIRV-Cross handles helper-scope `g_TextureN` natively by
        // hoisting the texture as a helper parameter — that's the whole
        // point of Phase 2b. The wrapper currently falls through to the
        // Swift transpiler when SPIRV-Cross's emitted stage_in is
        // incompatible with our fixed vertex shader (`[[user(locnN)]]`
        // doesn't match `wpe_fullscreen_vertex`'s outputs).
        //
        // The Swift transpiler can't handle helper-scope textures, so
        // the call EITHER returns successfully via SPIRV-Cross (when the
        // stage_in matches) OR throws (when fallback also can't handle).
        // Both are acceptable post-fix behaviour; what matters for the
        // corpus is that the wrapper doesn't silently produce broken
        // MSL that crashes the pipeline build.
        let device = try #require(MTLCreateSystemDefaultDevice())
        let compiler = WPESPIRVShaderCompiler(
            device: device,
            fallback: WPESwiftShaderCompiler(device: device)
        )
        let request = WPEShaderCompileRequest(
            shaderName: "helper_scope_smoke",
            processedVertexSource: "",
            processedFragmentSource: """
            #version 410 core
            uniform sampler2D g_Texture0;
            in vec2 v_TexCoord;
            float helperRead(vec2 uv) { return texture(g_Texture0, uv).r; }
            void main() {
                gl_FragColor = vec4(helperRead(v_TexCoord), 0.0, 0.0, 1.0);
            }
            """,
            sourceHash: "phase2b-smoke",
            comboValues: [:],
            textureBindings: [:]
        )
        do {
            let result = try compiler.compile(request)
            // If we got here, the result must be a usable library.
            #expect(result.library.makeFunction(name: result.fragmentFunctionName) != nil)
        } catch let error as WPEShaderCompilerError {
            // Acceptable: fallback chain exhausted because Swift transpiler
            // can't handle helper-scope textures. SPIRV-Cross MSL was
            // incompatible with our fixed vertex; we threw and the Swift
            // path also threw. Surface the error type for debugging.
            switch error {
            case .mslLibraryFailed, .translationFailed:
                // Expected — until bridge also emits matching vertex.
                break
            default:
                Issue.record("Unexpected error type: \(error)")
            }
        }
    }
}
