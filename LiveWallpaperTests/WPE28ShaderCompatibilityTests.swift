import Foundation
import Metal
import Testing
@testable import LiveWallpaper

@MainActor
@Suite("WPE 2.8 shader compatibility")
struct WPE28ShaderCompatibilityTests {

    private func makeLibrary(_ msl: String) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: msl, options: opts)
    }

    @Test("combine_video_hdr translates with g_HDRParams and compiles")
    func combineVideoHDRCompiles() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform vec2 g_HDRParams;
        in vec2 v_TexCoord;
        void main() {
            vec4 albedo = texture(g_Texture0, v_TexCoord);
            float maxHDR = g_HDRParams.y * 2.0;
            albedo.rgb /= maxHDR;
            albedo.rgb = clamp(albedo.rgb, 0.0, 1.0);
            albedo.rgb *= maxHDR;
            gl_FragColor = albedo;
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "combine_video_hdr",
            preprocessedSource: source
        )
        #expect(result.uniformLayout.contains { $0.name == "g_HDRParams" && $0.glslType == "vec2" })
        try makeLibrary(result.mslSource)
    }

    @Test("passthroughsrgb uses the 2.8 piecewise sRGB linearization and compiles")
    func passthroughSRGBCompiles() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        in vec2 v_TexCoord;
        vec3 lin(vec3 v) {
            vec3 c = step(0.04045, v);
            return c * (pow((v + 0.055) / 1.055, vec3(2.4))) + (1.0 - c) * (v / 12.92);
        }
        void main() {
            vec4 albedo = texture(g_Texture0, v_TexCoord);
            albedo.rgb = lin(albedo.rgb);
            gl_FragColor = albedo;
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "passthroughsrgb",
            preprocessedSource: source
        )
        #expect(result.mslSource.contains("step("))
        try makeLibrary(result.mslSource)
    }

    @Test("genericparticle REFRACT branch no longer requires NORMALMAP")
    func genericParticleRefractWithoutNormalMap() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        in vec2 v_TexCoord;
        in vec4 v_ScreenCoord;
        void main() {
            vec2 screenRefractionOffset = vec2(0.0);
            vec2 refractTexCoord = v_ScreenCoord.xy / v_ScreenCoord.z * vec2(0.5, 0.5) + 0.5 + screenRefractionOffset;
            gl_FragColor = texture(g_Texture0, refractTexCoord);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "genericparticle",
            preprocessedSource: source
        )
        try makeLibrary(result.mslSource)
    }

    @Test("Fragment-only compiler keeps the built-in fullscreen vertex (no model-vertex path)")
    func fragmentOnlyVertexContract() {
        #expect(WPESwiftShaderCompiler.fixedVertexFunctionName == "wpe_fullscreen_vertex")
    }

    @Test("font.frag non-MSDF raster branch (ConvertSampleR8) translates and compiles")
    func fontRasterBranchCompiles() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform vec4 g_Color4;
        in vec2 v_TexCoord;
        float ConvertSampleR8(vec4 _sample) { return _sample.r; }
        void main() {
            float _sample = ConvertSampleR8(texture(g_Texture0, v_TexCoord.xy));
            gl_FragColor = vec4(g_Color4.rgb, _sample * g_Color4.a);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "font",
            preprocessedSource: source
        )
        try makeLibrary(result.mslSource)
    }
}
