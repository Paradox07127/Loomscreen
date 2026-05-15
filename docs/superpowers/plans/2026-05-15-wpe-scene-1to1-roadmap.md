# WPE Scene 1:1 Native macOS Roadmap

**Worktree:** `.claude/worktrees/wpe-scene-1to1` on branch `worktree-wpe-scene-1to1`
**Goal:** Play any Wallpaper Engine `type:"scene"` wallpaper from the local `431960` corpus 1:1 on macOS via the existing native Metal renderer.
**Reference corpus:** `/Users/dev/Documents/Live Wallpapers/431960` — 33+ scene wallpapers (alongside videos and HTML).

---

## 1. Where the pipeline already is

The Phase 2 image-layer pipeline is mature. I verified it end-to-end. Data flow today:

```
scene.pkg  ──►  WallpaperEnginePackage          (pkg parse + LZ4 decompress)
   │             LiveWallpaper/Infrastructure/WallpaperEnginePackage.swift:25
   ▼
scene.json ──►  WPESceneDocumentParser           (camera/general/objects)
   │             LiveWallpaper/Infrastructure/WPESceneDocumentParser.swift
   ▼
WPESceneDocument
   │             LiveWallpaper/Models/WPESceneDocument.swift
   ▼
WPERenderGraphBuilder                            (resolves materials/effects/FBOs)
   │             LiveWallpaper/Infrastructure/WPERenderGraphBuilder.swift
   ▼
WPERenderPipelineBuilder                         (loads .vert/.frag, expands combos, includes)
   │             LiveWallpaper/Infrastructure/WPERenderPipelineBuilder.swift
   ▼
WPEPreparedRenderPipeline
   │             LiveWallpaper/Models/WPERenderPipeline.swift
   ▼
WPEMetalTextureLoader / WPETexDecoder            (.tex → MTLTexture, animated/video sources)
   │             LiveWallpaper/Infrastructure/WPEMetalTextureLoader.swift
   │             LiveWallpaper/Infrastructure/WPETexDecoder.swift
   ▼
WPEMetalRenderExecutor + WPEMetalShaderDispatcher
                 LiveWallpaper/Runtime/WPEMetalRenderExecutor.swift
                 LiveWallpaper/Runtime/WPEMetalShaderDispatcher.swift
   ▼
WPEMetalSceneRenderer  ──►  MTKView
                 LiveWallpaper/Runtime/WPEMetalSceneRenderer.swift
```

Working features today:
- Scene `.pkg` extraction (`PKGV0022`/`PKGV0023`).
- `.tex` decode incl. animated frames and embedded video (`WPEVideoTextureSource`).
- Scene parser: camera, general, image objects, materials, effects, animation-layer metadata, blend modes, alignment.
- Render graph: per-layer FBO ping-pong, effect-pass overrides, dependency mounting.
- Metal executor: sRGB-tagged targets, depth-state cache, pipeline-state cache, blend modes (`normal`, `translucent`, `additive`, `multiply`, `screen`), cull modes.
- Built-in shaders compiled into the app's Metal library: `solidcolor`, `solidlayer`, `copy`, `compose`, `colorbalance`, `blur`, `vignette`, `water`, `shake` — see `LiveWallpaper/VideoPlayback/WPEMetalBuiltins.metal`.
- Runtime uniforms: `g_Time`, `g_Daytime`, `g_Brightness`, `g_PointerPosition`, ortho camera matrices.
- 24 dedicated test files; in-progress refactor `phase C.2 step 6` extracts stateless shader inputs into `WPEMetalShaderInputs` (testability cleanup, not feature work).

## 2. The single blocker: custom GLSL passes throw `unsupportedShader`

`WPEMetalShaderDispatcher.dispatch(...)` is a hard-coded switch over the 9 built-in shader names (`LiveWallpaper/Runtime/WPEMetalShaderDispatcher.swift:20-261`). Anything else hits the `default:` arm at line 260 and throws `WPEMetalRenderExecutorError.unsupportedShader`. Because the corpus is dominated by:

| Shader name           | Uses (corpus) |
|-----------------------|---------------|
| `genericimage4`       | 562           |
| `genericparticle`     | 193           |
| `genericimage2`       | 103           |
| `blur_precise_gaussian`, `waterwaves`, `shake`, `opacity`, `foliagesway`, `scroll`, `pulse`, `lightshafts`, `simple_audio_bars`, `color_grading`, `spin`, `shine_gaussian` | many |

**~95% of scene packages will fail without a real GLSL→MSL pipeline.** The 5 hand-coded effects are pixel-approximations only — they can't replace `genericimage4` because that shader is the actual material vertex/fragment for almost every image layer.

That's the gating piece for "1:1 reproduction."

## 3. Existing plans vs reality

Two plans live under `docs/superpowers/plans/`:

- `2026-05-13-wpe-native-scene-playback.md` — small task: make Metal the default scene backend + accept unpacked scene folders. Likely done already (the repo defaults to Metal and the cache mirror logic is present).
- `2026-05-13-wpe-scene-full-runtime.md` — the **right** blueprint, 10 tasks. Tasks 1 + 2 show `[x]` but the deliverables (`WPECorpusScanner.swift`, `WPEScenePreflight.swift`, `WPECorpusCompatibilityTests.swift`) **do not exist on this branch** — `git log --all` shows no commit ever introduced them. The plan is aspirational. Also note the corpus path inside that plan is wrong for this machine (`/Users/tiramitree/...` vs actual `/Users/dev/Documents/...`).

This roadmap reuses that plan's structure but fixes the corpus path, marks the real status, and tightens the implementation strategy on the two hardest pieces (shader translator and particle runtime).

## 4. Recommended implementation order

Ordered by blast radius — each step unlocks a meaningful chunk of the corpus.

### Phase 1 — Truth-telling (Tasks 1-2 of existing plan, redo for real)

Build the corpus harness so every later phase is gated by measured coverage instead of "I think it works."

- **Create** `LiveWallpaper/Infrastructure/WPECorpusScanner.swift` using existing `WallpaperEnginePackage.parseIndex(streamingFrom:)` and `WallpaperEngineProject.read(from:)`. Counts: project types, object kinds, shader names, feature flags. Fix the corpus path constant.
- **Create** `LiveWallpaper/Infrastructure/WPEScenePreflight.swift` — classifies a scene into `nativePlayable | degradedPlayable | shaderTranslationRequired | runtimeSystemsRequired | unsupported` plus precise `WPESceneFeatureFlag` set.
- **Create** `LiveWallpaperTests/WPECorpusCompatibilityTests.swift` — opt-in via `WPE_CORPUS_ROOT=/Users/dev/Documents/Live Wallpapers/431960`; serves as the regression gate after every later phase.
- Wire preflight tier into `SceneDescriptor` (additive — keep `capabilityTier` until UI catches up).

**Acceptance:** The scanner prints a deterministic feature report identical to the corpus snapshot in the existing plan (46 scene pkgs, 2506 .json, 1305 .tex, 359 .vert/.frag, 1545/204/200/103 image/particle/text/sound counts).

### Phase 2 — GLSL → MSL shader translator (the unblocker)

This is the largest architectural task. Recommended shape:

**Vendoring strategy:** prefer **glslang + SPIRV-Cross** over DXC because WPE shaders are GLSL-flavored (`vec*`, `gl_FragColor`, `texture2D` / `texSample2D`), and SPIRV-Cross has battle-tested MSL emission used by Godot, RenderDoc, MoltenVK. Vendor as static archives built for `arm64`+`x86_64`; isolate under `ThirdParty/WPEShaderToolchain/`. Apple's open `metal-shaderconverter` (CLI) is *not* a runtime library, so it can't replace SPIRV-Cross for in-app translation.

**Pipeline:**

```
.vert/.frag (WPE GLSL flavor, with combo/include/metadata comments)
   ▼  WPEShaderPreprocessor (Swift) — combo expansion, #include resolution,
   │   `// [COMBO]`/`// [BIND]` parsing, WPE→GLSL fixups (texSample2D macros,
   │   gl_FragColor → out vec4 fragColor for #version 410)
   ▼
canonical GLSL 410 source
   ▼  glslang::TShader → SPIR-V binary
   ▼  spirv_cross::CompilerMSL → MSL source + reflection
   ▼  MTLDevice.makeLibrary(source:options:)  →  vertex + fragment MTLFunction
   ▼  MTLRenderPipelineState (cached by shader hash + combo hash)
```

**New files:**
- `LiveWallpaper/Runtime/WPEShaderCompiler.swift` — public `WPEShaderCompileRequest`/`WPEShaderCompileResult` API (signatures already drafted in plan #2 task 3).
- `LiveWallpaper/Runtime/WPEShaderTranslationCache.swift` — disk cache under `Application Support/.../wpe-msl-cache/` keyed by `(shaderName, sourceHash, combosHash, appVersion, OSVersion)`. Cache the **MSL source** plus the compiled `MTLLibrary` archive (use `MTLBinaryArchive` on macOS 12+).
- `ThirdParty/WPEShaderToolchain/README.md` — exact glslang + SPIRV-Cross commits, build script for fat archives, license inventory, signing/notarization notes.
- C/C++ wrapper bridging `glslang` and `SPIRV-Cross` to a flat C ABI; `module.modulemap` for Swift import.

**Reflection model:** SPIRV-Cross gives binding indices for textures, samplers, and uniform blocks. Translate them into `WPEPreparedRenderPass.textureBindings` / a new `uniformBufferLayout` so `WPEMetalShaderDispatcher` can route values without per-shader hand-coding. Promote the dispatcher's switch to a generic path: built-ins keep their fast lane; everything else uses the reflected layout.

**WPE → GLSL preprocessor specifics:** mine `linux-wallpaperengine`'s `src/WallpaperEngine/Render/Shaders/Compiler.cpp` and `Variables/CShaderVariablesFactory.cpp` (https://github.com/Almamu/linux-wallpaperengine) — they already handle `// [COMBO]`, `// [BIND]`, `texSample2D`/`texSampleNorm2D`/`texSampleLOD`, sampler aliases, and the `g_*` runtime uniform set. Port those tables — don't reinvent them.

**Executor changes** (`LiveWallpaper/Runtime/WPEMetalRenderExecutor.swift`):
- Add a generic `dispatchCustom(pass:)` that pulls the compiled `MTLRenderPipelineState`, sets reflected texture bindings, packs constants + runtime uniforms into a single MTL uniform buffer per pass.
- Wire sampler state from material flags (`addressing`, `filtering`) — currently nothing builds `MTLSamplerState`.
- Wire WPE vertex layouts: image quad + particle billboard need real vertex buffers, not just `gl_VertexID`-driven fullscreen triangles.

**Acceptance:** `genericimage4`, `genericimage2`, `opacity`, `scroll`, `pulse`, `color_grading`, `foliagesway`, `shake`, `spin`, `lightshafts`, `blur_precise_gaussian`, `waterwaves`, `shine_gaussian` all compile to `MTLLibrary`. Corpus gate: `report.sceneCompileResults.shaderCompileFailures <= 10`. Visual diff against `linux-wallpaperengine` golden frames on the smallest scenes.

### Phase 3 — Particle runtime (`genericparticle` lights up)

37/46 scenes use particles. After shader translation lands, the `genericparticle` shader will compile, but the renderer still needs a CPU emitter + a GPU draw path with proper instancing.

- **Create** `LiveWallpaper/Runtime/WPEParticleSystem.swift` — emitter / initializer / operator / renderer chain modeling. Reference: `linux-wallpaperengine/src/WallpaperEngine/Particles/*` — that DSL is already the closest thing to a spec.
- **Extend** `WPESceneDocumentParser` + `WPESceneDocument` with `particleObjects[]`, full operator decoding (velocity_decay, collision, lifetime, audio_response).
- **Extend** `WPEMetalRenderExecutor` with an instanced-quad draw path using `MTLBuffer` of `WPEParticleVertex { position, uv, color, lifetime }` and `drawIndexedPrimitives(..., instanceCount:)`.
- Defer audio-reactive operators to Phase 5 (sound runtime); use a constant zero spectrum in the meantime.

**Acceptance:** scenes with particle objects render the particles (visually approximate is fine if shader translation is correct); corpus gate threshold `<= 6` failures.

### Phase 4 — Text (200 instances) + sound (103 instances)

Both straightforward, gated by Apple frameworks:

- **`LiveWallpaper/Runtime/WPETextRenderer.swift`** — CoreText layout into a Metal texture per text object, then composite as a regular image layer. Use packaged `.ttf`/`.otf` (55 fonts in the corpus) via `CTFontManagerRegisterFontURLs`. Cache per `(fontHash, text, color, size, bounds)`.
- **`LiveWallpaper/Runtime/WPESoundRuntime.swift`** — `AVAudioEngine` per scene, one `AVAudioPlayerNode` per `sound` object. Honor app mute / audio-leader policy. Expose FFT spectrum via `installTap(onBus:bufferSize:format:)` → 64-bin float array → `g_AudioSpectrum` runtime uniform for audio-reactive shaders/particles.
- Diagnostic on decode failure must be non-blocking — visuals continue.

**Acceptance:** `WPETextRendererTests` produces non-empty raster; `WPESoundRuntimeTests` initializes nodes for the corpus's 31 sound-bearing scenes. Corpus gate threshold `<= 4`.

### Phase 5 — Animation layers / puppet warp (high stakes for 2955378002)

939 instances corpus-wide; 868 in scene `2955378002` alone. Two flavors:

1. **UV-frame animation** — array of UV/scale/rotation keyframes over time, no mesh deformation. Cheap; do this first.
2. **Mesh deformation** ("puppet warp") — control points + bone weights deform a mesh grid each frame. Expensive; only attempt after the simpler path proves insufficient on a test fixture.

- **Create** `LiveWallpaper/Runtime/WPEAnimationLayerRuntime.swift`.
- Bound the GPU buffer growth: pre-allocate per-layer `MTLBuffer` sized to peak control-point count, reuse per frame (no allocations in render loop). The plan calls this out explicitly — measure with Instruments after 300 frames on `2955378002`.

**Acceptance:** corpus gate threshold `<= 2`; `2955378002` first frame renders without OOM.

### Phase 6 — SceneScript + user properties

Tiny but visible. Use `JavaScriptCore` (already on macOS) in a sandboxed `JSContext`:

- **Create** `LiveWallpaper/Runtime/WPESceneScriptRuntime.swift`.
- Bridge surface: `engine.getPropertyValue/setPropertyValue`, `engine.getTimeOfDay()`, `scene.getImageLayer(name)` returning a thin proxy with `setVisible/setAlpha/setOrigin`.
- No file/network/process APIs — these must be unreachable from the JSContext.
- Drive the script tick **before** runtime uniforms get packed for that frame.
- Translate user-property values into shader constants per the `project.json` `general.properties` schema (color, slider, bool, combo) — already parsed, just needs a sink.

### Phase 7 — Final compatibility gate + UX

- Full corpus pass: import → preflight → graph → pipeline → shader compile → first-frame offscreen render across all 46 scenes.
- Target: `playable >= 40 / 46`; remaining failures must report a specific `WPESceneFeatureFlag`, not a generic error.
- Exact-reason UX in `WPESceneSection.swift` and gallery: surface the missing feature so users know whether the issue is a shader compile, a particle gap, an animation-layer gap, a Windows plugin, etc.
- `Localizable.xcstrings` updates for all new diagnostic strings.

## 5. Acceptance scenes — ordered easiest → hardest

Pick these as the regression suite (sizes from `stat`):

| Order | Workshop ID | Pkg size | Why |
|-------|-------------|----------|-----|
| 1 | `3287199039` | 1.4 MB | Smallest scene — earliest signal that the new path works at all. |
| 2 | `3526278753` | 5.1 MB | Second smallest. |
| 3 | `2740023533` | 14.4 MB | "Cogecha hair" — toggleable bool properties exercise user-property plumbing. |
| 4 | `3719111841` | 72 MB | Arknights Kal'tsit — referenced explicitly as a shader-variant stress case. |
| 5 | `3704273480` | medium | 58 effects + 8 animation layers — dense post-process. |
| 6 | `3596044309` | medium | Particles + text + unknown objects. |
| 7 | `3478434536` | medium | 42 effects + 21 text + 12 unknown objects. |
| 8 | `3326873240` | 247 MB | Very large; tests memory budget. |
| 9 | `2955378002` | 382 MB | **Final boss** — Persona 5 weather scene: 873 images, 1317 effects, 868 animation layers, 61 sounds. If this plays, the runtime is real. |

Each phase's "done" gate must include first-frame success on the next-deepest scene from this list.

## 6. Reference projects to mine

The biggest force multiplier is reusing reverse-engineered code instead of rediscovering the format.

| Project | URL | Use for |
|---------|-----|---------|
| **linux-wallpaperengine** | https://github.com/Almamu/linux-wallpaperengine | Authoritative reference. Mine for: shader preprocessor (combo/include/uniform tables), particle DSL execution, .tex decoder cross-check, scene-object shape-key inference, material pass executor (blending/depth state mapping). C++ → port to Swift. |
| **repkg / RePKG** | https://github.com/notscuffed/repkg | .pkg + .tex format reference. We already implement both, but useful as a tie-breaker for ambiguous bytes. |
| **wallpaper-engine-kde-plugin** | https://github.com/catsout/wallpaper-engine-kde-plugin | Vulkan reference renderer. Useful for scene script integration and property-binding shape. |
| **SPIRV-Cross** | https://github.com/KhronosGroup/SPIRV-Cross | The MSL emitter for Phase 2. |
| **glslang** | https://github.com/KhronosGroup/glslang | The GLSL→SPIR-V frontend for Phase 2. |
| **Official WPE docs** | https://docs.wallpaperengine.io/ | scene.json schema, particle operators, SceneScript API, shader combo system. |
| **TEX format spec** | https://github.com/Almamu/linux-wallpaperengine/blob/main/docs/textures/TEXTURE_FORMAT.md | .tex header + LZ4 + DXT layout (already implemented). |

## 7. Risks and how to defuse them

1. **Shader-translator scope creep.** WPE GLSL has many quirks (sampler aliases, default texture binding by name, magic uniforms). Defuse by: keeping a per-shader regression fixture from the corpus, and a "translated MSL snapshot" diff in tests so semantic regressions are loud.
2. **Vendoring fragility.** `glslang` + `SPIRV-Cross` are large C++ codebases. Defuse by: pinning to release tags, writing a one-shot `scripts/build_shader_toolchain.sh` that produces signed `.a` files for both architectures, and committing the prebuilt archives — not the source — into `ThirdParty/`.
3. **Notarization on shader libraries cached at runtime.** `MTLDevice.makeLibrary(source:)` runs the Metal compiler in-process; no external launch, so notarization is unaffected. Persisted `MTLBinaryArchive` files inherit the app's signature.
4. **Animation-layer memory blow-up.** `2955378002` has 868 animation layers in one scene. Defuse: pre-size per-layer GPU buffers from the descriptor at load time, never allocate inside `render()`.
5. **Audio + multi-display interaction.** Existing `audio-leader` policy must keep working — only one scene's `WPESoundRuntime` is allowed to play at a time, others muted. Defuse: route through the existing app-level audio leader, not per-renderer ad hoc.

## 8. Verification per phase

Every phase ships with the corpus test:

```bash
WPE_CORPUS_ROOT='/Users/dev/Documents/Live Wallpapers/431960' \
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper \
  -destination 'platform=macOS,arch=arm64,name=My Mac' \
  -parallel-testing-enabled NO \
  -only-testing:LiveWallpaperTests/WPECorpusCompatibilityTests
```

Plus phase-targeted unit tests. After Phase 7, the full suite plus a 60-second visual smoke test on the acceptance-scene list (each scene activated as the actual desktop wallpaper).

## 9. Out of scope (call out, don't silently skip)

- 3D `.mdl` model rendering (no public spec, 51 instances). Mark as `WPESceneFeatureFlag.modelObject` → `degradedPlayable` with model layers hidden. A future phase can investigate the format if a high-priority scene needs it.
- HTML/Web wallpapers — separate `WallpaperType` and a different runtime.
- Live2D / Spine — these are wallpapers' own bundled runtimes, not part of the WPE scene system.
- Ray-traced lights and SSAO — WPE supports them on Windows; treat as `degradedPlayable` (skip the light pass) until demand surfaces.

---

**Next concrete step (when you say go):** Phase 1, Task 1 — implement `WPECorpusScanner` + `WPECorpusCompatibilityTests` against the real corpus path so we have a measured baseline before touching the shader compiler. That's the smallest reversible step that makes everything afterwards measurable.
