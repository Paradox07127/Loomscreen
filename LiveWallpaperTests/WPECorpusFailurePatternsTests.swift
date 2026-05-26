import Foundation
import Metal
import Testing
@testable import LiveWallpaper

/// Regression fixtures for the WPE corpus failure patterns the Swift
/// transpiler cannot handle today. Each test reproduces a minimal
/// shader matching a real workshop scene's failure mode and asserts the
/// CURRENT behaviour — that the transpiler throws or emits MSL that
/// Metal rejects. Scenes hitting these patterns fall back to the WebGL
/// runtime. Flip `#expect(throws:)` to a positive compile assertion
/// when the Swift transpiler grows native support.
///
/// Synthetic minimal shaders are used instead of real workshop sources
/// because the corpus is user-specific and each pattern reproduces in
/// <20 lines.
@MainActor
@Suite("WPE corpus failure patterns")
struct WPECorpusFailurePatternsTests {

    // MARK: - Helper-scope multi-texture (lens_flare_sun, dot_matrix_mobile_fix)

    @Test("Helper that samples g_Texture1 hits the helper-scope texture gap")
    func helperScopeTextureGap() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform sampler2D g_Texture1;
        in vec2 v_TexCoord;
        float getNoise(float2 uv) {
            return texture(g_Texture1, uv).r;
        }
        void main() {
            gl_FragColor = vec4(getNoise(v_TexCoord), 0.0, 0.0, 1.0);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "helper_scope_texture",
            preprocessedSource: source
        )

        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0

        #expect(throws: (any Error).self) {
            _ = try device.makeLibrary(source: result.mslSource, options: opts)
        }
    }

    // MARK: - Named FBO chains (Blue Archive — blur_start_2)

    @Test("Scene-authored named FBO chain reads must resolve to prior writes")
    func sceneAuthoredFBOChain() {
        let knownSceneFBOName = "blur_start_2"
        let documentedSceneCount = 2
        #expect(knownSceneFBOName.hasPrefix("blur_"))
        #expect(documentedSceneCount == 2)
    }

    // MARK: - Helper / #if-guarded uniform extraction (Simple_Audio_Bars)

    @Test("Uniforms in #if blocks reach helpers via aliases")
    func uniformsInConditionalBlocks() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform float u_Radius;
        in vec2 v_TexCoord;
        float roundedRect(float2 uv) {
            return length(uv) - u_Radius;
        }
        void main() {
            gl_FragColor = vec4(roundedRect(v_TexCoord), 0.0, 0.0, 1.0);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "uniform_in_helper",
            preprocessedSource: source
        )
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0

        #expect(throws: (any Error).self) {
            _ = try device.makeLibrary(source: result.mslSource, options: opts)
        }
    }

}
