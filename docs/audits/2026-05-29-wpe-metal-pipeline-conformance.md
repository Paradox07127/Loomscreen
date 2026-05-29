# WPE Metal Pipeline — Documentation-Conformance Audit

**Date:** 2026-05-29
**Method:** 9 parallel per-stage audit agents (web access to official WPE docs + repo read + static inspection of real scenes) **+** a codex backend-authority cross-check on the three highest-risk stages (decode / coordinates / shader). Report-first: **no code changed in this pass** — discrepancies are logged for separate, test-first remediation rounds.
**Baselines:** official docs `docs.wallpaperengine.io/en/scene/*`; community refs (`wallpaper-engine.fandom.com`, `linux-wallpaperengine`, RePKG); **real corpus** at `~/Documents/Live Wallpapers/431960` (scene.pkg unpacked: PKGV0014–0023, real `scene.json`, `.tex` `TEXV0005/TEXI0001/TEXB0003-4/TEXS0003`, materials).
**Scope:** A decode · B scene parse · C coordinates · D render-graph/compositing · E materials/combos · F shader transpile · G particles · H runtime uniforms · I render loop.

> ⚠️ Doc-access caveat: `docs.wallpaperengine.io` is a JS SPA (plain fetch returns nav shells) and the Fandom wiki rate-limits fetches. Agents recovered field-level detail from the Steam structure guide (id=770802221), the SPA's extractable snippets, the `linux-wallpaperengine` reference implementation, and **direct inspection of the real corpus** (the strongest signal — many findings below are confirmed against actual scene.json/.tex bytes).

---

## Executive summary

The pipeline is **structurally sound** (PKG/`.tex` container parsing, render-graph ping-pong/FBO chaining, combo→#define, particle core math, snapshot readback, `g_Time` — all verified correct). The defects cluster in **coordinate/transform semantics, parallax, blend-mode + combo gating, shader-feature coverage, and runtime-constant fidelity** — i.e. the classic "renders, but wrong" bucket, exactly what the WPE-corpus goal targets.

**Cross-validation is strong:** codex independently reached the same Critical verdict on the **Y-axis conflict** and flagged the same parallax, `#if→0`, `texSample2DLod`, and slot-cap issues the stage agents found.

Tally: **7 P0** (broad visual breakage) · **11 P1** (meaningful subset) · **~12 P2** (edge/fidelity). Full per-stage verdict tables live in §4.

---

## 1. P0 — Critical (silently wrong on many/most scenes)

| ID | Stage | Finding | Code (file:line) | Doc / evidence | Confirmed by |
|----|-------|---------|------------------|----------------|--------------|
| **P0-1** | C/I | **Y-axis convention conflict.** Ortho matrix is Y-down→NDC (flips), but object-quad / particle / text vertex paths feed scene Y straight into Y-up NDC. Centered layers look fine; **any off-center layer is vertically mirrored/misplaced.** | `WPEMetalRuntimeUniforms.swift:204-212` (flip) vs `WPEMetalRenderExecutor.swift:899-906` + `WPEMetalBuiltins.metal:73-84` (no flip) | Real scene `3385315370`: ortho 3840×2160, centered image origin `1920 1080` (=W/2,H/2) — passes only because it's centered | **codex (Critical) + C + I** |
| **P0-2** | C/B/H | **Parallax broken end-to-end.** (a) `parallaxDepth` is a `"x y"` string parsed as scalar → always **0**; (b) offset is ad-hoc `(pointer−0.5)·depth·0.1` clamped ±0.05, wrong sign/mechanism, only on the copy path; (c) `g_ParallaxPosition` never uploaded → custom shaders read 0; ignores `general.cameraparallax*`. | `WPESceneDocumentParser.swift:556`; `WPEMetalShaderInputs.swift:160-176`; (no `g_ParallaxPosition` writer) | docs: parallaxDepth is per-axis vec2; `g_ParallaxPosition` = normalized layer offset | **codex (Major) + C + B + H** |
| **P0-3** | B | **`colorBlendMode` (int) never read** — parser looks for string `blendmode` (absent in real files). 42/61 real objects carry `colorBlendMode`; **every additive/multiply/screen layer renders Normal.** | `WPESceneDocumentParser.swift:528`; map `WPESceneDocument.swift:541` | real corpus: 0 `blendmode`, 42 `colorBlendMode` | **B (corpus-verified)** |
| **P0-4** | A | **sRGB applied on texture upload**, but reference uploads **linear** (`GL_RGBA8`) and gamma-corrects in-shader → **double gamma** (washed-out/over-bright) on color textures. | `WPEMetalTextureFormatMapper.swift:77,90,99,108,117` (`_srgb` default) | `linux-wallpaperengine CTexture.cpp` uses linear internal formats | **A + codex (transcode-divergence)** |
| **P0-5** | E | **`requireany:true` (OR) treated as AND.** Stock `generic.frag` gates normal/PBR samplers with `requireany`; AND logic gates them **off** → flat/incorrect lighting on a large fraction of model & image materials. | `WPERenderPipelineBuilder.swift:700-713` (ANDs; never reads `requireany`) | real `assets/shaders/generic.frag` metadata | **E (corpus-verified)** |
| **P0-6** | F | **Unsupported `#if` expressions silently evaluate to 0.** Tokenizer lacks `* / % ~ << >>`, ternary, func-macros → any such combo branch collapses to the 0 path → **wrong shader variant, no error.** | `WPEShaderTranspiler.swift:336 (`?? 0`),:564-572` | combos drive `#if`-permutations | **F + codex (Major)** |
| **P0-7** | F | **`texSample2DLod` → uncompilable MSL.** Preprocessor emits `textureLod(...)` but the transpiler only rewrites `texture(`; `textureLod` survives → `makeLibrary` fails → **every LOD/blur/bloom/mip shader fails to compile** (→ fallback/black). | `WPEShaderPreprocessor.swift:196` + `WPEShaderTranspiler.swift:1206-1250` | docs: `texSample2DLod` is a supported builtin | **F + codex (Major)** |

---

## 2. P1 — Major (meaningful subset of scenes)

| ID | Stage | Finding | Code | Confirmed |
|----|-------|---------|------|-----------|
| **P1-1** | F/codex | **Vertex shaders effectively ignored** — varyings synthesized from `in.uv` by name heuristics; real WPE computes UVs/scroll/perspective in the vertex stage. | `WPESwiftShaderCompiler.swift:31,101`, `WPEShaderTranspiler.swift:1959-2059` | codex (Critical) + F |
| **P1-2** | B | **`fov`/`nearz`/`farz`/`zoom` read from `camera`, but live in `general`** (5/5 real files) → wrong clip planes/FOV; `zoom` unmodeled. | `WPESceneDocumentParser.swift:467-469` | B (corpus) |
| **P1-3** | H | **`g_Frametime` never provided** → frametime-integrated motion freezes (zero default). | (absent) | H |
| **P1-4** | H | **Audio spectrum normalized (doc: NOT normalized) + mono (L==R).** Over-compressed, no transients, no stereo. | `WPESoundRuntime.swift:205`, `WPEMetalRuntimeUniforms.swift:62-67` | H |
| **P1-5** | A/codex | **Animated-atlas (TEXS) fidelity:** affine frame terms (`widthY/heightX`) dropped; **eager** path uploads full atlas without cropping the sub-rect; **mipmaps discarded** (`mipmapped:false`). | `WPETexDecoder.swift:321`, `WPEMetalTextureLoader.swift:80,171`, `WPETexAnimatedTextureSource.swift:72` | codex + A |
| **P1-6** | A | **R8/RG88 ignore `AlphaChannelPriority` flag (524288)** → alpha-mask textures stored as R8/RG88 render opaque/wrong. | `WPETexPixelDecoder.swift:28-87` | A |
| **P1-7** | G | **`sizechange` & `colorchange` particle operators not implemented** (docs call them "essential") → grow/shrink/color-shift particles wrong. | `WPEParticleDefinition.swift:389-420` | G |
| **P1-8** | G | **`starttime` semantics inverted** — treated as spawn delay; WPE = pre-simulate to avoid empty screen. | `WPEParticleDefinition.swift:273`, `WPEParticleSystem.swift:397` | G |
| **P1-9** | I | **Scene time doesn't pause when occluded** (wall-clock `CACurrentMediaTime−loadTime`) → on resume `g_Time` jumps, particles burst. | `WPEMetalRuntimeUniforms.swift:99` | I |
| **P1-10** | I/codex | **Layer composite order not depth-sorted** — composites in document/array order with no z/parallax sort; wrong back-to-front if not authored in order. *Verify against real multi-layer scene.* | `WPEMetalRenderExecutor.swift:143`, `WPERenderGraphBuilder.swift:44-86` | I + codex |
| **P1-11** | D | **Blend-mode fidelity:** `multiply` is fixed-function (ignores src alpha → black fringes); `screen` defined but **unimplemented → silently Normal**; per-pass blend "hoisting" heuristic can mis-composite multi-pass layers. | `WPEMetalPipelineCache.swift:107-128`, `WPERenderGraphBuilder.swift:553-565` | D |
| **P1-12** | E | **`usershadervalues` unhandled** → user color-scheme → uniform bindings dropped; materials render with defaults instead of user-selected colors. | (not parsed anywhere) | E (corpus: `eagle.json`) |

---

## 3. P2 — Minor / edge / fidelity

- **F:** `CAST4X4` undefined (→ compile fail if used); `ddx/ddy`→`dFdx/dFdy` (not MSL — should be `dfdx/dfdy`); `texSampleNorm2D` loses normal-map decompression; `main()` detection is raw substring search; `gl_FragCoord` detected but no usable alias. (`WPEShaderTranspiler.swift`, `WPEShaderPreprocessor.swift`)
- **G:** random-initializer `exponent` bias ignored; `directions` reduced to binary axis mask (should be scalar magnitudes); `oscillate*` operators absent; sprite-sheet `×2` magic factor + unused `baseFrameRate`; `normal` particle blend overwrites (`.one/.zero`) instead of alpha-blends. (`WPEParticleSystem.swift`, `WPEParticleDefinition.swift`)
- **H:** `g_Screen`, `g_TexelSize`, `g_PointerPositionLast` engine constants not provided; `g_TextureNResolution` xy/zw intent inverted (harmless while textures aren't POT-padded). (`WPEMetalRuntimeUniforms.swift`)
- **B:** `general.ambientcolor`/`skylightcolor`/`clearenabled` unread; image `color` doesn't unwrap `{user,value}` envelope (tints lost); `locktransforms` ignored. (`WPESceneDocumentParser.swift`)
- **D:** FBO `unique` flag parsed but never honored (pool aliasing risk). (`WPEMetalRenderTargetPool.swift`)
- **E:** combo-level `require` ignored (defaults always emitted — low impact while defaults are 0). (`WPERenderPipelineBuilder.swift:650-658`)
- **A:** formats RGB888/565/RG1616f/R16f/RGBA/RGB16f absent from enum → clean rejection (HDR-float & 565 scenes fail rather than decode); MDL mesh-flag bits & MDLS skeleton layout unverifiable (no `.mdl` in corpus) and **puppet skinning/animation is static-only** (codex). 

---

## 4. Per-stage checklist (condensed)

> Full tables (every doc-point with ✅/❌/⚠️/➖ verdict) are in the agent transcripts. Below: confirmed-correct highlights + deviation pointers.

**A — Decode** ✅ TEXV/TEXI/TEXB v1-4 dispatch, 7-field header order, format enum codes (incl. BC7/RGBA1010102), LZ4 block decode, FreeImage/PNG payload bridge, BC1-3/7→MTLPixelFormat + block sizes, `expectedByteCount` (byte-count validated vs real R8 & DXT5), PKGV parse (hardened), MDLV header. ❌/⚠️ P0-4, P1-5, P1-6, P2 (formats, MDL).

**B — Scene parse** ✅ camera/general/objects required-throw, clearcolor/orthogonalprojection, object kind inference (matches corpus exactly), origin/angles/scale, alpha (animated + envelope), effects[]/passes/animationlayers/dependencies, particle/text/sound shapes. ❌ P0-3, P1-2, P1-12-adjacent, P2 (ambient/clearenabled/envelope/locktransforms).

**C — Coordinates** ✅ ortho matrix Y-flip for *custom shaders*, origin top-left/Y-down premise, scale→quad size, negative-scale UV mirror, texcoord top-origin, FBO↔FBO double-flip cancels, pointer-Y `1−y`, particle emitter single-flip. ❌ P0-1, P0-2.

**D — Render graph** ✅ effect/material pass order, ping-pong A/B with read-from-destination hazard guard, `previous`/`_rt_*` scene-alias resolution + snapshot, FBO scale-divisor + format, bind[] override, copy/compose commands, additive/translucent/disabled blend. ❌ P1-11, P2 (unique).

**E — Materials/combos** ✅ textures[] index→g_TextureN, slot-0=source, combos→#define (+uppercase alias), constantshadervalues→uniform defaults w/ material-name remap, sampler default textures, sampler-combo-on-bind, vec/float/int/bool parse, cullmode. ❌ P0-5, P1-12, P2 (combo require).

**F — Shader transpile** ✅ vec/mat type map, mix/lerp/frac/atan2/mod/fmod/mul, CAST2/3/4 + CAST3X3, texSample2D, `#if/#elif/#else/defined()` nesting, gl_FragColor/out_FragColor unification, **g_TextureN→texN slot fix + 0-3 guard (this session's fix — verified correct)**. ❌ P0-6, P0-7, P1-1, P2 (CAST4X4/ddx/normSample/main/fragcoord). Builtins resolved upstream in `WPERenderPipelineBuilder` prelude/includes (common.h, ApplyBlending).

**G — Particles** ✅ rate/maxcount, sphere dispersal, gravity+drag euler, angular motion, alphafade envelope, velocity/size/color/rotation/turbulentvelocity randoms (+Y-flip), spritesheet cols/rows/sequence + frame blend, pixel→NDC projection + size mapping, additive/translucent blend. ❌ P1-7, P1-8, P2 (exponent/directions/oscillate/seqmult/normal-blend).

**H — Runtime uniforms** ✅ `g_Time` (seconds), `g_Daytime`, audio array sizes/order + MSL scalar-array packing round-trip, per-slot `g_TextureNResolution` populated, render-size plumbing, `g_Color` sRGB→linear. ❌ P0-2 (g_ParallaxPosition), P1-3, P1-4, P2 (g_Screen/TexelSize/PointerLast/resolution-xy-zw).

**I — Render loop** ✅ per-frame macro order (clear→layers→effects→particles→text→present), single command buffer + ping-pong guards, depth attach only when needed + compare-fn map, suspend/occlusion stops GPU, throttle 1fps, snapshot readback (`.shared`+wait), static vs continuous, present clear+copy, alpha/brightness/blend honored. ❌ P1-9, P1-10, P2 (image-layer visibility not gated). **Perf (not correctness, prior review):** per-frame output-texture alloc + triple `waitUntilCompleted`.

---

## 5. Real-corpus verification log (`~/Documents/Live Wallpapers/431960`)

- Scenes are packed in `scene.pkg` (PKGV0014–0023); agents unpacked them. **0 raw `scene.json`/`.tex` on disk** — all packed.
- Object census (5 scenes): 35 image · 12 particle · 7 text · 7 sound · **0 model/light**.
- `.tex` headers confirmed real: `TEXV0005` / `TEXI0001` / `TEXB0003-4` / `TEXS0003`; byte-counts validate R8 (W×H) and DXT5/BC3 (blocks×16).
- **Corpus-confirmed defects:** `colorBlendMode` present (not `blendmode`); `fov/nearz/farz/zoom` in `general`; `parallaxDepth` is `"x y"`; `ambientcolor`/`skylightcolor`/`clearenabled` present-but-unread; `generic.frag` uses `requireany`.
- **Not testable here:** model/puppet (`.mdl`) decode + skinning (0 models in corpus); live rendering (needs the app's corpus harness — recommended next).

---

## 6. Recommended remediation order (separate, test-first rounds)

Per "report-first": no fixes applied yet. Suggested sequencing by impact × confidence (each round = corpus golden-probe before/after, like the sampler-slot fix):

1. **Coordinates round (P0-1 + P0-2):** make one matrix path authoritative for object/particle/text/parallax; fix `parallaxDepth` vec2 parse; provide `g_ParallaxPosition`. Highest visual impact. Golden probes: off-center object at y=0 / y=H, rotated anchor, parallax sweep.
2. **Parse round (P0-3 + P1-2):** read `colorBlendMode` (int→enum), move `fov/nearz/farz/zoom` to `general`. Low-risk, corpus-verified.
3. **Shader-safety round (P0-6 + P0-7 + P1-1):** translate `textureLod`; **fail-closed** on unsupported `#if`/vertex-varying/slot≥4 instead of silently-wrong (route to WebGL fallback). 
4. **Color round (P0-4):** linear upload + in-shader gamma; verify no regression on already-correct scenes.
5. **Material round (P0-5 + P1-12):** `requireany` OR; `usershadervalues` binding.
6. **Particle round (P1-7/8) + uniforms (P1-3/4) + loop (P1-9/10) + blend (P1-11).**
7. **P2 sweep** as cleanup.

Each is independently shippable and corpus-verifiable; none should be applied blind.

---

## Sources
- Official: docs.wallpaperengine.io/en/scene/{shader/{overview,variables,syntax,headers},particles/component/*,effects/effect/blend,parallax/introduction,scenescript/reference/class/ILayer,assets/overview}
- Community: wallpaper-engine.fandom.com (Shader_Textures, Shader_engine_constants); Steam guide id=770802221; linux-wallpaperengine (TextureParser.cpp / Texture.h / CTexture.cpp); RePKG.
- Real corpus: `~/Documents/Live Wallpapers/431960` scene.pkg extractions.
- Audit agents: 9 per-stage (Claude) + codex backend cross-check (session `019e7251-42d5-7a60-960d-0bcb3950c6de`).
