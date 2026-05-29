# WPE Metal Visual Correctness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the Metal scene renderer from "compiles and is not black" to "renders Wallpaper Engine scene images, effects, and object placement with measurable visual correctness."

**Architecture:** Preserve the existing WPE render graph and shader pipeline, but stop treating all image/material passes as fullscreen post-process passes. Carry scene image-object geometry into the render graph, render base image/material passes with object-space quad geometry, and reserve fullscreen drawing for effect/composite/FBO passes. Add offscreen visual gates that compare texture coverage, bindings, and snapshots instead of only checking Metal compile success.

**Tech Stack:** Swift 6, Metal/MTKView, Swift Testing, `xcodebuild`, WPE scene project corpus at `/Users/tiramitree/tl_workspace/Live Wallpapers/431960`, WPE official scene/effect semantics, Apple Metal render command encoder semantics.

---

## Current Checkpoint

- Warning cleanup is implemented in `LiveWallpaper/Runtime/WPEShaderTranspiler.swift`.
- Regression coverage is added in `LiveWallpaperTests/WPEShaderTranspilerTests.swift`.
- Verified so far:
  - `WPEShaderTranspilerTests`: 16 tests passed.
  - `WPECorpusFailurePatternsTests`: 24 tests passed.
  - `git diff --check`: passed.
- Known limitation: these are compile/smoke-level gates. They do not prove visual correctness.

## 2026-05-28 Completion Checkpoint

- Preserved image-object geometry in the render graph, diagnostics envelope, and WebGL bridge payload.
- Added a Metal object-quad vertex path for base `genericimage2` and `genericimage4` material passes with non-identity object geometry.
- Added per-pass, per-slot texture binding diagnostics, including explicit fallback markers when a slot reuses the primary texture.
- Added first-frame visual stats, pass list, resolution summary, and selected corpus visual gates.
- Verified focused graph, executor, and corpus tests against `/Users/tiramitree/tl_workspace/Live Wallpapers/431960` with selected visual scene `3662499296`.

## 2026-05-28 2740023533 Debug Checkpoint

- Reproduced the user-reported white/mostly blank output through the real scene debug artifacts for workshop `2740023533`.
- Found two general Metal pipeline bugs:
  - `solidcolor`/`solidlayer` material passes still used the fullscreen vertex path even when the layer had object geometry.
  - Named FBO/layerComposite targets, including missing `.previous` bootstrap textures, were initialized as opaque black instead of transparent black, so later fullscreen effects could cover the scene.
- Added regression coverage:
  - `Solidcolor material pass renders with object quad geometry instead of fullscreen`
  - `Effect composite from object-sized solid layer preserves transparent FBO areas`
  - `Bootstraps missing FBO previous with a transparent cleared texture on first render`
- Verified:
  - `WPEMetalRenderExecutorTests`: 36 tests passed.
  - `WPEEndToEndCorpusTests` with selected scene `2740023533`: 3 tests passed.
- Latest `2740023533` visual artifact: `/Users/tiramitree/Library/Application Support/LiveWallpaper/scene-debug/20260528-085104-2740023533/first-frame.png`.
- Remaining visual risk: the frame is no longer white/black-occluded and covers the full scene, but there are still non-fatal `unsupportedAnimation` `.tex` misses and visible distortion. Treat those as the next debugging target, not as project-specific special cases.

## 2026-05-28 Effect Shader Dispatch Checkpoint

- Reproduced the later user-reported "twisted/tangled" output from `IMG_1753.HEIC` as a general effect-pass routing problem, not a scene-specific tuning issue.
- Found that `WPERenderPipelineBuilder` correctly preferred project-provided source for effect shaders such as `effects/waterwaves`, `effects/waterripple`, and `effects/foliagesway`, but `WPEMetalShaderDispatcher` ignored `WPEShaderProgram.isBuiltin == false` and routed those shader names into simplified native approximations.
- Fixed dispatcher precedence so non-builtin project shader source is translated and dispatched before matching any native builtin effect name. If translation cannot support a source shader, the existing precise translator error/fallback path is preserved instead of rendering with a visually wrong approximation.
- Added regression coverage:
  - `Project effect shader source overrides native effect approximation`
- Verified:
  - `WPEMetalRenderExecutorTests`: 37 tests passed.
  - `WPEEndToEndCorpusTests` with selected scene `2740023533`: 3 tests passed.
- Combined graph/executor/corpus verification: 50 tests passed across 3 suites.
- Latest `2740023533` visual artifact: `/Users/tiramitree/Library/Application Support/LiveWallpaper/scene-debug/20260528-165535-2740023533/first-frame.png`.
- Remaining visual risk: the selected scene now renders coherent first-frame imagery instead of global effect distortion, but resolution diagnostics still show non-fatal animated `.tex` misses and the selected run emitted a harmless Metal warning for an unused translated shader variable. Strict effect parity still depends on broader animated `.tex` support and shader translator coverage.

## 2026-05-28 Animated Varying Checkpoint

- Reproduced the user-reported 2x2 cloud tiling as a general shader translation bug: project fragment shaders used vertex-computed varyings, but the Metal transpiler synthesized undeclared varyings from `uv`.
- Fixed `WPESwiftShaderCompiler` to expose vertex-only animation uniforms to fragment translation, excluding model matrices.
- Added WPE-specific varying synthesis for common animated effect patterns, including `scroll`, `waterwaves`, `waterripple`, `iris`, `foliagesway` UV mode, `shake` bounds/mask UV, and neutral audio pulse fallback.
- Added runtime packing for `g_TextureNResolution` from the actual bound Metal texture and destination texture dimensions.
- Added regression coverage:
  - `Project scroll shader uses vertex-computed scroll varying`
  - `Project waterwaves shader uses vertex-computed direction and mask UV`
  - `Project foliage UV shader uses vertex-computed noise varyings`
- Verified:
  - `WPEShaderTranspilerTests`: 19 tests passed.
  - Combined graph/executor/transpiler/corpus verification against selected scene `2740023533`: 73 tests passed across 4 suites.
  - `git diff --check`: passed.
- Latest `2740023533` visual artifact: `/Users/tiramitree/Library/Application Support/LiveWallpaper/scene-debug/20260528-171819-2740023533/first-frame.png`.
- Remaining visual risk: first-frame composition no longer shows cloud tiling, but dynamic parity still needs visual observation in the running app because vertex-deformation mode and animated `.tex` frame playback remain broader follow-up areas.

## 2026-05-28 3479521040 Opening Animation Checkpoint

- Reproduced the user-reported picture-in-picture residue, author text residue, and red/orange fullscreen wash as a general animated-value parsing/runtime problem, not a scene-specific layer hack.
- Found that WPE values shaped as `{ "value": ..., "animation": ... }` were ignored by `WPEValueParser.shaderConstant(...)`; image/text alpha used `parseDouble(...)`, so `mode: "single"` fades were treated as static values and never clamped to their final keyframe.
- Scene-specific mapping:
  - `newproperty1` is the authored opening animation group.
  - Layer `187` (`原`), text `198` (`By Cogecha`), composelayer `367`, and post-process layer `201` all fade to zero by frame 90 at 30fps.
  - `newproperty5` is the authored sunlight/lens-flare layer.
  - `newproperty4` is the authored wind/smoke particle layer.
- Added reusable animated-value model support for shader constants and image/text/particle alpha, and resolve those values every Metal frame before dispatch.
- Added regression coverage:
  - `Image and text alpha animations are preserved and resolve single-shot fades`
  - `Animated single shader constants clamp to final keyframe after their duration`
  - `Animated loop shader constants wrap by authored animation length`
- Verified:
  - `WPESceneDocumentParserTests`, `WPERenderGraphBuilderTests`, and `WPEMetalRenderExecutorTests`: 70 tests passed.
  - `WPEMetalRuntimeUniformsTests`: 7 tests passed.
  - `WPEEndToEndCorpusTests` with selected scene `3479521040`: 3 tests passed.
  - `git diff --check`: passed.
- Latest `3479521040` visual artifact: `/Users/tiramitree/Library/Containers/Taijia.LiveWallpaper/Data/Library/Application Support/LiveWallpaper/scene-debug/20260528-195757-3479521040/first-frame.png`.
- Remaining visual risk: the authored wind/smoke and sunlight layers remain enabled by default; if smoke still fills the screen after the fade fix, the next target is particle scale/lifetime/alpha parity, not opening-layer opacity.

## Root Cause Summary

The current Metal path can render non-black output while still being visually wrong because scene object geometry is not part of the renderer-facing graph. `WPESceneImageObject` parses `origin`, `scale`, `angles`, `alignment`, `size`, `alpha`, `color`, and `brightness`, but `WPERenderLayer` currently carries only object identity, image/material paths, FBOs, passes, and parallax depth. `WPEMetalRenderExecutor.encode(...)` then draws every pass as a fullscreen triangle strip. That is correct for post-process/composite passes, but wrong for base image/object placement.

## Files

- Modify: `Packages/LiveWallpaperProWPE/Sources/LiveWallpaperProWPE/Schema/WPERenderGraph.swift`
  - Add renderable image-object geometry to `WPERenderLayer`.
- Modify: `LiveWallpaper/Infrastructure/WPERenderGraphBuilder.swift`
  - Populate layer geometry from each `WPESceneImageObject`.
- Modify: `LiveWallpaper/Models/WPEPipelineEnvelope.swift`
  - Export geometry fields for WebGL/diagnostic parity.
- Modify: `LiveWallpaper/Runtime/WPEMetalRenderErrors+Uniforms.swift`
  - Add uniform structs for object quad rendering if needed.
- Modify: `LiveWallpaper/Runtime/WPEMetalRenderExecutor.swift`
  - Draw object passes through a geometry-aware quad path.
- Modify: `LiveWallpaper/Runtime/WPEMetalShaderDispatcher.swift`
  - Preserve fullscreen dispatch for effect/composite passes and use object geometry for base image/material passes.
- Modify: `LiveWallpaper/VideoPlayback/WPEMetalBuiltins.metal`
  - Add or reuse a vertex function that maps object pixel geometry into clip space.
- Modify: `LiveWallpaperTests/WPERenderGraphBuilderTests.swift`
  - Assert graph preserves object geometry.
- Modify: `LiveWallpaperTests/WPEMetalRenderExecutorTests.swift`
  - Add offscreen tests for object placement and texture coverage.
- Modify: `LiveWallpaperTests/WPEEndToEndCorpusTests.swift` or add a focused test file
  - Add corpus visual smoke checks for selected scene IDs.

## Task 1: Preserve Scene Object Geometry In The Render Graph

**Files:**
- Modify: `Packages/LiveWallpaperProWPE/Sources/LiveWallpaperProWPE/Schema/WPERenderGraph.swift`
- Modify: `LiveWallpaper/Infrastructure/WPERenderGraphBuilder.swift`
- Modify: `LiveWallpaperTests/WPERenderGraphBuilderTests.swift`

- [x] **Step 1: Write the failing test**

Add a Swift Testing case that builds a document with one image object whose origin, scale, angle, size, alignment, alpha, color, and brightness are non-default. Assert the resulting `WPERenderLayer` carries those values.

Run:

```bash
xcodebuild test -scheme LiveWallpaper -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:LiveWallpaperTests/WPERenderGraphBuilderTests CODE_SIGNING_ALLOWED=NO
```

Expected: the new test fails because `WPERenderLayer` has no geometry payload yet.

- [x] **Step 2: Add graph geometry data**

Add a small value type, for example `WPERenderLayerGeometry`, to `WPERenderGraph.swift`:

```swift
public struct WPERenderLayerGeometry: Equatable, Sendable {
    public let origin: SIMD3<Double>
    public let scale: SIMD3<Double>
    public let angles: SIMD3<Double>
    public let alignment: WPESceneAlignment
    public let size: CGSize?
    public let alpha: Double
    public let color: SIMD3<Double>
    public let brightness: Double
}
```

Add `geometry: WPERenderLayerGeometry` to `WPERenderLayer`, with an explicit initializer argument. Update test fixtures to pass an identity/default geometry helper rather than silently defaulting production paths.

- [x] **Step 3: Populate geometry**

In `WPERenderGraphBuilder.buildLayer(...)`, construct `WPERenderLayerGeometry` from the source `WPESceneImageObject` and pass it into `WPERenderLayer`.

- [x] **Step 4: Verify**

Run:

```bash
xcodebuild test -scheme LiveWallpaper -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:LiveWallpaperTests/WPERenderGraphBuilderTests CODE_SIGNING_ALLOWED=NO
```

Expected: all graph builder tests pass, including the new geometry preservation case.

## Task 2: Add A Geometry-Aware Object Quad Path

**Files:**
- Modify: `LiveWallpaper/Runtime/WPEMetalRenderErrors+Uniforms.swift`
- Modify: `LiveWallpaper/VideoPlayback/WPEMetalBuiltins.metal`
- Modify: `LiveWallpaper/Runtime/WPEMetalRenderExecutor.swift`
- Modify: `LiveWallpaper/Runtime/WPEMetalShaderDispatcher.swift`
- Modify: `LiveWallpaperTests/WPEMetalRenderExecutorTests.swift`

- [x] **Step 1: Write the failing offscreen render test**

Create a synthetic 4x4 red texture and render it as an image layer into a 16x16 target with size 8x8 centered at scene position (8, 8). Read back the output and assert the red pixel bounding box is exactly the expected 8x8 region, not the full 16x16 frame.

Run:

```bash
xcodebuild test -scheme LiveWallpaper -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:LiveWallpaperTests/WPEMetalRenderExecutorTests CODE_SIGNING_ALLOWED=NO
```

Expected: the new test fails because the current executor draws a fullscreen triangle strip for the pass.

- [x] **Step 2: Add object uniforms**

Add a uniform struct with center, size, rotation, color, and scene size. Keep layout aligned with the MSL struct.

```swift
struct WPEObjectQuadUniforms {
    var centerAndSize: SIMD4<Float>
    var sceneSizeAndRotation: SIMD4<Float>
    var color: SIMD4<Float>
}
```

- [x] **Step 3: Add object vertex shader**

In `WPEMetalBuiltins.metal`, add a vertex function that emits four quad corners around `centerAndSize.xy`, applies rotation, converts scene pixels to clip space, and passes UVs to the fragment stage.

- [x] **Step 4: Dispatch base object passes through object geometry**

In the dispatcher/executor boundary, choose object geometry for material/image passes that represent an image object's base composite. Keep existing fullscreen behavior for effect, command, FBO copy, and final composite passes.

- [x] **Step 5: Verify**

Run:

```bash
xcodebuild test -scheme LiveWallpaper -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:LiveWallpaperTests/WPEMetalRenderExecutorTests CODE_SIGNING_ALLOWED=NO
```

Expected: object placement test passes and existing executor tests remain green.

## Task 3: Harden Texture Binding Diagnostics

**Files:**
- Modify: `LiveWallpaper/Runtime/WPEMetalShaderDispatcher.swift`
- Modify: `LiveWallpaper/Runtime/WPEMetalShaderInputs.swift`
- Modify: `LiveWallpaper/Infrastructure/WPESceneDebugArtifacts.swift`
- Modify: `LiveWallpaperTests/WPEMetalRenderExecutorTests.swift`

- [x] **Step 1: Write the failing diagnostic test**

Create a prepared pass with `g_Texture0` bound to a base image and `g_Texture1` bound to a mask. Assert the dispatcher resolves distinct textures for slots 0 and 1. Add a diagnostic event when a slot falls back to the primary texture.

Run:

```bash
xcodebuild test -scheme LiveWallpaper -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:LiveWallpaperTests/WPEMetalRenderExecutorTests CODE_SIGNING_ALLOWED=NO
```

Expected: test fails until slot resolution exposes enough evidence to distinguish intentional fallback from missing binding.

- [x] **Step 2: Implement binding audit data**

Record per-pass binding decisions in debug artifacts:

```text
[binding] pass=<id> slot=0 reference=image(materials/base.png) texture=<label>
[binding] pass=<id> slot=1 reference=image(materials/mask.png) texture=<label>
```

- [x] **Step 3: Verify**

Run:

```bash
xcodebuild test -scheme LiveWallpaper -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:LiveWallpaperTests/WPEMetalRenderExecutorTests CODE_SIGNING_ALLOWED=NO
```

Expected: tests pass and debug logs show per-slot references for custom shader passes.

## Task 4: Add Corpus Visual Gates

**Files:**
- Modify: `LiveWallpaper/Runtime/WPECorpusPlaybackHarness.swift`
- Modify: `LiveWallpaperTests/WPEEndToEndCorpusTests.swift`
- Create if useful: `LiveWallpaperTests/WPEMetalVisualCorrectnessTests.swift`

- [x] **Step 1: Write the failing visual gate**

Use one known-bad scene from `/Users/tiramitree/tl_workspace/Live Wallpapers/431960`. The gate should render a first frame offscreen, read back pixels, and assert:

- The frame is not all black.
- The non-background pixel bounding box is not the entire frame for a deliberately smaller object.
- Required image texture references were resolved by the resolver.
- No final scene pass sampled a missing FBO.

Run:

```bash
xcodebuild test -scheme LiveWallpaper -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:LiveWallpaperTests/WPEEndToEndCorpusTests CODE_SIGNING_ALLOWED=NO
```

Expected: at least one visual assertion fails before the geometry fix is complete.

- [x] **Step 2: Save debug artifacts**

When `WPEMetalCaptureScene=<sceneID>` is set, write:

- first-frame PNG
- pass list
- per-pass target/source/texture bindings
- nonzero pixel bounding box
- resolution summary

- [x] **Step 3: Verify**

Run the selected corpus test again.

Expected: corpus gate fails only for real visual regressions, not for missing instrumentation.

## Task 5: Compare Against WPE/WebGL Semantics

**Files:**
- Modify only the files implicated by Tasks 1-4.

- [x] **Step 1: Use references before implementation**

Before changing pass semantics, read:

- WPE scene/effect docs for material/effect pass and FBO expectations.
- Apple Metal render command encoder docs for load/store action and render pass target behavior.
- Existing `WPEWebGLRuntime/src/core/RenderGraphExecutor.ts` to compare graph execution order.

- [x] **Step 2: Record differences**

Add a short note to this plan or a follow-up doc listing observed differences between Metal and WebGL for the chosen scene:

```text
scene=<id>
expected object bounds=<...>
metal object bounds=<...>
expected texture slots=<...>
metal texture slots=<...>
first mismatching pass=<...>
```

Observed passing gate:

```text
scene=3662499296
expected object bounds=scene-sized animated texture layers may cover the full output
metal object bounds=(0,0)-(3839,2159), size=3840x2160
expected texture slots=WebGL binds pass.textures[0] before pass.source and binds explicit g_TextureN entries by slot
metal texture slots=pass 17.0 slot 0 asset(f529), slot 1 primary fallback; pass 127.0 slot 0 asset(workshop/2652493753/bar), slots 1-3 primary fallback
resolution=7 resolved, 2 unsupported animated .tex misses recorded as non-fatal
first mismatching pass=none for the selected visual smoke gate
```

Observed remaining debug target:

```text
scene=3287199039
expected object bounds=single scene-sized PS2 Startup Screen layer should produce visible non-black output
metal object bounds=nil, nonBlackPixelCount=0, nonTransparentPixelCount=8294400
expected texture slots=WebGL resolves pass.textures[0] for genericimage4 and uses placeholder texture when util/white is missing
metal texture slots=pass 13.0 slot 0 asset(util/white), slot 1 primary fallback; pass 13.1 slot 0 fbo(_rt_imageLayerComposite_13_a), slots 1-3 primary fallback
first mismatching pass=pass 13.0 or pass 13.1; final frame is transparent/black after util/white fallback and the ps2_startup_screen effect
```

- [x] **Step 3: Verify final gate**

Run:

```bash
xcodebuild test -scheme LiveWallpaper -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:LiveWallpaperTests/WPERenderGraphBuilderTests -only-testing:LiveWallpaperTests/WPEMetalRenderExecutorTests -only-testing:LiveWallpaperTests/WPEEndToEndCorpusTests CODE_SIGNING_ALLOWED=NO
```

Expected: graph, executor, and selected visual corpus tests pass with no shader compile warnings for the selected scene.

## Handoff Notes

- Do not use the current `WPEShaderTranspilerTests` pass count as visual correctness evidence. It proves generated MSL compiles for selected inputs.
- Keep `LiveWallpaper/Resources/Localizable.xcstrings` out of these commits unless the next worker is explicitly asked to handle localization.
- Prefer one commit per task after the initial geometry model is passing.
