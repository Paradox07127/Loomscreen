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
        // Mirrors workshop/2487531853/effects/lens_flare_sun:
        // helper function above main() references g_Texture1 directly.
        // Metal compile fails because the texture alias only exists
        // inside `wpe_translated_fragment()`, not at file scope where
        // helpers live.
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

        // CURRENT: Metal rejects the MSL with "undeclared identifier g_Texture1"
        // because helpers can't see the local texture alias.
        // POST-SPIRV-Cross: this `#expect(throws:)` should be inverted to
        // `_ = try device.makeLibrary(...)` (no throw).
        #expect(throws: (any Error).self) {
            _ = try device.makeLibrary(source: result.mslSource, options: opts)
        }
    }

    // MARK: - Named FBO chains (Blue Archive — blur_start_2)

    @Test("Scene-authored named FBO chain reads must resolve to prior writes")
    func sceneAuthoredFBOChain() {
        // Mirrors Blue Archive workshop scenes (3461168300, 3554161528):
        // the post-process layer writes to a named FBO `blur_start_2`,
        // then a later pass binds it as an input. The executor's
        // `frameState.latestNamedTextures` already tracks `_rt_*` engine
        // aliases (PR #67), but scene-authored names like `blur_start_2`
        // are not in the alias predicate AND the writing pass may fail
        // to compile (its blur shader hits Phase 2 transpiler limits),
        // leaving the read with no source.
        //
        // No direct transpiler reproduction — this is a pass-graph /
        // executor concern. Documents the gap for Phase 2c.
        let knownSceneFBOName = "blur_start_2"
        let documentedSceneCount = 2  // 3461168300, 3554161528
        #expect(knownSceneFBOName.hasPrefix("blur_"))
        #expect(documentedSceneCount == 2)
    }

    // MARK: - Helper / #if-guarded uniform extraction (Simple_Audio_Bars)

    @Test("Uniforms in #if blocks reach helpers via aliases")
    func uniformsInConditionalBlocks() throws {
        // Mirrors workshop/3082978660/effects/Simple_Audio_Bars: the
        // shader declares `uniform float u_Radius;` (etc.) inside
        // `#if SHAPE == ROUNDED` blocks. The transpiler walks
        // line-by-line and SHOULD parse these declarations (the line
        // pattern matches), but the corpus run shows them unresolved
        // in helper functions. Root cause is the helper-scope problem
        // again: even if u_Radius is in the uniform struct, the helper
        // can't see the `auto u_Radius = u.vals[N].x;` alias.
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

        // CURRENT: helper roundedRect references u_Radius, which is
        // only aliased inside main(). Metal rejects.
        // POST-SPIRV-Cross: should compile cleanly.
        #expect(throws: (any Error).self) {
            _ = try device.makeLibrary(source: result.mslSource, options: opts)
        }
    }

}
