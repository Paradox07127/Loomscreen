import Foundation
import Metal
import Testing
@testable import LiveWallpaper

/// End-to-end coverage for `WPEShaderTranspiler` + `WPESwiftShaderCompiler`
/// against representative WPE effect shader patterns. Each test exercises
/// a real-world structure (single sampler + uniforms + main rewriting
/// gl_FragColor) and verifies that the produced MSL compiles cleanly via
/// `MTLDevice.makeLibrary(source:)`.
struct WPEShaderTranspilerTests {

    @Test("Translates the canonical WPE scroll fragment to MSL that compiles")
    func translatesScrollFragment() throws {
        let source = """
        // stage: fragment
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform vec2 g_Scale;
        in vec2 v_TexCoord;
        in vec2 v_Scroll;
        void main() {
            vec2 texCoord = fract((v_TexCoord + v_Scroll) * g_Scale);
            gl_FragColor = texture(g_Texture0, texCoord);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "scroll",
            preprocessedSource: source
        )
        #expect(result.samplers == ["g_Texture0"])
        #expect(result.uniformLayout.contains { $0.name == "g_Scale" && $0.glslType == "vec2" })
        #expect(result.mslSource.contains("g_Texture0.sample(linearSampler"))
        #expect(result.mslSource.contains("out vec4") == false)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("Translates a tint-style fragment with vec3 uniform")
    func translatesTintFragment() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform vec3 g_TintColor;
        uniform float g_BlendAlpha;
        in vec2 v_TexCoord;
        void main() {
            vec4 albedo = texture(g_Texture0, v_TexCoord);
            albedo.rgb = mix(albedo.rgb, albedo.rgb * g_TintColor, g_BlendAlpha);
            gl_FragColor = albedo;
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "tint",
            preprocessedSource: source
        )
        #expect(result.uniformLayout.count == 2)
        #expect(result.uniformLayout[0].name == "g_TintColor")
        #expect(result.uniformLayout[0].slot == 0)
        #expect(result.uniformLayout[1].name == "g_BlendAlpha")
        #expect(result.uniformLayout[1].slot == 1)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("Type substitutions cover vec/mat families")
    func typeSubstitutions() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform mat3 g_Rotation;
        in vec2 v_TexCoord;
        void main() {
            vec3 p = vec3(v_TexCoord, 0.0);
            vec3 r = g_Rotation * p;
            gl_FragColor = vec4(r, 1.0);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "spin",
            preprocessedSource: source
        )
        #expect(result.mslSource.contains("float3 p = float3"))
        #expect(result.mslSource.contains("float4(r, 1.0)"))
        #expect(result.uniformLayout[0].slotCount == 3)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("Multi-sampler input declares textures in slot order")
    func multiSamplerOrdering() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform sampler2D g_Texture1;
        in vec2 v_TexCoord;
        void main() {
            vec4 a = texture(g_Texture0, v_TexCoord);
            vec4 b = texture(g_Texture1, v_TexCoord);
            gl_FragColor = mix(a, b, 0.5);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "blend",
            preprocessedSource: source
        )
        #expect(result.samplers == ["g_Texture0", "g_Texture1"])
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("End-to-end via WPESwiftShaderCompiler builds MTLLibrary")
    func endToEndViaSwiftCompiler() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let compiler = WPESwiftShaderCompiler(device: device)
        let request = WPEShaderCompileRequest(
            shaderName: "opacity_inline",
            processedVertexSource: "// not used by transpiler",
            processedFragmentSource: """
            #version 410 core
            uniform sampler2D g_Texture0;
            uniform float g_Opacity;
            in vec2 v_TexCoord;
            void main() {
                vec4 c = texture(g_Texture0, v_TexCoord);
                gl_FragColor = vec4(c.rgb * g_Opacity, c.a * g_Opacity);
            }
            """,
            sourceHash: "opacity-test",
            comboValues: [:],
            textureBindings: [:]
        )
        let result = try compiler.compile(request)
        #expect(result.fragmentFunctionName == "wpe_translated_fragment")
        #expect(!result.uniformLayout.isEmpty)
        #expect(result.library.makeFunction(name: "wpe_translated_fragment") != nil)
    }

    @Test("Rejects perspective vertex varyings instead of synthesizing z=0")
    func rejectsPerspectiveVertexVaryings() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let compiler = WPESwiftShaderCompiler(device: device)
        let request = WPEShaderCompileRequest(
            shaderName: "effects/lightshafts",
            processedVertexSource: """
            #version 410 core
            in vec3 a_Position;
            in vec2 a_TexCoord;
            out vec3 v_TexCoordFx;
            void main() {
                v_TexCoordFx = vec3(a_TexCoord, 1.0);
                gl_Position = vec4(a_Position, 1.0);
            }
            """,
            processedFragmentSource: """
            #version 410 core
            in vec3 v_TexCoordFx;
            void main() {
                vec2 fxCoord = v_TexCoordFx.xy / v_TexCoordFx.z;
                gl_FragColor = vec4(fxCoord, 0.0, 1.0);
            }
            """,
            sourceHash: "perspective-varying-test",
            comboValues: [:],
            textureBindings: [:]
        )

        #expect(throws: WPEShaderCompilerError.self) {
            _ = try compiler.compile(request)
        }
    }

    @Test("Translates audio-spectrum shader with uniform float array to MSL")
    func translatesAudioSpectrumArray() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform float g_AudioSpectrum32Left[32];
        uniform float u_BarCount;
        in vec2 v_TexCoord;
        void main() {
            int idx = int(v_TexCoord.x * u_BarCount);
            float bar = g_AudioSpectrum32Left[idx];
            gl_FragColor = vec4(bar, bar, bar, 1.0);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "audio_bars",
            preprocessedSource: source
        )
        let spectrum = try #require(result.uniformLayout.first { $0.name == "g_AudioSpectrum32Left" })
        #expect(spectrum.arrayLength == 32)
        #expect(spectrum.slotCount == 32)
        #expect(spectrum.slot == 0)
        let barCount = try #require(result.uniformLayout.first { $0.name == "u_BarCount" })
        #expect(barCount.slot == 32)

        #expect(result.mslSource.contains("float g_AudioSpectrum32Left[32];"))
        #expect(result.mslSource.contains("g_AudioSpectrum32Left[0] = u.vals[0].x;"))
        #expect(result.mslSource.contains("g_AudioSpectrum32Left[31] = u.vals[31].x;"))

        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("Audio runtime publishes spectrum slices for each resolution")
    func audioRuntimePublishesSpectrumSlices() {
        let runtime = WPEMetalRuntimeUniforms(
            time: 1,
            daytime: 0.5,
            brightness: 1,
            pointerPosition: SIMD2<Double>(0.5, 0.5),
            audioSpectrum: (0..<64).map { Double($0) / 63.0 }
        )
        let values = runtime.uniformValues
        guard case .vector(let s32) = values["g_AudioSpectrum32Left"] else {
            #expect(Bool(false), "Missing g_AudioSpectrum32Left"); return
        }
        guard case .vector(let s64) = values["g_AudioSpectrum64Left"] else {
            #expect(Bool(false), "Missing g_AudioSpectrum64Left"); return
        }
        #expect(s32.count == 32)
        #expect(s64.count == 64)
        #expect(abs(s32[0] - (s64[0] + s64[1]) * 0.5) < 1e-9)
    }

    @Test("Rejects shaders with no main entry point")
    func rejectsShadersWithoutMain() {
        let source = """
        uniform sampler2D g_Texture0;
        in vec2 v_TexCoord;
        // no main function
        """
        #expect(throws: WPEShaderCompilerError.self) {
            _ = try WPEShaderTranspiler.translateFragment(
                shaderName: "broken",
                preprocessedSource: source
            )
        }
    }

    @Test("Strips GLSL 'in' parameter qualifiers so MSL accepts helper signatures")
    func stripsInParameterQualifier() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        in vec2 v_TexCoord;
        float3 ApplyBlending(const int blendMode, in float3 A, in float3 B, in float opacity) {
            float3 result = B;
            if (blendMode == 1) { result = A; }
            return mix(A, result, opacity);
        }
        void main() {
            vec4 c = texture(g_Texture0, v_TexCoord);
            gl_FragColor = vec4(ApplyBlending(0, c.rgb, c.rgb, 1.0), 1.0);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "blend-in-quals",
            preprocessedSource: source
        )
        #expect(!result.mslSource.contains("in float3 A"))
        #expect(!result.mslSource.contains("in float3 B"))
        #expect(!result.mslSource.contains("in float opacity"))
        #expect(result.mslSource.contains("float3 A"))
        #expect(!result.mslSource.contains("thread in"))

        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("In-qualifier strip leaves top-level vertex inputs untouched")
    func inQualifierIgnoresTopLevelInputs() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        in vec2 v_TexCoord;
        in vec3 v_Normal;
        void main() {
            gl_FragColor = texture(g_Texture0, v_TexCoord) * vec4(v_Normal, 1.0);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "in-top-level",
            preprocessedSource: source
        )
        #expect(result.mslSource.contains("WPEStageIn"))
        #expect(!result.mslSource.contains("in vec2 v_TexCoord;"))

        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("Fragment out_FragColor scrub catches all variants")
    func fragmentOutScrubCatchesAllVariants() {
        #expect(WPEShaderTranspiler.scrubFragmentOutDeclarations("out vec4 out_FragColor;").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(WPEShaderTranspiler.scrubFragmentOutDeclarations("out float4 out_FragColor;").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(WPEShaderTranspiler.scrubFragmentOutDeclarations("out vec4 wpe_fragColor;").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let mixed = WPEShaderTranspiler.scrubFragmentOutDeclarations("precision highp float; out vec4 out_FragColor;")
        #expect(!mixed.contains("out_FragColor"))
        #expect(mixed.contains("precision highp float"))
        let withComment = WPEShaderTranspiler.scrubFragmentOutDeclarations("out vec4 out_FragColor; // injected by prelude\n#define M_PI 3.14")
        #expect(!withComment.contains("out_FragColor"))
        #expect(withComment.contains("#define M_PI"))
        let unrelated = "void foo(out float3 col) { col = float3(0); }"
        #expect(WPEShaderTranspiler.scrubFragmentOutDeclarations(unrelated) == unrelated)
    }

    @Test("End-to-end: shader with prelude out_FragColor compiles cleanly")
    func endToEndPreludeOutFragColor() throws {
        let source = """
        // LiveWallpaper WPE shader prelude
        #define GLSL 1
        #define mul(x, y) ((y) * (x))
        #define CAST3(x) (vec3(x))
        out vec4 out_FragColor;
        #define varying in

        uniform sampler2D g_Texture0;
        in vec2 v_TexCoord;
        void main() {
            out_FragColor = texture(g_Texture0, v_TexCoord);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "out_fragcolor_smoke",
            preprocessedSource: source
        )
        #expect(!result.mslSource.contains("out float4 out_FragColor"))
        #expect(!result.mslSource.contains("out vec4 out_FragColor"))
        #expect(result.mslSource.contains("out_color"))

        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("linearSampler is declared at file scope so helpers can use it")
    func linearSamplerAtFileScope() throws {
        let source = """
        #version 410 core
        in vec2 v_TexCoord;
        // Helper using only the sampler (texture passed as arg externally).
        float computeAngle(float2 uv) {
            return uv.x + uv.y;
        }
        void main() {
            gl_FragColor = vec4(computeAngle(v_TexCoord), 0.0, 0.0, 1.0);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "filescope_sampler",
            preprocessedSource: source
        )
        let mslSource = result.mslSource
        let samplerRange = try #require(mslSource.range(of: "constexpr sampler linearSampler"))
        let helperRange = try #require(mslSource.range(of: "float computeAngle("))
        #expect(samplerRange.lowerBound < helperRange.lowerBound, "linearSampler must precede the helper")
        let mainStart = try #require(mslSource.range(of: "wpe_translated_fragment"))
        let mainBodyRest = mslSource[mainStart.upperBound...]
        #expect(!mainBodyRest.contains("constexpr sampler linearSampler"), "no duplicate declaration inside main()")

        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: mslSource, options: opts)
    }
}
