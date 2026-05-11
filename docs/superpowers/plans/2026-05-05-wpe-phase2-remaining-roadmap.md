# WPE Phase 2 Remaining Roadmap

> **Status:** Planning, supersedes the 6-bullet "Phase 2/3 Roadmap" stub at the end of `2026-05-04-wpe-compatibility-core.md`.
>
> Each sub-phase below is the entry point for its own executable plan (one plan = one PR-sized vertical slice).

---

## Context

Phase 2A (`2026-05-05-wpe-metal-renderer-boundary.md`) shipped:

- `WPESceneRenderer` protocol + type-erased `SceneWallpaperSession`.
- BC1/2/3/7 native Metal mapping when `MTLDevice.supportsBCTextureCompression` is true.
- Raw `.tex` payload extraction (no forced CGImage round-trip).
- Built-in `solidcolor` / `genericimage*` / `commands/copy` executor for `target=.scene` only.
- Opt-in `.metalExperimental` backend behind `AmbientWallpaperSessionBuilder.rendererBackend`.

The original Phase 2/3 roadmap collapsed everything else into 6 one-line bullets. That was honest about scope but produced no actionable plans. This document fixes that.

---

## Goal Alignment

**Target:** full WPE scene replication on macOS — every Workshop scene that runs on Wallpaper Engine for Windows produces visually equivalent output here, with the SpriteKit path retired as fallback.

**Phase 2A delivered ~15-20%** of the Metal-side work (renderer skeleton + trivial built-ins). The remaining 80% is decomposed below.

---

## Phase 2A Holdovers (Pre-2B Cleanup)

These are bugs in the just-shipped Phase 2A code, not new sub-phases. They block any honest verification of 2B+ work and should land as small follow-up commits before opening Phase 2B.

### H1 — `WPEMetalSceneRenderer.loadDiagnostics` is permanently nil

`loadDiagnostics` is declared `private(set) var ... = nil` and never assigned in any code path. `WPESceneDetailView` reads it via `session.sceneRenderer?.loadDiagnostics?.errorDescription`; the experimental backend will silently report "All declared layers decoded cleanly" even when `WPEMetalRenderExecutor` threw `unsupportedShader` or `missingTexture`.

**Fix:** wrap `executor.render(...)` in a do/catch, build a `SceneLoadDiagnostic` from the typed error (mirroring `SceneRenderingController` lines 200-260), assign before rethrowing.

### H2 — `dependencyMounts` is silently dropped

`WPEMetalSceneRenderer.init(...)` accepts `dependencyMounts: [WPEAssetMount]` then `_ = dependencyMounts` discards it. SpriteKit path forwards mounts to `SceneResourceResolver`. Cross-package WPE scenes (Workshop dependencies) will look up paths that exist only under sibling roots and fail with `cacheRootMissing`.

**Fix:** persist `dependencyMounts` and pass into `SceneResourceResolver(cacheRootURL:dependencyMounts:)` exactly like `SceneRenderingController` does. Phase 1 already wired the resolver to honor mounts; this is a one-line plumbing fix.

### H3 — sRGB / color management divergence

`WPEMetalRenderExecutor.makeOutputTexture` uses `.rgba8Unorm` (linear). `WPEMetalTextureLoader.makeTexture(from cgImage:)` sets `MTKTextureLoader.Option.SRGB: false`. SpriteKit path renders through CG which applies sRGB-aware blending. The two backends will disagree on gamma for the same scene fixture.

**Fix:** decide once and document:
- **Option A (recommended):** swapchain `.rgba8Unorm_srgb`, output texture `.rgba8Unorm_srgb`, BC textures map to `bc1_rgba_srgb` / `bc7_rgbaUnorm_srgb`. Add an offscreen 50%-gray fixture test asserting backend parity.
- **Option B:** keep linear, document divergence, ship a `linearOutput` flag.

H1-H3 ship as one PR (~80 LOC + 60 test LOC).

---

## Phase 2B — Scene Runtime Hardening

**Goal:** bring Metal renderer to feature-parity with SpriteKit on everything that does NOT require custom shader compilation. Unblocks 2C-2I.

**In scope:**

- Per-frame clock uniforms wired through executor: `g_Time` (CACurrentMediaTime relative to load), `g_Daytime` (0..1 from system clock), `g_Brightness` (from `WallpaperPerformanceProfile`), `g_PointerPosition` (NSEvent global mouse, normalized to scene UV).
- Camera: orthographic projection matrix from `general.orthogonalprojection`, `mouse_position` parallax wiring (object `parallaxDepth` field already in WPE schema).
- Off-main texture upload: `WPEMetalTextureLoader.makeTexture(from: payload)` runs `texture.replace(...)` on the calling actor — move to a dedicated upload queue with semaphore so a 4K BC mip chain doesn't stall main-thread on a 6-display setup.
- Metal preview snapshot: read back the offscreen output texture into `NSImage` so `WPESceneDetailView` shows a thumbnail instead of `.previewUnavailable`. Reuse the readback pattern already in `WPEMetalRenderExecutorTests`.
- Diagnostics parity: extend H1 fix to surface texture/mount/parser failures with the same `SceneLoadDiagnostic` taxonomy SpriteKit uses.

**Out of scope:** custom GLSL shaders, FBOs, particles, audio, web.

**Depends on:** H1, H2, H3 landed.

**Acceptance fixtures:**

- Static `solidcolor` scene rendered offscreen at simulated `t=0` and `t=1.0` produces same pixels (clock plumbed but unused by built-ins — proves wiring without behavioral risk).
- `genericimage*` scene with a dummy `parallaxDepth=0.1` shifts UV by ≤1px under a 100px synthetic mouse delta.
- Multi-display synthetic 2× window setup renders at ≥55 FPS sustained on M1 with no main-thread frame drops > 16ms (Instruments trace asserted via XCUI).
- `WPESceneDetailView` shows a non-blank thumbnail for the experimental backend.

**Estimated size:** ~600 LOC + 250 test LOC.

---

## Phase 2C — Multi-Pass Render Graph Executor

**Goal:** execute the FBO/effect pipeline real WPE scenes depend on.

**In scope:**

- Pass `target` ∈ `{scene, fbo:<name>, previous}` routing in `WPEMetalRenderExecutor.encode(...)`.
- FBO allocation/recycling pool backed by `MTLHeap`, sized from `WPERenderGraph` declared FBO list. Reuse across frames; release on `applyPerformanceProfile(.suspended)`.
- Blend states from WPE blending strings: `normal`, `additive`, `multiply`, `translucent`, `normalmapped`, `disabled`. Map to `MTLRenderPipelineColorAttachmentDescriptor` blend factors. Cull mode + depth test similarly mapped.
- Source resolution: `previous`, `image:<path>`, `asset:<path>`, `fbo:<name>` — already enumerated by `WPETextureReference`; current executor throws `missingTexture` for `previous` and `fbo`. This phase makes those two work.
- Built-in base passes from `materials/util/`: `solidlayer`, `copy`, `compose`. Add as MSL functions in `WPEMetalBuiltins.metal`.

**Out of scope:** custom GLSL shaders (Phase 2D), particles (2F), audio (2G).

**Depends on:** Phase 2B.

**Acceptance fixtures:**

- Two-pass scene `solidcolor → composite-with-tint` outputs the tinted color (offscreen pixel test).
- FBO ping-pong: 3-pass scene with two FBOs and a `previous` blend produces a documented checkerboard fixture.
- Blend-mode coverage: 6 fixtures, one per blend string, golden-pixel match ±2 LSB.

**Estimated size:** ~800 LOC + 400 test LOC.

---

## Phase 2D — GLSL → MSL Shader Translator

**The keystone.** Without this, real Workshop content never leaves the SpriteKit fallback. Largest single sub-phase.

**Pre-decision required (before plan-write):**

- **Option A:** vendor `glslang` + `SPIRV-Cross` as Swift package source. Industry standard, correct on first try, but adds ~3MB binary footprint and a C++ build dependency.
- **Option B:** hand-rolled GLSL ES → MSL transpiler covering the WPE-specific subset (no tessellation, no compute, no UBO arrays). Smaller, faster to build, but every WPE shader edge case becomes our problem.

**Recommendation:** A unless the App Store binary-size budget rules it out. Decision is the first task of the Phase 2D plan.

**In scope:**

- WPE GLSL dialect recognition (HLSL-flavored ANGLE GLSL ES with WPE macros).
- `texSample2D` / `COMPOSITE` macro expansion before translation.
- Sampler state lifting from `samplerstate` declarations to MSL `constexpr sampler`.
- Preprocessor combos driven by `WPEPreparedRenderPipeline.comboValues` — emit one MSL function per combo hash, cached on disk in `Application Support/.../wpe-shader-cache/`.
- Built-in uniform binding table: `g_Time`, `g_Texture0..7`, `g_Texture0Resolution`, `g_TexelSize`, `g_TexelSizeHalf`, `g_DepthFromColor`, `g_PointerPosition`, `g_ModelMatrix`, `g_ModelViewProjectionMatrix`, `g_ViewProjectionMatrix`, `g_Brightness`, `g_Color`, `g_Alpha`. Bound by index, not name.
- Output: cached per-(shader, combo-hash) `MTLLibrary` blob.
- Fail-closed diagnostics: emit `WPEShaderTranslationError(.unsupportedMacro / .unsupportedBuiltin / .unsupportedExtension)` with the exact line so the layer falls back to placeholder, not a black frame.

**Out of scope:** tessellation, geometry shaders, compute (WPE doesn't use them), MSL 3.0+ features.

**Depends on:** Phase 2B (uniform table), Phase 2C (real pass routing for fixtures).

**Acceptance fixtures:**

- Translate WPE's `composite.frag` (the most common combo template) and run a 1×1 golden-pixel test.
- 5 hand-picked Workshop scenes from a curated compatibility list pass with output matching a reference image (±2 LSB).
- Translator throws `unsupportedBuiltin` (not silent black) when a scene uses `g_AudioSpectrum` before Phase 2G lands.

**Estimated size:** ~1500 LOC translator + 500 LOC harness + 800 LOC tests.

---

## Phase 2E — Animated and Video TEX

**Goal:** support multi-frame `.tex` containers and embedded MP4. Was hidden in original roadmap item 3 with no scope.

**In scope:**

- Animated `.tex`: multi-frame sprite sheet metadata (`frameCount`, `framerate`) read by `WPETexDecoder`, exposed via `WPETexTexturePayload.animationFrames`. Per-frame UV offset driven by `g_Time`.
- Video-in-`.tex` (MP4 inside container, the case `WPETexDecoder.parse` already detects via `unsupportedAnimation`): swap to `AVAssetReader` + `CVMetalTextureCache` so frames upload directly to GPU.
- Throttling integration with `WallpaperPerformanceProfile.suspended` (pause readers, release decompression sessions).

**Out of scope:** alpha video / HAP / ProRes (out of WPE Workshop content range).

**Depends on:** Phase 2B (clock).

**Acceptance fixtures:**

- 4-frame animated TEX rendered at 25 FPS, frame index increments once per 40ms ±2ms (clock-driven).
- 30-second 1080p MP4 TEX renders at ≥55 FPS sustained on M1 with no main-thread drops.
- `applyPerformanceProfile(.suspended)` releases `AVAssetReader` within one frame.

**Estimated size:** ~400 LOC + 200 test LOC.

---

## Phase 2F — Particle System

Largest behavioral subsystem WPE exposes. WPE Workshop has many particle-only scenes.

**In scope:**

- Emitter shapes: `point`, `sphere`, `box`, `mesh`.
- Initializers: `position`, `velocity`, `lifetime`, `color`, `size` distributions (constant / range / curve).
- Operators: `damping`, `vortex`, `turbulence`, `colorOverLife`, `sizeOverLife`, `alphaFadeInOut`, `rotation`, `attractor`.
- Renderers: billboard quad (camera-aligned), ribbon (segmented mesh), mesh (instanced static mesh).
- Control points: ID lookup parameterized by named binding (`g_ControlPoint0..9`).
- CPU simulation tick — WPE particles are CPU-driven on Windows; GPU-compute simulation is Phase 3 nice-to-have.

**Depends on:** Phase 2B, 2C, 2D (particle shaders are custom GLSL).

**Acceptance fixtures:**

- Single emitter, 1000 particles, deterministic seeded simulation: pixel-frame at `t=2.0` matches golden image.
- 5000-particle emitter sustains 60 FPS on M1.
- All 8 operators pass deterministic-trajectory tests with documented seed.

**Estimated size:** ~1200 LOC + 500 test LOC.

---

## Phase 2G — Audio Uniforms / Sound Objects

Smaller, decoupled from rendering pipeline.

**In scope:**

- AVAudioEngine system-output tap (or input device fallback) → 1024-sample window → 64-bin FFT → `g_AudioSpectrum` uniform.
- WPE `sound` objects: `AVAudioPlayer` attached to scene lifecycle, gain from `volume` field, looping from `loop` field.
- Reduce-motion / `.suspended` integration: stop tap, zero spectrum, pause sound objects.

**Out of scope:** external app audio routing (BlackHole or similar) — defer to Phase 3 with documented limitation in `WPESceneDetailView`.

**Depends on:** Phase 2B (uniform table).

**Acceptance fixtures:**

- 1kHz sine input populates spectrum bin 22 above threshold, others near zero (±2 LSB).
- `volume:0.5` sound object plays at -6dB compared to `volume:1.0` reference recording.
- `applyPerformanceProfile(.suspended)` zeros spectrum within one frame.

**Estimated size:** ~500 LOC + 200 test LOC.

---

## Phase 2H — Object Kinds: Model / Light / Text / Puppet Warp

Each is small individually; bundling them lets one renderer-feature plan ship them together. Splits into two PRs.

### Phase 2H-static (model + light + text)

- `model` objects: load WPE binary mesh format (`*.mdl`), transform via `g_ModelMatrix`, material binding through standard pass executor.
- `light` objects: directional/point/spot uniforms (`g_LightAmbientColor`, `g_LightDirectionWS0`, etc).
- `text` objects: TextKit2 → `MTLTexture` path, transform binding identical to `model`.

### Phase 2H-puppet

- Puppet warp: bone-driven mesh deform compute pass (or vertex-shader fallback when compute unavailable on older GPU).

**Depends on:** Phase 2C, 2D.

**Acceptance fixtures:**

- Quad model with checkerboard texture renders identically to `genericimage` path (reference parity).
- Single directional light + lit material produces correct half-Lambert shading versus reference image.
- Puppet warp on a 16×16 grid mesh deforms by exactly the bone displacement (analytic comparison).

**Estimated size:** 2H-static ~600 LOC + 200 test LOC; 2H-puppet ~400 LOC + 200 test LOC.

---

## Phase 2I — Web Compatibility (HTML / WPE JS API)

Entirely independent of Metal track. Can run in parallel with any of 2C-2H.

**In scope:**

- WKWebView fast path for static HTML wallpapers (already partially shipped in current SpriteKit-era code).
- WPE JS API shim: `window.wallpaperRegisterAudioListener`, `window.wallpaperPropertyListener`, `window.wallpaperRegisterMediaPropertiesListener` — minimal subset that maps to native runtime values.
- Property panels: parse WPE `project.json` `properties` block, render in `WPESceneDetailView` (slider/color/toggle/combo).

**Out of scope:** full CEF parity (Chromium-only `chrome.*` APIs), pre-render fallback for animation-heavy HTML scenes.

**Depends on:** nothing in 2A-2H. (Audio listener fixture below depends on 2G if exercised.)

**Acceptance fixtures:**

- Sample HTML wallpaper using `wallpaperPropertyListener({slider1: 0.5})` reflects the slider in `WPESceneDetailView`.
- Audio listener receives non-zero spectrum when 2G's tap is active.
- WKWebView wallpaper survives `applyPerformanceProfile(.suspended)` round-trip without leaking the WebContent process.

**Estimated size:** ~400 LOC native + ~300 LOC injected JS + 300 LOC tests.

---

## Phase 2J — Default Backend Switch (Production Cutover)

**Pre-conditions** (all must be true before opening this plan):

- 2B-2H acceptance fixtures green on M1 + Intel.
- Workshop top-100 compatibility manual sweep ≥ 95% visual match against Windows reference.
- Cumulative CPU < SpriteKit baseline on M1 at 60 FPS for the 100-scene sample.
- Crash-free over 24h soak test on at least one developer machine.

**Cutover work:** ~50 LOC change in `AmbientWallpaperSessionBuilder` (default = `.metal`, rename `.metalExperimental` → `.metal`), plus a kill-switch in settings for `useLegacySpriteKitScene`. SpriteKit path stays for one release cycle as fallback.

---

## Dependency Graph

```
            ┌────────────────────────────────────┐
            │  H1 H2 H3  (Phase 2A holdovers)    │
            └────────────────┬───────────────────┘
                             ↓
    ┌────────────────────  Phase 2B  ─────────────────────┐
    │  (clock, camera, sRGB, off-main, snapshot, diag)    │
    └────┬─────────┬─────────┬─────────────┬──────────────┘
         ↓         ↓         ↓             ↓
     Phase 2C   Phase 2E  Phase 2G    Phase 2I  (parallel)
     (multi-   (animated  (audio       (web
      pass)     /video)    uniforms)    compat)
         │         │         │
         ↓         │         │
     Phase 2D ◄────┘         │
     (GLSL→MSL translator)   │
         │                   │
         ↓                   ↓
     Phase 2F ◄──── (uses 2D shaders)
     (particles)
         │
         ↓
     Phase 2H (model/light/text  +  puppet warp)
         │
         ↓
     Phase 2J (default backend switch)
```

---

## Gap Closure vs Original 6-Bullet Roadmap

| Original bullet | Resolution |
|---|---|
| 1. Metal renderer boundary | Phase 2A shipped (modulo H1-H3) |
| 2. Render graph executor | Now Phase 2C with FBO/blend/source-resolution specifics |
| 3. Texture loader | BC mapping shipped in 2A. Animated/video carved out as Phase 2E |
| 4. Shader translator | Now Phase 2D with explicit GLSL dialect + Option A/B pre-decision |
| 5. Dynamic features (audio/particle/text/light/model/puppet) | Split: Phase 2F (particles), 2G (audio), 2H-static (model/light/text), 2H-puppet |
| 6. Web | Now Phase 2I, decoupled from Metal track |

**Items the original roadmap missed entirely:**

- Phase 2A holdovers (H1 diagnostics / H2 dependency mounts / H3 sRGB).
- Phase 2B scene runtime (clock / camera / off-main upload / preview snapshot).
- Phase 2J default-backend switch — the original assumed it's a flag flip; spec'd here as gated by acceptance fixtures + soak.

**Items intentionally NOT in any Phase 2 sub-plan** (deferred to Phase 3):

- ShaderToy import (`docs/roadmap.md` Phase 3).
- iCloud sync, App Store submission (`docs/roadmap.md` Phase 3).
- App-audio routing via BlackHole / loopback drivers.
- GPU-compute particle simulation.
- CEF / Chromium-only web APIs.

---

## Self-Review

- Each sub-phase has a single goal, in/out scope boundaries, dependencies, and acceptance fixtures with documented golden values.
- No bullet relies on "and various other things" — specific WPE field names and uniform names are quoted.
- The single largest risk (Phase 2D shader translator) carries an explicit Option A/B pre-decision rather than hand-waving.
- Phase 2J is gated, not implicit.
- Phase 2A holdovers (H1-H3) are filed against shipped code, not as new sub-phases — no scope creep.
- Sequencing reflects real blocking dependencies; 2I (web) and 2G (audio) are correctly identified as parallelizable.
