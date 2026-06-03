import Foundation
import Metal
import Testing
@testable import LiveWallpaper

/// Every combo the font material can emit. `MSDF=1` exercises the
/// `ScreenPxRange`/`ddx`/`ddy`/`CAST2` path that the CoreText fallback was
/// masking; `MSDF=0` is the raster control. File scope so the `@MainActor`
/// suite's parameterized `arguments:` (evaluated nonisolated) can read it.
private let msdfFontCombos: [[String: Int]] = [
    ["MSDF": 0, "COLORFONT": 0],
    ["MSDF": 0, "COLORFONT": 1],
    ["MSDF": 1, "OUTLINE_ENABLED": 0, "BLUR_ENABLED": 0, "DROP_SHADOW_ENABLED": 0, "COLORFONT": 0],
    ["MSDF": 1, "OUTLINE_ENABLED": 1, "BLUR_ENABLED": 0, "DROP_SHADOW_ENABLED": 0, "COLORFONT": 0],
    ["MSDF": 1, "OUTLINE_ENABLED": 0, "BLUR_ENABLED": 1, "DROP_SHADOW_ENABLED": 0, "COLORFONT": 0],
    ["MSDF": 1, "OUTLINE_ENABLED": 0, "BLUR_ENABLED": 0, "DROP_SHADOW_ENABLED": 1, "COLORFONT": 0],
    ["MSDF": 1, "OUTLINE_ENABLED": 1, "BLUR_ENABLED": 1, "DROP_SHADOW_ENABLED": 1, "COLORFONT": 0],
    ["MSDF": 1, "OUTLINE_ENABLED": 1, "BLUR_ENABLED": 1, "DROP_SHADOW_ENABLED": 1, "COLORFONT": 1]
]

/// End-to-end compile gate for the GPU MSDF text path. Runs the REAL 2.8
/// `assets/shaders/font.frag` (verbatim, with its `common_fragment.h` include)
/// through the exact pipeline `WPEMSDFTextRenderer` uses —
/// `WPEShaderPreprocessor.process` → `WPESwiftShaderCompiler.compile` — for
/// every MSDF combo set.
///
/// This is the gate that decides whether MSDF text actually renders or silently
/// falls back to CoreText: if font.frag won't translate+compile, the runtime
/// throws and every scene reverts to the CoreText overlay. The fixture is the
/// shipped source so the test fails for the same reason the device does.
@MainActor
@Suite("WPE 2.8 font.frag MSDF compile gate")
struct WPEMSDFFontFragCompileTests {

    /// Verbatim copy of `wallpaper_engine/assets/shaders/font.frag` (2.8.26).
    private static let fontFrag = """
    #include "common_fragment.h"

    uniform vec4 g_Color4;

    uniform sampler2D g_Texture0;
    uniform vec4 g_Texture0Resolution;
    uniform sampler2D g_Texture1;

    uniform vec4 g_RenderVar0;
    uniform vec4 g_RenderVar1;
    uniform vec4 g_RenderVar2;
    uniform vec4 g_RenderVar3;

    varying vec2 v_TexCoord;

    #define MSDF_RANGE g_RenderVar0.x
    #define OUTLINE_WIDTH g_RenderVar0.y
    #define BLUR_RADIUS g_RenderVar0.z
    #define DROP_SHADOW_RADIUS g_RenderVar0.w

    #define OUTLINE_COLOR g_RenderVar1.xyz
    #define DROP_SHADOW_COLOR g_RenderVar2.xyz
    #define DROP_SHADOW_OFFSET vec2(g_RenderVar1.w, g_RenderVar2.w)
    #define DROP_SHADOW_OPACITY g_RenderVar3.x

    float median(float r, float g, float b)
    {
        return max(min(r, g), min(max(r, g), b));
    }

    vec2 sqr(vec2 x) { return x*x; }

    float ScreenPxRange(vec2 texCoord)
    {
        vec2 unitRange = CAST2(MSDF_RANGE)/g_Texture0Resolution.xy;
        // If inversesqrt is not available, use vec2(1.0)/sqrt
        vec2 screenTexSize = CAST2(1.0) / sqrt(sqr(ddx(texCoord))+sqr(ddy(texCoord)));
        // Can also be approximated as screenTexSize = vec2(1.0)/fwidth(texCoord);
        return max(0.5*dot(unitRange, screenTexSize), 1.0);
    }

    float GetMsdfDistance(vec3 msdf, vec2 texCoord)
    {
        float sd = median(msdf.r, msdf.g, msdf.b);
        return ScreenPxRange(texCoord.xy)*(sd - 0.5);
    }

    float GetAtlasMsdfDistance(vec3 msdf)
    {
        float sd = median(msdf.r, msdf.g, msdf.b);
        return MSDF_RANGE * (sd - 0.5);
    }

    float SampleMSDF(float msdfDistance, float threshold, float blurRadius)
    {
    #if BLUR_ENABLED || DROP_SHADOW_ENABLED
        float halfWidth = max(blurRadius, 0.5);
        return smoothstep(-halfWidth, halfWidth, msdfDistance + threshold - 0.5);
    #else
        return clamp(msdfDistance + threshold, 0.0, 1.0);
    #endif
    }

    vec4 ApplyOutline(float msdfDistance, float fillCoverage, float outlineWidth, float blurRadius, vec3 fillColor, float baseAlpha)
    {
    #if OUTLINE_ENABLED
        float outlineCoverage = SampleMSDF(msdfDistance, 0.5 + outlineWidth, blurRadius);
        return vec4(mix(OUTLINE_COLOR, fillColor, fillCoverage), outlineCoverage * baseAlpha);
    #else
        return vec4(fillColor, fillCoverage * baseAlpha);
    #endif
    }

    vec4 ApplyDropShadow(vec4 glyphFrag, vec2 texCoord)
    {
    #if DROP_SHADOW_ENABLED
        vec2 offsetUV = DROP_SHADOW_OFFSET / g_Texture0Resolution.xy;
        vec2 shadowTexCoord = texCoord - offsetUV;
        vec3 shadowMsdf = texSample2D(g_Texture0, shadowTexCoord).rgb;
        float shadowAtlasDistance = GetAtlasMsdfDistance(shadowMsdf);
    #if OUTLINE_ENABLED
        float shadowThreshold = 0.5 + OUTLINE_WIDTH;
    #else
        float shadowThreshold = 0.5;
    #endif
        float shadowAlpha = saturate(DROP_SHADOW_OPACITY * SampleMSDF(shadowAtlasDistance, shadowThreshold, DROP_SHADOW_RADIUS)) * g_Color4.a;

        float outAlpha = glyphFrag.a + shadowAlpha * (1.0 - glyphFrag.a);
        vec3 outRGB = (glyphFrag.rgb * glyphFrag.a + DROP_SHADOW_COLOR * shadowAlpha * (1.0 - glyphFrag.a)) / max(outAlpha, 1e-6);
        return vec4(outRGB, outAlpha);
    #else
        return glyphFrag;
    #endif
    }

    void main() {
    #if MSDF // SDF scaling
        vec3 msdf = texSample2D(g_Texture0, v_TexCoord.xy).rgb;

    #if BLUR_ENABLED
        float msdfDistance = GetAtlasMsdfDistance(msdf);
        float outlineWidth = OUTLINE_WIDTH;
        float blurRadius = BLUR_RADIUS;
    #else
        float msdfDistance = GetMsdfDistance(msdf, v_TexCoord.xy);
        float outlineWidth = OUTLINE_WIDTH * (ScreenPxRange(v_TexCoord.xy) / MSDF_RANGE);
        float blurRadius = 0.0;
    #endif

        float opacity = SampleMSDF(msdfDistance, 0.5, blurRadius);

    #if COLORFONT
        vec3 color = texSample2D(g_Texture1, v_TexCoord.xy).rgb;
        gl_FragColor = ApplyOutline(msdfDistance, opacity, outlineWidth, blurRadius, color, g_Color4.a);
    #else
        gl_FragColor = ApplyOutline(msdfDistance, opacity, outlineWidth, blurRadius, g_Color4.rgb, g_Color4.a);
    #endif

        gl_FragColor = ApplyDropShadow(gl_FragColor, v_TexCoord.xy);

    #else // Basic rasterization
    #if COLORFONT
        vec4 _sample = texSample2D(g_Texture0, v_TexCoord.xy);
        gl_FragColor = vec4(_sample.rgb, _sample.a * g_Color4.a);
    #else
        float _sample = ConvertSampleR8(texSample2D(g_Texture0, v_TexCoord.xy));
        gl_FragColor = vec4(g_Color4.rgb, _sample * g_Color4.a);
    #endif
    #endif
    }
    """

    /// The subset of `common_fragment.h` font.frag actually pulls in. Only
    /// `ConvertSampleR8` is referenced, but the full header is included verbatim
    /// so the include-resolution + branch-stripping path matches the device.
    private static let commonFragmentH = """
    #define FORMAT_RGBA8888 0
    #define FORMAT_RGB888 1
    #define FORMAT_RGB565 2
    #define FORMAT_ETC1_RGB8 3
    #define FORMAT_DXT5 4
    #define FORMAT_ETC2_RGBA8 5
    #define FORMAT_DXT3 6
    #define FORMAT_DXT1 7
    #define FORMAT_RG88 8
    #define FORMAT_R8 9
    #define FORMAT_RG1616F 10
    #define FORMAT_R16F 11
    #define FORMAT_BC7 12

    float ConvertSampleR8(vec4 _sample)
    {
    #if HLSL_SM30
            return _sample.a;
    #else
            return _sample.r;
    #endif
    }
    """

    /// Mirrors `WPEMSDFTextRenderer.shaderRequest` + `WPESwiftShaderCompiler`,
    /// including the WPE builtin-macro prelude the renderer prepends (shared via
    /// `WPEShaderBuiltinMacros`, so the test can't drift from the runtime path).
    ///
    /// The shipped install ships font.frag/common_fragment.h with **CRLF** line
    /// endings, so the fixtures are fed as CRLF — exercising both gates at once:
    /// the preprocessor's newline normalization (without it the whole file
    /// collapses onto its `#include` line and the body is dropped) and the
    /// builtin prelude (without it `ScreenPxRange`'s `CAST2`/`ddx`/`ddy` fail).
    private func compile(combos: [String: Int]) throws {
        let crlf = { (s: String) in s.replacingOccurrences(of: "\n", with: "\r\n") }
        let preprocessor = WPEShaderPreprocessor { path, _ in
            path.hasSuffix("common_fragment.h") ? crlf(Self.commonFragmentH) : nil
        }
        let preludedFragment = WPEShaderBuiltinMacros.glslPrelude + "\n" + crlf(Self.fontFrag)
        let request = try preprocessor.process(
            shaderName: "font",
            vertexSource: "#version 410 core\nvoid main() {}",
            fragmentSource: preludedFragment,
            comboValues: combos,
            materialTextureBindings: [:]
        )
        let device = try #require(MTLCreateSystemDefaultDevice())
        _ = try WPESwiftShaderCompiler(device: device).compile(request)
    }

    @Test("Real 2.8 font.frag translates + compiles for every MSDF combo", arguments: msdfFontCombos)
    func fontFragCompiles(combo: [String: Int]) throws {
        try compile(combos: combo)
    }
}
