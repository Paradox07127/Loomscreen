# WPE Native Scene Playback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Wallpaper Engine scene projects imported through LiveWallpaper mount and play through the native macOS Metal scene pipeline by default.

**Architecture:** Keep the current Swift/Metal renderer boundary and make it the production scene path, while preserving SpriteKit as an explicit fallback backend. Mirror both packaged `scene.pkg` projects and unpacked WPE scene folders into the existing app-support WPE cache so `SceneDescriptor` remains cache-rooted and restorable. Treat shader translation as the next renderer phase: this slice makes imported scenes play when they fit the current graph/TEX/Metal coverage, and leaves unsupported custom GLSL as a precise runtime diagnostic rather than a silent blank frame.

**Tech Stack:** Swift 6, AppKit, MetalKit, existing WPE parser/cache/import/render graph models, Swift Testing, Xcode `xcodebuild`.

---

## File Structure

- Modify `LiveWallpaper/Infrastructure/WallpaperEngineCache.swift`
  - Add a cache method that mirrors an unpacked WPE project directory into `wpe-cache/<workshopID>`.
  - Reuse cache manifests so repeated imports do not recopy unchanged folders.

- Modify `LiveWallpaper/Infrastructure/WallpaperEngineImportService.swift`
  - Route scene projects without `scene.pkg` through the new mirror path instead of immediately returning unsupported.
  - Keep plugin and dependency gates before cache work.
  - Classify the mirrored `scene.json` exactly like packaged scenes.

- Modify `LiveWallpaper/Runtime/AmbientWallpaperSessionBuilder.swift`
  - Make `.metalExperimental` the default scene backend now that scene imports should use the native renderer.
  - Preserve `.spriteKit` as an explicit test/fallback option.

- Modify `LiveWallpaper/ScreenManager.swift`
  - Request the native Metal backend explicitly when activating scene wallpapers, making the production intent visible at the call site.

- Modify tests:
  - `LiveWallpaperTests/WallpaperEngineCacheTests.swift`
  - `LiveWallpaperTests/WallpaperEngineImportServiceTests.swift`
  - `LiveWallpaperTests/WPESceneRendererBoundaryTests.swift`

## Task 1: Mirror Unpacked Scene Projects Into Cache

- [ ] Write a failing cache test proving `ensureMirroredDirectory` copies a folder with `scene.json` and assets into `wpe-cache/<workshopID>`.
- [ ] Run only `WallpaperEngineCacheTests` for the new test and confirm it fails because the method does not exist.
- [ ] Implement the cache method with a directory fingerprint based on relative paths, file sizes, mtimes, and SHA-256 file bytes.
- [ ] Re-run the cache test and confirm it passes.

## Task 2: Import Unpacked Scene Projects

- [ ] Write a failing import-service test for a valid scene folder without `scene.pkg`.
- [ ] Run only that test and confirm it currently returns `.unsupported`.
- [ ] Update `importScene` so unpacked scene folders are mirrored into cache, parsed, classified, and returned as `.ready(.scene(...))`.
- [ ] Preserve existing unsupported behavior for missing `scene.json`, missing assets, Windows plugins, and missing dependencies.
- [ ] Re-run `WallpaperEngineImportServiceTests`.

## Task 3: Make Native Metal The Default Scene Runtime

- [ ] Replace the existing “SpriteKit default” boundary test with a failing test that expects `WPEMetalSceneRenderer` when no backend override is passed.
- [ ] Keep the explicit SpriteKit test by passing `rendererBackend: .spriteKit`.
- [ ] Change `AmbientWallpaperSessionBuilder.makeSceneSession` default backend to `.metalExperimental`.
- [ ] Update `ScreenManager.activateAmbientWallpaper(.scene)` to pass `.metalExperimental` explicitly.
- [ ] Re-run `WPESceneRendererBoundaryTests`.

## Task 4: Verification

- [ ] Run the targeted WPE tests:
  - `xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WallpaperEngineCacheTests -only-testing:LiveWallpaperTests/WallpaperEngineImportServiceTests -only-testing:LiveWallpaperTests/WPESceneRendererBoundaryTests`
- [ ] Run the renderer tests:
  - `xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPEMetalSceneRendererTests -only-testing:LiveWallpaperTests/WPEMetalRenderExecutorTests`
- [ ] If targeted tests pass, run the full unit suite if time permits:
  - `xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO`

## Follow-Up Phase: Third-Party Shader Translation

The next implementation plan should add a translator/compiler boundary backed by vendored shader tooling. The recommended shape is:

- Add `WPEShaderTranslator` and `WPEShaderCompiler` protocols.
- Vendor a translator path that can preprocess WPE GLSL/HLSL-like shaders and emit Metal-compatible code or an intermediate format.
- Cache translated libraries by `(workshopID, shaderName, comboHash)`.
- Teach `WPEMetalRenderExecutor` to dispatch non-built-in `WPEShaderProgram` through compiled runtime pipelines.
- Add corpus fixtures from real Workshop scenes and compare rendered pixels against reference captures.

This follow-up is intentionally separate because it will introduce third-party source/binary integration and a larger build-system change.
