# WPE Metal Visual Correctness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the Metal scene renderer from "compiles and is not black" to "renders Wallpaper Engine scene images, effects, and object placement with measurable visual correctness."

**Architecture:** Preserve the existing WPE render graph and shader pipeline, but stop treating all image/material passes as fullscreen post-process passes. Carry scene image-object geometry into the render graph, render base image/material passes with object-space quad geometry, and reserve fullscreen drawing for effect/composite/FBO passes. Add offscreen visual gates that compare texture coverage, bindings, and snapshots instead of only checking Metal compile success.

**Tech Stack:** Swift 6, Metal/MTKView, Swift Testing, `xcodebuild`, WPE scene project corpus at `/Users/taijial/Documents/Live Wallpapers/431960`, WPE official scene/effect semantics, Apple Metal render command encoder semantics.

---

## Current Checkpoint

- Warning cleanup is implemented in `LiveWallpaper/Runtime/WPEShaderTranspiler.swift`.
- Regression coverage is added in `LiveWallpaperTests/WPEShaderTranspilerTests.swift`.
- Verified so far:
  - `WPEShaderTranspilerTests`: 16 tests passed.
  - `WPECorpusFailurePatternsTests`: 24 tests passed.
  - `git diff --check`: passed.
- Known limitation: these are compile/smoke-level gates. They do not prove visual correctness.

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

- [ ] **Step 1: Write the failing test**

Add a Swift Testing case that builds a document with one image object whose origin, scale, angle, size, alignment, alpha, color, and brightness are non-default. Assert the resulting `WPERenderLayer` carries those values.

Run:

```bash
xcodebuild test -scheme LiveWallpaper -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:LiveWallpaperTests/WPERenderGraphBuilderTests CODE_SIGNING_ALLOWED=NO
```

Expected: the new test fails because `WPERenderLayer` has no geometry payload yet.

- [ ] **Step 2: Add graph geometry data**

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

- [ ] **Step 3: Populate geometry**

In `WPERenderGraphBuilder.buildLayer(...)`, construct `WPERenderLayerGeometry` from the source `WPESceneImageObject` and pass it into `WPERenderLayer`.

- [ ] **Step 4: Verify**

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

- [ ] **Step 1: Write the failing offscreen render test**

Create a synthetic 4x4 red texture and render it as an image layer into a 16x16 target with size 8x8 centered at scene position (8, 8). Read back the output and assert the red pixel bounding box is exactly the expected 8x8 region, not the full 16x16 frame.

Run:

```bash
xcodebuild test -scheme LiveWallpaper -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:LiveWallpaperTests/WPEMetalRenderExecutorTests CODE_SIGNING_ALLOWED=NO
```

Expected: the new test fails because the current executor draws a fullscreen triangle strip for the pass.

- [ ] **Step 2: Add object uniforms**

Add a uniform struct with center, size, rotation, color, and scene size. Keep layout aligned with the MSL struct.

```swift
struct WPEObjectQuadUniforms {
    var centerAndSize: SIMD4<Float>
    var sceneSizeAndRotation: SIMD4<Float>
    var color: SIMD4<Float>
}
```

- [ ] **Step 3: Add object vertex shader**

In `WPEMetalBuiltins.metal`, add a vertex function that emits four quad corners around `centerAndSize.xy`, applies rotation, converts scene pixels to clip space, and passes UVs to the fragment stage.

- [ ] **Step 4: Dispatch base object passes through object geometry**

In the dispatcher/executor boundary, choose object geometry for material/image passes that represent an image object's base composite. Keep existing fullscreen behavior for effect, command, FBO copy, and final composite passes.

- [ ] **Step 5: Verify**

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

- [ ] **Step 1: Write the failing diagnostic test**

Create a prepared pass with `g_Texture0` bound to a base image and `g_Texture1` bound to a mask. Assert the dispatcher resolves distinct textures for slots 0 and 1. Add a diagnostic event when a slot falls back to the primary texture.

Run:

```bash
xcodebuild test -scheme LiveWallpaper -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:LiveWallpaperTests/WPEMetalRenderExecutorTests CODE_SIGNING_ALLOWED=NO
```

Expected: test fails until slot resolution exposes enough evidence to distinguish intentional fallback from missing binding.

- [ ] **Step 2: Implement binding audit data**

Record per-pass binding decisions in debug artifacts:

```text
[binding] pass=<id> slot=0 reference=image(materials/base.png) texture=<label>
[binding] pass=<id> slot=1 reference=image(materials/mask.png) texture=<label>
```

- [ ] **Step 3: Verify**

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

- [ ] **Step 1: Write the failing visual gate**

Use one known-bad scene from `/Users/taijial/Documents/Live Wallpapers/431960`. The gate should render a first frame offscreen, read back pixels, and assert:

- The frame is not all black.
- The non-background pixel bounding box is not the entire frame for a deliberately smaller object.
- Required image texture references were resolved by the resolver.
- No final scene pass sampled a missing FBO.

Run:

```bash
xcodebuild test -scheme LiveWallpaper -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:LiveWallpaperTests/WPEEndToEndCorpusTests CODE_SIGNING_ALLOWED=NO
```

Expected: at least one visual assertion fails before the geometry fix is complete.

- [ ] **Step 2: Save debug artifacts**

When `WPEMetalCaptureScene=<sceneID>` is set, write:

- first-frame PNG
- pass list
- per-pass target/source/texture bindings
- nonzero pixel bounding box
- resolution summary

- [ ] **Step 3: Verify**

Run the selected corpus test again.

Expected: corpus gate fails only for real visual regressions, not for missing instrumentation.

## Task 5: Compare Against WPE/WebGL Semantics

**Files:**
- Modify only the files implicated by Tasks 1-4.

- [ ] **Step 1: Use references before implementation**

Before changing pass semantics, read:

- WPE scene/effect docs for material/effect pass and FBO expectations.
- Apple Metal render command encoder docs for load/store action and render pass target behavior.
- Existing `WPEWebGLRuntime/src/core/RenderGraphExecutor.ts` to compare graph execution order.

- [ ] **Step 2: Record differences**

Add a short note to this plan or a follow-up doc listing observed differences between Metal and WebGL for the chosen scene:

```text
scene=<id>
expected object bounds=<...>
metal object bounds=<...>
expected texture slots=<...>
metal texture slots=<...>
first mismatching pass=<...>
```

- [ ] **Step 3: Verify final gate**

Run:

```bash
xcodebuild test -scheme LiveWallpaper -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:LiveWallpaperTests/WPERenderGraphBuilderTests -only-testing:LiveWallpaperTests/WPEMetalRenderExecutorTests -only-testing:LiveWallpaperTests/WPEEndToEndCorpusTests CODE_SIGNING_ALLOWED=NO
```

Expected: graph, executor, and selected visual corpus tests pass with no shader compile warnings for the selected scene.

## Handoff Notes

- Do not use the current `WPEShaderTranspilerTests` pass count as visual correctness evidence. It proves generated MSL compiles for selected inputs.
- Keep `LiveWallpaper/Resources/Localizable.xcstrings` out of these commits unless the next worker is explicitly asked to handle localization.
- Prefer one commit per task after the initial geometry model is passing.
