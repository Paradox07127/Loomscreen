# Stage H — Runtime Uniforms / Engine Constants (time / audio / pointer)

## Checklist

| engine constant | doc semantics | impl (file:line) | verdict | note |
|---|---|---|---|---|
| `g_Time` | seconds since start | WPEMetalRuntimeUniforms:99,58; WPERenderPipeline:64 | ✅ | elapsed=mediaTime−loadTime, ≥0 |
| `g_Frametime` | current frametime (s) | — | ❌ | never computed/uploaded → zero default |
| `g_Daytime` | 0=00:00, 1≈23:59 | :100-103,59 | ✅ | seconds/86400 clamped |
| `g_PointerPosition` | normalized [0,1] cursor | :129-145,61 | ⚠️ | Y flipped (`1−y`) — correct for WPE top-left, verify view !isFlipped (D3) |
| `g_PointerPositionLast` | prev-frame cursor | — | ❌ | not tracked → zero default |
| `g_ParallaxPosition` | normalized layer parallax offset | not uploaded; baked into wpe_copy UV only (ShaderInputs:160) | ❌ | custom shaders get zero default (D4) |
| `g_AudioSpectrum16/32/64 L/R` | positive, NOT normalized, low→high | :50-67; WPESoundRuntime:194-211 | ⚠️ | log-normalized 0…1 (doc says NOT) + L==R mono (D1,D2) |
| `g_Texture0..7Resolution` | xy physical px, zw mapped | WPEMetalRenderExecutor:1293,1418-1436; Registry:19-26 | ⚠️ | xy/zw intent likely inverted (harmless w/o POT padding) (D5) |
| `g_Screen` (w,h,aspect) | screen size+aspect | — | ❌ | not uploaded |
| `g_TexelSize`/`g_TexelSizeHalf` | 1/w,1/h | only ad-hoc for blur (Dispatcher:218-221) | ❌ | not exposed as engine constant |
| `g_Color`/`g_Color4` | sRGB multiplier | WPEMetalShaderInputs:14-24 | ✅ | sRGB→linear |
| `g_ViewProjectionMatrix` | premult VP | :185-213 | ➖ | (Stage C) |
| render resolution → sceneRenderSize | engine render size | WPEMetalSceneRenderer:779 | ✅ | |

## Deviations

- **D1 (High) — audio spectrum normalized; docs say NOT.** `WPESoundRuntime:205` `log10(...)/6+1` clamped [0,1]; `:18` documents "normalized 0…1". WPE shaders expect unbounded positive magnitudes (often >1). Clamping changes dynamic range + transient shape → audio-reactive scenes over-compressed. Down-mix to 32/16 averages already-normalized bins, compounding.
- **D2 (Med) — Left==Right (mono).** `:62-67` assigns same buffer to both; FFT sums all channels first (`WPESoundRuntime:160-171`). Stereo-asymmetric visualizers collapse.
- **D3 (Med) — `g_PointerPosition` Y inversion** `1 − y` (`:143`). AppKit is bottom-left → `1−` gives top-left = WPE convention (arguably correct), but must agree with scene UV/parallax Y handling; verify against a real mouse-reactive scene + that the view isn't `isFlipped`.
- **D4 (Med) — `g_ParallaxPosition` not provided to custom shaders.** Parallax only baked into `wpe_copy` UV (`WPEMetalRenderExecutor:846-851`, bespoke `delta*depth*0.1` ±0.05). Custom shaders reading it get 0.
- **D5 (Low/Med) — `g_TextureNResolution` xy/zw intent inverted.** `Registry:19-26` emits [textureW,textureH,imageW,imageH]; doc XY=physical(padded), ZW=mapped(usable). Harmless while Apple textures aren't POT-padded (xy==zw); verify any atlas/sprite-sheet path.

**Correct:** `g_Time` units/semantics, `g_Daytime`, audio array sizes/ordering, MSL scalar-array packing round-trip (`packTranslatedUniforms` ↔ transpiler reader — no mismatch), per-slot `g_TextureNResolution` population.

**Most severe:** `g_Frametime` missing (motion shaders), audio normalization, missing `g_Screen`/`g_TexelSize`/`g_ParallaxPosition`/`g_PointerPositionLast`.

Sources: docs shader/variables; wallpaper-engine.fandom Shader_engine_constants.
