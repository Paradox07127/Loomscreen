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
