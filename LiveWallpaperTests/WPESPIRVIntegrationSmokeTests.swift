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

    @Test("Helper-scope texture shader now compiles via SPIRV-Cross")
    func helperScopeTextureViaToolchain() async throws {
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
        let result = try compiler.compile(request)
        #expect(result.mslSource.contains("helperRead"))
        #expect(result.library.makeFunction(name: result.fragmentFunctionName) != nil)
    }
}
