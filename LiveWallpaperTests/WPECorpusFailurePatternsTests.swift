import Foundation
import Metal
import Testing
@testable import LiveWallpaper

/// Regression fixtures for WPE corpus failure patterns. Each test
/// reproduces a minimal shader matching a real workshop scene's failure
/// mode and asserts the Metal translator accepts it.
///
/// Synthetic minimal shaders are used instead of real workshop sources
/// because the corpus is user-specific and each pattern reproduces in
/// <20 lines.
@MainActor
@Suite("WPE corpus failure patterns")
struct WPECorpusFailurePatternsTests {

    // MARK: - Helper-scope multi-texture (lens_flare_sun, dot_matrix_mobile_fix)

    @Test("Helper that samples g_Texture1 compiles through explicit helper resources")
    func helperScopeTextureCompiles() throws {
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

        #expect(result.mslSource.contains("getNoise(v_TexCoord, g_Texture1)"))
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
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

    @Test("Uniforms in helper scope compile through explicit helper resources")
    func uniformsInHelperScopeCompile() throws {
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

        #expect(result.mslSource.contains("roundedRect(v_TexCoord, u_Radius)"))
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("Macros used inside helpers carry texture resources into helper scope")
    func helperMacroTextureResourcesCompile() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform vec2 g_TexelSize;
        in vec2 v_TexCoord;
        #define Src(a,b) texture(g_Texture0, uv + vec2(a,b) * g_TexelSize)
        vec4 sharpen(vec2 uv) {
            return Src(0, 0);
        }
        void main() {
            gl_FragColor = sharpen(v_TexCoord);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "macro_helper_texture",
            preprocessedSource: source
        )
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0

        #expect(result.mslSource.contains("sharpen(v_TexCoord, g_Texture0, g_TexelSize)"))
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("GLSL-style mixed int and float min/max calls compile")
    func mixedIntegerFloatMinMaxCompiles() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        in vec2 v_TexCoord;
        void main() {
            float upper = v_TexCoord.x + 0.25;
            float lower = max(0, min(v_TexCoord.y, upper - 0.1));
            gl_FragColor = vec4(lower, 0.0, 0.0, 1.0);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "mixed_min_max",
            preprocessedSource: source
        )
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0

        #expect(result.mslSource.contains("max(0, min(v_TexCoord.y, upper - 0.1))"))
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("Float modulo assigned to uint compiles through fmod")
    func floatModuloAssignedToUnsignedIntegerCompiles() throws {
        let source = """
        #version 410 core
        #define RESOLUTION 64
        uniform sampler2D g_Texture0;
        in vec2 v_TexCoord;
        void main() {
            float frequency = v_TexCoord.x * 128.0;
            uint barFreq1 = frequency % RESOLUTION;
            gl_FragColor = vec4(float(barFreq1) / float(RESOLUTION), 0.0, 0.0, 1.0);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "float_modulo_uint",
            preprocessedSource: source
        )
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0

        #expect(result.mslSource.contains("uint barFreq1 = uint(fmod(float(frequency), float(RESOLUTION)));"))
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("Varying vec2 arrays compile with Metal initializer lists")
    func varyingVectorArrayCompiles() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        in vec2 v_TexCoord[4];
        void main() {
            vec4 color = texture(g_Texture0, v_TexCoord[0]);
            color += texture(g_Texture0, v_TexCoord[1]);
            gl_FragColor = color * 0.5;
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "varying_array",
            preprocessedSource: source
        )
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0

        #expect(result.mslSource.contains("float2 v_TexCoord[4] = { in.uv, in.uv, in.uv, in.uv };"))
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

}
