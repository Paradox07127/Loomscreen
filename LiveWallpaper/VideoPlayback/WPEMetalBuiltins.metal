#include <metal_stdlib>
using namespace metal;

struct WPEVertexOut {
    float4 position [[position]];
    float2 uv;
};

struct WPEMSDFTextVertex {
    float2 position;
    float2 uv;
};

// GPU MSDF text vertex stage. Reads per-glyph quad vertices (scene pixels +
// atlas UV) and converts to NDC; outputs the same WPEVertexOut layout the
// translated font.frag consumes via [[stage_in]] (position + uv).
vertex WPEVertexOut wpe_msdf_text_vertex(
    uint vid [[vertex_id]],
    constant WPEMSDFTextVertex* verts [[buffer(0)]],
    constant float2& sceneSize [[buffer(1)]]
) {
    WPEMSDFTextVertex v = verts[vid];
    float2 halfSize = max(sceneSize * 0.5, float2(0.5));
    WPEVertexOut out;
    out.position = float4(v.position.x / halfSize.x - 1.0, 1.0 - v.position.y / halfSize.y, 0.0, 1.0);
    out.uv = v.uv;
    return out;
}

struct WPESolidUniforms {
    float4 color;
};

struct WPEComposeLayerUniforms {
    float4 flags; // x = CLEARALPHA
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

struct WPEObjectQuadUniforms {
    float4 centerAndSize;        // x,y center in scene-centered pixels; z,w size in pixels
    float4 sceneSizeAndRotation; // x,y scene size; z rotation around quad center
    float4 uvSignAndPadding;     // x,y UV sign for negative WPE scale mirroring; z = local capture CLEARALPHA
};

vertex WPEVertexOut wpe_object_quad_vertex(
    uint vertexID [[vertex_id]],
    constant WPEObjectQuadUniforms& u [[buffer(1)]]
) {
    float2 corner;
    float2 uv;
    switch (vertexID) {
        case 0: corner = float2(-0.5, -0.5); uv = float2(0.0, 1.0); break;
        case 1: corner = float2( 0.5, -0.5); uv = float2(1.0, 1.0); break;
        case 2: corner = float2(-0.5,  0.5); uv = float2(0.0, 0.0); break;
        default: corner = float2( 0.5,  0.5); uv = float2(1.0, 0.0); break;
    }

    float rot = u.sceneSizeAndRotation.z;
    float c = cos(rot);
    float s = sin(rot);
    float2 localPixels = corner * u.centerAndSize.zw;
    float2 rotatedCorner = float2(
        c * localPixels.x - s * localPixels.y,
        s * localPixels.x + c * localPixels.y
    );
    float halfWidth = max(u.sceneSizeAndRotation.x, 1.0) * 0.5;
    float halfHeight = max(u.sceneSizeAndRotation.y, 1.0) * 0.5;
    float2 centerNDC = float2(
        u.centerAndSize.x / halfWidth,
        u.centerAndSize.y / halfHeight
    );
    float2 cornerNDC = rotatedCorner / float2(halfWidth, halfHeight);
    uv = float2(
        u.uvSignAndPadding.x < 0.0 ? 1.0 - uv.x : uv.x,
        u.uvSignAndPadding.y < 0.0 ? 1.0 - uv.y : uv.y
    );

    WPEVertexOut out;
    out.position = float4(centerNDC + cornerNDC, 0.0, 1.0);
    out.uv = uv;
    return out;
}

struct WPEPuppetVertex {
    float4 position;
    float4 uv;
    uint4 skinBlendIndices;
    float4 skinBlendWeights;
};

struct WPEPuppetMeshUniforms {
    float4 localSizeAndMode; // x,y local render target size; z=bone palette count; w=skinning enabled
    float4 meshCenterAndPadding; // x,y raw MDLV mesh center; z,w reserved
};

struct WPESceneModelMeshUniforms {
    float4x4 modelViewProjectionMatrix;
    float4 modeAndPadding; // x=bone palette count; y=skinning enabled; z,w reserved
};

// Puppet clip-composite path (WPE genericimage4 CLIPPINGUVS): carries the
// screen-space UV used to sample the clip-mask render target alongside the atlas UV.
struct WPEPuppetClipVertexOut {
    float4 position [[position]];
    float2 uv;
    float2 screenUV;
};

struct WPEPuppetSceneCompositeUniforms {
    float4 localSizeAndMode;       // x,y atlas/local layer size; z=bone palette count; w=skinning enabled
    float4 meshCenterAndScaleSign; // x,y raw MDLV mesh center; z,w = WPEObjectQuadUniforms.uvSignAndPadding.xy
    float4 objectCenterAndSize;    // exact WPEObjectQuadUniforms.centerAndSize
    float4 sceneSizeAndRotation;   // exact WPEObjectQuadUniforms.sceneSizeAndRotation
};

static inline float4 wpe_skin_puppet_position(
    WPEPuppetVertex v,
    constant float4x4* bonePalette,
    uint paletteCount
) {
    float4 sourcePosition = float4(v.position.xyz, 1.0);
    float4 weights = max(v.skinBlendWeights, float4(0.0));
    float weightSum = weights.x + weights.y + weights.z + weights.w;
    if (weightSum <= 0.00001) {
        return sourcePosition;
    }

    float4 skinned = float4(0.0);
    uint4 indices = v.skinBlendIndices;
    if (weights.x > 0.0) {
        skinned += weights.x * (indices.x < paletteCount ? bonePalette[indices.x] * sourcePosition : sourcePosition);
    }
    if (weights.y > 0.0) {
        skinned += weights.y * (indices.y < paletteCount ? bonePalette[indices.y] * sourcePosition : sourcePosition);
    }
    if (weights.z > 0.0) {
        skinned += weights.z * (indices.z < paletteCount ? bonePalette[indices.z] * sourcePosition : sourcePosition);
    }
    if (weights.w > 0.0) {
        skinned += weights.w * (indices.w < paletteCount ? bonePalette[indices.w] * sourcePosition : sourcePosition);
    }
    return skinned / weightSum;
}

vertex WPEVertexOut wpe_puppet_mesh_vertex(
    uint vertexID [[vertex_id]],
    constant WPEPuppetVertex* vertices [[buffer(0)]],
    constant WPEPuppetMeshUniforms& u [[buffer(1)]],
    constant float4x4* bonePalette [[buffer(2)]]
) {
    WPEPuppetVertex v = vertices[vertexID];
    uint paletteCount = uint(max(u.localSizeAndMode.z, 0.0));
    float4 position = (u.localSizeAndMode.w > 0.5 && paletteCount > 0)
        ? wpe_skin_puppet_position(v, bonePalette, paletteCount)
        : v.position;
    float2 halfSize = max(u.localSizeAndMode.xy * 0.5, float2(0.5));

    WPEVertexOut out;
    out.position = float4((position.xy - u.meshCenterAndPadding.xy) / halfSize, 0.0, 1.0);
    out.uv = v.uv.xy;
    return out;
}

vertex WPEVertexOut wpe_scene_model_mesh_vertex(
    uint vertexID [[vertex_id]],
    constant WPEPuppetVertex* vertices [[buffer(0)]],
    constant WPESceneModelMeshUniforms& u [[buffer(1)]],
    constant float4x4* bonePalette [[buffer(2)]]
) {
    WPEPuppetVertex v = vertices[vertexID];
    uint paletteCount = uint(max(u.modeAndPadding.x, 0.0));
    float4 position = (u.modeAndPadding.y > 0.5 && paletteCount > 0)
        ? wpe_skin_puppet_position(v, bonePalette, paletteCount)
        : float4(v.position.xyz, 1.0);

    WPEVertexOut out;
    out.position = u.modelViewProjectionMatrix * position;
    out.uv = v.uv.xy;
    return out;
}

// Same skinned placement as wpe_puppet_mesh_vertex, but also emits the screen-space
// UV (WPE CLIPPINGUVS) so the clip-target/compose fragments can sample the clip-mask RT.
vertex WPEPuppetClipVertexOut wpe_puppet_mesh_clip_vertex(
    uint vertexID [[vertex_id]],
    constant WPEPuppetVertex* vertices [[buffer(0)]],
    constant WPEPuppetMeshUniforms& u [[buffer(1)]],
    constant float4x4* bonePalette [[buffer(2)]]
) {
    WPEPuppetVertex v = vertices[vertexID];
    uint paletteCount = uint(max(u.localSizeAndMode.z, 0.0));
    float4 position = (u.localSizeAndMode.w > 0.5 && paletteCount > 0)
        ? wpe_skin_puppet_position(v, bonePalette, paletteCount)
        : v.position;
    float2 halfSize = max(u.localSizeAndMode.xy * 0.5, float2(0.5));
    float4 clipPosition = float4((position.xy - u.meshCenterAndPadding.xy) / halfSize, 0.0, 1.0);

    WPEPuppetClipVertexOut out;
    out.position = clipPosition;
    out.uv = v.uv.xy;
    // CLIPPINGUVS maps clip-space position to UV; Metal textures are top-left so flip Y.
    out.screenUV = float2(clipPosition.x * 0.5 + 0.5, 0.5 - clipPosition.y * 0.5);
    return out;
}

// Deferred-warp final composite: the base pass + effect chain ran in atlas/local
// UV space (masks aligned), so the mesh geometry warp happens here, once. This
// reproduces the old `base mesh-warp into FBO -> wpe_object_quad_vertex -> scene`
// placement exactly: a vertex's local quad coordinate is (meshPos - meshCenter) /
// localSize (matching the old base NDC = .../halfSize), then the object-quad
// placement (size/rotation/center, /halfScene) is applied. Negative WPE scale
// mirrors the MESH geometry (scaleSign) rather than the UV, which is equivalent
// because the old final quad mirrored an already-rasterized puppet FBO.
vertex WPEVertexOut wpe_puppet_scene_composite_vertex(
    uint vertexID [[vertex_id]],
    constant WPEPuppetVertex* vertices [[buffer(0)]],
    constant WPEPuppetSceneCompositeUniforms& u [[buffer(1)]],
    constant float4x4* bonePalette [[buffer(2)]]
) {
    WPEPuppetVertex v = vertices[vertexID];
    uint paletteCount = uint(max(u.localSizeAndMode.z, 0.0));
    float4 position = (u.localSizeAndMode.w > 0.5 && paletteCount > 0)
        ? wpe_skin_puppet_position(v, bonePalette, paletteCount)
        : v.position;

    float2 localSize = max(u.localSizeAndMode.xy, float2(1.0));
    float2 scaleMagnitude = u.objectCenterAndSize.zw / localSize;
    float2 scaleSign = float2(
        u.meshCenterAndScaleSign.z < 0.0 ? -1.0 : 1.0,
        u.meshCenterAndScaleSign.w < 0.0 ? -1.0 : 1.0
    );
    float2 localPixels = (position.xy - u.meshCenterAndScaleSign.xy) * scaleMagnitude * scaleSign;

    float rot = u.sceneSizeAndRotation.z;
    float c = cos(rot);
    float s = sin(rot);
    float2 rotated = float2(
        c * localPixels.x - s * localPixels.y,
        s * localPixels.x + c * localPixels.y
    );
    float2 halfScene = max(u.sceneSizeAndRotation.xy * 0.5, float2(0.5));

    WPEVertexOut out;
    out.position = float4(
        u.objectCenterAndSize.xy / halfScene + rotated / halfScene,
        0.0,
        1.0
    );
    out.uv = v.uv.xy;
    return out;
}

fragment half4 wpe_solidcolor_fragment(
    WPEVertexOut in [[stage_in]],
    constant WPESolidUniforms& uniforms [[buffer(0)]]
) {
    return half4(uniforms.color);
}

struct WPEPresentUniforms {
    float2 ndcScale;
    float2 uvScale;
    float2 uvOffset;
    float2 padding;
};

// Final on-screen blit with aspect handling, kept separate from the reused
// fullscreen copy/compose path so changing it can't affect scene-internal
// copies. `ndcScale` shrinks the quad (letterboxed Fit); `uvScale`/`uvOffset`
// crop the source UV (crop-to-fill). All-identity reproduces the legacy
// full-bleed Stretch.
vertex WPEVertexOut wpe_present_vertex(
    uint vertexID [[vertex_id]],
    constant WPEPresentUniforms& u [[buffer(0)]]
) {
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
    out.position = float4(positions[vertexID] * u.ndcScale, 0.0, 1.0);
    out.uv = uvs[vertexID] * u.uvScale + u.uvOffset;
    return out;
}

fragment half4 wpe_present_fragment(
    WPEVertexOut in [[stage_in]],
    texture2d<half, access::sample> texture0 [[texture(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    return texture0.sample(linearSampler, in.uv);
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

// WPE `composelayer.frag` parity: `passthrough:true` compose/project/fullscreen
// utility layers transfer the captured full-frame buffer 1:1 at screen UV via a
// plain fullscreen quad (wpe_fullscreen_vertex), IGNORING the object's authored
// size/rotation/origin — sampling through the layer transform warped oversized/
// rotated layers into a distorted inset. The layer transform positions the
// DOWNSTREAM effect (lens flare / DoF / foliage), not the compose capture.
// Single-texture by design (WPE composelayer samples only g_Texture0); the
// two-texture mix lives in wpe_compose_fragment for ordinary region composes.
fragment half4 wpe_composelayer_fragment(
    WPEVertexOut in [[stage_in]],
    texture2d<half, access::sample> texture0 [[texture(0)]],
    constant WPEComposeLayerUniforms& uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    float4 color = float4(texture0.sample(linearSampler, in.uv));
    if (uniforms.flags.x > 0.5) {
        // Premultiplied transparent = all channels zero (zeroing only alpha
        // would leave premultiplied rgb that re-adds under premultiplied over).
        color = float4(0.0);
    }
    return half4(color);
}

// Local composelayer scene capture: fill the layer-sized composite target with
// the scene pixels that sit under the object's authored quad. The final scene
// pass will draw that local target through wpe_object_quad_vertex, so this path
// pre-applies the inverse UV mirroring and the same z-rotation/placement math.
fragment half4 wpe_local_scene_capture_fragment(
    WPEVertexOut in [[stage_in]],
    texture2d<half, access::sample> texture0 [[texture(0)]],
    constant WPEObjectQuadUniforms& u [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    if (u.uvSignAndPadding.z > 0.5) {
        return half4(0.0);
    }

    float2 baseUV = float2(
        u.uvSignAndPadding.x < 0.0 ? 1.0 - in.uv.x : in.uv.x,
        u.uvSignAndPadding.y < 0.0 ? 1.0 - in.uv.y : in.uv.y
    );
    float2 localPixels = float2(
        (baseUV.x - 0.5) * u.centerAndSize.z,
        (0.5 - baseUV.y) * u.centerAndSize.w
    );
    float rot = u.sceneSizeAndRotation.z;
    float c = cos(rot);
    float s = sin(rot);
    float2 rotated = float2(
        c * localPixels.x - s * localPixels.y,
        s * localPixels.x + c * localPixels.y
    );
    float sceneW = max(u.sceneSizeAndRotation.x, 1.0);
    float sceneH = max(u.sceneSizeAndRotation.y, 1.0);
    float2 scenePixels = u.centerAndSize.xy + rotated;
    float2 uv = float2(
        (scenePixels.x + sceneW * 0.5) / sceneW,
        (sceneH * 0.5 - scenePixels.y) / sceneH
    );
    return texture0.sample(linearSampler, clamp(uv, float2(0.0), float2(1.0)));
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
    // Both inputs are premultiplied: composite b over a with the
    // premultiplied over operator (src + dst*(1-src.a)).
    float4 composed = float4(
        b.rgb + a.rgb * (1.0 - b.a),
        b.a + a.a * (1.0 - b.a)
    );
    float alphaScale = saturate(uniforms.color.a);
    return half4(float4(
        composed.rgb * uniforms.color.rgb * alphaScale,
        composed.a * alphaScale
    ));
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

// Phase 2D-D: native MSL implementations of WPE's most-used material
// shaders. Together they cover ~858 of the top shader uses across the
// 431960 corpus (562 genericimage4 + 103 genericimage2 + 193 genericparticle),
// so any scene built only on these + the existing built-ins now renders
// without needing the GLSL→MSL translator. Combos are not interpreted —
// the default no-combo case is what most scenes ship.

struct WPEGenericImageUniforms {
    float4 color;        // g_Color (sRGB→linear converted by executor)
    float4 alphaMaskUV;  // x=alpha multiplier, y=brightness, z=hasMask, w=mode/padding
    float4 textureUVScale; // xy=texture0 logical/physical scale, zw=texture1 logical/physical scale
};

static inline float2 wpe_logical_texture_uv(float2 uv, float2 scale) {
    return clamp(uv * max(scale, float2(0.0)), float2(0.0), float2(1.0));
}

fragment half4 wpe_genericimage2_fragment(
    WPEVertexOut in [[stage_in]],
    texture2d<half, access::sample> texture0 [[texture(0)]],
    constant WPEGenericImageUniforms& uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    float2 sourceUV = wpe_logical_texture_uv(in.uv, uniforms.textureUVScale.xy);
    float4 sampled = float4(texture0.sample(linearSampler, sourceUV));
    float3 rgb = sampled.rgb * uniforms.color.rgb * uniforms.alphaMaskUV.y;
    float alpha = sampled.a * uniforms.color.a * uniforms.alphaMaskUV.x;
    // Premultiplied-alpha render target: the layer-FBO / effect-chain passes
    // blend with srcRGB=.one (WPEMetalPipelineCache "premultiplied" mode), so
    // the shader stores rgb*alpha. Opaque texels are unchanged (rgb*1=rgb);
    // semi-transparent texels (puppet hair edges) no longer decay by alpha^N
    // across the effect chain.
    return half4(float4(rgb * alpha, alpha));
}

fragment half4 wpe_genericimage4_fragment(
    WPEVertexOut in [[stage_in]],
    texture2d<half, access::sample> texture0 [[texture(0)]],
    texture2d<half, access::sample> texture1 [[texture(1)]],
    constant WPEGenericImageUniforms& uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    float2 sourceUV = wpe_logical_texture_uv(in.uv, uniforms.textureUVScale.xy);
    float2 maskUV = wpe_logical_texture_uv(in.uv, uniforms.textureUVScale.zw);
    float4 sampled = float4(texture0.sample(linearSampler, sourceUV));
    float maskAlpha = 1.0;
    if (uniforms.alphaMaskUV.z > 0.5) {
        maskAlpha = float(texture1.sample(linearSampler, maskUV).a);
    }
    float3 rgb = sampled.rgb * uniforms.color.rgb * uniforms.alphaMaskUV.y;
    float alpha = sampled.a * maskAlpha * uniforms.color.a * uniforms.alphaMaskUV.x;
    // Premultiplied-alpha render target — see wpe_genericimage2_fragment.
    return half4(float4(rgb * alpha, alpha));
}

// Port of WPE clippingmaskimage4.frag: renders the clip SHAPE part into the clip-mask
// render target. `.r` carries the mask coverage (consumed by CLIPPINGTARGET below),
// `.a` carries the shape alpha. alphaMaskUV.w maps WPE's g_RenderVar0.x (invert toggle).
fragment half4 wpe_puppet_clippingmaskimage4_fragment(
    WPEPuppetClipVertexOut in [[stage_in]],
    texture2d<half, access::sample> texture0 [[texture(0)]],
    texture2d<half, access::sample> texture1 [[texture(1)]],
    constant WPEGenericImageUniforms& uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    float2 sourceUV = wpe_logical_texture_uv(in.uv, uniforms.textureUVScale.xy);
    float2 maskUV = wpe_logical_texture_uv(in.uv, uniforms.textureUVScale.zw);
    float albedoAlpha = float(texture0.sample(linearSampler, sourceUV).a);
    float mask = float(texture1.sample(linearSampler, maskUV).r);
    float alpha = mix(pow(albedoAlpha, 4.0), albedoAlpha, mask);
    float red = mask * alpha;
    red = mix(red, 1.0 - red, saturate(uniforms.alphaMaskUV.w));
    return half4(float4(red, 0.0, 0.0, alpha));
}

// Port of WPE genericimage4.frag clipping combos. alphaMaskUV.w selects the mode:
// 1=CLIPPINGTARGET (alpha *= clipMask.r), 2=CLIPPINGCOMPOSE (mix rgb), 3=both.
// The clip mask is sampled in screen space (CLIPPINGUVS), matching the mask RT.
fragment half4 wpe_genericimage4_puppet_clip_fragment(
    WPEPuppetClipVertexOut in [[stage_in]],
    texture2d<half, access::sample> texture0 [[texture(0)]],
    texture2d<half, access::sample> texture1 [[texture(1)]],
    texture2d<half, access::sample> texture8 [[texture(8)]],
    constant WPEGenericImageUniforms& uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    float2 sourceUV = wpe_logical_texture_uv(in.uv, uniforms.textureUVScale.xy);
    float2 maskUV = wpe_logical_texture_uv(in.uv, uniforms.textureUVScale.zw);
    float4 sampled = float4(texture0.sample(linearSampler, sourceUV));
    float maskAlpha = 1.0;
    if (uniforms.alphaMaskUV.z > 0.5) {
        maskAlpha = float(texture1.sample(linearSampler, maskUV).a);
    }
    float3 rgb = sampled.rgb * uniforms.color.rgb * uniforms.alphaMaskUV.y;
    float alpha = sampled.a * maskAlpha * uniforms.color.a * uniforms.alphaMaskUV.x;

    float4 clipping = float4(texture8.sample(linearSampler, saturate(in.screenUV)));
    float mode = uniforms.alphaMaskUV.w;
    if (mode > 0.5 && mode < 1.5) {
        alpha *= clipping.r;
    } else if (mode > 1.5 && mode < 2.5) {
        rgb = mix(rgb, clipping.rgb, clipping.a);
    } else if (mode > 2.5) {
        alpha *= clipping.r;
        rgb = mix(rgb, clipping.rgb, clipping.a);
    }
    return half4(float4(rgb * alpha, alpha));
}

struct WPEGenericParticleUniforms {
    float4 color;        // g_Color × per-particle tint
    float4 sizeAndAge;   // x=alpha, y=brightness, z=padding, w=padding
};

// Phase 2D-L: instanced particle render. Vertex stage reads a per-
// instance attribute (position+size, color+alpha) from `buffer(1)` and
// fans out a quad sized to that instance. Coordinates are in pixel
// space; the scene's orthogonal projection is supplied via buffer(2)
// as a vec4 (renderSizeX, renderSizeY, _, _) so we can map to NDC
// without a full 4x4 matrix.

struct WPEParticleInstance {
    float4 positionAndSize;   // x, y, signed sprite X scale, size in pixels
    float4 color;             // rgb 0..1, a = current alpha
    float4 rotationAndLife;   // x = rotationZ rad, y = lifetimeFraction, z = spriteFrameIndex, w = signed sprite Y scale
};

struct WPEParticleVertexOut {
    float4 position [[position]];
    float2 uvCurrent;
    float2 uvNext;
    float frameBlend;
    float4 color;
    // REFRACT screen-space tangents (WPE ComputeScreenRefractionTangents): the
    // quad's rotated right/up axes in screen-UV, pre-scaled by g_RefractAmount.
    // .xy = right, .zw = up. Zero for non-refract systems.
    float4 screenTangents;
    // Screen-space UV (top-left origin) of this fragment, for sampling a
    // compose-group opacity mask that spatially confines the system (e.g. the
    // matrix-rain layer masked to an upper-centre blob). Full-frame 0..1.
    float2 maskUV;
};

struct WPEParticleProjection {
    float4 sceneSize;         // x = width, y = height (pixels)
    float4 padding;           // reserved for future world transform
};

// Sprite-sheet slice + format hint. `grid.w == 1` means the atlas is an
// r8 single-channel alpha mask (fog particles), and the fragment shader
// reads colour from the per-particle tint instead of the texture.
struct WPEParticleSpriteParams {
    float4 grid;              // x=cols, y=rows, z=frameCount, w=isAlphaMask
    float4 frameRectMode;     // x=use explicit rects, y=rect count, z=overbright color scale, w=refractAmount
    // Compose-group effect baked from a particle's parent composelayer:
    // .xyz = tint colour multiplier (1,1,1 = no tint), .w = 1 when an opacity
    // mask is bound at texture(1) (0 = no mask).
    float4 tintAndMask;
};

vertex WPEParticleVertexOut wpe_particle_vertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    constant WPEParticleInstance* instances [[buffer(1)]],
    constant WPEParticleProjection& projection [[buffer(2)]],
    constant WPEParticleSpriteParams& sprite [[buffer(3)]],
    constant float4* frameRects [[buffer(4)]]
) {
    float2 corner;
    float2 unitUV;
    switch (vertexID) {
        case 0: corner = float2(-0.5, -0.5); unitUV = float2(0.0, 1.0); break;
        case 1: corner = float2( 0.5, -0.5); unitUV = float2(1.0, 1.0); break;
        case 2: corner = float2(-0.5,  0.5); unitUV = float2(0.0, 0.0); break;
        default: corner = float2( 0.5,  0.5); unitUV = float2(1.0, 0.0); break;
    }
    WPEParticleInstance instance = instances[instanceID];
    float2 spriteSign = float2(
        instance.positionAndSize.z < 0.0 ? -1.0 : 1.0,
        instance.rotationAndLife.w < 0.0 ? -1.0 : 1.0
    );
    corner *= spriteSign;
    // Spin the quad in screen space around its center. Z is the only
    // rotation axis we honour for 2D sprite particles; X/Y would need
    // a perspective particle pipeline (flags & 4 in the WPE JSON) that
    // we don't render yet.
    float rot = instance.rotationAndLife.x;
    float c = cos(rot);
    float s = sin(rot);
    float2 rotatedCorner = float2(c * corner.x - s * corner.y,
                                  s * corner.x + c * corner.y);
    float halfWidth = max(projection.sceneSize.x, 1.0) * 0.5;
    float halfHeight = max(projection.sceneSize.y, 1.0) * 0.5;
    // padding.xy = camera-parallax pixel offset for this system's depth.
    float2 parallaxPixels = projection.padding.xy;
    float2 centerNDC = float2(
        (instance.positionAndSize.x + parallaxPixels.x) / halfWidth,
        (instance.positionAndSize.y + parallaxPixels.y) / halfHeight
    );
    float2 cornerNDC = rotatedCorner * (instance.positionAndSize.w * 2.0)
        / float2(halfWidth * 2.0, halfHeight * 2.0);

    // Sprite-sheet: walk two adjacent cells and let the fragment shader
    // cross-fade between them by `frameBlend`. The WPE shader contract
    // (per ComputeSpriteFrame) is `floor(t*N)` = current frame and
    // `frac(t*N)` = blend toward next frame. Without this lerp the
    // 30-frame animation at ~90 fps reads as flicker.
    float cols = max(sprite.grid.x, 1.0);
    float rows = max(sprite.grid.y, 1.0);
    float frameCount = max(sprite.grid.z, 1.0);
    bool useFrameRects = sprite.frameRectMode.x > 0.5 && sprite.frameRectMode.y > 0.5;
    float frameRectCount = max(sprite.frameRectMode.y, 1.0);
    if (useFrameRects) {
        frameCount = min(frameCount, frameRectCount);
    }
    float2 frameUVScale = float2(1.0 / cols, 1.0 / rows);
    float frameContinuous = instance.rotationAndLife.z;
    float frameLo = floor(frameContinuous);
    float blend = frameContinuous - frameLo;
    float frameHi = (frameLo + 1.0 >= frameCount) ? 0.0 : (frameLo + 1.0);

    uint frameCountI = max(uint(frameCount), 1u);
    uint colsI = max(uint(cols), 1u);
    uint frameLoI = min(uint(frameLo), frameCountI - 1u);
    uint frameHiI = min(uint(frameHi), frameCountI - 1u);

    WPEParticleVertexOut out;
    float2 screenNDC = centerNDC + cornerNDC;
    out.position = float4(screenNDC, 0.0, 1.0);
    // NDC (y up, -1..1) → full-frame UV (y down, 0..1) for the group opacity mask.
    out.maskUV = float2(screenNDC.x * 0.5 + 0.5, 0.5 - screenNDC.y * 0.5);
    if (useFrameRects) {
        // Explicit TEXS sub-rects (x0,y0,x1,y1) in normalized UV. mix() maps
        // the quad's unit corners into the frame's rect.
        float4 rLo = frameRects[frameLoI];
        float4 rHi = frameRects[frameHiI];
        out.uvCurrent = mix(rLo.xy, rLo.zw, unitUV);
        out.uvNext = mix(rHi.xy, rHi.zw, unitUV);
    } else {
        uint colLo = frameLoI % colsI;
        uint rowLo = frameLoI / colsI;
        uint colHi = frameHiI % colsI;
        uint rowHi = frameHiI / colsI;
        float2 uvOriginLo = float2(float(colLo), float(rowLo)) * frameUVScale;
        float2 uvOriginHi = float2(float(colHi), float(rowHi)) * frameUVScale;
        out.uvCurrent = uvOriginLo + unitUV * frameUVScale;
        out.uvNext = uvOriginHi + unitUV * frameUVScale;
    }
    out.frameBlend = blend;
    out.color = instance.color;
    // Screen tangents = the quad's rotated right/up in screen-UV × g_RefractAmount
    // (frameRectMode.w; 0 ⇒ non-refract). Matches WPE's right/up→g_ViewRight/Up
    // projection for the 2D orthographic case (g_ViewRight=+x, g_ViewUp=+y).
    float refractAmount = sprite.frameRectMode.w;
    out.screenTangents.xy = float2(c, -s) * refractAmount;
    out.screenTangents.zw = float2(s, c) * refractAmount;
    return out;
}

fragment half4 wpe_particle_instanced_fragment(
    WPEParticleVertexOut in [[stage_in]],
    texture2d<half, access::sample> texture0 [[texture(0)]],
    constant WPEParticleSpriteParams& sprite [[buffer(0)]],
    texture2d<half, access::sample> groupOpacityMask [[texture(1)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    half4 sLo = texture0.sample(linearSampler, in.uvCurrent);
    half4 sHi = texture0.sample(linearSampler, in.uvNext);
    half blend = half(in.frameBlend);
    half4 sampled = mix(sLo, sHi, blend);
    // Single-channel alpha-mask atlases (WPE fog particles, format=r8)
    // pack the sprite shape into the R channel only — the texture has
    // no RGB content of its own. The particle's per-instance tint
    // becomes the colour, the texture sample becomes the opacity.
    bool isMask = sprite.grid.w > 0.5;
    half3 tint = half3(in.color.rgb);
    half3 rgb = isMask ? tint : (sampled.rgb * tint);
    half alpha = (isMask ? sampled.r : sampled.a) * half(in.color.a);
    // Material `ui_editor_properties_overbright`: an HDR colour multiplier
    // (>1 intensifies, <1 dims). It scales colour only, not opacity; on the
    // common additive blend this drives the glow intensity. Defaults to 1.
    half overbright = max(half(sprite.frameRectMode.z), half(0));
    rgb *= overbright;
    // Compose-group effect baked from the particle's parent composelayer:
    // a colour tint (recolours the sprite) and an opacity mask that spatially
    // confines the whole system to the authored region (matrix rain → upper
    // centre). Sampled in full-frame screen UV so it tracks the mask texture.
    rgb *= half3(sprite.tintAndMask.rgb);
    if (sprite.tintAndMask.w > 0.5) {
        alpha *= groupOpacityMask.sample(linearSampler, in.maskUV).r;
    }
    // Straight (non-premultiplied) alpha. The Metal pipeline state's
    // blend factors handle the translucent/additive/normal split set
    // up by `particlePipelineState`.
    return half4(rgb, alpha);
}

// genericparticle REFRACT (lens water droplets / heat haze). Instead of a flat
// sprite, the droplet shows the DISTORTED SCENE BEHIND it: sample the scene
// snapshot (texture2) at this fragment's screen UV, offset by the droplet's
// normal map (texture1), then multiply the albedo by it. White albedo ⇒ pure
// refracted background = a glassy droplet; on a dark background it (correctly)
// nearly vanishes. Reuses the instanced quad vertex (`[[position]]` gives the
// screen pixel, so no screen-coord varying is needed). Offset sign mirrors WPE's
// GLSL; magnitude = g_RefractAmount (sprite.frameRectMode.w).
fragment half4 wpe_particle_refract_fragment(
    WPEParticleVertexOut in [[stage_in]],
    texture2d<half, access::sample> albedoTex [[texture(0)]],
    texture2d<half, access::sample> normalTex [[texture(1)]],
    texture2d<half, access::sample> backgroundTex [[texture(2)]],
    constant WPEParticleSpriteParams& sprite [[buffer(0)]],
    constant WPEParticleProjection& projection [[buffer(1)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    half4 sLo = albedoTex.sample(linearSampler, in.uvCurrent);
    half4 sHi = albedoTex.sample(linearSampler, in.uvNext);
    half4 albedo = mix(sLo, sHi, half(in.frameBlend));
    // WPE RGBA8888 normal+mask packing: x in alpha, y in green, mask in red.
    half4 nt = normalTex.sample(linearSampler, in.uvCurrent);
    float nx = float(nt.a) * 2.0 - 1.0;
    float ny = float(nt.g) * 2.0 - 1.0;
    float mask = float(nt.r);
    float2 sceneSize = max(projection.sceneSize.xy, float2(1.0));
    float2 screenUV = in.position.xy / sceneSize;   // [[position]] = pixels, top-left
    // Project the tangent-space normal onto the quad's screen tangents (WPE's
    // v_ScreenTangents·normal). The tangents already fold in g_RefractAmount and
    // the quad rotation, so the offset rotates with the sprite and carries the
    // sign — no hardcoded axis flip.
    float2 offset = (in.screenTangents.xy * nx + in.screenTangents.zw * ny) * mask * float(in.color.a);
    half3 background = backgroundTex.sample(linearSampler, screenUV + offset).rgb;
    half overbright = max(half(sprite.frameRectMode.z), half(0));
    half3 rgb = albedo.rgb * half3(in.color.rgb) * background * overbright;
    half alpha = albedo.a * half(in.color.a);
    return half4(rgb, alpha);
}

// Rope/ribbon renderer (WPE `renderer: [{name:"rope"}]`). The CPU builds a
// per-frame triangle strip through the system's particles in emission order
// (two edge vertices per knot, offset ±half-size along the segment normal),
// so a meteor tail / cursor trail draws as ONE continuous textured strip
// rather than N stacked billboards. Reuses `wpe_particle_instanced_fragment`
// (frameBlend 0 ⇒ a single texture sample). v maps along the rope, u across.
struct WPEParticleRopeVertex {
    float4 positionUV;   // xy = centered scene pixels (Y-up), zw = uv
    float4 color;        // rgb 0..1, a = alpha
};

vertex WPEParticleVertexOut wpe_particle_rope_vertex(
    uint vertexID [[vertex_id]],
    constant WPEParticleRopeVertex* verts [[buffer(1)]],
    constant WPEParticleProjection& projection [[buffer(2)]]
) {
    WPEParticleRopeVertex v = verts[vertexID];
    float halfWidth = max(projection.sceneSize.x, 1.0) * 0.5;
    float halfHeight = max(projection.sceneSize.y, 1.0) * 0.5;
    float2 parallaxPixels = projection.padding.xy;   // camera-parallax offset
    float2 ndc = float2(
        (v.positionUV.x + parallaxPixels.x) / halfWidth,
        (v.positionUV.y + parallaxPixels.y) / halfHeight
    );
    WPEParticleVertexOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.uvCurrent = v.positionUV.zw;
    out.uvNext = v.positionUV.zw;
    out.frameBlend = 0.0;
    out.color = v.color;
    out.screenTangents = float4(0.0);   // rope never refracts
    out.maskUV = float2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
    return out;
}

// Phase 2D-N: text overlay quad. Vertex stage takes per-overlay center
// + size + color from a uniform buffer; fragment samples the rasterized
// CoreText output.

struct WPETextOverlayUniforms {
    float4 centerAndSize;   // x,y center (pixel space) ; z,w width,height (pixels)
    float4 sceneSize;       // x = scene width, y = scene height
    float4 color;           // rgb = straight text color, a = text alpha (applied in shader)
};

struct WPETextOverlayVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex WPETextOverlayVertexOut wpe_text_overlay_vertex(
    uint vertexID [[vertex_id]],
    constant WPETextOverlayUniforms& u [[buffer(0)]]
) {
    float2 corner;
    float2 uv;
    switch (vertexID) {
        case 0: corner = float2(-0.5, -0.5); uv = float2(0.0, 1.0); break;
        case 1: corner = float2( 0.5, -0.5); uv = float2(1.0, 1.0); break;
        case 2: corner = float2(-0.5,  0.5); uv = float2(0.0, 0.0); break;
        default: corner = float2( 0.5,  0.5); uv = float2(1.0, 0.0); break;
    }
    float halfWidth = max(u.sceneSize.x, 1.0) * 0.5;
    float halfHeight = max(u.sceneSize.y, 1.0) * 0.5;
    float2 centerNDC = float2(
        u.centerAndSize.x / halfWidth,
        u.centerAndSize.y / halfHeight
    );
    float2 cornerNDC = corner * float2(
        u.centerAndSize.z / halfWidth,
        u.centerAndSize.w / halfHeight
    );
    WPETextOverlayVertexOut out;
    // The vertical POSITION (centerNDC.y) is already correct in WPE's text
    // space — the clock sits next to Miku's face — so it must NOT be flipped.
    // Only the glyph's own vertical extent (cornerNDC.y) was inverted, which
    // rendered the text upside-down; negate just that so the text reads upright
    // while staying in the right place. X is untouched.
    out.position = float4(
        centerNDC.x + cornerNDC.x,
        centerNDC.y - cornerNDC.y,
        0.0, 1.0
    );
    out.uv = uv;
    return out;
}

fragment half4 wpe_text_overlay_fragment(
    WPETextOverlayVertexOut in [[stage_in]],
    texture2d<half, access::sample> texture0 [[texture(0)]],
    constant WPETextOverlayUniforms& u [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    // texture0 is a coverage mask (opaque white glyphs, .a = antialiasing
    // coverage). Apply the object's color + alpha ONCE → premultiplied output.
    float coverage = float(texture0.sample(linearSampler, in.uv).a);
    float alpha = coverage * u.color.a;
    return half4(float4(u.color.rgb * alpha, alpha));
}

fragment half4 wpe_genericparticle_fragment(
    WPEVertexOut in [[stage_in]],
    texture2d<half, access::sample> texture0 [[texture(0)]],
    constant WPEGenericParticleUniforms& uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    float4 sampled = float4(texture0.sample(linearSampler, in.uv));
    float3 rgb = sampled.rgb * uniforms.color.rgb * uniforms.sizeAndAge.y;
    float alpha = sampled.a * uniforms.color.a * uniforms.sizeAndAge.x;
    return half4(float4(rgb * alpha, alpha));
}

// Phase 2D-E: native MSL implementations of the most-common WPE effect
// shaders (per-corpus frequency: opacity 7, scroll 10, pulse 9, iris 6,
// shine_gaussian 6). All take a single source texture and emit an
// effect-modulated copy. These cover the simple 1-pass effects that
// dominate the long tail; multi-pass blur/lightshafts still need the
// translator.

struct WPEOpacityUniforms {
    float opacity;
    float hasMask;
    float maskScaleX;
    float maskScaleY;
};

fragment half4 wpe_effect_opacity_fragment(
    WPEVertexOut in [[stage_in]],
    texture2d<half, access::sample> texture0 [[texture(0)]],
    texture2d<half, access::sample> texture1 [[texture(1)]],
    constant WPEOpacityUniforms& uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    float4 sampled = float4(texture0.sample(linearSampler, in.uv));
    float mask = 1.0;
    if (uniforms.hasMask > 0.5) {
        float2 maskUV = in.uv * float2(uniforms.maskScaleX, uniforms.maskScaleY);
        mask = float(texture1.sample(linearSampler, maskUV).r);
    }
    // Input is premultiplied; scale rgb and alpha by the same factor so the
    // premultiplied invariant holds (rgb stays = straightRGB * alpha). The old
    // `sampled.rgb * alpha` re-multiplied the already-premultiplied rgb by the
    // new alpha (rgb*a^2), collapsing semi-transparent regions to a hole.
    float factor = mask * saturate(uniforms.opacity);
    return half4(float4(sampled.rgb * factor, sampled.a * factor));
}

struct WPEScrollUniforms {
    float2 speed;        // UV per second
    float time;
    float padding;
};

fragment half4 wpe_effect_scroll_fragment(
    WPEVertexOut in [[stage_in]],
    texture2d<half, access::sample> texture0 [[texture(0)]],
    constant WPEScrollUniforms& uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::repeat, filter::linear);
    float2 uv = fract(in.uv + uniforms.speed * uniforms.time);
    return texture0.sample(linearSampler, uv);
}

struct WPEPulseUniforms {
    float frequency;
    float amplitude;     // 0..1 modulation depth
    float time;
    float padding;
};

struct WPEGodraysCombineUniforms {
    uint useBase;
    uint padding0;
    uint padding1;
    uint padding2;
};

fragment half4 wpe_effect_pulse_fragment(
    WPEVertexOut in [[stage_in]],
    texture2d<half, access::sample> texture0 [[texture(0)]],
    constant WPEPulseUniforms& uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    float4 sampled = float4(texture0.sample(linearSampler, in.uv));
    float modulation = 1.0 + sin(uniforms.time * uniforms.frequency * 6.2831853) * uniforms.amplitude;
    return half4(float4(saturate(sampled.rgb * modulation), sampled.a));
}

fragment half4 wpe_effect_godrays_combine_fragment(
    WPEVertexOut in [[stage_in]],
    texture2d<half, access::sample> raysTexture [[texture(0)]],
    [[maybe_unused]] texture2d<half, access::sample> albedoTexture [[texture(1)]],
    texture2d<half, access::sample> baseTexture [[texture(2)]],
    constant WPEGodraysCombineUniforms& uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    float4 raysRaw = float4(raysTexture.sample(linearSampler, in.uv));
    if (uniforms.useBase == 0u) {
        return half4(raysRaw);
    }

    float4 albedoRaw = float4(baseTexture.sample(linearSampler, in.uv));
    return half4(float4(
        saturate(albedoRaw.rgb + raysRaw.rgb),
        saturate(max(albedoRaw.a, raysRaw.a))
    ));
}

struct WPEIrisUniforms {
    float radius;
    float softness;
    float padding0;
    float padding1;
};

fragment half4 wpe_effect_iris_fragment(
    WPEVertexOut in [[stage_in]],
    texture2d<half, access::sample> texture0 [[texture(0)]],
    constant WPEIrisUniforms& uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    float4 sampled = float4(texture0.sample(linearSampler, in.uv));
    float dist = distance(in.uv, float2(0.5, 0.5));
    float radius = max(uniforms.radius, 0.0);
    float softness = max(uniforms.softness, 0.0001);
    float gate = 1.0 - smoothstep(radius, radius + softness, dist);
    return half4(float4(sampled.rgb * gate, sampled.a * gate));
}

struct WPEWaterWavesUniforms {
    float time;
    float speed;
    float scale;
    float strength;
    float exponent;
    float directionX;
    float directionY;
    float hasMask;
    float debugMode; // 0 normal; 1 mask grayscale; 2 source+red mask overlay; 3 displacement heatmap; 4 solid magenta
    float4 texture1Resolution; // (textureWidth, textureHeight, imageWidth, imageHeight)
};

// Port of WPE's effects/waterwaves.frag: a sine wave travels along `direction` at
// `speed`/`scale`, and displaces the sample UV perpendicular to that direction by
// strength² (an opacity mask localizes it, e.g. to a character's hair).
fragment half4 wpe_effect_waterwaves_fragment(
    WPEVertexOut in [[stage_in]],
    texture2d<half, access::sample> texture0 [[texture(0)]],
    texture2d<half, access::sample> texture1 [[texture(1)]],
    constant WPEWaterWavesUniforms& uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    float2 direction = float2(uniforms.directionX, uniforms.directionY);
    // Mirror waterwaves.vert's mask-UV padding correction (v_TexCoord.zw *= res.zw/res.xy)
    // for the debug overlay so the mask visualization lands where the real effect samples.
    float2 maskUV = in.uv;
    if (uniforms.debugMode > 0.5) {
        float2 maskScale = float2(
            abs(uniforms.texture1Resolution.x) > 0.000001 ? uniforms.texture1Resolution.z / uniforms.texture1Resolution.x : 1.0,
            abs(uniforms.texture1Resolution.y) > 0.000001 ? uniforms.texture1Resolution.w / uniforms.texture1Resolution.y : 1.0
        );
        maskUV *= maskScale;
    }
    float mask = (uniforms.hasMask > 0.5)
        ? float(texture1.sample(linearSampler, maskUV).r)
        : 1.0;

    float distance = uniforms.time * uniforms.speed + dot(in.uv, direction) * uniforms.scale;
    float strength = uniforms.strength * uniforms.strength;
    float2 offset = float2(direction.y, -direction.x);
    float wave = sin(distance);
    float shaped = sign(wave) * pow(abs(wave), max(uniforms.exponent, 0.0001));

    float2 displacement = shaped * offset * strength * mask;
    float2 uv = clamp(in.uv + displacement, float2(0.0), float2(1.0));

    // Developer Tools "Waterwaves debug" visualizations (0 in production).
    if (uniforms.debugMode > 0.5) {
        if (uniforms.debugMode > 3.5) {
            // Plumbing test: paint the whole pass solid magenta, ignoring mask/source.
            // If this shows on the character, the waterwaves pass runs live and the flag
            // reaches the renderer (so any "no motion" is mask alignment, not plumbing).
            return half4(1.0h, 0.0h, 1.0h, 1.0h);
        }
        if (uniforms.debugMode < 1.5) {
            // Mask as grayscale — shows WHERE the effect is allowed to act (and reveals
            // any vertical flip vs the character).
            return half4(half3(mask), 1.0h);
        } else if (uniforms.debugMode < 2.5) {
            // Source with the mask region tinted red — confirms the trigger region lands on
            // the intended part of the character (e.g. the hair).
            float4 base = float4(texture0.sample(linearSampler, in.uv));
            float3 tinted = mix(base.rgb, float3(1.0, 0.0, 0.0), mask * 0.6);
            return half4(half3(tinted), half(base.a));
        }
        // Displacement-magnitude heatmap (amplified) — shows whether the wave field is
        // actually nonzero over the masked region.
        float mag = clamp(length(displacement) * 120.0, 0.0, 1.0);
        return half4(half(mag), half(mag * 0.4), 0.0h, 1.0h);
    }

    return texture0.sample(linearSampler, uv);
}

// Phase 2D-F: more single-pass effect approximations that show up across
// the corpus. These are visually plausible drop-ins; the shader translator
// will replace them with the WPE-original output when it ships.

struct WPESpinUniforms {
    float angularSpeed;  // radians per second
    float time;
    float padding0;
    float padding1;
};

fragment half4 wpe_effect_spin_fragment(
    WPEVertexOut in [[stage_in]],
    texture2d<half, access::sample> texture0 [[texture(0)]],
    constant WPESpinUniforms& uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    float a = uniforms.angularSpeed * uniforms.time;
    float2 c = float2(0.5, 0.5);
    float2 d = in.uv - c;
    float s = sin(a), co = cos(a);
    float2 r = float2(d.x * co - d.y * s, d.x * s + d.y * co) + c;
    float2 uv = clamp(r, float2(0.0), float2(1.0));
    return texture0.sample(linearSampler, uv);
}

struct WPETintUniforms {
    float4 color;        // tint color (linear, executor pre-converts)
    float intensity;
    float padding0;
    float padding1;
    float padding2;
};

fragment half4 wpe_effect_tint_fragment(
    WPEVertexOut in [[stage_in]],
    texture2d<half, access::sample> texture0 [[texture(0)]],
    constant WPETintUniforms& uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    float4 sampled = float4(texture0.sample(linearSampler, in.uv));
    float t = saturate(uniforms.intensity);
    float3 rgb = mix(sampled.rgb, sampled.rgb * uniforms.color.rgb, t);
    return half4(float4(rgb, sampled.a));
}

struct WPEFoliageSwayUniforms {
    float amplitude;
    float frequency;
    float speed;
    float time;
};

fragment half4 wpe_effect_foliagesway_fragment(
    WPEVertexOut in [[stage_in]],
    texture2d<half, access::sample> texture0 [[texture(0)]],
    constant WPEFoliageSwayUniforms& uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    float yMask = 1.0 - in.uv.y;
    float wave = sin(uniforms.time * uniforms.speed + in.uv.y * uniforms.frequency);
    float2 uv = clamp(in.uv + float2(wave * uniforms.amplitude * yMask, 0.0), float2(0.0), float2(1.0));
    return texture0.sample(linearSampler, uv);
}

struct WPEWaterRippleUniforms {
    float amplitude;
    float frequency;
    float speed;
    float time;
};

fragment half4 wpe_effect_waterripple_fragment(
    WPEVertexOut in [[stage_in]],
    texture2d<half, access::sample> texture0 [[texture(0)]],
    constant WPEWaterRippleUniforms& uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    float2 c = float2(0.5, 0.5);
    float2 d = in.uv - c;
    float r = length(d);
    float wave = sin(r * uniforms.frequency - uniforms.time * uniforms.speed);
    float2 disp = (r > 0.0001) ? (d / r) * wave * uniforms.amplitude : float2(0.0);
    float2 uv = clamp(in.uv + disp, float2(0.0), float2(1.0));
    return texture0.sample(linearSampler, uv);
}

struct WPEBlendUniforms {
    float4 color;        // blend color
    float opacity;
    float padding0;
    float padding1;
    float padding2;
};

fragment half4 wpe_effect_blend_fragment(
    WPEVertexOut in [[stage_in]],
    texture2d<half, access::sample> texture0 [[texture(0)]],
    constant WPEBlendUniforms& uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    float4 sampled = float4(texture0.sample(linearSampler, in.uv));
    float o = saturate(uniforms.opacity);
    float3 rgb = mix(sampled.rgb, sampled.rgb * uniforms.color.rgb, o);
    return half4(float4(rgb, sampled.a));
}

// Phase 2D-G: more single-pass effects.

struct WPEWaterFlowUniforms {
    float2 direction;    // unit-vector flow direction in UV space
    float speed;
    float time;
};

fragment half4 wpe_effect_waterflow_fragment(
    WPEVertexOut in [[stage_in]],
    texture2d<half, access::sample> texture0 [[texture(0)]],
    constant WPEWaterFlowUniforms& uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::repeat, filter::linear);
    float2 uv = fract(in.uv + uniforms.direction * uniforms.speed * uniforms.time);
    return texture0.sample(linearSampler, uv);
}

struct WPEColorGradingUniforms {
    float4 lift;         // shadow lift (linear color)
    float4 gamma;        // mid-tone gamma curve
    float4 gain;         // highlight gain
};

fragment half4 wpe_effect_color_grading_fragment(
    WPEVertexOut in [[stage_in]],
    texture2d<half, access::sample> texture0 [[texture(0)]],
    constant WPEColorGradingUniforms& uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    float4 sampled = float4(texture0.sample(linearSampler, in.uv));
    float3 lifted = sampled.rgb + uniforms.lift.rgb;
    float3 gained = lifted * max(uniforms.gain.rgb, float3(0.0001));
    float3 graded = pow(saturate(gained), float3(1.0) / max(uniforms.gamma.rgb, float3(0.0001)));
    return half4(float4(saturate(graded), sampled.a));
}

struct WPEShimmerUniforms {
    float speed;
    float intensity;
    float time;
    float padding;
};

fragment half4 wpe_effect_shimmer_fragment(
    WPEVertexOut in [[stage_in]],
    texture2d<half, access::sample> texture0 [[texture(0)]],
    constant WPEShimmerUniforms& uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    float4 sampled = float4(texture0.sample(linearSampler, in.uv));
    float n = fract(sin(dot(in.uv * 100.0, float2(12.9898, 78.233)) + uniforms.time * uniforms.speed) * 43758.5453);
    float boost = 1.0 + n * uniforms.intensity;
    return half4(float4(saturate(sampled.rgb * boost), sampled.a));
}

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
