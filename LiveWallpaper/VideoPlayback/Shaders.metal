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
// Rain-on-glass Metal pipeline.
//
// Inspired by Codrops/RainEffect: a dynamic water map stores refraction
// direction, thickness, and alpha. A second pass composites blurred glass,
// sharp refracted video, procedural shine, and a soft contact shadow.
// -----------------------------------------------------------------------

struct RainCompositeUniforms {
    float2 resolution;
    float time;
    float brightness;
    float minRefraction;
    float refractionDelta;
    float alphaMultiply;
    float alphaSubtract;
    float parallaxBg;
    float parallaxFg;
    float blurRadius;
    float padding;
};

static float rainHash11(float n) {
    return fract(sin(n) * 43758.5453123);
}

static float rainHash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float2 rainHash22(float2 p) {
    float n = rainHash21(p);
    return float2(n, rainHash11(n + dot(p, float2(17.13, 73.91))));
}

static void addRainDrop(float2 local,
                        float2 center,
                        float2 radius,
                        float weight,
                        thread float2 &normal,
                        thread float &thickness,
                        thread float &alpha)
{
    float2 p = local - center;
    float2 shaped = p / radius;
    float d = length(shaped);
    float body = smoothstep(1.0, 0.05, d);
    float core = smoothstep(0.50, 0.03, d);
    float rim = smoothstep(1.0, 0.70, d) * smoothstep(0.22, 0.62, d);
    float meniscus = max(rim, body - core * 0.45);

    float trailGate = smoothstep(0.0, 0.55, p.y) * smoothstep(0.55, 0.05, abs(p.x) / max(radius.x, 0.001));
    float beads = pow(saturate(1.0 - abs(fract(p.y * 11.0 + center.x * 2.7) - 0.5) * 2.0), 2.4);
    float tailTaper = smoothstep(1.25, 0.05, p.y) * smoothstep(-0.08, 0.18, p.y);
    float trail = trailGate * beads * tailTaper;
    float clearWake = smoothstep(0.02, 0.22, p.y) * smoothstep(0.22, 0.02, abs(p.x) / max(radius.x * 1.6, 0.001));

    float signal = saturate(body + trail * 0.55) * weight;
    float2 gradient = -normalize(shaped + float2(0.0001)) * meniscus * weight;
    gradient += float2(-p.x, -abs(p.y) * 0.35) * trail * weight;
    gradient += float2(-0.08, -0.16) * core * weight;

    normal += gradient * 0.38;
    thickness = max(thickness, saturate((core * 0.98 + rim * 0.60 + trail * 0.26) * weight));
    alpha = max(alpha, max(signal, clearWake * weight * 0.36));
}

kernel void rainWaterMapCompute(
    texture2d<float, access::write> output [[texture(0)]],
    constant float &time [[buffer(0)]],
    constant float2 &resolution [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint w = output.get_width();
    uint h = output.get_height();
    if (gid.x >= w || gid.y >= h) return;

    float2 uv = (float2(gid) + 0.5) / resolution;
    float2 aspect = float2(resolution.x / max(resolution.y, 1.0), 1.0);
    float2 normal = float2(0.0);
    float thickness = 0.0;
    float alpha = 0.0;

    for (int layer = 0; layer < 3; layer++) {
        float lf = float(layer);
        float scale = mix(4.4, 10.5, lf / 2.0);
        float speed = mix(0.075, 0.19, lf / 2.0);
        float2 grid = uv * aspect * scale;
        grid.y += time * speed;
        float2 cell = floor(grid);
        float2 local = fract(grid);

        for (int oy = -1; oy <= 1; oy++) {
            for (int ox = -1; ox <= 1; ox++) {
                float2 offset = float2(float(ox), float(oy));
                float2 seedCell = cell + offset;
                float2 rnd = rainHash22(seedCell + lf * 31.7);
                float phase = fract(rnd.x + time * (0.07 + rnd.y * 0.12 + lf * 0.025));
                float wobble = sin((time * 1.7) + rnd.x * 6.28318) * 0.05;
                float2 center = offset + float2(0.18 + rnd.x * 0.64 + wobble, 1.08 - phase * 1.62);
                float size = mix(0.052, 0.15, pow(rnd.y, 2.0)) * mix(1.15, 0.65, lf / 2.0);
                float active = smoothstep(0.16, 0.92, rnd.x);
                addRainDrop(
                    local,
                    center,
                    float2(size * 0.78, size * 1.32),
                    active * (1.0 - lf * 0.18),
                    normal,
                    thickness,
                    alpha
                );
            }
        }
    }

    float2 mistGrid = uv * aspect * 34.0;
    float2 mistCell = floor(mistGrid);
    float2 mistLocal = fract(mistGrid) - 0.5;
    float mistSeed = rainHash21(mistCell);
    float mistRadius = mix(0.04, 0.13, rainHash11(mistSeed + 4.2));
    float mistDistance = length(mistLocal / mistRadius);
    float mist = smoothstep(1.0, 0.05, mistDistance) * smoothstep(0.52, 1.0, mistSeed);
    float clearStreak = smoothstep(0.15, 0.0, abs(sin((uv.x + time * 0.015) * 19.0))) * smoothstep(0.35, 1.0, uv.y);
    mist *= 1.0 - clearStreak * 0.82;
    normal += -normalize(mistLocal + float2(0.0001)) * mist * 0.065;
    thickness = max(thickness, mist * 0.20);
    alpha = max(alpha, mist * 0.34);

    float glassRipple = sin(uv.y * 42.0 + time * 0.6) * cos(uv.x * 35.0 - time * 0.45) * 0.012;
    normal.x += glassRipple * (0.25 + alpha);

    float2 encodedNormal = clamp(normal * 0.5 + float2(0.5), float2(0.0), float2(1.0));
    output.write(float4(encodedNormal.y, encodedNormal.x, saturate(thickness), saturate(alpha)), gid);
}

static float4 rainBlend(float4 bg, float4 fg) {
    float ia = 1.0 - fg.a;
    float a = fg.a + bg.a * ia;
    float3 rgb = (a > 0.0001) ? (fg.rgb * fg.a + bg.rgb * bg.a * ia) / a : float3(0.0);
    return float4(rgb, a);
}

static float4 rainSampleBlur(texture2d<half, access::sample> source, sampler s, float2 uv, float2 pixel, float radius) {
    float2 stepX = float2(pixel.x * radius, 0.0);
    float2 stepY = float2(0.0, pixel.y * radius);
    float4 color = float4(source.sample(s, uv)) * 0.20;
    color += float4(source.sample(s, clamp(uv + stepX, float2(0.0), float2(1.0)))) * 0.10;
    color += float4(source.sample(s, clamp(uv - stepX, float2(0.0), float2(1.0)))) * 0.10;
    color += float4(source.sample(s, clamp(uv + stepY, float2(0.0), float2(1.0)))) * 0.10;
    color += float4(source.sample(s, clamp(uv - stepY, float2(0.0), float2(1.0)))) * 0.10;
    color += float4(source.sample(s, clamp(uv + stepX + stepY, float2(0.0), float2(1.0)))) * 0.10;
    color += float4(source.sample(s, clamp(uv + stepX - stepY, float2(0.0), float2(1.0)))) * 0.10;
    color += float4(source.sample(s, clamp(uv - stepX + stepY, float2(0.0), float2(1.0)))) * 0.10;
    color += float4(source.sample(s, clamp(uv - stepX - stepY, float2(0.0), float2(1.0)))) * 0.10;
    return color;
}

fragment half4 rainGlassCompositeFragment(
    VertexOut in [[stage_in]],
    texture2d<half, access::sample> source [[texture(0)]],
    texture2d<half, access::sample> waterMap [[texture(1)]],
    constant RainCompositeUniforms &uniforms [[buffer(0)]])
{
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    float2 uv = in.texCoord;
    float2 pixel = 1.0 / max(uniforms.resolution, float2(1.0));
    float2 pointer = float2(
        sin(uniforms.time * 0.11),
        cos(uniforms.time * 0.09)
    );
    float2 parallax = pointer * pixel;

    float4 water = float4(waterMap.sample(linearSampler, uv + parallax * uniforms.parallaxFg));
    float thickness = water.b;
    float alpha = saturate(water.a * uniforms.alphaMultiply - uniforms.alphaSubtract);
    float2 refraction = (float2(water.g, water.r) - 0.5) * 2.0;

    float4 blurred = rainSampleBlur(source, linearSampler, uv + parallax * uniforms.parallaxBg, pixel, uniforms.blurRadius);
    blurred.rgb *= 0.78;

    float refractionScale = uniforms.minRefraction + thickness * uniforms.refractionDelta;
    float2 refractedUV = clamp(
        uv + refraction * pixel * refractionScale + parallax * (uniforms.parallaxBg - uniforms.parallaxFg),
        float2(0.0),
        float2(1.0)
    );
    float4 sharp = float4(source.sample(linearSampler, refractedUV));

    float facing = dot(normalize(refraction + float2(0.001)), normalize(float2(-0.45, -0.85))) * 0.5 + 0.5;
    float rim = pow(saturate(length(refraction) * 1.35), 1.4) * alpha;
    float sparkle = pow(saturate(facing), 14.0) * smoothstep(0.18, 0.85, thickness);
    float crescent = smoothstep(0.18, 0.82, rim) * pow(saturate(1.0 - thickness * 0.38), 2.0);
    sharp.rgb = sharp.rgb * uniforms.brightness + float3(0.96, 0.985, 1.0) * sparkle * 0.54;
    sharp.rgb += float3(0.55, 0.72, 0.92) * crescent * 0.12;

    float shadowSample = float(waterMap.sample(linearSampler, clamp(uv + float2(0.0, pixel.y * (2.0 + thickness * 9.0)), float2(0.0), float2(1.0))).a);
    float shadow = saturate(shadowSample - water.a) * 0.22 + alpha * thickness * 0.10;
    float4 foreground = float4(max(sharp.rgb - float3(shadow), float3(0.0)), alpha);

    return half4(rainBlend(blurred, foreground));
}
