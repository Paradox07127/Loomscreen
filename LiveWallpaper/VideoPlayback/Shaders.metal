#include <metal_stdlib>
using namespace metal;

// -----------------------------------------------------------------------
// Uniforms  (must match the Swift-side ShaderUniforms struct)
// -----------------------------------------------------------------------
struct Uniforms {
    float  time;
    float2 resolution;
    int    shaderType;
};

// -----------------------------------------------------------------------
// Vertex output / fragment input
// -----------------------------------------------------------------------
struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// -----------------------------------------------------------------------
// Vertex shader: full-screen quad from vertex_id (triangle strip, 4 verts)
// -----------------------------------------------------------------------
vertex VertexOut vertexShader(uint vertexID [[vertex_id]]) {
    // Triangle strip: 0 -> bottom-left, 1 -> bottom-right,
    //                 2 -> top-left,    3 -> top-right
    float2 positions[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0)
    };

    float2 texCoords[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0)
    };

    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = texCoords[vertexID];
    return out;
}

// -----------------------------------------------------------------------
// Noise helpers
// -----------------------------------------------------------------------

// Simple hash for value noise
static float hash(float2 p) {
    float h = dot(p, float2(127.1, 311.7));
    return fract(sin(h) * 43758.5453);
}

// Smooth value noise
static float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);

    float a = hash(i);
    float b = hash(i + float2(1.0, 0.0));
    float c = hash(i + float2(0.0, 1.0));
    float d = hash(i + float2(1.0, 1.0));

    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Fractal Brownian Motion (3 octaves)
static float fbm(float2 p) {
    float value = 0.0;
    float amplitude = 0.5;
    for (int i = 0; i < 3; i++) {
        value += amplitude * valueNoise(p);
        p *= 2.0;
        amplitude *= 0.5;
    }
    return value;
}

// -----------------------------------------------------------------------
// Shader 0: Waves -- animated sine wave pattern with color gradients
// -----------------------------------------------------------------------
static half4 wavesEffect(float2 uv, float time) {
    float wave1 = sin(uv.x * 6.0 + time * 1.2) * 0.15;
    float wave2 = sin(uv.x * 3.0 - time * 0.8 + 1.5) * 0.1;
    float wave3 = sin(uv.x * 10.0 + time * 2.0) * 0.05;

    float y = uv.y + wave1 + wave2 + wave3;

    float3 deepColor  = float3(0.02, 0.05, 0.2);
    float3 midColor   = float3(0.05, 0.2,  0.5);
    float3 lightColor = float3(0.2,  0.5,  0.8);

    float3 col = mix(deepColor, midColor, smoothstep(0.3, 0.5, y));
    col = mix(col, lightColor, smoothstep(0.5, 0.7, y));

    // Foam line
    float foam = smoothstep(0.0, 0.01, abs(y - 0.5));
    col = mix(float3(0.9, 0.95, 1.0), col, foam);

    return half4(half3(col), 1.0h);
}

// -----------------------------------------------------------------------
// Shader 1: Plasma -- classic plasma effect
// -----------------------------------------------------------------------
static half4 plasmaEffect(float2 uv, float time) {
    float v1 = sin(uv.x * 5.0 + time);
    float v2 = sin(uv.y * 5.0 + time * 1.3);
    float v3 = sin((uv.x + uv.y) * 5.0 + time * 0.7);
    float v4 = sin(length(uv - 0.5) * 8.0 - time * 1.5);

    float v = (v1 + v2 + v3 + v4) * 0.25;

    float r = sin(v * M_PI_F + time * 0.3) * 0.5 + 0.5;
    float g = sin(v * M_PI_F + time * 0.3 + 2.094) * 0.5 + 0.5;
    float b = sin(v * M_PI_F + time * 0.3 + 4.189) * 0.5 + 0.5;

    return half4(half(r), half(g), half(b), 1.0h);
}

// -----------------------------------------------------------------------
// Shader 2: Gradient -- slowly rotating color gradient
// -----------------------------------------------------------------------
static half4 gradientEffect(float2 uv, float time) {
    float angle = time * 0.15;

    float2 center = uv - 0.5;
    float2 rotated = float2(
        center.x * cos(angle) - center.y * sin(angle),
        center.x * sin(angle) + center.y * cos(angle)
    );

    float t = rotated.x + 0.5;

    float3 c1 = float3(0.15, 0.05, 0.35);   // deep purple
    float3 c2 = float3(0.9,  0.3,  0.2);    // warm orange
    float3 c3 = float3(0.1,  0.6,  0.8);    // teal

    float3 col;
    if (t < 0.5) {
        col = mix(c1, c2, t * 2.0);
    } else {
        col = mix(c2, c3, (t - 0.5) * 2.0);
    }

    // Subtle radial vignette
    float dist = length(center);
    col *= 1.0 - dist * 0.3;

    return half4(half3(col), 1.0h);
}

// -----------------------------------------------------------------------
// Shader 3: Noise -- animated value noise
// -----------------------------------------------------------------------
static half4 noiseEffect(float2 uv, float time) {
    float2 p = uv * 4.0;

    float n1 = fbm(p + float2(time * 0.3, time * 0.2));
    float n2 = fbm(p + float2(time * -0.2, time * 0.4) + 5.0);
    float n3 = fbm(p * 1.5 + float2(time * 0.1, time * -0.3));

    float3 col;
    col.r = n1 * 0.7 + 0.15;
    col.g = n2 * 0.5 + 0.1;
    col.b = n3 * 0.8 + 0.2;

    // Contrast boost
    col = smoothstep(float3(0.1), float3(0.9), col);

    return half4(half3(col), 1.0h);
}

// -----------------------------------------------------------------------
// Shader 4: Aurora -- flowing aurora borealis simulation
// -----------------------------------------------------------------------
static half4 auroraEffect(float2 uv, float time) {
    // Night sky base
    float3 sky = mix(float3(0.0, 0.0, 0.05), float3(0.02, 0.02, 0.1), uv.y);

    // Aurora layers
    float aurora = 0.0;
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float speed = 0.3 + fi * 0.1;
        float freq  = 2.0 + fi * 0.5;

        float wave = sin(uv.x * freq + time * speed + fi * 2.0) * 0.1;
        wave += sin(uv.x * freq * 2.3 - time * speed * 0.7 + fi) * 0.05;

        float band = smoothstep(0.0, 0.15, abs(uv.y - 0.65 - wave - fi * 0.05));
        band = 1.0 - band;
        band *= 0.5 - fi * 0.1;

        aurora += band;
    }

    // Aurora color: green to cyan to purple
    float3 auroraColor;
    float colorShift = sin(time * 0.2 + uv.x * 3.0) * 0.5 + 0.5;
    auroraColor = mix(float3(0.1, 0.8, 0.3), float3(0.2, 0.5, 0.9), colorShift);
    auroraColor = mix(auroraColor, float3(0.5, 0.2, 0.8), colorShift * colorShift);

    float3 col = sky + auroraColor * aurora;

    // Subtle stars
    float starField = hash(floor(uv * 200.0));
    if (starField > 0.98) {
        float twinkle = sin(time * 3.0 + starField * 100.0) * 0.5 + 0.5;
        col += float3(twinkle * 0.6);
    }

    return half4(half3(col), 1.0h);
}

// -----------------------------------------------------------------------
// Fragment shader: dispatch based on shaderType uniform
// -----------------------------------------------------------------------
fragment half4 fragmentShader(VertexOut in [[stage_in]],
                              constant Uniforms &uniforms [[buffer(0)]]) {
    float2 uv = in.texCoord;

    switch (uniforms.shaderType) {
        case 0:  return wavesEffect(uv, uniforms.time);
        case 1:  return plasmaEffect(uv, uniforms.time);
        case 2:  return gradientEffect(uv, uniforms.time);
        case 3:  return noiseEffect(uv, uniforms.time);
        case 4:  return auroraEffect(uv, uniforms.time);
        default: return wavesEffect(uv, uniforms.time);
    }
}

// -----------------------------------------------------------------------
// Compute shader: Rain-on-glass displacement map (Heartfelt algorithm)
//
// Generates a 2-channel displacement map encoding refraction normals.
// Red = horizontal displacement, Green = vertical displacement.
// 0.5 is neutral (no distortion). Used with CIDisplacementDistortion.
//
// Replaces the deprecated CIColorKernel(source:) CIKL string that
// previously lived in VideoEffectsManager.swift.
// -----------------------------------------------------------------------

kernel void rainDisplacementCompute(
    texture2d<float, access::write> output [[texture(0)]],
    constant float  &time       [[buffer(0)]],
    constant float2 &resolution [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint w = output.get_width();
    uint h = output.get_height();
    if (gid.x >= w || gid.y >= h) return;

    float2 uv = float2(gid) / resolution;
    float2 aspect = float2(resolution.x / resolution.y, 1.0);
    float t = fmod(time * 0.2, 7200.0); // prevent overflow

    float2 normal = float2(0.0);
    // 累积"清晰区"强度：水滴中心 + 拖尾 + 静态小水珠都贡献 mask。Swift 层
    // 用此通道把模糊玻璃与清晰扭曲层做 alpha 混合，呈现真正的"雨滴清楚、
    // 玻璃朦胧"观感（参考 Wallpaper Engine / ShaderToy "Heartfelt"）。
    float dropMask = 0.0;

    // Two depth layers for parallax
    for (float i = 0.0; i < 2.0; i += 1.0) {
        float layerScale = 4.0 + i * 3.0;
        float2 st = uv * aspect * layerScale;
        st.y += t * (1.0 + i * 0.5);

        float2 id = floor(st);
        float2 f  = fract(st) - 0.5;

        // Noise hash per grid cell
        float2 hashP = id * float2(123.34, 345.45);
        hashP += dot(hashP, hashP + 34.345);
        float n = fract(hashP.x * hashP.y);

        float localTime = t + n * 6.28;

        // Main drop: stick-slip physics
        float dropY = -sin(localTime + sin(localTime + sin(localTime) * 0.5)) * 0.45;
        float2 dropCenter = float2((n - 0.5) * 0.7, dropY);
        float2 dropPos = f - dropCenter;
        float mainDrop = smoothstep(0.12, 0.02, length(dropPos));

        // Trail drops left behind
        float2 trailPos = f - float2(dropCenter.x, 0.0);
        trailPos.y = (fract(trailPos.y * 6.0) - 0.5) * 0.15;
        float trailMask = smoothstep(-dropCenter.y, 0.45, f.y);
        float trailDrop = smoothstep(0.04, 0.01, length(trailPos)) * trailMask;

        // Static background drops
        float2 staticPos = f - float2((n - 0.5) * 0.5, (fract(n * 12.34) - 0.5) * 0.5);
        float staticDrops = smoothstep(-0.5, 1.0, n) * smoothstep(0.05, 0.01, length(staticPos));

        normal += dropPos * mainDrop + trailPos * trailDrop + staticPos * staticDrops;

        // 雨滴 mask：水滴中心权重最高，拖尾次之，零散小点最弱；
        // 后层（i=1）权重略低制造景深。
        float layerWeight = 1.0 - i * 0.35;
        dropMask += (mainDrop * 1.0 + trailDrop * 0.55 + staticDrops * 0.35) * layerWeight;
    }

    // Subtle global ripple (uneven glass)
    float ripple = sin(uv.y * 10.0 + time) * cos(uv.x * 8.0 + time) * 0.02;
    normal.x += ripple;

    // Encode: 0.5 = neutral displacement，B 通道存 drop mask 供 CPU 端
    // 提取作 alpha mask；A=1 保持兼容。
    float2 encoded = clamp((normal * 0.5) + 0.5, 0.0, 1.0);
    float maskOut = clamp(dropMask, 0.0, 1.0);
    output.write(float4(encoded.x, encoded.y, maskOut, 1.0), gid);
}
