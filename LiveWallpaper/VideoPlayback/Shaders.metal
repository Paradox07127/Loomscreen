#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float  time;
    float2 resolution;
    int    shaderType;
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

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

// -------------------------------------------------------------------------
// Noise primitives (value noise + 3-octave fBm) — shared across presets
// -------------------------------------------------------------------------

static float hash(float2 p) {
    float h = dot(p, float2(127.1, 311.7));
    return fract(sin(h) * 43758.5453);
}

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

// -------------------------------------------------------------------------
// Preset 0 — Waves: silk-like horizontal bands with a soft highlight band
// drifting upward. Deep ocean → teal → soft cyan palette.
// -------------------------------------------------------------------------
static half4 wavesEffect(float2 uv, float time) {
    float t = time * 0.15;
    float warp = sin(uv.x * 2.0 + t) * 0.8 + t * 0.5;
    float band = sin(uv.y * 4.0 + warp) * 0.5 + 0.5;
    band = pow(band, 1.6);

    float3 deep  = float3(0.04, 0.08, 0.22);
    float3 mid   = float3(0.08, 0.32, 0.45);
    float3 light = float3(0.45, 0.72, 0.85);

    float3 col = mix(deep, mid, band);
    col = mix(col, light, pow(band, 3.5) * 0.65);

    float ribbonY = 0.55 + sin(uv.x * 3.0 + t) * 0.05;
    float ribbon = exp(-pow((uv.y - ribbonY) * 6.0, 2.0));
    col += float3(0.18, 0.30, 0.40) * ribbon * 0.4;

    return half4(half3(col), 1.0h);
}

// -------------------------------------------------------------------------
// Preset 1 — Plasma: three soft metaballs orbiting the center, blending
// into a continuous field. Deep indigo → magenta → peach palette.
// -------------------------------------------------------------------------
static half4 plasmaEffect(float2 uv, float time) {
    float t = time * 0.3;
    float2 p = uv - 0.5;

    float2 b1 = float2(sin(t * 0.7),        cos(t * 0.5))        * 0.35;
    float2 b2 = float2(sin(t * 0.9 + 2.1),  cos(t * 0.6 + 1.4))  * 0.30;
    float2 b3 = float2(sin(t * 0.5 + 4.2),  cos(t * 0.8 + 2.7))  * 0.40;

    float d1 = 1.0 / (length(p - b1) * 8.0 + 1.0);
    float d2 = 1.0 / (length(p - b2) * 8.0 + 1.0);
    float d3 = 1.0 / (length(p - b3) * 8.0 + 1.0);
    float field = d1 + d2 + d3;

    float3 deep  = float3(0.05, 0.02, 0.18);
    float3 mid   = float3(0.55, 0.18, 0.50);
    float3 light = float3(0.92, 0.58, 0.70);

    float3 col = mix(deep, mid, smoothstep(0.3, 0.9, field));
    col = mix(col, light, smoothstep(0.9, 1.4, field) * 0.6);

    return half4(half3(col), 1.0h);
}

// -------------------------------------------------------------------------
// Preset 2 — Gradient: slow rotating diagonal sweep with fBm-driven warp,
// giving a "silk fold" feel. Peach → coral → twilight palette.
// -------------------------------------------------------------------------
static half4 gradientEffect(float2 uv, float time) {
    float angle = time * 0.08;
    float2 center = uv - 0.5;

    float2 warp = float2(
        fbm(uv * 1.5 + time * 0.05),
        fbm(uv * 1.5 + 5.7 - time * 0.05)
    ) * 0.15;

    float2 q = center + warp;
    float2 rotated = float2(
        q.x * cos(angle) - q.y * sin(angle),
        q.x * sin(angle) + q.y * cos(angle)
    );

    float t = rotated.x + 0.5;

    float3 peach    = float3(0.95, 0.55, 0.40);
    float3 coral    = float3(0.85, 0.35, 0.55);
    float3 twilight = float3(0.35, 0.20, 0.55);

    float3 col;
    if (t < 0.5) {
        col = mix(peach,    coral,    smoothstep(0.0, 1.0, t * 2.0));
    } else {
        col = mix(coral, twilight, smoothstep(0.0, 1.0, (t - 0.5) * 2.0));
    }

    col *= 1.0 - length(center) * 0.25;

    return half4(half3(col), 1.0h);
}

// -------------------------------------------------------------------------
// Preset 3 — Noise: dreamy drifting cloud field. Two fBm layers cross-fade
// in pastel dusk colors (slate → mauve → cream).
// -------------------------------------------------------------------------
static half4 noiseEffect(float2 uv, float time) {
    float2 p = uv * 2.5;

    float n = fbm(p           + float2( time * 0.08, time * 0.05));
    float m = fbm(p * 1.7 + 4.3 + float2(-time * 0.04, time * 0.06));

    float cloud = smoothstep(0.30, 0.80, n);
    float wisp  = smoothstep(0.40, 0.90, m);

    float3 slate = float3(0.45, 0.40, 0.55);
    float3 mauve = float3(0.70, 0.55, 0.65);
    float3 cream = float3(0.95, 0.85, 0.75);

    float3 col = mix(slate, mauve, cloud);
    col = mix(col, cream, wisp * 0.7);

    return half4(half3(col), 1.0h);
}

// -------------------------------------------------------------------------
// Preset 4 — Aurora: silky bands floating over a deep night sky. Hue
// shifts green → teal → soft magenta. Star density reduced and twinkle
// dampened so it reads as a wallpaper rather than a screensaver.
// -------------------------------------------------------------------------
static half4 auroraEffect(float2 uv, float time) {
    float3 sky = mix(float3(0.0, 0.0, 0.05),
                     float3(0.05, 0.04, 0.15),
                     1.0 - uv.y);

    float aurora = 0.0;
    for (int i = 0; i < 4; i++) {
        float fi = float(i);
        float speed = 0.2 + fi * 0.08;
        float freq  = 1.5 + fi * 0.4;

        float wave = sin(uv.x * freq + time * speed + fi * 1.7) * 0.08;
        wave += sin(uv.x * freq * 2.1 - time * speed * 0.6 + fi) * 0.04;

        float yPos = 0.55 + fi * 0.06 + wave;
        float band = exp(-pow((uv.y - yPos) * 7.0, 2.0));
        band *= 0.6 - fi * 0.1;

        aurora += band;
    }

    float colorShift = sin(time * 0.15 + uv.x * 2.5) * 0.5 + 0.5;
    float3 green   = float3(0.15, 0.85, 0.50);
    float3 teal    = float3(0.20, 0.55, 0.95);
    float3 magenta = float3(0.70, 0.30, 0.85);

    float3 auroraColor = mix(green, teal, colorShift);
    auroraColor = mix(auroraColor, magenta, colorShift * colorShift * 0.8);

    float3 col = sky + auroraColor * aurora * 1.2;

    float starField = hash(floor(uv * 280.0));
    if (starField > 0.992) {
        float twinkle = sin(time * 2.5 + starField * 100.0) * 0.5 + 0.5;
        col += float3(twinkle * 0.4);
    }

    return half4(half3(col), 1.0h);
}

// -------------------------------------------------------------------------
// Fragment dispatch — shaderType uniform selects the preset above.
// -------------------------------------------------------------------------
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
