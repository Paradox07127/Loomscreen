# WPE Phase 2B Scene Runtime Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the experimental Metal WPE scene renderer to SpriteKit parity for runtime behavior that does not require custom shader compilation: frame uniforms, camera/projection data, conservative mouse parallax, off-main texture uploads, Metal thumbnail snapshots, and per-layer texture diagnostics.

**Architecture:** Phase 2B keeps SpriteKit as the default renderer and hardens only the opt-in `.metalExperimental` backend. Runtime state is computed once per Metal render call, merged into `WPEPreparedRenderPass.uniformValues`, and consumed by built-in Metal paths without changing custom shader scope. Texture uploads and snapshot readback move to bounded background queues while `WPEMetalSceneRenderer` remains `@MainActor`.

**Tech Stack:** Swift 6 strict concurrency, AppKit, Metal, MetalKit, QuartzCore, existing WPE scene/parser/render graph models, Swift Testing, `xcodebuild`.

---

## Suitability Assessment

Phase 2B is now executable because Phase 2A and the H1+H3 holdover fixes are already on `main`:

- `WPESceneRenderer` is already a non-generic renderer boundary, so Phase 2B can add `previewSnapshot` and runtime hooks without reworking session ownership.
- `WPEMetalSceneRenderer` already builds `WPESceneDocument`, `WPERenderGraph`, and `WPEPreparedRenderPipeline`, so clock/camera/parallax uniforms can be layered onto the prepared IR instead of reparsing WPE JSON.
- `WPEMetalRenderExecutor` already has sRGB-correct built-in `solidcolor`, `genericimage*`, and `commands/copy` paths, so Phase 2B can prove new uniform plumbing does not regress those paths.
- `WPEMetalTextureLoader` already supports `.tex` payload upload and CGImage upload, making the upload queue change a concurrency hardening step rather than a new texture feature.
- H1 diagnostics already route Metal failures through `SceneLoadDiagnostic`; Phase 2B only needs to carry layer attribution through texture-load context.
- There is no `.context/` directory on `main` at planning time, so no additional `.context/prefs/` or `.context/history/commits.jsonl` constraints apply.

## Architecture Decision

**Rationale:** Implement Phase 2B as narrow runtime hardening around the existing Metal backend. The renderer remains `@MainActor`, but expensive texture upload and snapshot readback are dispatched to explicit non-actor queues. Runtime uniforms are represented as renderer-neutral `WPESceneShaderConstantValue` entries so future Phase 2D custom shader binding can reuse the same names.

**Rejected Alternatives:**

- Do not introduce a shader compiler or GLSL-to-MSL translation in this phase. Built-in shaders only need `g_Time`, `g_Daytime`, `g_Brightness`, `g_PointerPosition`, and camera matrix values to be present in `uniformValues`; custom shader consumption is deferred.
- Do not make `WPEMetalTextureLoader` an actor. Metal upload work needs a dedicated `DispatchQueue` plus `DispatchSemaphore` so multiple renderer instances share one bounded upload lane without actor reentrancy surprises.
- Do not block `WPESceneDetailView` on synchronous `MTLTexture.getBytes`. Snapshot generation is an async readback queued off-main and cached as `previewSnapshot`.
- Do not replace SpriteKit preview hosting. SpriteKit still uses `ScenePreviewContainer`; Metal gets an `NSImage` snapshot fallback through the same state machine.

**Assumptions:**

- `WallpaperPerformanceProfile.quality` maps to `g_Brightness = 1.0`; `.suspended` maps to `g_Brightness = 0.0`.
- `g_Daytime` is seconds since local midnight divided by `86_400`, using hour/minute/second from the current calendar.
- `g_PointerPosition` is scene UV with `(0, 0)` at the top-left and `(1, 1)` at the bottom-right.
- Built-in parallax is conservative: `uvOffset = (pointer - 0.5) * parallaxDepth * 0.1`, clamped in shader. This wires the field without attempting full WPE camera-parallax fidelity.
- `general.orthogonalprojection` produces a top-left-origin orthographic matrix and an output texture size, matching existing SpriteKit canvas sizing.

**Potential Side Effects:**

- `WPERenderLayer` gains a `parallaxDepth` field, so all test fixtures and manual `WPERenderLayer` initializers must pass `0` unless they explicitly exercise parallax.
- `WPEMetalTextureLoader` texture creation becomes async for runtime callers; existing synchronous logic is retained privately to keep the upload operation testable and bounded.
- `WPESceneDetailView` state gains a Metal snapshot playing case, so equality and preview rendering logic must be updated together.
- Continuous Metal rendering under `.quality` may increase GPU work for the experimental backend, but `.suspended` still pauses and drops drawable work.

## UX & Frontend Spec

> Synthesized from the parallel gemini frontend review. The structural plan
> below references this section instead of duplicating the rationale; Task 5
> Step 5 implements `MetalSnapshotPreview` to this spec, and Task 6 Step 6
> updates `SceneLoadDiagnostic.errorDescription` per §2.

### 1. Preview Snapshot UX

For the Metal renderer backend, `WPESceneDetailView` transitions from a live
`SKView` to a periodically updated `NSImage` snapshot.

**Visual States**

- **Loading** — `LiquidGlassSpinner` while the renderer initializes and the first `previewSnapshot` is `nil`.
- **Ready** — `NSImage` displayed with an `.opacity` transition once the snapshot is populated.
- **Stale** — when a parameter change invalidates the cached snapshot, dim the current image to `opacity(0.7)` until the next snapshot is read back.
- **Unavailable** — fall back to the existing static "Preview Unavailable" placeholder when `previewSnapshot` is still `nil` after `load()` succeeded (offscreen-only fixtures and headless tests).

**Refresh Policy**

Throttled 1 FPS timer while the detail view is visible, with a one-shot
override when `accessibilityReduceMotion` is active. SpriteKit gets its
60 fps live view because `SKView` runs its own runloop; pulling
`previewSnapshot` at 60 fps would force a Metal readback per frame on the
main thread. 1 FPS proves the scene is animating without contention; the
reduce-motion override avoids unnecessary GPU/main-thread work for users
who explicitly disabled motion.

**View Hierarchy**

In `WPESceneDetailView`'s `.playing` branch, dispatch on the renderer
backend:

- `SpriteKit` → existing `ScenePreviewContainer(controller:)`.
- `Metal` (`.playingSnapshot(NSImage)`) → new `MetalSnapshotPreview` component:
  - `Image(nsImage:)` `.resizable()` `.aspectRatio(contentMode: .fit)` so the orthographic projection is never cropped.
  - `.background(Color(NSColor.controlBackgroundColor))` to letterbox non-square projections.
  - `@State` timer firing every 1 s polls `renderer.previewSnapshot`; cancelled when the window is hidden or `reduceMotion == true`.
  - `.transition(.opacity)` on the snapshot image for the initial reveal.

**Accessibility**

- `.accessibilityLabel("Scene preview snapshot")` on the `Image`.
- `.accessibilityAddTraits(.updatesFrequently)` so VoiceOver knows content changes.
- Honor `@Environment(\.accessibilityReduceMotion)` — disable the polling timer; emit a single readback after `load()` and again after `reload()`.

### 2. Per-Layer Diagnostic Copy

`SceneLoadDiagnostic.errorDescription` is rewritten so messages name the
failing layer (`Clouds_Back`, `Mountain_Far`, …) and prefer user-facing
language ("image file", "rendering feature") over engineering jargon
("texture", "shader"). Task 6 Step 6 lands the rewrite; the messages
below are the contract:

```swift
extension SceneLoadDiagnostic {
    var errorDescription: String {
        switch self {
        case .texture(let layer, _):
            return "The image for '\(layer)' couldn't be loaded."
        case .legacyUnsupportedTexture(let layer):
            return "The image format used by '\(layer)' is no longer supported."
        case .fileMissing(let layer, _):
            return "A file required by the '\(layer)' layer is missing."
        case .crossPackageReference(let layer, _):
            return "The layer '\(layer)' requires files from an external package, which is not supported."
        case .materialUnresolved(let layer, _):
            return "A rendering feature needed by '\(layer)' is not supported yet."
        case .other(let layer, let message):
            return "The layer '\(layer)' encountered an issue: \(message)."
        }
    }
}
```

The current `errorDescription` implementation in
`LiveWallpaper/Models/WPESceneErrors.swift` returns `String` (not
`String?`); preserve that contract.

---

## Scope

### In Scope

- Per-frame Metal runtime uniforms:
  - `g_Time`
  - `g_Daytime`
  - `g_Brightness`
  - `g_PointerPosition`
- Camera uniform support from `general.orthogonalprojection`.
- Conservative built-in mouse parallax for `WPERenderLayer.parallaxDepth != 0`.
- Off-main `.tex` payload and CGImage texture uploads through a dedicated upload queue and semaphore.
- Metal preview snapshot readback into `NSImage`.
- `WPESceneDetailView` thumbnail display for Metal instead of `.previewUnavailable`.
- Texture-load diagnostics attributed to `WPERenderLayer.objectName`.

### Out Of Scope

- Custom GLSL shader compilation or MSL generation.
- FBO and multi-pass render graph execution.
- Particles.
- Audio uniforms.
- Web compatibility or WPE JavaScript API.
- Full WPE camera parallax fidelity beyond conservative UV offset wiring.
- Changing SpriteKit as the default renderer.

---

## File Structure

### New Files

- `LiveWallpaper/Runtime/WPEMetalRuntimeUniforms.swift`
  - Clock, pointer, brightness, camera matrix, and uniform merge helpers.
- `LiveWallpaper/Infrastructure/WPEMetalTextureUploadQueue.swift`
  - Shared bounded DispatchQueue for texture upload work.
- `LiveWallpaper/Infrastructure/WPEMetalTextureSnapshotter.swift`
  - Shared background readback helper that converts RGBA8 Metal output to `NSImage`.
- `LiveWallpaperTests/WPEMetalRuntimeUniformsTests.swift`
  - Deterministic tests for clock/daytime/brightness/pointer/camera merge behavior.

### Existing Files To Modify

- `LiveWallpaper/Runtime/WPESceneRenderer.swift`
  - Add `previewSnapshot: NSImage?`.
- `LiveWallpaper/Runtime/SceneRenderingController.swift`
  - Conform to `previewSnapshot`.
- `LiveWallpaper/Runtime/SceneWallpaperSession.swift`
  - No API shape change expected; existing `sceneRenderer` exposes snapshot through protocol.
- `LiveWallpaper/Runtime/WPEMetalSceneRenderer.swift`
  - Store runtime clock/pointer sampler/camera/loaded textures, render with runtime uniforms, await uploads, snapshot first output, and carry layer diagnostics.
- `LiveWallpaper/Runtime/WPEMetalRenderExecutor.swift`
  - Accept runtime/camera uniforms, merge them into passes, bind copy uniforms, apply parallax offset.
- `LiveWallpaper/VideoPlayback/WPEMetalBuiltins.metal`
  - Add copy fragment uniform buffer and UV offset clamp.
- `LiveWallpaper/Infrastructure/WPEMetalTextureLoader.swift`
  - Move upload methods to async upload queue.
- `LiveWallpaper/Models/WPESceneDocument.swift`
  - Add `WPESceneImageObject.parallaxDepth`.
- `LiveWallpaper/Models/WPERenderGraph.swift`
  - Add `WPERenderLayer.parallaxDepth`.
- `LiveWallpaper/Models/WPERenderPipeline.swift`
  - Add runtime/camera uniform merge helpers.
- `LiveWallpaper/Models/WPESceneErrors.swift`
  - Rewrite `SceneLoadDiagnostic.errorDescription` per UX & Frontend Spec §2.
- `LiveWallpaper/Infrastructure/WPESceneDocumentParser.swift`
  - Parse `parallaxDepth` / `parallaxdepth`.
- `LiveWallpaper/Infrastructure/WPERenderGraphBuilder.swift`
  - Propagate `parallaxDepth` from image object to render layer.
- `LiveWallpaper/Views/ScreenDetail/WPESceneDetailView.swift`
  - Resolve Metal snapshot state and render `NSImage` preview.
- `LiveWallpaperTests/WPESceneDocumentParserTests.swift`
  - Add parallax schema test.
- `LiveWallpaperTests/WPERenderGraphBuilderTests.swift`
  - Add parallax propagation test.
- `LiveWallpaperTests/WPEMetalRenderExecutorTests.swift`
  - Add runtime uniform non-regression and parallax tests.
- `LiveWallpaperTests/WPEMetalTextureLoaderTests.swift`
  - Add off-main upload queue tests.
- `LiveWallpaperTests/WPEMetalSceneRendererTests.swift`
  - Add runtime uniform, snapshot, async upload, and layer diagnostic tests.
- `LiveWallpaperTests/WPESceneRendererBoundaryTests.swift`
  - Update fake renderer for `previewSnapshot` and add detail-state snapshot test.

---

## Task 1: Add Runtime Uniform And Camera Models

**Files:**
- Create: `LiveWallpaper/Runtime/WPEMetalRuntimeUniforms.swift`
- Modify: `LiveWallpaper/Runtime/WPESceneRenderer.swift`
- Modify: `LiveWallpaper/Models/WPERenderPipeline.swift`
- Test: `LiveWallpaperTests/WPEMetalRuntimeUniformsTests.swift`
- Test: `LiveWallpaperTests/WPESceneRendererBoundaryTests.swift`

- [ ] **Step 1: Write failing runtime uniform tests**

Create `LiveWallpaperTests/WPEMetalRuntimeUniformsTests.swift`:

```swift
import AppKit
import QuartzCore
import Testing
@testable import LiveWallpaper

@MainActor
@Suite("WPE Metal runtime uniforms")
struct WPEMetalRuntimeUniformsTests {
    @Test("Frame clock computes time daytime brightness and pointer uniforms")
    func frameClockComputesRuntimeUniforms() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let date = try #require(DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 5,
            day: 5,
            hour: 6,
            minute: 30,
            second: 0
        ).date)

        let clock = WPEMetalFrameClock(
            loadTime: 10,
            currentMediaTime: { 12.5 },
            currentDate: { date },
            calendar: calendar
        )

        let uniforms = clock.runtimeUniforms(
            profile: .quality,
            pointerPosition: SIMD2<Double>(0.25, 0.75)
        )

        #expect(abs(uniforms.time - 2.5) < 0.0001)
        #expect(abs(uniforms.daytime - 0.2708333333) < 0.0001)
        #expect(uniforms.brightness == 1)
        #expect(uniforms.pointerPosition == SIMD2<Double>(0.25, 0.75))
        #expect(uniforms.uniformValues["g_Time"]?.numberValue == 2.5)
        #expect(uniforms.uniformValues["g_Brightness"]?.numberValue == 1)
        #expect(uniforms.uniformValues["g_PointerPosition"]?.vectorValue == [0.25, 0.75])
    }

    @Test("Suspended profile maps brightness uniform to zero")
    func suspendedProfileMapsBrightnessToZero() {
        let uniforms = WPEMetalRuntimeUniforms(
            time: 4,
            daytime: 0.5,
            brightness: WallpaperPerformanceProfile.suspended.metalBrightnessUniformValue,
            pointerPosition: SIMD2<Double>(0.5, 0.5)
        )

        #expect(uniforms.brightness == 0)
        #expect(uniforms.uniformValues["g_Brightness"]?.numberValue == 0)
    }

    @Test("Pointer sampler normalizes global mouse position to top-left scene UV")
    func pointerSamplerNormalizesGlobalMousePosition() throws {
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 200, height: 100),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        window.contentView = view

        let uv = WPEMetalPointerSampler.normalizedSceneUV(
            mouseLocation: CGPoint(x: 200, y: 125),
            in: view
        )

        #expect(abs(uv.x - 0.5) < 0.0001)
        #expect(abs(uv.y - 0.75) < 0.0001)
    }

    @Test("Orthographic camera uses scene projection dimensions")
    func orthographicCameraUsesSceneProjectionDimensions() {
        let projection = WPESceneOrthogonalProjection(width: 200, height: 100, auto: true)
        let camera = WPEMetalCameraUniforms(
            orthogonalProjection: projection,
            sceneCamera: .defaultCamera
        )

        #expect(camera.renderSize == CGSize(width: 200, height: 100))
        #expect(camera.viewProjectionMatrix.count == 16)
        #expect(abs(camera.viewProjectionMatrix[0] - 0.01) < 0.0001)
        #expect(abs(camera.viewProjectionMatrix[5] + 0.02) < 0.0001)
        #expect(abs(camera.viewProjectionMatrix[12] + 1.0) < 0.0001)
        #expect(abs(camera.viewProjectionMatrix[13] - 1.0) < 0.0001)
    }

    @Test("Prepared pipeline receives runtime and camera uniforms without losing material uniforms")
    func preparedPipelineReceivesRuntimeAndCameraUniforms() {
        let pass = WPERenderPass(
            id: "solid.0",
            phase: .material,
            shader: "solidcolor",
            source: .previous,
            target: .scene,
            textures: [:],
            binds: [:],
            constants: ["g_Color": .vector([1, 0, 0, 1])],
            combos: [:],
            blending: "normal",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )
        let layer = WPERenderLayer(
            objectID: "layer",
            objectName: "Layer",
            imagePath: "materials/base.png",
            materialPath: nil,
            compositeA: "a",
            compositeB: "b",
            localFBOs: [],
            passes: [pass],
            parallaxDepth: 0
        )
        let pipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(
                graphLayer: layer,
                passes: [
                    WPEPreparedRenderPass(
                        pass: pass,
                        shader: WPEShaderProgram(
                            name: "solidcolor",
                            vertexSource: "",
                            fragmentSource: "",
                            isBuiltin: true
                        ),
                        textureBindings: [:],
                        comboValues: [:],
                        uniformValues: ["g_Color": .vector([1, 0, 0, 1])]
                    )
                ]
            )
        ])

        let runtime = WPEMetalRuntimeUniforms(
            time: 1,
            daytime: 0.25,
            brightness: 1,
            pointerPosition: SIMD2<Double>(0.2, 0.8)
        )
        let camera = WPEMetalCameraUniforms(
            orthogonalProjection: WPESceneOrthogonalProjection(width: 64, height: 32, auto: true),
            sceneCamera: .defaultCamera
        )

        let prepared = pipeline.addingMetalRuntimeUniforms(runtime, camera: camera)
        let values = prepared.layers[0].passes[0].uniformValues

        #expect(values["g_Color"]?.vectorValue == [1, 0, 0, 1])
        #expect(values["g_Time"]?.numberValue == 1)
        #expect(values["g_Daytime"]?.numberValue == 0.25)
        #expect(values["g_Brightness"]?.numberValue == 1)
        #expect(values["g_PointerPosition"]?.vectorValue == [0.2, 0.8])
        #expect(values["g_ViewProjectionMatrix"]?.vectorValue?.count == 16)
    }
}
```

Update `LiveWallpaperTests/WPESceneRendererBoundaryTests.swift` fake renderer to fail until the protocol adds a snapshot getter:

```swift
@MainActor
private final class FakeSceneRenderer: WPESceneRenderer {
    let view = NSView(frame: .zero)
    var loadCallCount = 0
    var lastThrottle: Bool?
    var lastProfile: WallpaperPerformanceProfile?
    var onProgress: (@MainActor (String) -> Void)?
    var loadDiagnostics: SceneLoadDiagnostic?
    var renderGraph: WPERenderGraph?
    var renderPipeline: WPEPreparedRenderPipeline?
    var hasPresentedFrame = false
    var previewSnapshot: NSImage?
    var nsView: NSView { view }

    func load() async throws {
        loadCallCount += 1
        hasPresentedFrame = true
    }

    func reload() async throws {
        try await load()
    }

    func setThrottled(_ throttled: Bool) {
        lastThrottle = throttled
    }

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        lastProfile = profile
    }

    func cleanup() {}
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPEMetalRuntimeUniformsTests -only-testing:LiveWallpaperTests/WPESceneRendererBoundaryTests
```

Expected: FAIL because `WPEMetalFrameClock`, `WPEMetalRuntimeUniforms`, `WPEMetalPointerSampler`, `WPEMetalCameraUniforms`, `addingMetalRuntimeUniforms`, `metalBrightnessUniformValue`, and `WPESceneRenderer.previewSnapshot` do not exist.

- [ ] **Step 3: Add runtime uniform models**

Create `LiveWallpaper/Runtime/WPEMetalRuntimeUniforms.swift`:

```swift
import AppKit
import Foundation
import QuartzCore

struct WPEMetalRuntimeUniforms: Equatable, Sendable {
    let time: Double
    let daytime: Double
    let brightness: Double
    let pointerPosition: SIMD2<Double>

    static let zero = WPEMetalRuntimeUniforms(
        time: 0,
        daytime: 0,
        brightness: 1,
        pointerPosition: SIMD2<Double>(0.5, 0.5)
    )

    var uniformValues: [String: WPESceneShaderConstantValue] {
        [
            "g_Time": .number(time),
            "g_Daytime": .number(daytime),
            "g_Brightness": .number(brightness),
            "g_PointerPosition": .vector([pointerPosition.x, pointerPosition.y])
        ]
    }
}

struct WPEMetalFrameClock: Sendable {
    let loadTime: CFTimeInterval

    private let currentMediaTime: @Sendable () -> CFTimeInterval
    private let currentDate: @Sendable () -> Date
    private let calendar: Calendar

    init(
        loadTime: CFTimeInterval = CACurrentMediaTime(),
        currentMediaTime: @escaping @Sendable () -> CFTimeInterval = { CACurrentMediaTime() },
        currentDate: @escaping @Sendable () -> Date = { Date() },
        calendar: Calendar = .current
    ) {
        self.loadTime = loadTime
        self.currentMediaTime = currentMediaTime
        self.currentDate = currentDate
        self.calendar = calendar
    }

    func runtimeUniforms(
        profile: WallpaperPerformanceProfile,
        pointerPosition: SIMD2<Double>
    ) -> WPEMetalRuntimeUniforms {
        let elapsed = max(currentMediaTime() - loadTime, 0)
        let date = currentDate()
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        let seconds = Double((components.hour ?? 0) * 3600 + (components.minute ?? 0) * 60 + (components.second ?? 0))
        let daytime = min(max(seconds / 86_400, 0), 1)

        return WPEMetalRuntimeUniforms(
            time: elapsed,
            daytime: daytime,
            brightness: profile.metalBrightnessUniformValue,
            pointerPosition: pointerPosition.clampedToUnitSquare
        )
    }
}

@MainActor
struct WPEMetalPointerSampler: Sendable {
    let sample: @MainActor @Sendable (NSView) -> SIMD2<Double>

    static let live = WPEMetalPointerSampler { view in
        normalizedSceneUV(mouseLocation: NSEvent.mouseLocation, in: view)
    }

    static func fixed(_ uv: SIMD2<Double>) -> WPEMetalPointerSampler {
        WPEMetalPointerSampler { _ in uv.clampedToUnitSquare }
    }

    static func normalizedSceneUV(mouseLocation: CGPoint, in view: NSView) -> SIMD2<Double> {
        guard view.bounds.width > 0, view.bounds.height > 0 else {
            return SIMD2<Double>(0.5, 0.5)
        }

        let localPoint: CGPoint
        if let window = view.window {
            let windowPoint = window.convertPoint(fromScreen: mouseLocation)
            localPoint = view.convert(windowPoint, from: nil)
        } else {
            localPoint = view.convert(mouseLocation, from: nil)
        }

        let x = Double(localPoint.x / view.bounds.width)
        let y = 1.0 - Double(localPoint.y / view.bounds.height)
        return SIMD2<Double>(x, y).clampedToUnitSquare
    }
}

struct WPEMetalCameraUniforms: Equatable, Sendable {
    let renderSize: CGSize
    let viewProjectionMatrix: [Double]

    static let identity = WPEMetalCameraUniforms(
        renderSize: CGSize(width: 1, height: 1),
        viewProjectionMatrix: [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1
        ]
    )

    init(
        orthogonalProjection: WPESceneOrthogonalProjection,
        sceneCamera: WPESceneCamera
    ) {
        let width = max(orthogonalProjection.width, 1)
        let height = max(orthogonalProjection.height, 1)
        renderSize = CGSize(width: width, height: height)
        viewProjectionMatrix = Self.topLeftOrthographicMatrix(
            width: width,
            height: height,
            nearZ: sceneCamera.nearZ,
            farZ: sceneCamera.farZ
        )
    }

    private init(renderSize: CGSize, viewProjectionMatrix: [Double]) {
        self.renderSize = renderSize
        self.viewProjectionMatrix = viewProjectionMatrix
    }

    var uniformValues: [String: WPESceneShaderConstantValue] {
        [
            "g_ViewProjectionMatrix": .vector(viewProjectionMatrix)
        ]
    }

    private static func topLeftOrthographicMatrix(
        width: Double,
        height: Double,
        nearZ: Double,
        farZ: Double
    ) -> [Double] {
        let left = 0.0
        let right = width
        let top = 0.0
        let bottom = height
        let near = nearZ
        let far = farZ == nearZ ? nearZ + 1 : farZ

        return [
            2.0 / (right - left), 0, 0, 0,
            0, 2.0 / (top - bottom), 0, 0,
            0, 0, 1.0 / (near - far), 0,
            (left + right) / (left - right),
            (top + bottom) / (bottom - top),
            near / (near - far),
            1
        ]
    }
}

extension WallpaperPerformanceProfile {
    var metalBrightnessUniformValue: Double {
        switch self {
        case .quality:
            return 1
        case .suspended:
            return 0
        }
    }
}

private extension SIMD2 where Scalar == Double {
    var clampedToUnitSquare: SIMD2<Double> {
        SIMD2<Double>(
            min(max(x, 0), 1),
            min(max(y, 0), 1)
        )
    }
}
```

- [ ] **Step 4: Add preview snapshot to the renderer protocol**

Modify `LiveWallpaper/Runtime/WPESceneRenderer.swift`:

```swift
import AppKit

enum WPESceneRendererBackend: String, Codable, Equatable, Sendable {
    case spriteKit
    case metalExperimental
}

@MainActor
protocol WPESceneRenderer: AnyObject, WallpaperPerformanceConfigurable {
    var nsView: NSView { get }
    var onProgress: (@MainActor (String) -> Void)? { get set }
    var loadDiagnostics: SceneLoadDiagnostic? { get }
    var renderGraph: WPERenderGraph? { get }
    var renderPipeline: WPEPreparedRenderPipeline? { get }
    var hasPresentedFrame: Bool { get }
    var previewSnapshot: NSImage? { get }

    func load() async throws
    func reload() async throws
    func setThrottled(_ throttled: Bool)
    func cleanup()
}
```

Add a SpriteKit snapshot getter to `LiveWallpaper/Runtime/SceneRenderingController.swift`:

```swift
var previewSnapshot: NSImage? {
    guard skView.bounds.width > 0, skView.bounds.height > 0 else {
        return nil
    }
    guard let representation = skView.bitmapImageRepForCachingDisplay(in: skView.bounds) else {
        return nil
    }
    skView.cacheDisplay(in: skView.bounds, to: representation)
    let image = NSImage(size: skView.bounds.size)
    image.addRepresentation(representation)
    return image
}
```

- [ ] **Step 5: Add prepared pipeline runtime merge helper**

Modify `LiveWallpaper/Models/WPERenderPipeline.swift`:

```swift
extension WPEPreparedRenderPipeline {
    func addingMetalRuntimeUniforms(
        _ runtimeUniforms: WPEMetalRuntimeUniforms,
        camera: WPEMetalCameraUniforms
    ) -> WPEPreparedRenderPipeline {
        WPEPreparedRenderPipeline(
            layers: layers.map { layer in
                WPEPreparedRenderLayer(
                    graphLayer: layer.graphLayer,
                    passes: layer.passes.map { pass in
                        var values = pass.uniformValues
                        for (key, value) in runtimeUniforms.uniformValues {
                            values[key] = value
                        }
                        for (key, value) in camera.uniformValues {
                            values[key] = value
                        }
                        return WPEPreparedRenderPass(
                            pass: pass.pass,
                            shader: pass.shader,
                            textureBindings: pass.textureBindings,
                            comboValues: pass.comboValues,
                            uniformValues: values
                        )
                    }
                )
            }
        )
    }
}
```

- [ ] **Step 6: Run targeted runtime uniform tests**

```bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPEMetalRuntimeUniformsTests -only-testing:LiveWallpaperTests/WPESceneRendererBoundaryTests
```

Expected: PASS for runtime uniform tests and existing boundary tests after all fake renderers expose `previewSnapshot`.

---

## Task 2: Parse Camera Parallax And Apply Built-In UV Offset

**Files:**
- Modify: `LiveWallpaper/Models/WPESceneDocument.swift`
- Modify: `LiveWallpaper/Models/WPERenderGraph.swift`
- Modify: `LiveWallpaper/Infrastructure/WPESceneDocumentParser.swift`
- Modify: `LiveWallpaper/Infrastructure/WPERenderGraphBuilder.swift`
- Modify: `LiveWallpaper/Runtime/WPEMetalRenderExecutor.swift`
- Modify: `LiveWallpaper/VideoPlayback/WPEMetalBuiltins.metal`
- Test: `LiveWallpaperTests/WPESceneDocumentParserTests.swift`
- Test: `LiveWallpaperTests/WPERenderGraphBuilderTests.swift`
- Test: `LiveWallpaperTests/WPEMetalRenderExecutorTests.swift`

- [ ] **Step 1: Write failing parallax and executor tests**

Add to `LiveWallpaperTests/WPESceneDocumentParserTests.swift`:

```swift
@Test("Parses image parallax depth from scene object")
func parsesImageParallaxDepth() throws {
    let json = """
    {
      "camera": { "center": "0 0 0" },
      "general": { "orthogonalprojection": { "width": 100, "height": 50, "auto": true } },
      "objects": [{
        "id": "layer",
        "name": "Layer",
        "type": "image",
        "image": "materials/base.png",
        "parallaxDepth": 0.125
      }]
    }
    """

    let document = try WPESceneDocumentParser.parse(data: Data(json.utf8))
    let object = try #require(document.imageObjects.first)

    #expect(object.parallaxDepth == 0.125)
}
```

Add to `LiveWallpaperTests/WPERenderGraphBuilderTests.swift`:

```swift
@Test("Render graph preserves image object parallax depth on layer")
func renderGraphPreservesParallaxDepth() throws {
    let object = WPESceneImageObject(
        id: "hero",
        name: "Hero",
        imageRelativePath: "materials/hero.png",
        materialRelativePath: nil,
        origin: SIMD3<Double>(0, 0, 0),
        scale: SIMD3<Double>(1, 1, 1),
        angles: SIMD3<Double>(0, 0, 0),
        visible: true,
        alpha: 1,
        color: SIMD3<Double>(1, 1, 1),
        brightness: 1,
        blendMode: .normal,
        alignment: .center,
        size: nil,
        effects: [],
        animationLayers: [],
        parallaxDepth: 0.2
    )
    let document = WPESceneDocument(
        camera: .defaultCamera,
        general: .defaultGeneral,
        imageObjects: [object],
        diagnostics: []
    )

    let graph = try WPERenderGraphBuilder(
        cacheRootURL: FileManager.default.temporaryDirectory
    ).build(document: document)

    #expect(graph.layers.first?.parallaxDepth == 0.2)
}
```

Add to `LiveWallpaperTests/WPEMetalRenderExecutorTests.swift`:

```swift
@Test("Runtime clock uniforms do not change solidcolor built-in output")
func runtimeClockDoesNotChangeSolidColorOutput() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let executor = try WPEMetalRenderExecutor(device: device)
    let pass = solidPass()
    let pipeline = WPEPreparedRenderPipeline(layers: [
        WPEPreparedRenderLayer(
            graphLayer: graphLayer(pass: pass, parallaxDepth: 0),
            passes: [
                WPEPreparedRenderPass(
                    pass: pass,
                    shader: WPEShaderProgram(
                        name: "solidcolor",
                        vertexSource: "",
                        fragmentSource: "",
                        isBuiltin: true
                    ),
                    textureBindings: [:],
                    comboValues: [:],
                    uniformValues: ["g_Color": .vector([0.5, 0.5, 0.5, 1])]
                )
            ]
        )
    ])
    let camera = WPEMetalCameraUniforms(
        orthogonalProjection: WPESceneOrthogonalProjection(width: 4, height: 4, auto: true),
        sceneCamera: .defaultCamera
    )

    let output0 = try executor.render(
        pipeline: pipeline,
        size: CGSize(width: 4, height: 4),
        textures: [:],
        runtimeUniforms: WPEMetalRuntimeUniforms(
            time: 0,
            daytime: 0,
            brightness: 1,
            pointerPosition: SIMD2<Double>(0.5, 0.5)
        ),
        cameraUniforms: camera
    )
    let output1 = try executor.render(
        pipeline: pipeline,
        size: CGSize(width: 4, height: 4),
        textures: [:],
        runtimeUniforms: WPEMetalRuntimeUniforms(
            time: 1,
            daytime: 0.5,
            brightness: 1,
            pointerPosition: SIMD2<Double>(0.9, 0.1)
        ),
        cameraUniforms: camera
    )

    #expect(try readPixel(output0, x: 2, y: 2) == readPixel(output1, x: 2, y: 2))
}

@Test("Generic image parallax offset is bounded by pointer delta and layer depth")
func genericImageParallaxOffsetIsBounded() throws {
    let offset = WPEMetalRenderExecutor.parallaxUVOffset(
        pointerPosition: SIMD2<Double>(1.5, 0.5),
        parallaxDepth: 0.1
    )

    #expect(abs(offset.x - 0.01) < 0.0001)
    #expect(abs(offset.y) < 0.0001)
}

@Test("Generic image copy path shifts samples when parallax depth is non-zero")
func genericImageCopyPathShiftsSamplesWithParallax() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let executor = try WPEMetalRenderExecutor(device: device)

    var bytes = Data()
    for x in 0..<100 {
        bytes.append(UInt8(x))
        bytes.append(0)
        bytes.append(0)
        bytes.append(255)
    }
    let input = try makeRGBAInputTexture(device: device, width: 100, height: 1, bytes: bytes)
    let pass = copyPass()
    let layer = graphLayer(pass: pass, parallaxDepth: 0.1)
    let pipeline = WPEPreparedRenderPipeline(layers: [
        WPEPreparedRenderLayer(
            graphLayer: layer,
            passes: [
                WPEPreparedRenderPass(
                    pass: pass,
                    shader: WPEShaderProgram(
                        name: "genericimage2",
                        vertexSource: "",
                        fragmentSource: "",
                        isBuiltin: true
                    ),
                    textureBindings: [0: .image("materials/base.png")],
                    comboValues: [:],
                    uniformValues: [:]
                )
            ]
        )
    ])

    let camera = WPEMetalCameraUniforms(
        orthogonalProjection: WPESceneOrthogonalProjection(width: 100, height: 1, auto: true),
        sceneCamera: .defaultCamera
    )
    let baseline = try executor.render(
        pipeline: pipeline,
        size: CGSize(width: 100, height: 1),
        textures: ["materials/base.png": input],
        runtimeUniforms: WPEMetalRuntimeUniforms(
            time: 0,
            daytime: 0,
            brightness: 1,
            pointerPosition: SIMD2<Double>(0.5, 0.5)
        ),
        cameraUniforms: camera
    )
    let shifted = try executor.render(
        pipeline: pipeline,
        size: CGSize(width: 100, height: 1),
        textures: ["materials/base.png": input],
        runtimeUniforms: WPEMetalRuntimeUniforms(
            time: 0,
            daytime: 0,
            brightness: 1,
            pointerPosition: SIMD2<Double>(1.5, 0.5)
        ),
        cameraUniforms: camera
    )

    let baselinePixel = try readPixel(baseline, x: 50, y: 0)
    let shiftedPixel = try readPixel(shifted, x: 50, y: 0)

    #expect(shiftedPixel.r >= baselinePixel.r)
    #expect(Int(shiftedPixel.r) - Int(baselinePixel.r) <= 5)
}
```

Update helper types in `LiveWallpaperTests/WPEMetalRenderExecutorTests.swift`:

```swift
private struct Pixel: Equatable {
    let r: UInt8
    let g: UInt8
    let b: UInt8
    let a: UInt8
}

private func makeRGBAInputTexture(
    device: MTLDevice,
    width: Int = 2,
    height: Int = 2,
    bytes: Data
) throws -> MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba8Unorm,
        width: width,
        height: height,
        mipmapped: false
    )
    descriptor.usage = [.shaderRead]
    descriptor.storageMode = .shared
    let texture = try #require(device.makeTexture(descriptor: descriptor))
    bytes.withUnsafeBytes { raw in
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: raw.baseAddress!,
            bytesPerRow: width * 4
        )
    }
    return texture
}

private func graphLayer(pass: WPERenderPass, parallaxDepth: Double = 0) -> WPERenderLayer {
    WPERenderLayer(
        objectID: "layer",
        objectName: "Layer",
        imagePath: "materials/base.png",
        materialPath: nil,
        compositeA: "a",
        compositeB: "b",
        localFBOs: [],
        passes: [pass],
        parallaxDepth: parallaxDepth
    )
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPESceneDocumentParserTests -only-testing:LiveWallpaperTests/WPERenderGraphBuilderTests -only-testing:LiveWallpaperTests/WPEMetalRenderExecutorTests
```

Expected: FAIL because `parallaxDepth` is missing from models and `WPEMetalRenderExecutor` does not accept runtime uniforms or compute parallax offset.

- [ ] **Step 3: Add parallax fields to scene and graph models**

Modify `LiveWallpaper/Models/WPESceneDocument.swift`:

```swift
struct WPESceneImageObject: Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let imageRelativePath: String
    let materialRelativePath: String?
    let origin: SIMD3<Double>
    let scale: SIMD3<Double>
    let angles: SIMD3<Double>
    let visible: Bool
    let alpha: Double
    let color: SIMD3<Double>
    let brightness: Double
    let blendMode: WPESceneBlendMode
    let alignment: WPESceneAlignment
    let size: CGSize?
    let effects: [WPESceneImageEffect]
    let animationLayers: [WPESceneAnimationLayer]
    let parallaxDepth: Double
}
```

Modify `LiveWallpaper/Models/WPERenderGraph.swift`:

```swift
struct WPERenderLayer: Equatable, Sendable, Identifiable {
    var id: String { objectID }

    let objectID: String
    let objectName: String
    let imagePath: String
    let materialPath: String?
    let compositeA: String
    let compositeB: String
    let localFBOs: [WPERenderFBO]
    let passes: [WPERenderPass]
    let parallaxDepth: Double
}
```

Update every existing `WPERenderLayer(...)` initializer in tests and source to include `parallaxDepth: 0` unless the test is explicitly exercising parallax.

- [ ] **Step 4: Parse and propagate parallax depth**

Modify `LiveWallpaper/Infrastructure/WPESceneDocumentParser.swift` inside `parseImageObject`:

```swift
let parallaxDepth = parseDouble(dict["parallaxDepth"]) ?? parseDouble(dict["parallaxdepth"]) ?? 0
```

Update the `WPESceneImageObject` initializer in `parseImageObject`:

```swift
return WPESceneImageObject(
    id: id,
    name: name,
    imageRelativePath: imagePath,
    materialRelativePath: materialRelativePath,
    origin: origin,
    scale: scale,
    angles: angles,
    visible: visible,
    alpha: alpha,
    color: color,
    brightness: brightness,
    blendMode: blend,
    alignment: alignment,
    size: size,
    effects: effects,
    animationLayers: animationLayers,
    parallaxDepth: parallaxDepth
)
```

Modify `LiveWallpaper/Infrastructure/WPERenderGraphBuilder.swift` where it returns `WPERenderLayer`:

```swift
return WPERenderLayer(
    objectID: object.id,
    objectName: object.name,
    imagePath: object.imageRelativePath,
    materialPath: materialPath,
    compositeA: compositeA,
    compositeB: compositeB,
    localFBOs: context.localFBOs,
    passes: context.finalizedPasses(),
    parallaxDepth: object.parallaxDepth
)
```

- [ ] **Step 5: Bind parallax copy uniforms in Metal executor**

Modify `LiveWallpaper/Runtime/WPEMetalRenderExecutor.swift`:

```swift
struct WPESolidUniforms {
    var color: SIMD4<Float>
}

struct WPECopyUniforms {
    var uvOffset: SIMD2<Float>
    var padding: SIMD2<Float> = SIMD2<Float>(0, 0)
}
```

Replace the render signature and loop with:

```swift
func render(
    pipeline: WPEPreparedRenderPipeline,
    size: CGSize,
    textures: [String: MTLTexture],
    runtimeUniforms: WPEMetalRuntimeUniforms = .zero,
    cameraUniforms: WPEMetalCameraUniforms = .identity
) throws -> MTLTexture {
    let preparedPipeline = pipeline.addingMetalRuntimeUniforms(runtimeUniforms, camera: cameraUniforms)
    let output = try makeOutputTexture(size: size)
    guard let commandBuffer = commandQueue.makeCommandBuffer() else {
        throw WPEMetalRenderExecutorError.commandBufferFailed
    }

    var shouldClear = true
    var didEncode = false
    for layer in preparedPipeline.layers {
        if layer.passes.isEmpty {
            try encodeCopy(
                reference: .image(layer.graphLayer.imagePath),
                layer: layer.graphLayer,
                runtimeUniforms: runtimeUniforms,
                output: output,
                textures: textures,
                commandBuffer: commandBuffer,
                shouldClear: shouldClear
            )
            shouldClear = false
            didEncode = true
            continue
        }
        for pass in layer.passes {
            try encode(
                pass: pass,
                layer: layer.graphLayer,
                output: output,
                textures: textures,
                commandBuffer: commandBuffer,
                shouldClear: shouldClear
            )
            shouldClear = false
            didEncode = true
        }
    }
    guard didEncode else {
        throw WPEMetalRenderExecutorError.noRenderablePasses
    }

    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    if commandBuffer.status == .error {
        throw WPEMetalRenderExecutorError.commandBufferFailed
    }
    return output
}
```

Replace `encode(pass:output:textures:commandBuffer:shouldClear:)` with:

```swift
private func encode(
    pass: WPEPreparedRenderPass,
    layer: WPERenderLayer,
    output: MTLTexture,
    textures: [String: MTLTexture],
    commandBuffer: MTLCommandBuffer,
    shouldClear: Bool
) throws {
    guard pass.pass.target == .scene else {
        throw WPEMetalRenderExecutorError.unsupportedTarget(pass.pass.target)
    }

    let descriptor = MTLRenderPassDescriptor()
    descriptor.colorAttachments[0].texture = output
    descriptor.colorAttachments[0].loadAction = shouldClear ? .clear : .load
    descriptor.colorAttachments[0].storeAction = .store
    descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
        throw WPEMetalRenderExecutorError.commandBufferFailed
    }
    defer { encoder.endEncoding() }

    if pass.pass.shader == "solidcolor" {
        encoder.setRenderPipelineState(try renderPipeline(fragmentName: "wpe_solidcolor_fragment"))
        var uniforms = WPESolidUniforms(color: colorVector(for: pass))
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPESolidUniforms>.stride, index: 0)
    } else if pass.pass.shader == "commands/copy" || pass.pass.shader.hasPrefix("genericimage") {
        encoder.setRenderPipelineState(try renderPipeline(fragmentName: "wpe_copy_fragment"))
        let reference = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
        let texture = try resolve(reference: reference, textures: textures)
        var uniforms = copyUniforms(for: pass, layer: layer)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPECopyUniforms>.stride, index: 0)
    } else {
        throw WPEMetalRenderExecutorError.unsupportedShader(pass.pass.shader)
    }

    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
}
```

Replace `encodeCopy` with:

```swift
private func encodeCopy(
    reference: WPETextureReference,
    layer: WPERenderLayer,
    runtimeUniforms: WPEMetalRuntimeUniforms,
    output: MTLTexture,
    textures: [String: MTLTexture],
    commandBuffer: MTLCommandBuffer,
    shouldClear: Bool
) throws {
    let descriptor = MTLRenderPassDescriptor()
    descriptor.colorAttachments[0].texture = output
    descriptor.colorAttachments[0].loadAction = shouldClear ? .clear : .load
    descriptor.colorAttachments[0].storeAction = .store
    descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
        throw WPEMetalRenderExecutorError.commandBufferFailed
    }
    defer { encoder.endEncoding() }

    var values = runtimeUniforms.uniformValues
    let pass = WPEPreparedRenderPass(
        pass: WPERenderPass(
            id: "\(layer.objectID).copy",
            phase: .material,
            shader: "genericimage2",
            source: reference,
            target: .scene,
            textures: [0: reference],
            binds: [:],
            constants: [:],
            combos: [:],
            blending: "normal",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        ),
        shader: WPEShaderProgram(
            name: "genericimage2",
            vertexSource: "",
            fragmentSource: "",
            isBuiltin: true
        ),
        textureBindings: [0: reference],
        comboValues: [:],
        uniformValues: values
    )

    encoder.setRenderPipelineState(try renderPipeline(fragmentName: "wpe_copy_fragment"))
    encoder.setFragmentTexture(try resolve(reference: reference, textures: textures), index: 0)
    var uniforms = copyUniforms(for: pass, layer: layer)
    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPECopyUniforms>.stride, index: 0)
    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
}
```

Add helper methods to `WPEMetalRenderExecutor`:

```swift
static func parallaxUVOffset(
    pointerPosition: SIMD2<Double>,
    parallaxDepth: Double
) -> SIMD2<Float> {
    guard parallaxDepth != 0 else {
        return SIMD2<Float>(0, 0)
    }
    let delta = SIMD2<Double>(
        pointerPosition.x - 0.5,
        pointerPosition.y - 0.5
    )
    let offset = delta * parallaxDepth * 0.1
    return SIMD2<Float>(
        Float(min(max(offset.x, -0.05), 0.05)),
        Float(min(max(offset.y, -0.05), 0.05))
    )
}

private func copyUniforms(for pass: WPEPreparedRenderPass, layer: WPERenderLayer) -> WPECopyUniforms {
    let vector = pass.uniformValues["g_PointerPosition"]?.vectorValue ?? [0.5, 0.5]
    let pointer = SIMD2<Double>(
        vector[safe: 0] ?? 0.5,
        vector[safe: 1] ?? 0.5
    )
    return WPECopyUniforms(
        uvOffset: Self.parallaxUVOffset(
            pointerPosition: pointer,
            parallaxDepth: layer.parallaxDepth
        )
    )
}
```

Update `present(texture:in:)` so the changed copy fragment still receives a buffer:

```swift
var uniforms = WPECopyUniforms(uvOffset: SIMD2<Float>(0, 0))
encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPECopyUniforms>.stride, index: 0)
```

- [ ] **Step 6: Update Metal built-in shader**

Modify `LiveWallpaper/VideoPlayback/WPEMetalBuiltins.metal`:

```metal
struct WPECopyUniforms {
    float2 uvOffset;
    float2 padding;
};

fragment half4 wpe_copy_fragment(
    WPEVertexOut in [[stage_in]],
    texture2d<half, access::sample> texture0 [[texture(0)]],
    constant WPECopyUniforms& uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    float2 uv = clamp(in.uv + uniforms.uvOffset, float2(0.0), float2(1.0));
    return texture0.sample(linearSampler, uv);
}
```

- [ ] **Step 7: Run targeted parallax/executor tests**

```bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPESceneDocumentParserTests -only-testing:LiveWallpaperTests/WPERenderGraphBuilderTests -only-testing:LiveWallpaperTests/WPEMetalRenderExecutorTests
```

Expected: PASS. Existing solidcolor and genericimage tests still pass, proving runtime uniforms and copy shader changes do not regress Phase 2A built-ins.

---

## Task 3: Wire Per-Frame Runtime Uniforms Through `WPEMetalSceneRenderer`

**Files:**
- Modify: `LiveWallpaper/Runtime/WPEMetalSceneRenderer.swift`
- Test: `LiveWallpaperTests/WPEMetalSceneRendererTests.swift`

- [ ] **Step 1: Write failing renderer runtime test**

Add to `LiveWallpaperTests/WPEMetalSceneRendererTests.swift`:

```swift
@Test("Computes runtime uniforms from clock pointer and performance profile during load render")
func computesRuntimeUniformsDuringLoadRender() async throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let fixture = try MetalSceneFixture.solidColorScene()
    defer { fixture.cleanup() }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let date = try #require(DateComponents(
        calendar: calendar,
        timeZone: calendar.timeZone,
        year: 2026,
        month: 5,
        day: 5,
        hour: 12,
        minute: 0,
        second: 0
    ).date)

    let renderer = try WPEMetalSceneRenderer(
        descriptor: fixture.descriptor,
        cacheRootURL: fixture.root,
        dependencyMounts: [],
        frame: CGRect(x: 0, y: 0, width: 64, height: 64),
        device: device,
        frameClock: WPEMetalFrameClock(
            loadTime: 100,
            currentMediaTime: { 101.25 },
            currentDate: { date },
            calendar: calendar
        ),
        pointerSampler: .fixed(SIMD2<Double>(0.25, 0.75))
    )
    renderer.applyPerformanceProfile(.suspended)

    try await renderer.load()

    let uniforms = try #require(renderer.lastRuntimeUniforms)
    #expect(abs(uniforms.time - 1.25) < 0.0001)
    #expect(abs(uniforms.daytime - 0.5) < 0.0001)
    #expect(uniforms.brightness == 0)
    #expect(uniforms.pointerPosition == SIMD2<Double>(0.25, 0.75))
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPEMetalSceneRendererTests
```

Expected: FAIL because `WPEMetalSceneRenderer` has no injected `frameClock`, no `pointerSampler`, and no `lastRuntimeUniforms`.

- [ ] **Step 3: Add runtime state properties and initializer dependencies**

Modify `LiveWallpaper/Runtime/WPEMetalSceneRenderer.swift` stored properties:

```swift
private var outputTexture: MTLTexture?
private var loadedTextures: [String: MTLTexture] = [:]
private var sceneRenderSize: CGSize = CGSize(width: 1, height: 1)
private var cameraUniforms: WPEMetalCameraUniforms = .identity
private var frameClock: WPEMetalFrameClock
private let pointerSampler: WPEMetalPointerSampler
private(set) var lastRuntimeUniforms: WPEMetalRuntimeUniforms?
```

Update the initializer signature and assignments:

```swift
init(
    descriptor: SceneDescriptor,
    cacheRootURL: URL,
    dependencyMounts: [WPEAssetMount],
    frame: CGRect,
    device: MTLDevice,
    frameClock: WPEMetalFrameClock = WPEMetalFrameClock(),
    pointerSampler: WPEMetalPointerSampler = .live
) throws {
    self.descriptor = descriptor
    self.cacheRootURL = cacheRootURL
    self.dependencyMounts = dependencyMounts
    self.entryResolver = SceneResourceResolver(cacheRootURL: cacheRootURL)
    self.resourceResolver = WPEMultiRootResourceResolver(
        primaryRootURL: cacheRootURL,
        dependencyMounts: dependencyMounts
    )
    self.executor = try WPEMetalRenderExecutor(device: device)
    self.textureLoader = WPEMetalTextureLoader(device: device)
    self.mtkView = MTKView(frame: frame, device: device)
    self.frameClock = frameClock
    self.pointerSampler = pointerSampler
    super.init()

    mtkView.delegate = self
    mtkView.colorPixelFormat = WPEMetalRenderExecutor.outputPixelFormat
    mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    mtkView.preferredFramesPerSecond = SceneRenderingController.defaultPreferredFPS
    mtkView.autoresizingMask = [.width, .height]
    mtkView.enableSetNeedsDisplay = false
    mtkView.isPaused = true
}
```

- [ ] **Step 4: Render through runtime uniforms during load**

Replace the render section of `performLoad()`:

```swift
renderGraph = graph
renderPipeline = pipeline
cameraUniforms = WPEMetalCameraUniforms(
    orthogonalProjection: document.general.orthogonalProjection,
    sceneCamera: document.camera
)
sceneRenderSize = cameraUniforms.renderSize

onProgress?("Loading textures")
loadedTextures = try await loadTextures(for: pipeline)

onProgress?("Rendering scene")
outputTexture = try renderCurrentFrame()
hasPresentedFrame = true
didLoad = true
applyPerformanceProfile(currentProfile)
mtkView.setNeedsDisplay(mtkView.bounds)
```

Add this helper:

```swift
private func renderCurrentFrame() throws -> MTLTexture {
    guard let pipeline = renderPipeline else {
        throw WPEMetalRenderExecutorError.noRenderablePasses
    }
    let uniforms = frameClock.runtimeUniforms(
        profile: currentProfile,
        pointerPosition: pointerSampler.sample(mtkView)
    )
    lastRuntimeUniforms = uniforms
    return try executor.render(
        pipeline: pipeline,
        size: sceneRenderSize,
        textures: loadedTextures,
        runtimeUniforms: uniforms,
        cameraUniforms: cameraUniforms
    )
}
```

- [ ] **Step 5: Refresh render output in `draw(in:)`**

Replace `draw(in:)`:

```swift
nonisolated func draw(in view: MTKView) {
    MainActor.assumeIsolated { [weak self] in
        guard let self, didLoad else { return }
        do {
            outputTexture = try renderCurrentFrame()
            guard let outputTexture else { return }
            if try executor.present(texture: outputTexture, in: view) {
                SystemMonitor.shared.tickFrame()
            }
        } catch {
            Logger.warning("Experimental Metal scene present failed: \(error.localizedDescription)", category: .screenManager)
        }
    }
}
```

Update lifecycle reset points in `reload()` and `cleanup()`:

```swift
loadedTextures = [:]
sceneRenderSize = CGSize(width: 1, height: 1)
cameraUniforms = .identity
lastRuntimeUniforms = nil
```

Update `applyPerformanceProfile(_:)` for continuous drawing under quality:

```swift
func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
    currentProfile = profile
    switch profile {
    case .quality:
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
        mtkView.preferredFramesPerSecond = isThrottled
            ? SceneRenderingController.throttledPreferredFPS
            : SceneRenderingController.defaultPreferredFPS
    case .suspended:
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = true
        mtkView.releaseDrawables()
    }
}
```

- [ ] **Step 6: Run targeted renderer runtime test**

```bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPEMetalSceneRendererTests
```

Expected: PASS. The new runtime-uniform test verifies clock, daytime, brightness, and pointer values are computed once during the render call.

---

## Task 4: Move Texture Uploads To A Bounded Off-Main Queue

**Files:**
- Create: `LiveWallpaper/Infrastructure/WPEMetalTextureUploadQueue.swift`
- Modify: `LiveWallpaper/Infrastructure/WPEMetalTextureLoader.swift`
- Modify: `LiveWallpaper/Runtime/WPEMetalSceneRenderer.swift`
- Test: `LiveWallpaperTests/WPEMetalTextureLoaderTests.swift`
- Test: `LiveWallpaperTests/WPEMetalSceneRendererTests.swift`

- [ ] **Step 1: Write failing off-main upload tests**

Add to `LiveWallpaperTests/WPEMetalTextureLoaderTests.swift`:

```swift
@Test("Payload upload runs on the dedicated upload queue instead of the main thread")
@MainActor
func payloadUploadRunsOffMainThread() async throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let recorder = UploadThreadRecorder()
    let queue = WPEMetalTextureUploadQueue(
        label: "test.livewallpaper.upload.off-main",
        maxConcurrentUploads: 1,
        didStartUpload: { isMainThread in
            recorder.append(isMainThread)
        }
    )
    let loader = WPEMetalTextureLoader(device: device, uploadQueue: queue)
    let payload = WPETexTexturePayload(
        info: WPETexInfo(
            containerVersion: 5,
            infoVersion: 1,
            width: 2,
            height: 2,
            textureFormatCode: WPETexFormat.rgba8888.rawValue,
            format: .rgba8888,
            mipmapCount: 1,
            flags: 0
        ),
        mipmaps: [
            WPETexTextureMipmap(
                index: 0,
                width: 2,
                height: 2,
                bytes: Data([
                    255, 0, 0, 255,
                    0, 255, 0, 255,
                    0, 0, 255, 255,
                    255, 255, 255, 255
                ])
            )
        ],
        hasAnimationFrames: false
    )

    let texture = try await loader.makeTexture(from: payload, label: "test-rgba-off-main")

    #expect(texture.width == 2)
    #expect(recorder.snapshot() == [false])
}

@Test("Upload queue semaphore bounds concurrent upload operations")
func uploadQueueSemaphoreBoundsConcurrency() async throws {
    let probe = UploadConcurrencyProbe()
    let queue = WPEMetalTextureUploadQueue(
        label: "test.livewallpaper.upload.semaphore",
        maxConcurrentUploads: 1
    )

    async let first: Void = queue.perform {
        probe.enter()
        Thread.sleep(forTimeInterval: 0.05)
        probe.leave()
    }
    async let second: Void = queue.perform {
        probe.enter()
        Thread.sleep(forTimeInterval: 0.05)
        probe.leave()
    }

    try await first
    try await second

    #expect(probe.maximumConcurrentUploads == 1)
}

private final class UploadThreadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []

    func append(_ value: Bool) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [Bool] {
        lock.lock()
        let current = values
        lock.unlock()
        return current
    }
}

private final class UploadConcurrencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var activeUploads = 0
    private var maximum = 0

    var maximumConcurrentUploads: Int {
        lock.lock()
        let value = maximum
        lock.unlock()
        return value
    }

    func enter() {
        lock.lock()
        activeUploads += 1
        maximum = max(maximum, activeUploads)
        lock.unlock()
    }

    func leave() {
        lock.lock()
        activeUploads -= 1
        lock.unlock()
    }
}
```

Update existing texture loader tests to call async APIs:

```swift
let texture = try await WPEMetalTextureLoader(device: device).makeTexture(from: payload, label: "test-rgba")
```

Add to `LiveWallpaperTests/WPEMetalSceneRendererTests.swift`:

```swift
@Test("Loads TEX payload textures through async upload path")
func loadsTexPayloadTexturesThroughAsyncUploadPath() async throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let fixture = try MetalSceneFixture.materialTextureScene(color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    defer { fixture.cleanup() }

    let renderer = try WPEMetalSceneRenderer(
        descriptor: fixture.descriptor,
        cacheRootURL: fixture.root,
        dependencyMounts: [],
        frame: CGRect(x: 0, y: 0, width: 64, height: 64),
        device: device
    )

    try await renderer.load()

    #expect(renderer.renderedTexture != nil)
    #expect(renderer.hasPresentedFrame)
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPEMetalTextureLoaderTests -only-testing:LiveWallpaperTests/WPEMetalSceneRendererTests
```

Expected: FAIL because `WPEMetalTextureUploadQueue` and async loader methods do not exist.

- [ ] **Step 3: Add upload queue**

Create `LiveWallpaper/Infrastructure/WPEMetalTextureUploadQueue.swift`:

```swift
import Foundation

final class WPEMetalTextureUploadQueue: @unchecked Sendable {
    static let shared = WPEMetalTextureUploadQueue(
        label: "com.livewallpaper.wpe-metal.texture-upload",
        maxConcurrentUploads: max(1, min(2, ProcessInfo.processInfo.activeProcessorCount / 2))
    )

    private let queue: DispatchQueue
    private let semaphore: DispatchSemaphore
    private let didStartUpload: (@Sendable (Bool) -> Void)?

    init(
        label: String,
        maxConcurrentUploads: Int,
        didStartUpload: (@Sendable (Bool) -> Void)? = nil
    ) {
        self.queue = DispatchQueue(label: label, qos: .userInitiated, attributes: .concurrent)
        self.semaphore = DispatchSemaphore(value: max(maxConcurrentUploads, 1))
        self.didStartUpload = didStartUpload
    }

    func perform<T>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.semaphore.wait()
                defer { self.semaphore.signal() }
                self.didStartUpload?(Thread.isMainThread)
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
```

- [ ] **Step 4: Convert Metal texture loader to async upload APIs**

Modify `LiveWallpaper/Infrastructure/WPEMetalTextureLoader.swift`:

```swift
import CoreGraphics
import Metal
import MetalKit

struct WPEMetalTextureLoader {
    private let device: MTLDevice
    private let capabilities: WPEMetalTextureCapabilities
    private let uploadQueue: WPEMetalTextureUploadQueue

    init(
        device: MTLDevice,
        capabilities: WPEMetalTextureCapabilities? = nil,
        uploadQueue: WPEMetalTextureUploadQueue = .shared
    ) {
        self.device = device
        self.capabilities = capabilities ?? WPEMetalTextureCapabilities(device: device)
        self.uploadQueue = uploadQueue
    }

    func makeTexture(from payload: WPETexTexturePayload, label: String) async throws -> MTLTexture {
        try await uploadQueue.perform {
            try makeTextureSynchronously(from: payload, label: label)
        }
    }

    func makeTexture(from image: DecodedRGBAImage, label: String) async throws -> MTLTexture {
        let payload = WPETexTexturePayload(
            info: WPETexInfo(
                containerVersion: 0,
                infoVersion: 0,
                width: image.width,
                height: image.height,
                textureFormatCode: WPETexFormat.rgba8888.rawValue,
                format: .rgba8888,
                mipmapCount: 1,
                flags: 0
            ),
            mipmaps: [
                WPETexTextureMipmap(
                    index: 0,
                    width: image.width,
                    height: image.height,
                    bytes: image.pixels
                )
            ],
            hasAnimationFrames: false
        )
        return try await makeTexture(from: payload, label: label)
    }

    func makeTexture(from cgImage: CGImage, label: String) async throws -> MTLTexture {
        try await uploadQueue.perform {
            let loader = MTKTextureLoader(device: device)
            do {
                let texture = try loader.newTexture(
                    cgImage: cgImage,
                    options: [
                        MTKTextureLoader.Option.SRGB: true,
                        MTKTextureLoader.Option.textureUsage: MTLTextureUsage.shaderRead.rawValue
                    ]
                )
                texture.label = label
                return texture
            } catch {
                throw WPEMetalTextureLoaderError.malformedPayload(error.localizedDescription)
            }
        }
    }

    private func makeTextureSynchronously(from payload: WPETexTexturePayload, label: String) throws -> MTLTexture {
        guard let format = payload.info.format else {
            throw WPEMetalTextureLoaderError.malformedPayload("unknown texture format \(payload.info.textureFormatCode)")
        }
        guard let mip = payload.largestMipmap else {
            throw WPEMetalTextureLoaderError.malformedPayload("missing mipmap")
        }

        let mapping = try WPEMetalTextureFormatMapper.mapping(for: format, capabilities: capabilities)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: mapping.pixelFormat,
            width: mip.width,
            height: mip.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw WPEMetalTextureLoaderError.textureAllocationFailed
        }
        texture.label = label

        let expected = format.expectedByteCount(width: mip.width, height: mip.height)
        guard mip.bytes.count >= expected else {
            throw WPEMetalTextureLoaderError.malformedPayload(
                "mip bytes \(mip.bytes.count) smaller than expected \(expected)"
            )
        }
        let bytesPerRow = try Self.bytesPerRow(width: mip.width, mapping: mapping)

        mip.bytes.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegionMake2D(0, 0, mip.width, mip.height),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: bytesPerRow
            )
        }
        return texture
    }

    private static func bytesPerRow(width: Int, mapping: WPEMetalTextureFormatMapping) throws -> Int {
        if let bytesPerPixel = mapping.bytesPerPixel {
            return width * bytesPerPixel
        }
        if let bytesPerBlock = mapping.bytesPerBlock {
            return max((width + 3) / 4, 1) * bytesPerBlock
        }
        throw WPEMetalTextureLoaderError.malformedPayload("missing row-stride information")
    }
}
```

- [ ] **Step 5: Await texture loads in Metal scene renderer**

Change signatures in `LiveWallpaper/Runtime/WPEMetalSceneRenderer.swift`:

```swift
private func loadTextures(for pipeline: WPEPreparedRenderPipeline) async throws -> [String: MTLTexture] {
    var textures: [String: MTLTexture] = [:]
    for layer in pipeline.layers {
        if layer.passes.isEmpty {
            try await loadTexture(
                reference: .image(layer.graphLayer.imagePath),
                layerName: layer.graphLayer.objectName,
                into: &textures
            )
            continue
        }
        for preparedPass in layer.passes {
            for reference in requiredTextureReferences(for: preparedPass) {
                try await loadTexture(
                    reference: reference,
                    layerName: layer.graphLayer.objectName,
                    into: &textures
                )
            }
        }
    }
    return textures
}

private func loadTexture(
    reference: WPETextureReference,
    layerName: String,
    into textures: inout [String: MTLTexture]
) async throws {
    guard let path = externalTexturePath(for: reference), textures[path] == nil else {
        return
    }
    do {
        textures[path] = try await makeTexture(relativePath: path, label: "WPE texture \(path)")
    } catch {
        throw WPEMetalTextureLoadContextError(layerName: layerName, path: path, underlying: error)
    }
}

private func makeTexture(relativePath: String, label: String) async throws -> MTLTexture {
    var lastError: Error?
    for candidate in textureCandidates(for: relativePath) {
        do {
            if shouldTryTexturePayload(candidate) {
                do {
                    let payload = try resourceResolver.resolveTexturePayload(relativePath: candidate)
                    return try await textureLoader.makeTexture(from: payload, label: label)
                } catch {
                    lastError = error
                }
            }
            let image = try resourceResolver.resolveImage(relativePath: candidate)
            return try await textureLoader.makeTexture(from: image, label: label)
        } catch {
            lastError = error
        }
    }
    throw lastError ?? WPEMetalRenderExecutorError.missingTexture(.image(relativePath))
}
```

The `performLoad()` call site must be:

```swift
loadedTextures = try await loadTextures(for: pipeline)
```

- [ ] **Step 6: Run targeted upload tests**

```bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPEMetalTextureLoaderTests -only-testing:LiveWallpaperTests/WPEMetalSceneRendererTests
```

Expected: PASS. The upload queue test records `false` for `Thread.isMainThread`, and the semaphore test records a maximum concurrency of `1`.

---

## Task 5: Read Back Metal Preview Snapshot And Use It In Detail View

**Files:**
- Create: `LiveWallpaper/Infrastructure/WPEMetalTextureSnapshotter.swift`
- Modify: `LiveWallpaper/Runtime/WPEMetalSceneRenderer.swift`
- Modify: `LiveWallpaper/Views/ScreenDetail/WPESceneDetailView.swift`
- Test: `LiveWallpaperTests/WPEMetalSceneRendererTests.swift`
- Test: `LiveWallpaperTests/WPESceneRendererBoundaryTests.swift`

- [ ] **Step 1: Write failing snapshot tests**

Add to `LiveWallpaperTests/WPEMetalSceneRendererTests.swift`:

```swift
@Test("Loads preview snapshot from Metal offscreen output")
func loadsPreviewSnapshotFromMetalOutput() async throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let fixture = try MetalSceneFixture.solidColorScene()
    defer { fixture.cleanup() }

    let renderer = try WPEMetalSceneRenderer(
        descriptor: fixture.descriptor,
        cacheRootURL: fixture.root,
        dependencyMounts: [],
        frame: CGRect(x: 0, y: 0, width: 64, height: 64),
        device: device
    )

    try await renderer.load()

    let snapshot = try #require(renderer.previewSnapshot)
    #expect(snapshot.size.width == 64)
    #expect(snapshot.size.height == 64)

    let pixel = try #require(snapshot.centerPixel())
    #expect(pixel.r >= 200)
    #expect(pixel.g <= 20)
    #expect(pixel.b <= 20)
}

private extension NSImage {
    func centerPixel() -> MetalPixel? {
        var proposed = CGRect(origin: .zero, size: size)
        guard let cgImage = cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
            return nil
        }

        var bytes = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &bytes,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.draw(
            cgImage,
            in: CGRect(
                x: -CGFloat(cgImage.width / 2),
                y: -CGFloat(cgImage.height / 2),
                width: CGFloat(cgImage.width),
                height: CGFloat(cgImage.height)
            )
        )
        return MetalPixel(r: bytes[0], g: bytes[1], b: bytes[2], a: bytes[3])
    }
}
```

Add to `LiveWallpaperTests/WPESceneRendererBoundaryTests.swift`:

```swift
@Test("Detail state uses Metal preview snapshot instead of preview unavailable")
func detailStateUsesMetalSnapshotInsteadOfPreviewUnavailable() {
    let snapshot = NSImage(size: CGSize(width: 32, height: 18))
    let renderer = FakeSceneRenderer()
    renderer.hasPresentedFrame = true
    renderer.previewSnapshot = snapshot

    let window = NSWindow(
        contentRect: CGRect(x: 0, y: 0, width: 64, height: 64),
        styleMask: [],
        backing: .buffered,
        defer: false
    )
    let session = SceneWallpaperSession(window: window, renderer: renderer)

    let state = SceneRenderStateResolver.state(
        session: session,
        reduceMotion: false
    )

    if case .playingSnapshot(let image) = state {
        #expect(image === snapshot)
    } else {
        Issue.record("Expected .playingSnapshot, got \(state)")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPEMetalSceneRendererTests -only-testing:LiveWallpaperTests/WPESceneRendererBoundaryTests
```

Expected: FAIL because `WPEMetalTextureSnapshotter`, `WPEMetalSceneRenderer.previewSnapshot`, `SceneRenderStateResolver`, and `.playingSnapshot` do not exist.

- [ ] **Step 3: Add Metal texture snapshotter**

Create `LiveWallpaper/Infrastructure/WPEMetalTextureSnapshotter.swift`:

```swift
import AppKit
import Metal

final class WPEMetalTextureSnapshotter: @unchecked Sendable {
    static let shared = WPEMetalTextureSnapshotter()

    private let queue: DispatchQueue

    init(label: String = "com.livewallpaper.wpe-metal.snapshot-readback") {
        self.queue = DispatchQueue(label: label, qos: .utility)
    }

    func snapshot(from texture: MTLTexture) async -> NSImage? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: Self.makeImage(from: texture))
            }
        }
    }

    private static func makeImage(from texture: MTLTexture) -> NSImage? {
        guard texture.width > 0, texture.height > 0 else {
            return nil
        }
        guard texture.pixelFormat == .rgba8Unorm || texture.pixelFormat == .rgba8Unorm_srgb else {
            return nil
        }

        let bytesPerPixel = 4
        let bytesPerRow = texture.width * bytesPerPixel
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        texture.getBytes(
            &bytes,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height),
            mipmapLevel: 0
        )

        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else {
            return nil
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let cgImage = CGImage(
            width: texture.width,
            height: texture.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            return nil
        }

        return NSImage(
            cgImage: cgImage,
            size: CGSize(width: texture.width, height: texture.height)
        )
    }
}
```

- [ ] **Step 4: Cache snapshot in Metal scene renderer**

Modify `LiveWallpaper/Runtime/WPEMetalSceneRenderer.swift` stored properties and initializer:

```swift
private let snapshotter: WPEMetalTextureSnapshotter
private(set) var previewSnapshot: NSImage?
```

```swift
init(
    descriptor: SceneDescriptor,
    cacheRootURL: URL,
    dependencyMounts: [WPEAssetMount],
    frame: CGRect,
    device: MTLDevice,
    frameClock: WPEMetalFrameClock = WPEMetalFrameClock(),
    pointerSampler: WPEMetalPointerSampler = .live,
    snapshotter: WPEMetalTextureSnapshotter = .shared
) throws {
    self.descriptor = descriptor
    self.cacheRootURL = cacheRootURL
    self.dependencyMounts = dependencyMounts
    self.entryResolver = SceneResourceResolver(cacheRootURL: cacheRootURL)
    self.resourceResolver = WPEMultiRootResourceResolver(
        primaryRootURL: cacheRootURL,
        dependencyMounts: dependencyMounts
    )
    self.executor = try WPEMetalRenderExecutor(device: device)
    self.textureLoader = WPEMetalTextureLoader(device: device)
    self.mtkView = MTKView(frame: frame, device: device)
    self.frameClock = frameClock
    self.pointerSampler = pointerSampler
    self.snapshotter = snapshotter
    super.init()

    mtkView.delegate = self
    mtkView.colorPixelFormat = WPEMetalRenderExecutor.outputPixelFormat
    mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    mtkView.preferredFramesPerSecond = SceneRenderingController.defaultPreferredFPS
    mtkView.autoresizingMask = [.width, .height]
    mtkView.enableSetNeedsDisplay = false
    mtkView.isPaused = true
}
```

After `outputTexture = try renderCurrentFrame()` in `performLoad()`:

```swift
if let outputTexture {
    previewSnapshot = await snapshotter.snapshot(from: outputTexture)
}
```

Reset snapshot in `reload()` and `cleanup()`:

```swift
previewSnapshot = nil
```

- [ ] **Step 5: Add Metal snapshot state to detail view**

Modify `LiveWallpaper/Views/ScreenDetail/WPESceneDetailView.swift` preview switch:

```swift
case .playing(let controller):
    // SpriteKit retains the existing 16:9 layout frame; SKView scales the
    // scene inside this container.
    ScenePreviewContainer(controller: controller)
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
case .playingSnapshot(let image):
    // Metal snapshot honours the rendered texture's intrinsic ratio so a
    // square or portrait orthogonal projection is not letterboxed inside a
    // 16:9 box. See UX & Frontend Spec §1 (Aspect Ratio and Frame Fit).
    MetalSnapshotPreview(image: image)
```

Update paused rendering to prefer a snapshot when no SpriteKit controller exists:

```swift
case .paused(let reason):
    if let controller = session?.sceneController {
        ScenePreviewContainer(controller: controller)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay(pausedOverlay(reason: reason))
    } else if let image = session?.sceneRenderer?.previewSnapshot {
        MetalSnapshotPreview(image: image)
            .overlay(pausedOverlay(reason: reason))
    } else {
        fallbackBackground
            .overlay(pausedOverlay(reason: reason))
    }
```

Define `MetalSnapshotPreview` per the UX & Frontend Spec §1 view-hierarchy block:

```swift
@MainActor
private struct MetalSnapshotPreview: View {
    let image: NSImage

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.medium)
            .aspectRatio(contentMode: .fit)
            .background(Color(nsColor: .controlBackgroundColor))
            .accessibilityLabel("Scene preview snapshot")
            .accessibilityAddTraits(.updatesFrequently)
            .transition(.opacity)
    }
}
```

The 1 fps polling timer that refreshes `session.sceneRenderer?.previewSnapshot`
lives in `WPESceneDetailView` and is gated by both window visibility and
`@Environment(\.accessibilityReduceMotion)`; see the spec for the
reduce-motion override.

Replace the state derivation body with a resolver call:

```swift
private func refreshState() async {
    state = SceneRenderStateResolver.state(
        session: session,
        reduceMotion: reduceMotion
    )
}
```

Add the resolver near the state machine declarations:

```swift
@MainActor
enum SceneRenderStateResolver {
    static func state(
        session: SceneWallpaperSession?,
        reduceMotion: Bool
    ) -> SceneRenderState {
        guard let session else {
            return .error(.unsupportedType)
        }
        if let error = session.loadError {
            return .error(WPESceneDetailView.fallbackReason(for: error))
        }
        guard let renderer = session.sceneRenderer else {
            return .idle
        }
        if !renderer.hasPresentedFrame {
            return .loading(progress: session.loadProgress)
        }

        renderer.applyPerformanceProfile(reduceMotion ? .suspended : .quality)

        if reduceMotion || session.isThrottled {
            return .paused(reason: reduceMotion ? .reduceMotion : .throttled)
        }
        if let controller = session.sceneController {
            return .playing(controller)
        }
        if let snapshot = renderer.previewSnapshot {
            return .playingSnapshot(snapshot)
        }
        return .loading(progress: session.loadProgress)
    }
}
```

Add a helper because `mapToFallbackReason(_:)` is currently instance-scoped:

```swift
static func fallbackReason(for error: SceneRenderingError) -> FallbackReason {
    switch error {
    case .cacheRootMissing, .entryFileMissing:
        return .sceneResourceMissing
    case .parseFailed(let detail):
        return .sceneParseFailed(detail)
    case .unsupportedShader:
        return .sceneShaderUnsupported
    case .noRenderableObjects:
        return .sceneResourceMissing
    case .resourceFailed(let diagnostic):
        return fallbackReason(for: diagnostic)
    }
}
```

Update `SceneRenderState`:

```swift
enum SceneRenderState: Equatable {
    case idle
    case loading(progress: String?)
    case playing(SceneRenderingController)
    case playingSnapshot(NSImage)
    case paused(reason: PausedReason)
    case error(FallbackReason)

    static var loading: SceneRenderState { .loading(progress: nil) }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    static func == (lhs: SceneRenderState, rhs: SceneRenderState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.loading(let l), .loading(let r)): return l == r
        case (.playing(let lhsCtrl), .playing(let rhsCtrl)): return lhsCtrl === rhsCtrl
        case (.playingSnapshot(let lhsImage), .playingSnapshot(let rhsImage)): return lhsImage === rhsImage
        case (.paused(let l), .paused(let r)): return l == r
        case (.error(let l), .error(let r)): return l == r
        default: return false
        }
    }
}
```

Update `stateKey`, `stateLabel`, and `stateAccessibilityText` so `.playingSnapshot` maps to the same user-facing state as `.playing`.

- [ ] **Step 6: Run targeted snapshot/detail tests**

```bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPEMetalSceneRendererTests -only-testing:LiveWallpaperTests/WPESceneRendererBoundaryTests
```

Expected: PASS. Metal renderer exposes a nonblank `NSImage`, and detail state resolves to `.playingSnapshot` instead of `.paused(.previewUnavailable)`.

---

## Task 6: Attribute Metal Texture Diagnostics To WPE Layer Names

**Files:**
- Modify: `LiveWallpaper/Runtime/WPEMetalSceneRenderer.swift`
- Test: `LiveWallpaperTests/WPEMetalSceneRendererTests.swift`

- [ ] **Step 1: Write failing diagnostic attribution test**

Add to `LiveWallpaperTests/WPEMetalSceneRendererTests.swift`:

```swift
@Test("Texture load diagnostics use the WPE object name that referenced the texture")
func textureLoadDiagnosticsUseLayerObjectName() async throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let fixture = try MetalSceneFixture.missingTextureScene()
    defer { fixture.cleanup() }

    let renderer = try WPEMetalSceneRenderer(
        descriptor: fixture.descriptor,
        cacheRootURL: fixture.root,
        dependencyMounts: [],
        frame: CGRect(x: 0, y: 0, width: 64, height: 64),
        device: device
    )

    await #expect(throws: (any Error).self) {
        try await renderer.load()
    }

    let diagnostic = try #require(renderer.loadDiagnostics)
    if case .fileMissing(let layer, let path) = diagnostic {
        #expect(layer == "Hero Layer")
        #expect(path == "materials/missing.png")
    } else {
        Issue.record("Expected .fileMissing diagnostic, got \(diagnostic)")
    }
}
```

Add this fixture to `MetalSceneFixture`:

```swift
static func missingTextureScene() throws -> MetalSceneFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WPEMetalSceneRenderer-\(UUID().uuidString)", isDirectory: true)
    let models = root.appendingPathComponent("models", isDirectory: true)
    let materials = root.appendingPathComponent("materials", isDirectory: true)
    try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: materials, withIntermediateDirectories: true)

    try Data(#"{ "material": "materials/missing-material.json" }"#.utf8)
        .write(to: models.appendingPathComponent("hero.json"))
    try Data(#"{ "passes": [{ "shader": "genericimage2", "textures": ["materials/missing.png"] }] }"#.utf8)
        .write(to: materials.appendingPathComponent("missing-material.json"))

    let scene = """
    {
      "camera": { "center": "0 0 0" },
      "general": { "orthogonalprojection": { "width": 64, "height": 64, "auto": true } },
      "objects": [{
        "id": "hero",
        "name": "Hero Layer",
        "type": "image",
        "image": "models/hero.json",
        "origin": "0.5 0.5 0",
        "scale": "1 1 1",
        "alpha": 1
      }]
    }
    """
    try Data(scene.utf8).write(to: root.appendingPathComponent("scene.json"))

    return MetalSceneFixture(
        root: root,
        descriptor: SceneDescriptor(
            workshopID: UUID().uuidString,
            cacheRelativePath: "wpe-cache/test",
            entryFile: "scene.json",
            capabilityTier: .imageOnly
        ),
        dependencyRoot: nil
    )
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPEMetalSceneRendererTests
```

Expected: FAIL because `WPEMetalSceneRenderer.diagnostic(for:)` still hardcodes `layer = "scene"`.

- [ ] **Step 3: Carry layer context through texture load errors**

Modify the private context error in `LiveWallpaper/Runtime/WPEMetalSceneRenderer.swift`:

```swift
private struct WPEMetalTextureLoadContextError: Error {
    let layerName: String
    let path: String
    let underlying: any Error
}
```

Ensure the `loadTexture` helper from Task 4 throws the layer-aware error:

```swift
throw WPEMetalTextureLoadContextError(layerName: layerName, path: path, underlying: error)
```

- [ ] **Step 4: Replace hardcoded diagnostic layer when context is available**

Replace the diagnostic helpers in `LiveWallpaper/Runtime/WPEMetalSceneRenderer.swift`:

```swift
private func diagnostic(for error: Error) -> SceneLoadDiagnostic {
    diagnostic(for: error, fallbackPath: nil, layerName: "scene")
}

private func diagnostic(
    for error: Error,
    fallbackPath: String?,
    layerName: String
) -> SceneLoadDiagnostic {
    switch error {
    case let context as WPEMetalTextureLoadContextError:
        return diagnostic(
            for: context.underlying,
            fallbackPath: context.path,
            layerName: context.layerName
        )
    case let executorError as WPEMetalRenderExecutorError:
        switch executorError {
        case .unsupportedShader(let name):
            return .materialUnresolved(
                layer: layerName,
                reason: "Shader \"\(name)\" is not supported by the Metal renderer yet."
            )
        case .unsupportedTarget:
            return .materialUnresolved(
                layer: layerName,
                reason: "This wallpaper uses an unsupported rendering target."
            )
        case .missingTexture(let reference):
            switch reference {
            case .image(let path), .asset(let path), .fbo(let path):
                return .fileMissing(layer: layerName, path: path)
            case .previous:
                return .materialUnresolved(
                    layer: layerName,
                    reason: "Previous-frame effects (motion blur, feedback) are not yet supported."
                )
            }
        case .noRenderablePasses:
            return .materialUnresolved(layer: layerName, reason: "Scene contains no renderable passes.")
        case .commandQueueUnavailable, .libraryUnavailable, .pipelineUnavailable, .commandBufferFailed:
            return .other(layer: layerName, message: executorError.errorDescription ?? "Metal renderer failed.")
        }
    case let loaderError as WPEMetalTextureLoaderError:
        switch loaderError {
        case .unsupportedFormat, .unsupportedCompressedFormat, .malformedPayload, .textureAllocationFailed:
            return .other(layer: layerName, message: loaderError.errorDescription ?? "Texture upload failed.")
        }
    case let resolveError as SceneResourceResolver.ResolveError:
        switch resolveError {
        case .fileMissing:
            return .fileMissing(layer: layerName, path: fallbackPath ?? descriptor.entryFile)
        case .pathEscape:
            return .crossPackageReference(layer: layerName, path: fallbackPath ?? descriptor.entryFile)
        case .materialUnresolved(let reason):
            return .materialUnresolved(layer: layerName, reason: reason)
        case .texture(let texError):
            return .texture(layer: layerName, error: texError)
        case .unsupportedTexture:
            return .legacyUnsupportedTexture(layer: layerName)
        case .decodeFailed:
            return .other(layer: layerName, message: "A texture or image file is corrupted and cannot be decoded.")
        }
    default:
        return .other(layer: layerName, message: error.localizedDescription)
    }
}
```

- [ ] **Step 5: Run targeted diagnostic test**

```bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPEMetalSceneRendererTests
```

Expected: PASS. Missing texture diagnostics report the WPE object name in the
`layer:` slot of the `SceneLoadDiagnostic`.

- [ ] **Step 6: Rewrite `SceneLoadDiagnostic.errorDescription` for user-facing copy**

The mapper now feeds the layer name into every diagnostic case, but the
rendered string in `WPESceneDetailView` still reads as engineering shorthand
("Layer Hero Layer: missing asset materials/missing.png"). Update the copy
per UX & Frontend Spec §2 so the message names the layer in plain language
and avoids "texture"/"shader" jargon.

Add to `LiveWallpaperTests/WPEMetalSceneRendererTests.swift`:

```swift
@Test("SceneLoadDiagnostic.errorDescription mentions the layer name in user-facing copy")
func errorDescriptionMentionsLayerName() {
    let diag: SceneLoadDiagnostic = .fileMissing(layer: "Clouds_Back", path: "materials/clouds.png")
    let text = diag.errorDescription
    #expect(text.contains("Clouds_Back"))
    #expect(text.lowercased().contains("missing"))
    #expect(!text.lowercased().contains("texture"))
}
```

Modify `LiveWallpaper/Models/WPESceneErrors.swift`:

```swift
var errorDescription: String {
    switch self {
    case .texture(let layer, _):
        return "The image for '\(layer)' couldn't be loaded."
    case .legacyUnsupportedTexture(let layer):
        return "The image format used by '\(layer)' is no longer supported."
    case .fileMissing(let layer, _):
        return "A file required by the '\(layer)' layer is missing."
    case .crossPackageReference(let layer, _):
        return "The layer '\(layer)' requires files from an external package, which is not supported."
    case .materialUnresolved(let layer, _):
        return "A rendering feature needed by '\(layer)' is not supported yet."
    case .other(let layer, let message):
        return "The layer '\(layer)' encountered an issue: \(message)."
    }
}
```

Note: existing call sites in `WPESceneDetailView.swift` and
`SceneRenderingController.swift` already consume `errorDescription` as a
non-optional `String`. Preserve that signature.

- [ ] **Step 7: Run targeted diagnostic + UI copy test**

```bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPEMetalSceneRendererTests
```

Expected: PASS. Both `textureLoadDiagnosticsUseLayerObjectName` and
`errorDescriptionMentionsLayerName` pass; the rendered string surfaces the
layer's WPE object name and avoids the words "texture" / "shader".

---

## Final Verification

Run all Phase 2B targeted suites:

```bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO \
  -only-testing:LiveWallpaperTests/WPEMetalRuntimeUniformsTests \
  -only-testing:LiveWallpaperTests/WPESceneDocumentParserTests \
  -only-testing:LiveWallpaperTests/WPERenderGraphBuilderTests \
  -only-testing:LiveWallpaperTests/WPEMetalRenderExecutorTests \
  -only-testing:LiveWallpaperTests/WPEMetalTextureLoaderTests \
  -only-testing:LiveWallpaperTests/WPEMetalSceneRendererTests \
  -only-testing:LiveWallpaperTests/WPESceneRendererBoundaryTests
```

Then run the non-UI regression suite:

```bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -skip-testing:LiveWallpaperUITests
```

Expected:

- Phase 2B targeted suites pass on Macs with Metal.
- Metal-only tests use `#require(MTLCreateSystemDefaultDevice())` and skip on machines without Metal.
- Existing Phase 2A solidcolor, genericimage, texture mapping, and renderer boundary tests still pass.
- SpriteKit remains the default scene backend.
- Experimental Metal detail preview shows an `NSImage` snapshot instead of `.previewUnavailable`.
- Texture upload tests prove upload work is off-main and semaphore-bounded.

---

## Main Improvements Delivered By This Plan

- **Runtime uniform parity:** Metal now computes `g_Time`, `g_Daytime`, `g_Brightness`, and `g_PointerPosition` once per render call and merges them into prepared pass uniforms.
- **Camera foundation:** `general.orthogonalprojection` now produces a stable render size and `g_ViewProjectionMatrix` payload for future shader binding.
- **Mouse parallax wiring:** Built-in image copy paths apply a bounded UV offset for layers with non-zero `parallaxDepth`.
- **Main-thread protection:** Texture uploads move to a shared upload queue with a semaphore, preventing large `.tex` payloads from blocking the main actor across displays.
- **Preview honesty:** Metal renderer snapshots its shared RGBA8 output texture into `NSImage`, giving `WPESceneDetailView` a real thumbnail.
- **Diagnostics parity:** Texture failures are attributed to the WPE object name that referenced the missing or invalid texture path.
- **Future unlock:** Phase 2C-2I can rely on runtime uniforms, camera matrix plumbing, upload infrastructure, and layer-aware diagnostics.

## Self-Review

- Spec coverage: all five Phase 2B sub-areas are covered by separate tests and implementation steps.
- In-scope discipline: custom shaders, FBOs, particles, audio, and web compatibility remain deferred.
- TDD coverage: every task starts with failing Swift Testing snippets and an exact `xcodebuild` command before implementation.
- Type consistency: `WPEMetalRuntimeUniforms`, `WPEMetalFrameClock`, `WPEMetalPointerSampler`, `WPEMetalCameraUniforms`, `WPEMetalTextureUploadQueue`, and `WPEMetalTextureSnapshotter` are introduced before later tasks use them.
- Concurrency check: `WPEMetalSceneRenderer` stays `@MainActor`; upload/readback queues are explicit non-actor `DispatchQueue` instances with bounded work.
- Regression check: existing built-in `solidcolor` and `genericimage*` executor paths remain covered by pixel tests.
- Placeholder scan: no task depends on unspecified code, missing file paths, or deferred implementation details.
