#include <metal_stdlib>
using namespace metal;

struct WPEVertexOut {
    float4 position [[position]];
    float2 uv;
};

struct WPESolidUniforms {
    float4 color;
};

struct WPEComposeRegionUniforms {
    float4 color;
    float4 texture0UVRect;
    float4 texture1UVRect;
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
    float4 uvSignAndPadding;     // x,y UV sign for negative WPE scale mirroring
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

// WPE `composelayer.frag` parity: `passthrough:true` compose/project/fullscreen
// utility layers transfer the captured full-frame buffer 1:1 at screen UV via a
// plain fullscreen quad (wpe_fullscreen_vertex), IGNORING the object's authored
// size/rotation/origin — sampling through the layer transform warped oversized/
// rotated layers into a distorted inset. The layer transform positions the
// DOWNSTREAM effect (lens flare / DoF / foliage), not the compose capture.
// Single-texture by design (WPE composelayer samples only g_Texture0); the
// two-texture mix lives in wpe_compose_fragment for the legacy fallback path.
fragment half4 wpe_composelayer_fragment(
    WPEVertexOut in [[stage_in]],
    texture2d<half, access::sample> texture0 [[texture(0)]],
    constant WPEComposeLayerUniforms& uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    float4 color = float4(texture0.sample(linearSampler, in.uv));
    if (uniforms.flags.x > 0.5) {
        color.a = 0.0;
    }
    return half4(color);
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

fragment half4 wpe_compose_region_fragment(
    WPEVertexOut in [[stage_in]],
    texture2d<half, access::sample> texture0 [[texture(0)]],
    texture2d<half, access::sample> texture1 [[texture(1)]],
    constant WPEComposeRegionUniforms& uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    float2 uv0 = clamp(
        uniforms.texture0UVRect.xy + in.uv * uniforms.texture0UVRect.zw,
        float2(0.0),
        float2(1.0)
    );
    float2 uv1 = clamp(
        uniforms.texture1UVRect.xy + in.uv * uniforms.texture1UVRect.zw,
        float2(0.0),
        float2(1.0)
    );
    float4 a = float4(texture0.sample(linearSampler, uv0));
    float4 b = float4(texture1.sample(linearSampler, uv1));
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

// Phase 2D-D: native MSL implementations of WPE's most-used material
// shaders. Together they cover ~858 of the top shader uses across the
// 431960 corpus (562 genericimage4 + 103 genericimage2 + 193 genericparticle),
// so any scene built only on these + the existing built-ins now renders
// without needing the GLSL→MSL translator. Combos are not interpreted —
// the default no-combo case is what most scenes ship.

struct WPEGenericImageUniforms {
    float4 color;        // g_Color (sRGB→linear converted by executor)
    float4 alphaMaskUV;  // x=alpha multiplier, y=brightness, z=hasMask, w=padding
};

fragment half4 wpe_genericimage2_fragment(
    WPEVertexOut in [[stage_in]],
    texture2d<half, access::sample> texture0 [[texture(0)]],
    constant WPEGenericImageUniforms& uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    float4 sampled = float4(texture0.sample(linearSampler, in.uv));
    float3 rgb = sampled.rgb * uniforms.color.rgb * uniforms.alphaMaskUV.y;
    float alpha = sampled.a * uniforms.color.a * uniforms.alphaMaskUV.x;
    return half4(float4(rgb * alpha, alpha));
}

fragment half4 wpe_genericimage4_fragment(
    WPEVertexOut in [[stage_in]],
    texture2d<half, access::sample> texture0 [[texture(0)]],
    texture2d<half, access::sample> texture1 [[texture(1)]],
    constant WPEGenericImageUniforms& uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    float4 sampled = float4(texture0.sample(linearSampler, in.uv));
    float maskAlpha = 1.0;
    if (uniforms.alphaMaskUV.z > 0.5) {
        maskAlpha = float(texture1.sample(linearSampler, in.uv).a);
    }
    float3 rgb = sampled.rgb * uniforms.color.rgb * uniforms.alphaMaskUV.y;
    float alpha = sampled.a * maskAlpha * uniforms.color.a * uniforms.alphaMaskUV.x;
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
};

vertex WPEParticleVertexOut wpe_particle_vertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    constant WPEParticleInstance* instances [[buffer(1)]],
    constant WPEParticleProjection& projection [[buffer(2)]],
    constant WPEParticleSpriteParams& sprite [[buffer(3)]]
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
    float2 centerNDC = float2(
        instance.positionAndSize.x / halfWidth,
        instance.positionAndSize.y / halfHeight
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
    float2 frameUVScale = float2(1.0 / cols, 1.0 / rows);
    float frameContinuous = instance.rotationAndLife.z;
    float frameLo = floor(frameContinuous);
    float blend = frameContinuous - frameLo;
    float frameHi = (frameLo + 1.0 >= frameCount) ? 0.0 : (frameLo + 1.0);

    uint colsI = max(uint(cols), 1u);
    uint frameLoI = uint(frameLo);
    uint colLo = frameLoI % colsI;
    uint rowLo = frameLoI / colsI;
    uint frameHiI = uint(frameHi);
    uint colHi = frameHiI % colsI;
    uint rowHi = frameHiI / colsI;
    float2 uvOriginLo = float2(float(colLo), float(rowLo)) * frameUVScale;
    float2 uvOriginHi = float2(float(colHi), float(rowHi)) * frameUVScale;

    WPEParticleVertexOut out;
    out.position = float4(centerNDC + cornerNDC, 0.0, 1.0);
    out.uvCurrent = uvOriginLo + unitUV * frameUVScale;
    out.uvNext = uvOriginHi + unitUV * frameUVScale;
    out.frameBlend = blend;
    out.color = instance.color;
    return out;
}

fragment half4 wpe_particle_instanced_fragment(
    WPEParticleVertexOut in [[stage_in]],
    texture2d<half, access::sample> texture0 [[texture(0)]],
    constant WPEParticleSpriteParams& sprite [[buffer(0)]]
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
    // Straight (non-premultiplied) alpha. The Metal pipeline state's
    // blend factors handle the translucent/additive/normal split set
    // up by `particlePipelineState`.
    return half4(rgb, alpha);
}

// Phase 2D-N: text overlay quad. Vertex stage takes per-overlay center
// + size + color from a uniform buffer; fragment samples the rasterized
// CoreText output.

struct WPETextOverlayUniforms {
    float4 centerAndSize;   // x,y center (pixel space) ; z,w width,height (pixels)
    float4 sceneSize;       // x = scene width, y = scene height
    float4 color;           // rgb tint × per-text alpha (already premultiplied by alpha in .a)
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
    out.position = float4(centerNDC + cornerNDC, 0.0, 1.0);
    out.uv = uv;
    return out;
}

fragment half4 wpe_text_overlay_fragment(
    WPETextOverlayVertexOut in [[stage_in]],
    texture2d<half, access::sample> texture0 [[texture(0)]],
    constant WPETextOverlayUniforms& u [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    float4 sampled = float4(texture0.sample(linearSampler, in.uv));
    float3 rgb = sampled.rgb * u.color.rgb;
    float alpha = sampled.a * u.color.a;
    return half4(float4(rgb, alpha));
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
    float alpha = sampled.a * mask * saturate(uniforms.opacity);
    return half4(float4(sampled.rgb * alpha, alpha));
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
    float debugMode; // 0 normal; 1 mask grayscale; 2 source+red mask overlay; 3 displacement heatmap
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
    float mask = (uniforms.hasMask > 0.5)
        ? float(texture1.sample(linearSampler, in.uv).r)
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
