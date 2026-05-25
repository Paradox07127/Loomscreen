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

// Phase 2D-D: native MSL implementations of WPE's most-used material
// shaders. Together they cover ~858 of the top shader uses across the
// 431960 corpus (562 genericimage4 + 103 genericimage2 + 193 genericparticle),
// so any scene built only on these + the existing built-ins now renders
// without needing the GLSL→MSL translator. Combos are not interpreted —
// the default no-combo case is what most scenes ship.

struct WPEGenericImageUniforms {
    float4 color;        // g_Color, forwarded verbatim by the executor (raw RGBA8 pipeline)
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
    float4 positionAndSize;   // x, y, z (unused), size in pixels
    float4 color;             // rgb 0..1, a = current alpha
    float4 rotationAndLife;   // x = rotationZ rad, y = lifetimeFraction, z = spriteFrameIndex, w reserved
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
    float padding0;
    float padding1;
    float padding2;
};

fragment half4 wpe_effect_opacity_fragment(
    WPEVertexOut in [[stage_in]],
    texture2d<half, access::sample> texture0 [[texture(0)]],
    constant WPEOpacityUniforms& uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    float4 sampled = float4(texture0.sample(linearSampler, in.uv));
    float a = saturate(uniforms.opacity);
    return half4(float4(sampled.rgb * a, sampled.a * a));
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
    float amplitude;
    float frequency;
    float speed;
    float time;
};

fragment half4 wpe_effect_waterwaves_fragment(
    WPEVertexOut in [[stage_in]],
    texture2d<half, access::sample> texture0 [[texture(0)]],
    constant WPEWaterWavesUniforms& uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    float phase = uniforms.time * uniforms.speed;
    float frequency = max(uniforms.frequency, 0.0);
    float2 wave = float2(
        sin((in.uv.y + phase) * frequency * 1.3),
        cos((in.uv.x + phase) * frequency * 1.7)
    ) * uniforms.amplitude;
    float2 uv = clamp(in.uv + wave, float2(0.0), float2(1.0));
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
