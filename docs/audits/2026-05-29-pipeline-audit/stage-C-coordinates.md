# Stage C — Coordinate System / Transforms / Parallax / Projection

(Highest-risk stage. See the parent doc §7 for the WPE=D3D / Metal=D3D / GL-outlier ground truth that resolves these.)

## Checklist (abridged)

| rule | impl (file:line) | verdict | note |
|---|---|---|---|
| Scene origin top-left, Y-DOWN (D3D/Win32) | WPEMetalRuntimeUniforms:148-150,191-213; real scene 3385315370 ortho 3840×2160, centered origin `1920 1080` | ✅ | comment + ortho + real data agree |
| Ortho from general.orthogonalprojection w/h | WPEMetalRuntimeUniforms:165-178; consumed WPEMetalSceneRenderer:372-376 | ✅ | exported as g_ViewProjectionMatrix |
| Ortho maps [0,W]×[0,H] (Y-down) → NDC with Y flip | WPEMetalRuntimeUniforms:204-212 | ✅ | `2/(top-bottom)` with top=0,bottom=H ⇒ flip. Correct for **custom shaders** using the matrix |
| scene px → NDC for built-in object quads | WPEMetalBuiltins.metal:71-84; WPEMetalRenderExecutor:885-927 | ⚠️ | object-quad path does NOT use the ortho matrix; divides centered px by halfHeight → Y NOT flipped. See Dev 1 |
| object origin (px or normalized) → center | WPEMetalRenderExecutor:899-906 | ✅ | origin∈[0,1]→*W else px; anchor=originPx−W/2 |
| object scale → quad size | :893-898 | ✅ | width=baseSize*|scaleX| |
| negative scale → UV mirror | .metal:78-81; :920-925 | ✅ | uvSign<0 ⇒ uv=1-uv |
| object rotation about quad center | .metal:63-70; :917 | ⚠️ | applied in un-flipped Y-up quad space → spin inverted relative to true Y-down→Y-up. Same root as Dev 1 |
| texcoord origin: texture row 0 = top | .metal:24-42/54-61/489-500 | ✅ | top→uv.y=0; FBO↔FBO round-trips cancel |
| FBO→FBO copy preserves orientation | .metal:24-42 + :754-856, :416-474 | ✅ | same flipped-UV table every hop ⇒ double-flip = identity |
| particle scene-object origin → centered px | WPEParticleSystem:34-39,996-1002 | ⚠️ | objectOrigin.y − H/2, no Y-flip (matches object-quad path → shares Dev 1) |
| particle emitter-internal Y-down, flipped once at spawn | WPEParticleSystem:15-27,201,442-462 | ✅ | documented single flip; angles negated |
| g_PointerPosition normalized [0,1], Y matched | WPEMetalRuntimeUniforms:129-145 | ✅ | `y = 1 − localPoint.y/H` → top-left Y-down |
| parallax: pointer offset × parallaxDepth | WPEMetalShaderInputs:160-176; applied :847-853 | ❌ | arbitrary `×0.1` + clamp ±0.05; sign not WPE; see Dev 2 |
| parallax as layer/position shift (per g_ParallaxPosition) | WPEMetalShaderInputs:146-176, .metal:119-127 | ❌ | WPE moves layer **position**; impl shifts **sampling UV** in a fullscreen copy. Wrong mechanism + sign. Dev 2 |
| parallaxDepth is per-axis vec2 | WPEPipelineEnvelope:82 (Double) | ⚠️ | stored scalar; can't express X-only/Y-only parallax. Dev 3 |

## Deviations

- **Dev 1 — Object-quad/particle/text Y mapping bypasses the ortho Y-flip (MEDIUM, systematic).** `WPEMetalBuiltins.metal:73-84` (`centerNDC.y = u.centerAndSize.y/halfHeight`, Y-up) fed by `WPEMetalRenderExecutor:899-906` (Y-down scene value). Matrix path flips; built-in geometry path doesn't. Centered objects pass; **off-center layers vertically mirrored**. Internally consistent across the 3 built-in paths but inconsistent with the matrix path + WPE. Fix: negate `center.y` (and rotate with `-angle`) or route quads through `g_ViewProjectionMatrix`. **Highest-value thing to validate on a real off-center scene.**
- **Dev 2 — Parallax sign + mechanism wrong (HIGH).** `WPEMetalShaderInputs:160-176`: `offset = (pointer−0.5)*parallaxDepth*0.1` clamped ±0.05, applied as a UV add in `wpe_copy_fragment`. (1) WPE shifts layers **opposite** the cursor; impl slides UV the **same** way; sign not derived from any WPE rule. (2) `×0.1`/`±0.05` arbitrary; applying as UV offset on a fullscreen copy means it's skipped for object-quad/particle layers. Fix: compute a layer-position offset ∝ parallaxDepth × pointer delta, apply to quad center; verify sign vs a known WPE scene.
- **Dev 3 — `parallaxDepth` collapsed vec2→scalar (LOW–MED).** Can't express single-axis parallax. Widen to SIMD2 when fixing Dev 2.

**Confirmed correct:** pointer-Y `1−y`, ortho Y-flip for custom shaders, FBO↔FBO round-trip, particle emitter single-flip, negative-scale UV mirror.

**Fix order:** Dev 2 (parallax, every parallax scene) then Dev 1 (off-center mirror).

Sources: docs.wallpaperengine.io shader/variables, ILayer, parallax/introduction, assets/overview.
