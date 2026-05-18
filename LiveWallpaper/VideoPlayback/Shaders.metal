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

    float3 c1 = float3(0.15, 0.05, 0.35);
    float3 c2 = float3(0.9,  0.3,  0.2);
    float3 c3 = float3(0.1,  0.6,  0.8);

    float3 col;
    if (t < 0.5) {
        col = mix(c1, c2, t * 2.0);
    } else {
        col = mix(c2, c3, (t - 0.5) * 2.0);
    }

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

    col = smoothstep(float3(0.1), float3(0.9), col);

    return half4(half3(col), 1.0h);
}

// -----------------------------------------------------------------------
// Shader 4: Aurora -- flowing aurora borealis simulation
// -----------------------------------------------------------------------
static half4 auroraEffect(float2 uv, float time) {
    float3 sky = mix(float3(0.0, 0.0, 0.05), float3(0.02, 0.02, 0.1), uv.y);

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

    float3 auroraColor;
    float colorShift = sin(time * 0.2 + uv.x * 3.0) * 0.5 + 0.5;
    auroraColor = mix(float3(0.1, 0.8, 0.3), float3(0.2, 0.5, 0.9), colorShift);
    auroraColor = mix(auroraColor, float3(0.5, 0.2, 0.8), colorShift * colorShift);

    float3 col = sky + auroraColor * aurora;

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
