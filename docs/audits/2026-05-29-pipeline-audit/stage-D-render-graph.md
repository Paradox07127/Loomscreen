# Stage D — Render Graph / Effect Compositing / FBO / Blend Modes

## Checklist (abridged)

| rule | impl (file:line) | verdict | note |
|---|---|---|---|
| Effects applied in document order; passes appended sequentially | WPERenderGraphBuilder:116-158 | ✅ | material passes first, then effects |
| Untargeted pass reads previous, writes intermediate (ping-pong A/B) | WPERenderGraphBuilder:197-222 | ✅ | source=.fbo(next); composite flips A↔B |
| `"previous"` → prior write of current target | WPEMetalShaderInputs:61-65; WPEMetalFrameState:54-72 | ✅ | latestTexture(for: currentTargetID) |
| read-from-destination avoided (true ping-pong) | WPEMetalRenderTargetPool:87-125; WPEMetalRenderExecutor:493-534 | ✅ | secondary alloc + blit seed |
| `_rt_FullFrameBuffer`/`_rt_imageLayerComposite` alias live scene | WPEMetalShaderInputs:44-46,98-110 | ✅ | snapshot before aliasing pass |
| cross-layer composite refs force dependency build | WPERenderGraphBuilder:59-83,27-52 | ✅ | referencedLayerIDs pulls deps |
| effect-declared FBOs (name/scale/format/unique) | WPERenderGraphBuilder:393-405; WPEMetalRenderTargetPool:127-166,262-271 | ⚠️ | `unique` parsed but never consumed (D3) |
| FBO scale = downsample divisor | WPEMetalRenderTargetPool:6-10 | ✅ | base/divisor |
| FBO format → MTLPixelFormat | :262-271 | ✅ | rgba8888/16f/r8 |
| command `copy` (source=previous default) | builder:137-156; dispatcher:83-118 | ✅ | |
| command `compose` (2-input) | dispatcher:120-166 | ✅ | scene-capture region variant handled |
| `bind[]` override pass textures | builder:407-424; dispatcher:95,121-122,736-741 | ✅ | binds > textures priority |
| pass `target` honored; only untargeted ping-pong | builder:197,217-222 | ✅ | |
| final layer pass → scene w/ layer blend | builder:499-534,553-565 | ⚠️ | blend-mode hoisting heuristic (D2) |
| `additive` blend | WPEMetalPipelineCache:98-105 | ✅ | src=srcAlpha,dst=one |
| `translucent`/`normal` | :116-127 | ✅ | src=srcAlpha,dst=1-srcAlpha |
| `disabled` | :95-96 | ✅ | opaque overwrite |
| `multiply` | :107-114 | ⚠️ | fixed-function src=dstColor,dst=zero → ignores src alpha (D1) |
| `screen` + other PS modes | :90-128; WPESceneDocument:534-549 | ❌ | `.screen` defined but no case → silently translucent (D4) |
| WPE in-shader ApplyBlending modes | — | ➖ | Blend effect high-level modes not modeled |

## Deviations

- **D1 (⚠️ Med) — `multiply` fixed-function, not WPE in-shader Blend.** `WPEMetalPipelineCache:107-114` `src=dstColor,dst=zero` → no alpha weighting → black fringes on alpha-masked multiply sprites. WPE multiply = `ApplyBlending(BLENDMODE,...)` in shader, alpha-aware + intensity-controlled.
- **D2 (⚠️ Med) — `movingFirstBlendModeToFinalPass` hoisting is non-WPE.** `WPERenderGraphBuilder:553-565` rewrites pass[0] blend to "normal" and stamps its original blend on the last pass. Fragile for multi-pass materials where an interior pass needs additive/multiply against its intermediate FBO. Model the layer composite blend explicitly instead.
- **D3 (⚠️ Low) — FBO `unique` flag dead.** Parsed (`WPERenderGraph:124,130`) but pool keys on name+size+format only → two `unique` FBOs of identical dims would alias. Rare.
- **D4 (❌ Low impact) — `screen` (+ other PS modes) silently → translucent.** `WPESceneDocument:539,546` define `.screen`; `applyBlendMode:90-128` has no case → default (translucent). Implement screen or at least diagnose unmapped modes.

**Strengths:** topology sound — ping-pong with read-from-destination hazard guard, `previous`/`_rt_*` resolution + snapshot, FBO scale/format, copy/compose, bind override all correct.

Sources: Steam guide id=770802221; docs shader/headers (ApplyBlending), effects/effect/blend; SteamDB 2.7 patchnotes (FBO `unique`).
