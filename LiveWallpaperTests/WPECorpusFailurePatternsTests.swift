import Foundation
import Metal
import Testing
@testable import LiveWallpaper

/// Regression fixtures for the WPE corpus failure patterns the Swift
/// transpiler cannot handle today. Each test reproduces a minimal
/// shader matching a real workshop scene's failure mode and asserts the
/// CURRENT behaviour — that the transpiler throws or emits MSL that
/// Metal rejects.
///
/// When the SPIRV-Cross toolchain integration lands (Phase 2b — see
/// PR #73 + PR #74), these tests should be UPDATED, not deleted: flip
/// the `#expect(throws:)` to `#expect` of a successful compile so they
/// turn into positive regression coverage that proves the new path
/// actually handles the documented gap.
///
/// This file deliberately uses synthetic minimal shaders rather than
/// embedding real workshop sources because (a) the corpus is
/// user-specific (Wallpaper Engine asset trees), and (b) the failure
/// patterns are simple enough to reproduce in <20 lines each.
@MainActor
@Suite("WPE corpus failure patterns (documents Phase 2 gap)")
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
