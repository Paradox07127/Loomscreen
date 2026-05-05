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
