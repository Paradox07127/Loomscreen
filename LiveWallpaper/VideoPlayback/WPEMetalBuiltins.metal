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
