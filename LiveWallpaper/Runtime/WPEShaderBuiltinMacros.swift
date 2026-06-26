#if !LITE_BUILD
import Foundation

/// WPE shader-dialect builtin macros, shared by `WPERenderPipelineBuilder.shaderPrelude`
/// and the GPU MSDF text path (`WPEMSDFTextRenderer.shaderRequest`) so both resolve the
/// same WPE intrinsics.
///
/// Stage-agnostic: no `#version`, no `out`-declaration, no combo `#define`s — each caller
/// adds those. Without these macros any shader that uses them fails MSL compilation: the
/// shipped `font.frag` (file-scope `ScreenPxRange` uses `CAST2(...)` + `ddx`/`ddy`)
/// compiles for *no* combo until the prelude is present, so MSDF text silently falls back
/// to the CoreText overlay.
enum WPEShaderBuiltinMacros {
    static let glslPreludeLines: [String] = [
        "#define GLSL 1",
        "#define wpe_common_included 1",
        "#define mul(x, y) ((y) * (x))",
        "#define lerp mix",
        "#define frac fract",
        "#define saturate(x) (clamp((x), 0.0, 1.0))",
        "#define texSample2D texture",
        "#define texSample2DLod textureLod",
        "#define texture2D texture",
        "#define ddx dFdx",
        "#define ddy dFdy",
        "#define fmod(x, y) ((x) - (y) * trunc((x) / (y)))",
        "#define CAST2(x) (vec2(x))",
        "#define CAST3(x) (vec3(x))",
        "#define CAST4(x) (vec4(x))",
        "#define CAST2X2(x) (mat2(x))",
        "#define CAST3X3(x) (mat3(x))",
        "#define CAST4X4(x) (mat4(x))",
        "#ifndef M_PI",
        "#define M_PI 3.14159265358979323846",
        "#endif",
        // WPE shader sources use `M_PI_2` as a full turn (2π), not the
        // mathematical π/2 constant. `shake.frag` and several workshop
        // audio/shape shaders divide by it to normalize a complete cycle.
        "#ifndef M_PI_2",
        "#define M_PI_2 6.28318530717958647692",
        "#endif",
        "#ifndef M_PI_4",
        "#define M_PI_4 0.78539816339744830962",
        "#endif",
        "#ifndef M_E",
        "#define M_E 2.71828182845904523536",
        "#endif"
    ]

    static var glslPrelude: String { glslPreludeLines.joined(separator: "\n") }
}
#endif
