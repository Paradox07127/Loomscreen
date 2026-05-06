#include <metal_stdlib>
using namespace metal;

struct WPEVertexOut {
    float4 position [[position]];
    float2 uv;
};

struct WPESolidUniforms {
    float4 color;
};

struct WPECopyUniforms {
    float2 uvOffset;
    float2 padding;
};

vertex WPEVertexOut wpe_fullscreen_vertex(uint vertexID [[vertex_id]]) {
    float2 positions[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0)
    };
    float2 uvs[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0)
    };

    WPEVertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.uv = uvs[vertexID];
    return out;
}

fragment half4 wpe_solidcolor_fragment(
    WPEVertexOut in [[stage_in]],
    constant WPESolidUniforms& uniforms [[buffer(0)]]
) {
    return half4(uniforms.color);
}

fragment half4 wpe_copy_fragment(
    WPEVertexOut in [[stage_in]],
    texture2d<half, access::sample> texture0 [[texture(0)]],
    constant WPECopyUniforms& uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    float2 uv = clamp(in.uv + uniforms.uvOffset, float2(0.0), float2(1.0));
    return texture0.sample(linearSampler, uv);
}

// Phase 2C util built-ins. `solidlayer` writes color * alpha into the
// per-layer FBO. `util_copy` is the parallax-free copy used when chaining
// `materials/util/copy.json` between FBOs. `compose` blends two layer
// composites into the scene under a tint color.

fragment half4 wpe_solidlayer_fragment(
    WPEVertexOut in [[stage_in]],
    constant WPESolidUniforms& uniforms [[buffer(0)]]
) {
    float alpha = saturate(uniforms.color.a);
    return half4(float4(uniforms.color.rgb * alpha, alpha));
}

fragment half4 wpe_util_copy_fragment(
    WPEVertexOut in [[stage_in]],
    texture2d<half, access::sample> texture0 [[texture(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    return texture0.sample(linearSampler, in.uv);
}

fragment half4 wpe_compose_fragment(
    WPEVertexOut in [[stage_in]],
    texture2d<half, access::sample> texture0 [[texture(0)]],
    texture2d<half, access::sample> texture1 [[texture(1)]],
    constant WPESolidUniforms& uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    float4 a = float4(texture0.sample(linearSampler, in.uv));
    float4 b = float4(texture1.sample(linearSampler, in.uv));
    float4 composed = mix(a, b, b.a);
    return half4(float4(composed.rgb * uniforms.color.rgb, composed.a * uniforms.color.a));
}

// Phase 2D-C: pre-compiled WPE effect set. Each fragment ships hand-written
// MSL approximating a popular WPE Workshop effect; auto GLSL→MSL
// translation (Phase 2D route A/B) is a separate, larger project.

struct WPEColorBalanceUniforms {
    float brightness;
    float contrast;
    float saturation;
    float padding;
};

fragment half4 wpe_effect_colorbalance_fragment(
    WPEVertexOut in [[stage_in]],
    texture2d<half, access::sample> texture0 [[texture(0)]],
    constant WPEColorBalanceUniforms& uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    float4 color = float4(texture0.sample(linearSampler, in.uv));

    float3 rgb = color.rgb + uniforms.brightness;
    rgb = (rgb - 0.5) * max(uniforms.contrast, 0.0) + 0.5;

    float luma = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    rgb = mix(float3(luma), rgb, max(uniforms.saturation, 0.0));

    return half4(float4(saturate(rgb), color.a));
}

struct WPEBlurUniforms {
    float2 texelSize;
    float radius;
    float padding;
};

fragment half4 wpe_effect_blur_fragment(
    WPEVertexOut in [[stage_in]],
    texture2d<half, access::sample> texture0 [[texture(0)]],
    constant WPEBlurUniforms& uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);

    const float offsets[9] = {
        -4.0, -3.0, -2.0, -1.0, 0.0, 1.0, 2.0, 3.0, 4.0
    };
    const float weights[9] = {
        0.05, 0.09, 0.12, 0.15, 0.18, 0.15, 0.12, 0.09, 0.05
    };

    float2 stepUV = float2(uniforms.texelSize.x, 0.0) * max(uniforms.radius, 0.0);
    float4 color = float4(0.0);
    for (uint i = 0; i < 9; i++) {
        float2 uv = clamp(in.uv + stepUV * offsets[i], float2(0.0), float2(1.0));
        color += float4(texture0.sample(linearSampler, uv)) * weights[i];
    }

    return half4(color);
}

struct WPEVignetteUniforms {
    float innerRadius;
    float outerRadius;
    float intensity;
    float padding;
};

fragment half4 wpe_effect_vignette_fragment(
    WPEVertexOut in [[stage_in]],
    texture2d<half, access::sample> texture0 [[texture(0)]],
    constant WPEVignetteUniforms& uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);

    float4 color = float4(texture0.sample(linearSampler, in.uv));
    float innerRadius = max(uniforms.innerRadius, 0.0);
    float outerRadius = max(uniforms.outerRadius, innerRadius + 0.0001);
    float edge = smoothstep(innerRadius, outerRadius, distance(in.uv, float2(0.5, 0.5)));
    float factor = mix(1.0, 1.0 - saturate(uniforms.intensity), edge);

    return half4(float4(saturate(color.rgb * factor), color.a));
}

struct WPEWaterUniforms {
    float amplitude;
    float frequency;
    float speed;
    float time;
};

fragment half4 wpe_effect_water_fragment(
    WPEVertexOut in [[stage_in]],
    texture2d<half, access::sample> texture0 [[texture(0)]],
    constant WPEWaterUniforms& uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);

    float phase = uniforms.time * uniforms.speed;
    float frequency = max(uniforms.frequency, 0.0);
    float2 wave = float2(
        sin((in.uv.y + phase) * frequency),
        cos((in.uv.x + phase) * frequency)
    ) * uniforms.amplitude;

    float2 uv = clamp(in.uv + wave, float2(0.0), float2(1.0));
    return texture0.sample(linearSampler, uv);
}

struct WPEShakeUniforms {
    float magnitude;
    float time;
    float frequency;
    float padding;
};

fragment half4 wpe_effect_shake_fragment(
    WPEVertexOut in [[stage_in]],
    texture2d<half, access::sample> texture0 [[texture(0)]],
    constant WPEShakeUniforms& uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);

    float frequency = max(uniforms.frequency, 0.001);
    float phase = floor(uniforms.time * frequency);
    float magnitude = clamp(uniforms.magnitude, 0.0, 0.25);
    float2 jitter = float2(
        cos(phase * 12.9898),
        sin(phase * 78.233)
    ) * magnitude;

    float2 uv = clamp(in.uv + jitter, float2(0.0), float2(1.0));
    return texture0.sample(linearSampler, uv);
}
