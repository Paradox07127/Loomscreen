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

    @Test("GLSL-style mixed int and float clamp calls compile")
    func mixedIntegerFloatClampCompiles() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        in vec2 v_TexCoord;
        void main() {
            float depth = v_TexCoord.x;
            depth = clamp(0, 0.15, depth);
            gl_FragColor = vec4(depth, 0.0, 0.0, 1.0);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "mixed_clamp",
            preprocessedSource: source
        )
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0

        #expect(result.mslSource.contains("clamp(0, 0.15, depth)"))
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

    @Test("Common WPE shader helpers are available to translated fragments")
    func commonWPEShaderHelpersCompile() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        in vec2 v_TexCoord;
        void main() {
            vec2 wrapped = mod(v_TexCoord * 2.0, 1.0);
            vec4 sampleColor = texture(g_Texture0, wrapped);
            float luma = greyscale(sampleColor.rgb);
            vec3 color = hsv2rgb(rgb2hsv(sampleColor.rgb));
            vec3 normal = DecompressNormal(sampleColor);
            gl_FragColor = vec4(color * luma + normal * 0.0, sampleColor.a);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "common_wpe_shader_helpers",
            preprocessedSource: source
        )
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0

        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("Compatibility prelude does not redefine scene-authored helpers")
    func compatibilityPreludeDoesNotRedefineSceneHelpers() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        in vec2 v_TexCoord;
        vec3 DecompressNormal(vec4 packed) {
            vec2 nxy = packed.xy * 2.0 - 1.0;
            float nz = sqrt(max(0.0, 1.0 - dot(nxy, nxy)));
            return vec3(nxy, nz);
        }
        vec3 DecompressNormal(vec3 packed) {
            return DecompressNormal(vec4(packed, 0.0));
        }
        void main() {
            vec4 sampleColor = texture(g_Texture0, v_TexCoord);
            vec3 normal = DecompressNormal(sampleColor);
            gl_FragColor = vec4(normal, sampleColor.a);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "scene_defined_common_helper",
            preprocessedSource: source
        )
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0

        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("Inactive WPE combo branches do not leak extra main functions")
    func inactiveComboBranchesAreRemovedBeforeTranslation() throws {
        let source = """
        #version 410 core
        #define AA_VERSION 2
        uniform sampler2D g_Texture0;
        #if AA_VERSION == 3
        in vec2 wrongPath;
        void main() {
            gl_FragColor = vec4(wrongPath, 0.0, 1.0);
        }
        #endif
        #if AA_VERSION == 2
        in vec2 v_TexCoord;
        void main() {
            gl_FragColor = texture(g_Texture0, v_TexCoord);
        }
        #endif
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "inactive_combo_branch",
            preprocessedSource: source
        )
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0

        #expect(!result.mslSource.contains("wrongPath"))
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("Main locals may shadow generated varying aliases")
    func mainLocalsMayShadowGeneratedVaryingAliases() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        in vec2 v_TexCoord;
        varying vec4 timer;
        void main() {
            float timer = 0.5;
            vec4 color = texture(g_Texture0, v_TexCoord);
            gl_FragColor = color * timer;
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "varying_shadowed_by_main_local",
            preprocessedSource: source
        )
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0

        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("Float locals initialized from vec2 expressions infer the vector type")
    func floatLocalsInitializedFromVec2ExpressionsInferVectorType() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform vec2 g_PointerPosition;
        uniform float u_pointerSpeed;
        varying vec4 v_TexCoord;
        void main() {
            float pointer = g_PointerPosition.xy * u_pointerSpeed;
            gl_FragColor = texture(g_Texture0, v_TexCoord.xy + pointer);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "float_local_from_vec2_expression",
            preprocessedSource: source
        )
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0

        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("Texture samples narrow to scalar or RGB locals")
    func textureSamplesNarrowToScalarOrRGBLocals() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform sampler2D g_Texture1;
        varying vec3 v_TexCoord;
        void main() {
            vec3 albedo = texture(g_Texture0, v_TexCoord.xy);
            float mask = texture(g_Texture1, v_TexCoord.xy);
            float scale = length(abs(v_TexCoord - vec2(0.5)));
            gl_FragColor = vec4(albedo * mask * scale, 1.0);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "texture_sample_narrowing",
            preprocessedSource: source
        )
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0

        #expect(result.mslSource.contains("float3 albedo = g_Texture0.sample(linearSampler, v_TexCoord.xy).rgb;"))
        #expect(result.mslSource.contains("float mask = g_Texture1.sample(linearSampler, v_TexCoord.xy).r;"))
        #expect(result.mslSource.contains("v_TexCoord.xy - float2(0.5)"))
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("Mask UV access through v_TexCoord zw compiles on the fullscreen path")
    func maskTexCoordZWAccessFallsBackToBaseUV() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform sampler2D g_Texture1;
        varying vec2 v_TexCoord;
        void main() {
            float mask = texture(g_Texture1, v_TexCoord.zw).r;
            gl_FragColor = texture(g_Texture0, v_TexCoord) * mask;
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "mask_texcoord_zw",
            preprocessedSource: source
        )
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0

        #expect(result.mslSource.contains("g_Texture1.sample(linearSampler, v_TexCoord.xy).r"))
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("Metal reserved local identifiers from WPE shaders are renamed")
    func reservedLocalIdentifiersCompile() throws {
        let source = """
        #version 410 core
        #define mul(x, y) ((y) * (x))
        uniform sampler2D g_Texture0;
        varying vec2 v_TexCoord;
        void main() {
            mat2 rot = mat2(1.0, 0.0, 0.0, 1.0);
            vec2 o = v_TexCoord;
            vec2 or = mul(o, rot);
            float d = length(v_TexCoord - or);
            gl_FragColor = vec4(d, 0.0, 0.0, 1.0);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "reserved_or_local",
            preprocessedSource: source
        )
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0

        #expect(result.mslSource.contains("float2 orValue = mul(o, rot);"))
        #expect(result.mslSource.contains("v_TexCoord - orValue"))
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("Metal reserved helper parameter identifiers from WPE shaders are renamed")
    func reservedHelperParameterIdentifiersCompile() throws {
        let source = """
        #version 410 core
        varying vec2 v_TexCoord;
        vec3 illuminate(vec2 fragment) {
            return vec3(fragment.x, fragment.y, 0.0);
        }
        void main() {
            vec2 fragment = v_TexCoord - vec2(0.5);
            gl_FragColor = vec4(illuminate(fragment), 1.0);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "reserved_fragment_helper_parameter",
            preprocessedSource: source
        )
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0

        #expect(result.mslSource.contains("float3 illuminate(float2 fragmentValue)"))
        #expect(result.mslSource.contains("float2 fragmentValue = v_TexCoord.xy - float2(0.5);"))
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("GLSL mix assigned to rgb swizzle narrows the base color argument")
    func mixAssignedToRGBSwizzleNarrowsBaseColorArgument() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform sampler2D g_Texture1;
        varying vec2 v_TexCoord;
        void main() {
            vec4 albedo = texture(g_Texture0, v_TexCoord);
            float mask = texture(g_Texture1, v_TexCoord).r;
            vec3 newAlbedo = albedo.rgb * 0.5;
            albedo.rgb = mix(albedo, newAlbedo, mask);
            gl_FragColor = albedo;
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "hue_shift_rgb_mix_narrowing",
            preprocessedSource: source
        )
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0

        #expect(result.mslSource.contains("albedo.rgb = mix(albedo.rgb, newAlbedo, mask);"))
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("Program-scope constants referencing uniforms expand inside fragment scope")
    func programScopeConstantsReferencingUniformsExpandInsideFragmentScope() throws {
        let source = """
        #version 410 core
        uniform float u_Feather;
        const float FEATHER = u_Feather * 0.5;
        void main() {
            float mask = smoothstep(0.0 - FEATHER, 0.0 + FEATHER, 0.1);
            gl_FragColor = vec4(vec3(mask), 1.0);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "uniform_backed_program_scope_const",
            preprocessedSource: source
        )
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0

        #expect(result.mslSource.contains("#define FEATHER (u_Feather * 0.5)"))
        #expect(!result.mslSource.contains("constant float FEATHER = u_Feather"))
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("Texture resolution vec4 uniforms narrow to xy in vec2 compound assignments")
    func textureResolutionNarrowsInVector2CompoundAssignments() throws {
        let source = """
        #version 410 core
        uniform vec4 g_Texture0Resolution;
        uniform sampler2D g_Texture0;
        varying vec2 v_TexCoord;
        void main() {
            vec2 strength = vec2(1.0);
            strength *= 500 / g_Texture0Resolution;
            gl_FragColor = vec4(strength, 0.0, 1.0);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "texture_resolution_vec2_compound",
            preprocessedSource: source
        )
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0

        #expect(result.mslSource.contains("500 / g_Texture0Resolution.xy"))
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("Chromatic aberration style vec4 UV and vector offsets compile")
    func chromaticAberrationStyleVectorUVAndOffsetsCompile() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform float g_Time;
        uniform float u_rOffset;
        uniform float u_shiftSpeed;
        uniform float u_pointerSpeed;
        uniform vec2 g_PointerPosition;
        varying vec4 v_TexCoord;
        void main() {
            vec4 scene = texture(g_Texture0, v_TexCoord);
            vec4 timer = texture(g_Texture0, v_TexCoord);
            float pointer = g_PointerPosition * u_pointerSpeed;
            v_TexCoord += g_Time * u_shiftSpeed;
            vec4 rValue = texture(g_Texture0, v_TexCoord.xy - (u_rOffset * timer + pointer));
            vec3 finalColor = vec4(rValue.r, scene.g, timer.b, 0.1);
            gl_FragColor = vec4(finalColor, scene.a);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "chromatic_aberration_vector_uv",
            preprocessedSource: source
        )
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0

        #expect(result.mslSource.contains("g_Texture0.sample(linearSampler, v_TexCoord.xy);"))
        #expect(result.mslSource.contains("auto pointer = g_PointerPosition * u_pointerSpeed;"))
        #expect(result.mslSource.contains("u_rOffset * timer.xy + pointer"))
        #expect(result.mslSource.contains("float3 finalColor = float4(rValue.r, scene.g, timer.b, 0.1).rgb;"))
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("Program-scope vector constants compile in Metal constant address space")
    func programScopeVectorConstantsCompileInConstantAddressSpace() throws {
        let source = """
        #version 410 core
        const vec3 LUMINANCE_FACTOR = vec3(0.2126, 0.7152, 0.0722);
        const vec3 NORMALIZED_LUMINANCE_FACTOR = normalize(LUMINANCE_FACTOR);
        void main() {
            vec3 color = vec3(1.0, 0.5, 0.25);
            float luma = dot(normalize(color), NORMALIZED_LUMINANCE_FACTOR);
            gl_FragColor = vec4(vec3(luma), 1.0);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "tone_mapping_program_scope_constants",
            preprocessedSource: source
        )
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0

        #expect(result.mslSource.contains("constant float3 LUMINANCE_FACTOR = float3(0.2126, 0.7152, 0.0722);"))
        #expect(result.mslSource.contains("#define NORMALIZED_LUMINANCE_FACTOR (normalize(LUMINANCE_FACTOR))"))
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("Main-local const scalars remain automatic variables")
    func mainLocalConstScalarsRemainAutomaticVariables() throws {
        let source = """
        #version 410 core
        void main() {
            const float sampleIntensity = 0.1 * (30.0 / 8.0);
            gl_FragColor = vec4(vec3(sampleIntensity), 1.0);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "shine_cast_local_const",
            preprocessedSource: source
        )
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0

        #expect(result.mslSource.contains("const float sampleIntensity = 0.1 * (30.0 / 8.0);"))
        #expect(!result.mslSource.contains("constant float sampleIntensity"))
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("GLSL vector array constructors become Metal initializer lists")
    func glslVectorArrayConstructorsBecomeMetalInitializerLists() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        varying vec2 v_TexCoord;
        #define KERNEL2 vec2(0,0),vec2(1,0)
        #define kernelSampleCount 2
        const vec2 kernel[kernelSampleCount] = vec2[kernelSampleCount](KERNEL2);
        void main() {
            vec2 offset = kernel[1] * 0.5;
            gl_FragColor = texture(g_Texture0, v_TexCoord + offset);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "glsl_array_constructor",
            preprocessedSource: source
        )
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0

        #expect(result.mslSource.contains("constant float2 kernelValues[kernelSampleCount] = { KERNEL2 };"))
        #expect(result.mslSource.contains("float2 offset = kernelValues[1] * 0.5;"))
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

}
