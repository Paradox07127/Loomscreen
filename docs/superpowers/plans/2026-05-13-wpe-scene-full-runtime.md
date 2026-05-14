# WPE Scene Full Runtime Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the current native Metal scene path into a high-compatibility WPE scene runtime for the local Workshop corpus at `/Users/tiramitree/tl_workspace/Live Wallpapers/431960`, while explicitly rejecting Windows plugin scenes.

**Architecture:** Keep the current import/cache/session pipeline. Expand the scene runtime below it: pkg/corpus diagnostics, complete scene AST preservation, shader translation, custom Metal pass execution, then particles/text/sound/puppet systems. Each phase must be validated against the real `431960` corpus before moving on.

**Tech Stack:** Swift 6, AppKit, Metal/MetalKit, existing `WallpaperEnginePackage`, existing `WPEMetalSceneRenderer`, embedded third-party shader toolchain (`DXC` or `glslang` + `SPIRV-Cross`), Xcode tests.

---

## Corpus Findings

Scanned source: `/Users/tiramitree/tl_workspace/Live Wallpapers/431960`

- Total projects: 112
- Scene projects: 46, all with `scene.pkg`
- Web projects: 36
- Video projects: 30
- Scene package contents across 46 scene pkgs:
  - `.json`: 2506
  - `.tex`: 1305
  - `.vert`: 359
  - `.frag`: 359
  - `.mp3`: 97
  - `.mdl`: 51
  - fonts: 55 (`.otf` + `.ttf`)
  - audio extras: 8 (`.flac` + `.wav`)
- Scene object totals:
  - image: 1545
  - particle: 204
  - text: 200
  - sound: 103
  - unknown: 80
- Image references:
  - 1543 image references point at `.json` model/material descriptors.
  - No direct PNG/JPEG image-layer path dominates this corpus.
- Dynamic/effect usage:
  - 43 of 46 scenes have image effects.
  - 37 of 46 scenes have particles.
  - 34 of 46 scenes have text.
  - 31 of 46 scenes have sound.
  - 17 of 46 scenes have `animationlayers`.
  - Total effect instances: 2224.
  - Total animation layer instances: 939.
  - 44 of 46 scenes include shader source files.
- Most common shader names:
  - `genericimage4`: 562
  - `genericparticle`: 193
  - `genericimage2`: 103
  - `blur_precise_gaussian`, `waterwaves`, `shake`, `opacity`, `foliagesway`, `scroll`, `pulse`, `lightshafts`, `simple_audio_bars`, `color_grading`, `spin`, `shine_gaussian`.

Implication: this corpus is not an image-only workload. Full coverage requires shader translation and runtime object systems, not only more import logic.

## File Structure

Modify:

- `LiveWallpaper/Infrastructure/WPESceneDocumentParser.swift`
  - Preserve all object kinds, not just image objects.
  - Decode particle, text, sound, animation layer, and unknown-object payloads into typed models.
- `LiveWallpaper/Models/WPESceneDocument.swift`
  - Add `particleObjects`, `textObjects`, `soundObjects`, `unknownObjects`, and richer animation-layer data.
- `LiveWallpaper/Infrastructure/WPERenderGraphBuilder.swift`
  - Build graph nodes for full-screen/project/composite layers, custom material passes, post-processes, linked textures, and particle draw inputs.
- `LiveWallpaper/Infrastructure/WPERenderPipelineBuilder.swift`
  - Keep metadata parsing, but route non-built-in shaders through the new compiler.
- `LiveWallpaper/Runtime/WPEMetalRenderExecutor.swift`
  - Add custom shader PSO execution, dynamic uniform buffers, sampler state mapping, vertex formats, and particle draw path.
- `LiveWallpaper/Runtime/WPEMetalSceneRenderer.swift`
  - Drive per-frame scripts, particle emission, text layout, sound state, dynamic texture updates, and custom shader library cache.
- `LiveWallpaper.xcodeproj/project.pbxproj`
  - Add embedded third-party shader compiler sources/binaries and new Swift files.

Create:

- `LiveWallpaper/Infrastructure/WPECorpusScanner.swift`
  - Test/debug scanner for pkg indexes, scene objects, material/effect shader names, and feature flags.
- `LiveWallpaperTests/WPECorpusCompatibilityTests.swift`
  - Optional corpus tests gated by `WPE_CORPUS_ROOT`.
- `LiveWallpaper/Runtime/WPEShaderCompiler.swift`
  - Swift API for compiling WPE `.vert/.frag` into Metal-ready libraries.
- `LiveWallpaper/Runtime/WPEShaderTranslationCache.swift`
  - Disk cache keyed by shader source hash, combo values, platform, and app version.
- `LiveWallpaper/Runtime/WPEParticleSystem.swift`
  - CPU-side particle emitter/update model plus GPU buffers.
- `LiveWallpaper/Runtime/WPETextRenderer.swift`
  - Text object layout/rasterization into Metal textures.
- `LiveWallpaper/Runtime/WPESoundRuntime.swift`
  - Scene sound object loader and playback/mute bridge.
- `ThirdParty/WPEShaderToolchain/README.md`
  - Exact third-party versions, license notes, build/update command, signing/notarization notes.

## Acceptance Targets

- Phase A: scan all 46 scene pkgs and produce deterministic feature reports.
- Phase B: import preflight classifies all 46 scenes as `nativePlayable`, `degraded`, or `unsupported` without mounting a renderer.
- Phase C: at least the 2 simplest scene pkgs render first frame through Metal without SpriteKit fallback.
- Phase D: custom shader compilation handles all `genericimage*` and common effect shader families in the corpus.
- Phase E: particle/text/sound systems make the high-use samples visually close enough to be considered playable.
- Phase F: high-risk samples either play or report exact missing feature reasons:
  - `2955378002` Persona 5 weather scene: 873 images, 1317 effects, 868 animation layers, 61 sounds.
  - `3226487183` Sparkle media/audio scene: 105 effects, custom UI/text/audio features.
  - `3704273480` 夏日影: 58 effects, 8 animation layers.
  - `3478434536` Miku Fallen: 42 effects, 21 text, 12 unknown objects.
  - `3596044309` Mika: 78 effects, particles, text, unknown objects.

## Task 1: Corpus Scanner And Baseline Tests

**Files:**
- Create: `LiveWallpaper/Infrastructure/WPECorpusScanner.swift`
- Create: `LiveWallpaperTests/WPECorpusCompatibilityTests.swift`
- Modify: `LiveWallpaper.xcodeproj/project.pbxproj`

- [x] **Step 1: Write scanner tests**

Add `WPECorpusCompatibilityTests` with tests gated by:

```swift
guard let root = ProcessInfo.processInfo.environment["WPE_CORPUS_ROOT"], !root.isEmpty else {
    return
}
```

Tests:

- `scan431960CorpusCountsSceneProjects()`
- `scan431960CorpusFindsShaderAndRuntimeFeatureTotals()`
- `scan431960CorpusCanReadEverySceneJSONFromPkg()`

Expected assertions for `/Users/tiramitree/tl_workspace/Live Wallpapers/431960`:

```swift
#expect(report.projectCounts[.scene] == 46)
#expect(report.scenePackageCount == 46)
#expect(report.entryExtensionCounts[".tex"] == 1305)
#expect(report.entryExtensionCounts[".vert"] == 359)
#expect(report.entryExtensionCounts[".frag"] == 359)
#expect(report.objectKindCounts[.image] == 1545)
#expect(report.objectKindCounts[.particle] == 204)
#expect(report.objectKindCounts[.text] == 200)
#expect(report.objectKindCounts[.sound] == 103)
#expect(report.scenesWithShaderSources == 44)
```

- [x] **Step 2: Run tests and verify red**

Run:

```bash
WPE_CORPUS_ROOT='/Users/tiramitree/tl_workspace/Live Wallpapers/431960' \
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper \
  -destination 'platform=macOS,arch=arm64,name=My Mac' \
  -parallel-testing-enabled NO \
  -only-testing:LiveWallpaperTests/WPECorpusCompatibilityTests
```

Expected: compile failure because `WPECorpusScanner` does not exist.

- [x] **Step 3: Implement `WPECorpusScanner`**

Use existing `WallpaperEngineProject.read(from:)` and `WallpaperEnginePackage.parseIndex(streamingFrom:)`. Do not duplicate pkg parsing in production code. The scanner should:

- count project types case-insensitively,
- read every scene `scene.pkg`,
- read `project.file` or `scene.json`,
- parse scene JSON object arrays,
- count object kinds using the same inference rules as `WPESceneDocumentParser`,
- count entry extensions and shader source files,
- collect top shader names from material/effect JSON.

- [x] **Step 4: Run corpus tests and verify green**

Use the command from Step 2.

Expected: all scanner tests pass.

## Task 2: Import-Time Scene Preflight

**Files:**
- Create: `LiveWallpaper/Infrastructure/WPEScenePreflight.swift`
- Modify: `LiveWallpaper/Infrastructure/WallpaperEngineImportService.swift`
- Modify: `LiveWallpaper/Models/SceneDescriptor.swift`
- Test: `LiveWallpaperTests/WallpaperEngineImportServiceTests.swift`
- Test: `LiveWallpaperTests/WPECorpusCompatibilityTests.swift`

- [x] **Step 1: Add failing tests for preflight classification**

Add unit tests covering:

- image-only built-in scene returns `.nativePlayable`,
- scene with custom shader returns `.shaderTranslationRequired`,
- scene with particle object returns `.runtimeSystemsRequired`,
- Windows DLL scene still returns `.unsupported`.

Add corpus test:

```swift
let report = try await WPECorpusScanner(rootURL: corpusRoot).scan()
#expect(report.scenePackageCount == 46)
#expect(report.sceneFeatureCounts[.customShaderSource] == 44)
#expect(report.sceneFeatureCounts[.particleObject] == 37)
```

- [x] **Step 2: Implement `WPEScenePreflight`**

Preflight should read cached scene content and return:

```swift
enum WPEScenePreflightTier: String, Codable, Sendable {
    case nativePlayable
    case degradedPlayable
    case shaderTranslationRequired
    case runtimeSystemsRequired
    case unsupported
}
```

Also return precise missing feature flags:

```swift
enum WPESceneFeatureFlag: String, Codable, Hashable, Sendable {
    case customShaderSource
    case particleObject
    case textObject
    case soundObject
    case animationLayer
    case unknownObject
    case windowsPlugin
}
```

- [x] **Step 3: Wire import service to descriptor**

`SceneDescriptor` should carry preflight tier and feature flags while preserving existing `capabilityTier` for backward compatibility. The UI can keep showing current badges until a later UI task.

- [x] **Step 4: Run import and corpus tests**

Run:

```bash
WPE_CORPUS_ROOT='/Users/tiramitree/tl_workspace/Live Wallpapers/431960' \
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper \
  -destination 'platform=macOS,arch=arm64,name=My Mac' \
  -parallel-testing-enabled NO \
  -only-testing:LiveWallpaperTests/WallpaperEngineImportServiceTests \
  -only-testing:LiveWallpaperTests/WPECorpusCompatibilityTests
```

Expected: tests pass and every scene is classified before playback.

## Task 3: Third-Party Shader Toolchain Boundary

**Files:**
- Create: `ThirdParty/WPEShaderToolchain/README.md`
- Create: `LiveWallpaper/Runtime/WPEShaderCompiler.swift`
- Create: `LiveWallpaper/Runtime/WPEShaderTranslationCache.swift`
- Create: `LiveWallpaperTests/WPEShaderCompilerTests.swift`
- Modify: `LiveWallpaper.xcodeproj/project.pbxproj`

- [ ] **Step 1: Vendor compiler strategy**

Recommended strategy:

- Use DXC-compatible preprocessing/compilation for WPE's hybrid shader dialect.
- Use SPIRV-Cross to emit MSL.
- Compile emitted MSL at runtime with `MTLDevice.makeLibrary(source:options:)`.
- Cache compiled source and diagnostics under Application Support.

The README must record:

- exact DXC/SPIRV-Cross versions,
- source URLs,
- licenses,
- how binaries/static libraries are built for arm64/x86_64 macOS,
- signing/notarization treatment,
- fallback behavior when compiler initialization fails.

- [ ] **Step 2: Add compiler tests**

Tests:

- `compilesGenericImage4PairToMetalLibrary()`
- `appliesComboDefinesBeforeCompilation()`
- `mapsUniformAnnotationsToResourceBindings()`
- `returnsDiagnosticForInvalidShaderSource()`

Use a minimal in-test shader fixture first, then add one real corpus shader fixture copied into `LiveWallpaperTests/Fixtures/WPEShaders/`.

- [ ] **Step 3: Implement Swift compiler API**

Public shape:

```swift
struct WPEShaderCompileRequest: Sendable, Hashable {
    let name: String
    let vertexSource: String
    let fragmentSource: String
    let comboValues: [String: Int]
    let uniformLayout: [WPEShaderUniformLayout]
    let textureLayout: [WPEShaderTextureLayout]
}

struct WPEShaderCompileResult: Sendable {
    let mslSource: String
    let library: MTLLibrary
    let vertexFunctionName: String
    let fragmentFunctionName: String
    let diagnostics: [String]
}
```

- [ ] **Step 4: Run compiler tests**

Run:

```bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper \
  -destination 'platform=macOS,arch=arm64,name=My Mac' \
  -parallel-testing-enabled NO \
  -only-testing:LiveWallpaperTests/WPEShaderCompilerTests
```

Expected: minimal and one corpus shader compile to `MTLLibrary`.

## Task 4: Custom Shader Pass Execution

**Files:**
- Modify: `LiveWallpaper/Runtime/WPEMetalRenderExecutor.swift`
- Modify: `LiveWallpaper/Infrastructure/WPERenderPipelineBuilder.swift`
- Modify: `LiveWallpaper/Models/WPERenderPipeline.swift`
- Test: `LiveWallpaperTests/WPEMetalRenderExecutorTests.swift`
- Test: `LiveWallpaperTests/WPEMetalSceneRendererTests.swift`

- [ ] **Step 1: Add red tests**

Add tests that currently fail with `unsupportedShader`:

- custom `genericimage4` material pass renders an input `.tex`,
- custom opacity effect modifies alpha,
- custom blur/lightshafts shader compiles and runs against offscreen FBO,
- bad shader reports `SceneLoadDiagnostic.unsupportedShader`.

- [ ] **Step 2: Extend prepared pipeline**

`WPEPreparedRenderPass` should carry either:

- built-in shader identity, or
- compiled Metal shader library/function names/resource layout.

- [ ] **Step 3: Execute custom passes**

Map WPE state into Metal:

- blend mode,
- cull mode,
- depth test/write,
- sampler state,
- texture slots,
- constants/uniform buffer,
- runtime uniforms,
- camera uniforms,
- FBO target.

- [ ] **Step 4: Run executor and renderer tests**

Run:

```bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper \
  -destination 'platform=macOS,arch=arm64,name=My Mac' \
  -parallel-testing-enabled NO \
  -only-testing:LiveWallpaperTests/WPEMetalRenderExecutorTests \
  -only-testing:LiveWallpaperTests/WPEMetalSceneRendererTests
```

Expected: custom shader tests pass; existing built-in tests still pass.

## Task 5: Corpus Shader Coverage Gate

**Files:**
- Modify: `LiveWallpaper/Infrastructure/WPECorpusScanner.swift`
- Modify: `LiveWallpaperTests/WPECorpusCompatibilityTests.swift`

- [ ] **Step 1: Add compile coverage test**

For each scene pkg:

- extract or read shader sources from package,
- build render graph,
- build render pipeline,
- compile shaders without presenting to an `MTKView`.

Expected target after Task 4:

```swift
#expect(report.sceneCompileResults.total == 46)
#expect(report.sceneCompileResults.shaderCompileFailures <= 10)
```

The initial threshold is intentionally not zero because particles, scripts, and puppet systems are still missing.

- [ ] **Step 2: Tighten threshold after each runtime task**

Update expected maximum failures after every task:

- after particle task: `<= 6`
- after text/sound task: `<= 4`
- after animation layer task: `<= 2`

## Task 6: Particle Runtime

**Files:**
- Create: `LiveWallpaper/Runtime/WPEParticleSystem.swift`
- Modify: `LiveWallpaper/Infrastructure/WPESceneDocumentParser.swift`
- Modify: `LiveWallpaper/Models/WPESceneDocument.swift`
- Modify: `LiveWallpaper/Runtime/WPEMetalSceneRenderer.swift`
- Modify: `LiveWallpaper/Runtime/WPEMetalRenderExecutor.swift`
- Test: `LiveWallpaperTests/WPEParticleSystemTests.swift`
- Test: `LiveWallpaperTests/WPECorpusCompatibilityTests.swift`

- [ ] **Step 1: Add parser tests for particle objects**

Use a real corpus-like particle object fixture and assert:

- emitter count,
- texture/material path,
- lifetime,
- rate,
- color/alpha,
- size,
- velocity,
- blend mode.

- [ ] **Step 2: Implement CPU emitter model**

The first pass should be deterministic and frame-time driven. It does not need audio reactivity yet.

- [ ] **Step 3: Add Metal particle draw path**

Support `genericparticle` shader first, because the corpus uses it 193 times.

- [ ] **Step 4: Corpus gate**

Run:

```bash
WPE_CORPUS_ROOT='/Users/tiramitree/tl_workspace/Live Wallpapers/431960' \
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper \
  -destination 'platform=macOS,arch=arm64,name=My Mac' \
  -parallel-testing-enabled NO \
  -only-testing:LiveWallpaperTests/WPEParticleSystemTests \
  -only-testing:LiveWallpaperTests/WPECorpusCompatibilityTests
```

Expected: scenes with particle objects no longer fail solely because of `genericparticle`.

## Task 7: Text And Sound Runtime

**Files:**
- Create: `LiveWallpaper/Runtime/WPETextRenderer.swift`
- Create: `LiveWallpaper/Runtime/WPESoundRuntime.swift`
- Modify: `LiveWallpaper/Infrastructure/WPESceneDocumentParser.swift`
- Modify: `LiveWallpaper/Models/WPESceneDocument.swift`
- Modify: `LiveWallpaper/Runtime/WPEMetalSceneRenderer.swift`
- Test: `LiveWallpaperTests/WPETextRendererTests.swift`
- Test: `LiveWallpaperTests/WPESoundRuntimeTests.swift`

- [ ] **Step 1: Text parser and raster tests**

Test font resolution from packaged `.ttf/.otf`, fallback font behavior, text color, alignment, opacity, and transform.

- [ ] **Step 2: Implement text renderer**

Render text objects into cached Metal textures using CoreText/CoreGraphics. Place them as scene layers using the same camera/orthographic transform path as images.

- [ ] **Step 3: Sound runtime**

Load packaged `.mp3/.flac/.wav` via AVFoundation. Respect app mute/audio-leader behavior. Do not fail scene playback if audio file decode fails; surface a non-blocking diagnostic.

- [ ] **Step 4: Tests**

Run:

```bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper \
  -destination 'platform=macOS,arch=arm64,name=My Mac' \
  -parallel-testing-enabled NO \
  -only-testing:LiveWallpaperTests/WPETextRendererTests \
  -only-testing:LiveWallpaperTests/WPESoundRuntimeTests
```

Expected: text renders to non-empty texture; sound objects initialize or produce non-blocking diagnostics.

## Task 8: Animation Layers / Puppet Warp

**Files:**
- Create: `LiveWallpaper/Runtime/WPEAnimationLayerRuntime.swift`
- Modify: `LiveWallpaper/Infrastructure/WPESceneDocumentParser.swift`
- Modify: `LiveWallpaper/Runtime/WPEMetalRenderExecutor.swift`
- Test: `LiveWallpaperTests/WPEAnimationLayerRuntimeTests.swift`
- Test: `LiveWallpaperTests/WPECorpusCompatibilityTests.swift`

- [ ] **Step 1: Add tests from high-risk sample**

Use a small extracted fixture based on `2955378002`, because it contains 868 animation layers.

Assertions:

- animation layer metadata parses,
- current-frame mesh/UV transform is deterministic,
- disabling animation layer falls back to base image,
- renderer does not allocate unbounded transient buffers.

- [ ] **Step 2: Implement minimal puppet support**

Start with UV-frame animation and transform animation. Add mesh deformation only after the corpus fixture proves the simpler path is insufficient.

- [ ] **Step 3: Performance check**

Run high-risk corpus test with memory counters. Expected: no unbounded per-frame texture/buffer growth after 300 frames.

## Task 9: Scene Scripts And User Properties

**Files:**
- Create: `LiveWallpaper/Runtime/WPESceneScriptRuntime.swift`
- Modify: `LiveWallpaper/Infrastructure/WallpaperEngineProject.swift`
- Modify: `LiveWallpaper/Runtime/WPEMetalSceneRenderer.swift`
- Test: `LiveWallpaperTests/WPESceneScriptRuntimeTests.swift`

- [ ] **Step 1: Decide script strategy**

Use JavaScriptCore for WPE scene scripts if script files are present. Run in a restricted context:

- no file system access,
- no network access,
- no process APIs,
- explicit bridge only for scene node transforms, time, mouse, and user properties.

- [ ] **Step 2: Add user property tests**

Use existing project property defaults and assert values reach shader constants or scene script variables.

- [ ] **Step 3: Implement script tick**

Call script runtime once per frame before render graph runtime uniforms are updated.

## Task 10: Final Corpus Compatibility And UX

**Files:**
- Modify: `LiveWallpaper/Views/ScreenDetail/WPESceneSection.swift`
- Modify: `LiveWallpaper/Views/ScreenDetail/WorkshopGalleryView.swift`
- Modify: `LiveWallpaper/Resources/Localizable.xcstrings`
- Modify: `LiveWallpaperTests/WPECorpusCompatibilityTests.swift`

- [ ] **Step 1: Add final corpus gate**

Run all 46 scene packages through:

- import,
- preflight,
- graph build,
- pipeline build,
- shader compile,
- first-frame offscreen render.

Expected:

```swift
#expect(report.firstFrameResults.total == 46)
#expect(report.firstFrameResults.playable >= 40)
#expect(report.firstFrameResults.windowsPluginUnsupported == 0)
```

For any remaining failures, assert exact feature reason, not generic failure.

- [ ] **Step 2: UX copy**

Show exact unsupported/degraded reasons:

- custom shader compile failed,
- particle runtime unsupported,
- animation layer unsupported,
- Windows plugin,
- missing dependency,
- corrupt texture.

- [ ] **Step 3: Full verification**

Run targeted:

```bash
WPE_CORPUS_ROOT='/Users/tiramitree/tl_workspace/Live Wallpapers/431960' \
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper \
  -destination 'platform=macOS,arch=arm64,name=My Mac' \
  -parallel-testing-enabled NO \
  -only-testing:LiveWallpaperTests/WPECorpusCompatibilityTests
```

Run unit tests:

```bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper \
  -destination 'platform=macOS,arch=arm64,name=My Mac' \
  -parallel-testing-enabled NO \
  -only-testing:LiveWallpaperTests
```

Expected: corpus gate passes target threshold and unit tests pass.

## Main Difficulties

1. **WPE shader dialect**
   WPE shader source is a hybrid dialect. It uses GLSL-style `vec*`, `mat*`, `gl_FragColor`, HLSL-style helpers such as `mul`, custom `texSample2D`, combo defines, include files, and metadata comments. This is the largest blocker.

2. **Resource binding parity**
   Shader compilation alone is not enough. Texture slots, default textures, material aliases, sampler states, runtime uniforms, camera matrices, FBOs, previous-frame textures, and link textures must match WPE semantics.

3. **Runtime object systems**
   This corpus has 204 particle objects, 200 text objects, 103 sound objects, and 939 animation layers. These are real runtime systems, not parser-only features.

4. **Performance and memory**
   The largest pkg is 364.4 MB and contains 873 image objects plus 868 animation layers. The renderer must cache aggressively and release transient buffers on suspend.

5. **No official spec**
   Compatibility must be corpus-driven. Every task should add real scene fixtures and compatibility reporting because WPE scene behavior is learned from examples and open-source reimplementations.

6. **Platform hard boundary**
   Windows `.dll` plugins cannot be loaded on macOS. These must remain explicit unsupported cases unless a specific plugin is reimplemented natively.

## Recommended Execution Order

1. Task 1: corpus scanner.
2. Task 2: import-time preflight.
3. Task 3: shader compiler boundary.
4. Task 4: custom shader pass execution.
5. Task 5: corpus shader coverage gate.
6. Task 6: particles.
7. Task 7: text and sound.
8. Task 8: animation layers.
9. Task 9: scripts and user properties.
10. Task 10: final corpus gate and UX.

This order is chosen because the actual `431960` scene set shows shader/material support as the first blocker, then particles/text/sound, then animation layers.
