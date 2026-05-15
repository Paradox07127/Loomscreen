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
        // `texture(g_Texture0, x)` should have been rewritten to a Metal
        // sampler call.
        #expect(result.mslSource.contains("g_Texture0.sample(linearSampler"))
        #expect(result.mslSource.contains("out vec4") == false) // GLSL syntax should be gone
        // Confirm Metal accepts what we emitted.
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
        // mat3 takes 3 slots
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
        // Layout: 32-element array first (32 slots), then u_BarCount (1 slot).
        let spectrum = try #require(result.uniformLayout.first { $0.name == "g_AudioSpectrum32Left" })
        #expect(spectrum.arrayLength == 32)
        #expect(spectrum.slotCount == 32)
        #expect(spectrum.slot == 0)
        let barCount = try #require(result.uniformLayout.first { $0.name == "u_BarCount" })
        #expect(barCount.slot == 32)

        // MSL emission must declare the array and unroll element reads
        // so dynamic indexing works at draw time.
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
        // 32-bin slice averages adjacent 64-bin pairs.
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
}
