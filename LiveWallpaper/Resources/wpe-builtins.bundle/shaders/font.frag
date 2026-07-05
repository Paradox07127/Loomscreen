// LiveWallpaper clean-room implementation of the text fragment stage
// (`shaders/font.frag`). Authored locally from two public references — the
// msdfgen multi-channel signed-distance-field sampling algorithm
// (median-of-three reconstruction + screen-pixel-range, V. Chlumsky, MIT)
// and the uniform/combo contract packed by WPEMSDFFontMaterial and bound by
// WPEMSDFTextRenderer / WPEMetalRenderExecutor. Contains no Wallpaper
// Engine bytes.
//
// Contract (see WPEMSDFFontMaterial.make):
//   g_Texture0            glyph atlas — MSDF RGB when MSDF=1,
//                         single-channel coverage when MSDF=0
//   g_Texture1            per-glyph color layer, sampled when COLORFONT=1
//   g_Texture0Resolution  atlas resolution (xy = width, height in texels)
//   g_Color4              fill color (rgb) + object alpha (a)
//   g_RenderVar0          x = distance-field range (atlas px)
//                         y = outline width (atlas px)
//                         z = blur radius (atlas px)
//                         w = drop-shadow radius (atlas px)
//   g_RenderVar1          xyz = outline color, w = shadow offset x (atlas px)
//   g_RenderVar2          xyz = shadow color,  w = shadow offset y (atlas px)
//   g_RenderVar3          x = drop-shadow opacity
// Combos: MSDF, COLORFONT, OUTLINE_ENABLED, BLUR_ENABLED, DROP_SHADOW_ENABLED.
//
// Output is STRAIGHT (non-premultiplied) alpha — vec4(rgb, a). The MSDF
// text pipeline state multiplies source RGB by source alpha at blend time,
// so premultiplying here would halo semi-transparent edges.

uniform sampler2D g_Texture0;
uniform sampler2D g_Texture1;
uniform vec4 g_Texture0Resolution;

uniform vec4 g_Color4;
uniform vec4 g_RenderVar0;
uniform vec4 g_RenderVar1;
uniform vec4 g_RenderVar2;
uniform vec4 g_RenderVar3;

varying vec2 v_TexCoord;

// Median of the three field channels — the defining MSDF reconstruction
// step: at any texel two channels agree on the true signed distance, and
// the median discards the outlier that carries a neighboring edge.
float fieldMedian(vec3 f)
{
    return max(min(f.r, f.g), min(max(f.r, f.g), f.b));
}

// Signed distance to the glyph edge in ATLAS pixels. The field stores
// 0.5 at the edge; g_RenderVar0.x is the encoded range of the field.
float atlasDistancePx(vec3 f)
{
    return g_RenderVar0.x * (fieldMedian(f) - 0.5);
}

// How many SCREEN pixels the field range spans at this fragment, derived
// from the screen-space UV footprint (L2 norm of the UV derivatives).
// Clamped to >= 1 so heavily minified text keeps at least a one-pixel
// anti-aliasing ramp instead of dissolving.
float screenRangePx(vec2 uv)
{
    vec2 rangeUV = CAST2(g_RenderVar0.x) / g_Texture0Resolution.xy;
    vec2 duvdx = ddx(uv);
    vec2 duvdy = ddy(uv);
    vec2 pxPerUV = CAST2(1.0) / sqrt(duvdx * duvdx + duvdy * duvdy);
    return max(0.5 * dot(rangeUV, pxPerUV), 1.0);
}

// Signed distance in SCREEN pixels — the sharp path measures here so the
// anti-aliasing ramp is one screen pixel at every text scale.
float screenDistancePx(vec3 f, vec2 uv)
{
    return screenRangePx(uv) * (fieldMedian(f) - 0.5);
}

// Coverage from a signed distance. `edgeShift` moves the covered iso-line
// outward (0.5 lands exactly on the glyph edge; larger values dilate — used
// for outlines). `softness` widens the transition for blur / shadow falloff;
// soft combos keep a minimum half-pixel ramp so hard edges stay antialiased.
float edgeCoverage(float distancePx, float edgeShift, float softness)
{
#if BLUR_ENABLED || DROP_SHADOW_ENABLED
    float ramp = max(softness, 0.5);
    return smoothstep(-ramp, ramp, distancePx + edgeShift - 0.5);
#else
    return clamp(distancePx + edgeShift, 0.0, 1.0);
#endif
}

void main()
{
#if MSDF
    vec3 field = texSample2D(g_Texture0, v_TexCoord.xy).rgb;

    // Blur authors its radius in atlas pixels, so the blurred path measures
    // distance and outline width in atlas space; the sharp path converts to
    // screen space for scale-independent one-pixel edges.
#if BLUR_ENABLED
    float dist = atlasDistancePx(field);
    float outlinePx = g_RenderVar0.y;
    float soft = g_RenderVar0.z;
#else
    float dist = screenDistancePx(field, v_TexCoord.xy);
    float outlinePx = g_RenderVar0.y * (screenRangePx(v_TexCoord.xy) / g_RenderVar0.x);
    float soft = 0.0;
#endif

    float fill = edgeCoverage(dist, 0.5, soft);

#if COLORFONT
    vec3 fillColor = texSample2D(g_Texture1, v_TexCoord.xy).rgb;
#else
    vec3 fillColor = g_Color4.rgb;
#endif

#if OUTLINE_ENABLED
    // The outline is a dilated iso-line: its coverage bounds the whole
    // glyph, and the fill coverage selects fill color over outline color.
    float outlined = edgeCoverage(dist, 0.5 + outlinePx, soft);
    vec4 glyph = vec4(mix(g_RenderVar1.xyz, fillColor, fill), outlined * g_Color4.a);
#else
    vec4 glyph = vec4(fillColor, fill * g_Color4.a);
#endif

#if DROP_SHADOW_ENABLED
    // Re-sample the field at the shadow offset (atlas px → UV) and place
    // the shadow UNDER the glyph: straight-alpha "over" with the glyph on
    // top, un-premultiplied at the end because the output stays straight.
    vec2 shadowUV = v_TexCoord.xy - vec2(g_RenderVar1.w, g_RenderVar2.w) / g_Texture0Resolution.xy;
    float shadowDist = atlasDistancePx(texSample2D(g_Texture0, shadowUV).rgb);
#if OUTLINE_ENABLED
    float shadowShift = 0.5 + g_RenderVar0.y;
#else
    float shadowShift = 0.5;
#endif
    float shadow = saturate(g_RenderVar3.x * edgeCoverage(shadowDist, shadowShift, g_RenderVar0.w)) * g_Color4.a;
    float outAlpha = glyph.a + shadow * (1.0 - glyph.a);
    vec3 outColor = (glyph.rgb * glyph.a + g_RenderVar2.xyz * shadow * (1.0 - glyph.a)) / max(outAlpha, 1e-6);
    gl_FragColor = vec4(outColor, outAlpha);
#else
    gl_FragColor = glyph;
#endif

#else // MSDF == 0: pre-rasterized coverage atlas, no distance field.
#if COLORFONT
    vec4 texel = texSample2D(g_Texture0, v_TexCoord.xy);
    gl_FragColor = vec4(texel.rgb, texel.a * g_Color4.a);
#else
    // Single-channel coverage atlas tinted with the fill color.
    float coverage = texSample2D(g_Texture0, v_TexCoord.xy).r;
    gl_FragColor = vec4(g_Color4.rgb, coverage * g_Color4.a);
#endif
#endif
}
