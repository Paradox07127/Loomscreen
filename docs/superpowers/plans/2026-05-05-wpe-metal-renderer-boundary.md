# WPE Phase 2A Metal Renderer Boundary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in native Metal WPE scene renderer foundation that can render synthetic WPE solid-color and image-copy material passes offscreen, while SpriteKit remains the production default.

**Architecture:** Phase 2A introduces a non-generic `WPESceneRenderer` boundary, type-erases `SceneWallpaperSession` over SpriteKit and Metal renderers, and adds a Metal executor that consumes the existing `WPERenderGraph` / `WPEPreparedRenderPipeline` IR. Metal execution starts with built-in pass coverage only (`solidcolor`, `genericimage*`, `commands/copy`) plus offscreen pixel tests; custom shader translation, particles, audio uniforms, and dynamic WPE systems stay out of this plan.

**Tech Stack:** Swift 6, AppKit, MetalKit, Metal Shading Language, existing WPE scene/parser/render graph models, Swift Testing, `xcodebuild`.

---

## Suitability Assessment

Phase 2 can start because Phase 1 now makes scene import/restoration honest enough for a renderer switch:

- Object kind parsing, capability classification, transform mapping, and dependency mounts are already hardened.
- `SceneRenderingController` already builds `WPERenderGraph` and `WPEPreparedRenderPipeline`, so Phase 2A can consume existing IR instead of reparsing WPE JSON.
- The previous Phase 2 roadmap is not executable as-is. This plan narrows scope to the renderer boundary and a minimal Metal golden-test loop.
- The old BC "transcoder" framing is technically wrong. Phase 2A introduces native compressed texture mapping for Metal devices that report `supportsBCTextureCompression`; it does not attempt blit-based BC-to-RGBA conversion.

## Scope

### In Scope

- Non-generic renderer protocol: no `associatedtype`.
- `SceneWallpaperSession` stores a type-erased renderer.
- SpriteKit remains default and preserves current behavior.
- Opt-in `.metalExperimental` backend path for tests and future feature flags.
- Metal texture format mapping for WPE RGBA/R/RG and BC1/2/3/7 formats.
- Public `.tex` payload extraction API so Metal can upload raw mip bytes without forcing `CGImage`.
- Minimal Metal executor for:
  - `solidcolor`
  - `genericimage*`
  - `commands/copy`
  - final `.scene` targets
- Offscreen render tests that read pixels back from a `MTLTexture`.

### Out Of Scope

- GLSL-to-MSL custom shader translator.
- Preprocessor combo semantics beyond the already prepared metadata.
- MRT-equivalent effect graphs, multi-pass blur, water, shake, puppet warp.
- Particle emitters/operators/renderers/control points.
- Audio uniforms and sound-object playback.
- HTML/WKWebView WPE JavaScript API shim.
- Replacing SpriteKit default runtime behavior.

---

## File Structure

### New Files

- `LiveWallpaper/Runtime/WPESceneRenderer.swift`
  - Type-erased scene renderer protocol plus backend enum.
- `LiveWallpaper/Infrastructure/WPEMetalTextureFormatMapper.swift`
  - Pure Metal pixel-format mapping and device capability model.
- `LiveWallpaper/Infrastructure/WPEMetalTextureLoader.swift`
  - Uploads `CGImage`, `DecodedRGBAImage`, and extracted `.tex` mip payloads into `MTLTexture`.
- `LiveWallpaper/Runtime/WPEMetalRenderExecutor.swift`
  - Offscreen pass executor for built-in WPE shader coverage.
- `LiveWallpaper/Runtime/WPEMetalSceneRenderer.swift`
  - Runtime `MTKView` wrapper implementing `WPESceneRenderer`.
- `LiveWallpaper/VideoPlayback/WPEMetalBuiltins.metal`
  - Built-in fullscreen vertex/copy/solid-color Metal shaders.
- `LiveWallpaperTests/WPESceneRendererBoundaryTests.swift`
- `LiveWallpaperTests/WPEMetalTextureFormatMapperTests.swift`
- `LiveWallpaperTests/WPETexTexturePayloadTests.swift`
- `LiveWallpaperTests/WPEMetalTextureLoaderTests.swift`
- `LiveWallpaperTests/WPEMetalRenderExecutorTests.swift`
- `LiveWallpaperTests/WPEMetalSceneRendererTests.swift`

### Existing Files To Modify

- `LiveWallpaper/Runtime/SceneRenderingController.swift`
  - Conform to `WPESceneRenderer`.
- `LiveWallpaper/Runtime/SceneWallpaperSession.swift`
  - Store `WPESceneRenderer` instead of `SceneRenderingController`.
- `LiveWallpaper/Runtime/AmbientWallpaperSessionBuilder.swift`
  - Accept `rendererBackend`, route default SpriteKit and opt-in Metal.
- `LiveWallpaper/Views/ScreenDetail/ScenePreviewContainer.swift`
  - Keep SpriteKit preview path typed to `SceneRenderingController`.
- `LiveWallpaper/Views/ScreenDetail/WPESceneDetailView.swift`
  - Use `sceneRenderer` for lifecycle state and `sceneController` only for SpriteKit snapshot preview.
- `LiveWallpaper/Infrastructure/WPETexDecoder.swift`
  - Add raw texture payload extraction for Metal upload.
- `LiveWallpaper/Models/WPETexErrors.swift`
  - Add `WPETexTexturePayload` and typed Metal texture loader errors.
- `LiveWallpaper/Infrastructure/WPETexMetalTranscoder.swift`
  - Replace "transcode" semantics with a compatibility wrapper or remove references from new Metal path.

---

## Task 1: Add A Non-Generic Scene Renderer Boundary

**Files:**
- Create: `LiveWallpaper/Runtime/WPESceneRenderer.swift`
- Modify: `LiveWallpaper/Runtime/SceneRenderingController.swift`
- Modify: `LiveWallpaper/Runtime/SceneWallpaperSession.swift`
- Test: `LiveWallpaperTests/WPESceneRendererBoundaryTests.swift`

- [ ] **Step 1: Write failing boundary tests**

Create `LiveWallpaperTests/WPESceneRendererBoundaryTests.swift`:

```swift
import AppKit
import Testing
@testable import LiveWallpaper

@MainActor
@Suite("WPE scene renderer boundary")
struct WPESceneRendererBoundaryTests {
    @Test("SceneWallpaperSession forwards lifecycle to a type-erased renderer")
    func sessionForwardsLifecycleToTypeErasedRenderer() async throws {
        let renderer = FakeSceneRenderer()
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 64, height: 64), styleMask: [], backing: .buffered, defer: false)
        let session = SceneWallpaperSession(window: window, renderer: renderer)

        session.startLoadIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        session.setThrottled(true)
        session.applyPerformanceProfile(.suspended)
        await session.reload()

        #expect(renderer.loadCallCount == 2)
        #expect(renderer.lastThrottle == true)
        #expect(renderer.lastProfile == .suspended)
        #expect(session.sceneRenderer === renderer)
        #expect(session.sceneController == nil)
    }

    @Test("SpriteKit controller conforms to WPESceneRenderer without losing SKView access")
    func spriteKitControllerConformsToRendererBoundary() throws {
        let fixture = try SceneFixture.singlePNGScene()
        defer { fixture.cleanup() }
        let controller = SceneRenderingController(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            frame: CGRect(x: 0, y: 0, width: 100, height: 100)
        )

        let renderer: WPESceneRenderer = controller

        #expect(renderer.nsView === controller.view)
        #expect(controller.view.frame.size == CGSize(width: 100, height: 100))
    }
}

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

Add a small fixture helper in the same file:

```swift
private struct SceneFixture {
    let root: URL
    let descriptor: SceneDescriptor

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    static func singlePNGScene() throws -> SceneFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPESceneRendererBoundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{ "camera": { "center": "0 0 0" }, "general": { "orthogonalprojection": { "width": 64, "height": 64, "auto": true } }, "objects": [] }"#.utf8)
            .write(to: root.appendingPathComponent("scene.json"))
        return SceneFixture(
            root: root,
            descriptor: SceneDescriptor(
                workshopID: UUID().uuidString,
                cacheRelativePath: "wpe-cache/test",
                entryFile: "scene.json",
                capabilityTier: .imageOnly
            )
        )
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPESceneRendererBoundaryTests
```

Expected: compile failure because `WPESceneRenderer`, `sceneRenderer`, and `SceneWallpaperSession(window:renderer:)` do not exist.

- [ ] **Step 3: Add renderer protocol and backend enum**

Create `LiveWallpaper/Runtime/WPESceneRenderer.swift`:

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

    func load() async throws
    func reload() async throws
    func setThrottled(_ throttled: Bool)
    func cleanup()
}
```

- [ ] **Step 4: Make SpriteKit controller conform**

Modify `SceneRenderingController`:

```swift
@MainActor
final class SceneRenderingController: WPESceneRenderer {
    var nsView: NSView { skView }
    var hasPresentedFrame: Bool { skView.scene != nil }
}
```

Keep existing `var view: SKView { skView }` so `ScenePreviewContainer` keeps compiling.

- [ ] **Step 5: Type-erase SceneWallpaperSession**

Modify `SceneWallpaperSession`:

```swift
private var renderer: WPESceneRenderer?

init(window: NSWindow, controller: SceneRenderingController) {
    self.window = window
    self.renderer = controller
}

init(window: NSWindow, renderer: WPESceneRenderer) {
    self.window = window
    self.renderer = renderer
}

var sceneRenderer: WPESceneRenderer? { renderer }
var sceneController: SceneRenderingController? { renderer as? SceneRenderingController }
```

Replace controller calls:

```swift
renderer?.nsView.frame = CGRect(origin: .zero, size: frame.size)
renderer?.applyPerformanceProfile(currentProfile)
renderer?.setThrottled(throttled)
renderer?.cleanup()
try await renderer.load()
try await renderer.reload()
```

Update progress installation:

```swift
private func installProgressHandler(on renderer: WPESceneRenderer) {
    renderer.onProgress = { [weak self] progress in
        self?.loadProgress = progress
    }
}
```

- [ ] **Step 6: Run targeted test**

```bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPESceneRendererBoundaryTests
```

Expected: `WPESceneRendererBoundaryTests` passes.

---

## Task 2: Replace BC Transcoder Semantics With Metal Texture Format Mapping

**Files:**
- Create: `LiveWallpaper/Infrastructure/WPEMetalTextureFormatMapper.swift`
- Modify: `LiveWallpaper/Infrastructure/WPETexMetalTranscoder.swift`
- Test: `LiveWallpaperTests/WPEMetalTextureFormatMapperTests.swift`
- Test: `LiveWallpaperTests/WPETexMetalTranscoderTests.swift`

- [ ] **Step 1: Write failing format mapper tests**

Create `LiveWallpaperTests/WPEMetalTextureFormatMapperTests.swift`:

```swift
import Metal
import Testing
@testable import LiveWallpaper

@Suite("WPE Metal texture format mapper")
struct WPEMetalTextureFormatMapperTests {
    @Test("Maps CPU-decodable formats to direct Metal pixel formats")
    func mapsUncompressedFormats() throws {
        let capabilities = WPEMetalTextureCapabilities(supportsBCTextureCompression: false)

        #expect(try WPEMetalTextureFormatMapper.mapping(for: .rgba8888, capabilities: capabilities).pixelFormat == .rgba8Unorm)
        #expect(try WPEMetalTextureFormatMapper.mapping(for: .r8, capabilities: capabilities).pixelFormat == .r8Unorm)
        #expect(try WPEMetalTextureFormatMapper.mapping(for: .rg88, capabilities: capabilities).pixelFormat == .rg8Unorm)
    }

    @Test("Maps BC formats to native compressed Metal formats when supported")
    func mapsBCFormatsWhenSupported() throws {
        let capabilities = WPEMetalTextureCapabilities(supportsBCTextureCompression: true)

        #expect(try WPEMetalTextureFormatMapper.mapping(for: .dxt1, capabilities: capabilities).pixelFormat == .bc1_rgba)
        #expect(try WPEMetalTextureFormatMapper.mapping(for: .dxt3, capabilities: capabilities).pixelFormat == .bc2_rgba)
        #expect(try WPEMetalTextureFormatMapper.mapping(for: .dxt5, capabilities: capabilities).pixelFormat == .bc3_rgba)
        #expect(try WPEMetalTextureFormatMapper.mapping(for: .bc7, capabilities: capabilities).pixelFormat == .bc7_rgbaUnorm)
    }

    @Test("Fails closed for BC formats when device support is absent")
    func rejectsBCWhenUnsupported() {
        let capabilities = WPEMetalTextureCapabilities(supportsBCTextureCompression: false)

        #expect(throws: WPEMetalTextureLoaderError.unsupportedCompressedFormat(.bc7)) {
            _ = try WPEMetalTextureFormatMapper.mapping(for: .bc7, capabilities: capabilities)
        }
    }

    @Test("Rejects RGBA1010102 until a concrete sampling path exists")
    func rejectsRGBA1010102() {
        let capabilities = WPEMetalTextureCapabilities(supportsBCTextureCompression: true)

        #expect(throws: WPEMetalTextureLoaderError.unsupportedFormat(.rgba1010102)) {
            _ = try WPEMetalTextureFormatMapper.mapping(for: .rgba1010102, capabilities: capabilities)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPEMetalTextureFormatMapperTests
```

Expected: compile failure because mapper types do not exist.

- [ ] **Step 3: Add mapper implementation**

Create `LiveWallpaper/Infrastructure/WPEMetalTextureFormatMapper.swift`:

```swift
import Metal

struct WPEMetalTextureCapabilities: Equatable, Sendable {
    let supportsBCTextureCompression: Bool

    init(device: MTLDevice) {
        self.supportsBCTextureCompression = device.supportsBCTextureCompression
    }

    init(supportsBCTextureCompression: Bool) {
        self.supportsBCTextureCompression = supportsBCTextureCompression
    }
}

struct WPEMetalTextureFormatMapping: Equatable, Sendable {
    let pixelFormat: MTLPixelFormat
    let bytesPerPixel: Int?
    let bytesPerBlock: Int?
}

enum WPEMetalTextureLoaderError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedFormat(WPETexFormat)
    case unsupportedCompressedFormat(WPETexFormat)
    case malformedPayload(String)
    case textureAllocationFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let format):
            return "WPE Metal texture format is unsupported: \(format.debugLabel)"
        case .unsupportedCompressedFormat(let format):
            return "This Metal device cannot sample \(format.debugLabel) textures."
        case .malformedPayload(let reason):
            return "WPE Metal texture payload is malformed: \(reason)"
        case .textureAllocationFailed:
            return "Metal texture allocation failed."
        }
    }
}

enum WPEMetalTextureFormatMapper {
    static func mapping(
        for format: WPETexFormat,
        capabilities: WPEMetalTextureCapabilities
    ) throws -> WPEMetalTextureFormatMapping {
        switch format {
        case .rgba8888:
            return WPEMetalTextureFormatMapping(pixelFormat: .rgba8Unorm, bytesPerPixel: 4, bytesPerBlock: nil)
        case .r8:
            return WPEMetalTextureFormatMapping(pixelFormat: .r8Unorm, bytesPerPixel: 1, bytesPerBlock: nil)
        case .rg88:
            return WPEMetalTextureFormatMapping(pixelFormat: .rg8Unorm, bytesPerPixel: 2, bytesPerBlock: nil)
        case .dxt1:
            guard capabilities.supportsBCTextureCompression else {
                throw WPEMetalTextureLoaderError.unsupportedCompressedFormat(format)
            }
            return WPEMetalTextureFormatMapping(pixelFormat: .bc1_rgba, bytesPerPixel: nil, bytesPerBlock: 8)
        case .dxt3:
            guard capabilities.supportsBCTextureCompression else {
                throw WPEMetalTextureLoaderError.unsupportedCompressedFormat(format)
            }
            return WPEMetalTextureFormatMapping(pixelFormat: .bc2_rgba, bytesPerPixel: nil, bytesPerBlock: 16)
        case .dxt5:
            guard capabilities.supportsBCTextureCompression else {
                throw WPEMetalTextureLoaderError.unsupportedCompressedFormat(format)
            }
            return WPEMetalTextureFormatMapping(pixelFormat: .bc3_rgba, bytesPerPixel: nil, bytesPerBlock: 16)
        case .bc7:
            guard capabilities.supportsBCTextureCompression else {
                throw WPEMetalTextureLoaderError.unsupportedCompressedFormat(format)
            }
            return WPEMetalTextureFormatMapping(pixelFormat: .bc7_rgbaUnorm, bytesPerPixel: nil, bytesPerBlock: 16)
        case .rgba1010102:
            throw WPEMetalTextureLoaderError.unsupportedFormat(format)
        }
    }
}
```

- [ ] **Step 4: Convert transcoder tests to legacy-bridge tests**

Modify `LiveWallpaperTests/WPETexMetalTranscoderTests.swift` so it asserts the old API is not used for Phase 2A rendering:

```swift
@Test("Legacy transcoder remains unavailable; Phase 2A uses native texture mapping")
func legacyTranscoderRemainsUnavailable() {
    #expect(!WPETexMetalTranscoder.isAvailable(for: .dxt1))
    #expect(!WPETexMetalTranscoder.isAvailable(for: .dxt3))
    #expect(!WPETexMetalTranscoder.isAvailable(for: .dxt5))
    #expect(!WPETexMetalTranscoder.isAvailable(for: .bc7))
}
```

Keep `transcodeBCThrowsMetalUnavailable()` unchanged so SpriteKit CGImage decode remains fail-closed for BC.

- [ ] **Step 5: Run mapper and legacy tests**

```bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPEMetalTextureFormatMapperTests -only-testing:LiveWallpaperTests/WPETexMetalTranscoderTests
```

Expected: both suites pass.

---

## Task 3: Expose Raw TEX Payloads For Metal Upload

**Files:**
- Modify: `LiveWallpaper/Models/WPETexErrors.swift`
- Modify: `LiveWallpaper/Infrastructure/WPETexDecoder.swift`
- Test: `LiveWallpaperTests/WPETexTexturePayloadTests.swift`
- Test: `LiveWallpaperTests/WPETexDecoderTests.swift`

- [ ] **Step 1: Write failing payload extraction tests**

Create `LiveWallpaperTests/WPETexTexturePayloadTests.swift`:

```swift
import Foundation
import Testing
@testable import LiveWallpaper

@Suite("WPETexDecoder texture payload extraction")
struct WPETexTexturePayloadTests {
    @Test("Extracts raw RGBA8888 mip payload without creating CGImage")
    func extractsRGBA8888Payload() throws {
        let payload = Data(repeating: 0xaa, count: 4 * 4 * 4)
        let tex = makeImage(width: 4, height: 4, formatCode: WPETexFormat.rgba8888.rawValue, payload: payload)

        let result = WPETexDecoder().extractTexturePayload(data: tex)

        let extracted = try #require(result.get())
        #expect(extracted.info.format == .rgba8888)
        #expect(extracted.largestMipmap?.bytes == payload)
        #expect(extracted.largestMipmap?.width == 4)
        #expect(extracted.largestMipmap?.height == 4)
    }

    @Test("Extracts BC7 payload for native Metal sampling")
    func extractsBC7Payload() throws {
        let payload = Data(repeating: 0x3f, count: WPETexFormat.bc7.expectedByteCount(width: 4, height: 4))
        let tex = makeImage(width: 4, height: 4, formatCode: WPETexFormat.bc7.rawValue, payload: payload)

        let extracted = try #require(WPETexDecoder().extractTexturePayload(data: tex).get())

        #expect(extracted.info.format == .bc7)
        #expect(extracted.largestMipmap?.bytes == payload)
        #expect(extracted.hasAnimationFrames == false)
    }

    @Test("Rejects MP4-backed TEX payloads for Metal texture upload")
    func rejectsVideoPayload() {
        let tex = makeImage(
            width: 1,
            height: 1,
            formatCode: WPETexFormat.rgba8888.rawValue,
            payload: Data([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70])
        )

        let result = WPETexDecoder().extractTexturePayload(data: tex)

        #expect(throws: WPETexDecodeError.unsupportedAnimation) {
            _ = try result.get()
        }
    }
}
```

Add the same helper functions from `WPETexDecoderTests` to this file: `makeImage`, `appendMagic`, `appendInt32`, and `appendUInt32`.

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPETexTexturePayloadTests
```

Expected: compile failure because `extractTexturePayload` and payload structs do not exist.

- [ ] **Step 3: Add payload value types**

Modify `LiveWallpaper/Models/WPETexErrors.swift`:

```swift
struct WPETexTexturePayload: Sendable, Equatable {
    let info: WPETexInfo
    let mipmaps: [WPETexTextureMipmap]
    let hasAnimationFrames: Bool

    var largestMipmap: WPETexTextureMipmap? {
        mipmaps.first
    }
}

struct WPETexTextureMipmap: Sendable, Equatable {
    let index: Int
    let width: Int
    let height: Int
    let bytes: Data
}
```

- [ ] **Step 4: Add extraction API**

Modify `WPETexDecoder`:

```swift
func extractTexturePayload(data: Data) -> Result<WPETexTexturePayload, WPETexDecodeError> {
    do {
        let parsed = try parse(data: data)
        guard !parsed.bitmap.isVideoPayload else {
            throw WPETexDecodeError.unsupportedAnimation
        }
        guard !parsed.bitmap.usesEncodedImagePayload else {
            throw WPETexDecodeError.unsupportedFormat(parsed.info.textureFormatCode)
        }
        let mipmaps = try parsed.bitmap.mipmaps.map { mipmap in
            WPETexTextureMipmap(
                index: mipmap.index,
                width: mipmap.width,
                height: mipmap.height,
                bytes: try normalizedBytes(for: mipmap, format: parsed.info.format)
            )
        }
        return .success(WPETexTexturePayload(
            info: parsed.info,
            mipmaps: mipmaps,
            hasAnimationFrames: parsed.hasAnimationFrames
        ))
    } catch let error as WPETexDecodeError {
        return .failure(error)
    } catch {
        return .failure(.decodeFailed(mipmap: 0, detail: error.localizedDescription))
    }
}
```

Add helper:

```swift
private func normalizedBytes(for mipmap: WPETexMipmap, format: WPETexFormat?) throws -> Data {
    guard let format else {
        throw WPETexDecodeError.unsupportedFormat(-1)
    }
    let expected = format.expectedByteCount(width: mipmap.width, height: mipmap.height)
    if mipmap.payload.count == expected {
        return mipmap.payload
    }
    if mipmap.payload.count > expected, !mipmap.isCompressed {
        return mipmap.payload.prefix(expected)
    }
    if mipmap.isCompressed {
        return try inflate(mipmap: mipmap, expectedByteCount: expected)
    }
    throw WPETexDecodeError.decodeFailed(
        mipmap: mipmap.index,
        detail: "payload size \(mipmap.payload.count) does not match expected \(expected)"
    )
}
```

Use the decoder's existing LZ4 inflate helper instead of duplicating compression logic.

- [ ] **Step 5: Run payload and decoder tests**

```bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPETexTexturePayloadTests -only-testing:LiveWallpaperTests/WPETexDecoderTests
```

Expected: both suites pass.

---

## Task 4: Implement Metal Texture Upload

**Files:**
- Create: `LiveWallpaper/Infrastructure/WPEMetalTextureLoader.swift`
- Test: `LiveWallpaperTests/WPEMetalTextureLoaderTests.swift`

- [ ] **Step 1: Write failing texture loader tests**

Create `LiveWallpaperTests/WPEMetalTextureLoaderTests.swift`:

```swift
import Metal
import Testing
@testable import LiveWallpaper

@Suite("WPE Metal texture loader")
struct WPEMetalTextureLoaderTests {
    @Test("Uploads RGBA texture payload into an MTLTexture")
    func uploadsRGBA8888Payload() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let bytes = Data([
            255, 0, 0, 255,
            0, 255, 0, 255,
            0, 0, 255, 255,
            255, 255, 255, 255
        ])
        let payload = WPETexTexturePayload(
            info: WPETexInfo(containerVersion: 5, infoVersion: 1, width: 2, height: 2, textureFormatCode: WPETexFormat.rgba8888.rawValue, format: .rgba8888, mipmapCount: 1, flags: 0),
            mipmaps: [WPETexTextureMipmap(index: 0, width: 2, height: 2, bytes: bytes)],
            hasAnimationFrames: false
        )

        let texture = try WPEMetalTextureLoader(device: device).makeTexture(from: payload, label: "test-rgba")

        #expect(texture.width == 2)
        #expect(texture.height == 2)
        #expect(texture.pixelFormat == .rgba8Unorm)
    }

    @Test("Rejects BC payload when current device cannot sample BC")
    func rejectsBCWithoutDeviceSupport() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let payload = WPETexTexturePayload(
            info: WPETexInfo(containerVersion: 5, infoVersion: 1, width: 4, height: 4, textureFormatCode: WPETexFormat.bc7.rawValue, format: .bc7, mipmapCount: 1, flags: 0),
            mipmaps: [WPETexTextureMipmap(index: 0, width: 4, height: 4, bytes: Data(count: 16))],
            hasAnimationFrames: false
        )
        let loader = WPEMetalTextureLoader(
            device: device,
            capabilities: WPEMetalTextureCapabilities(supportsBCTextureCompression: false)
        )

        #expect(throws: WPEMetalTextureLoaderError.unsupportedCompressedFormat(.bc7)) {
            _ = try loader.makeTexture(from: payload, label: "test-bc7")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPEMetalTextureLoaderTests
```

Expected: compile failure because `WPEMetalTextureLoader` does not exist.

- [ ] **Step 3: Add texture loader**

Create `LiveWallpaper/Infrastructure/WPEMetalTextureLoader.swift`:

```swift
import CoreGraphics
import Metal

struct WPEMetalTextureLoader {
    private let device: MTLDevice
    private let capabilities: WPEMetalTextureCapabilities

    init(device: MTLDevice, capabilities: WPEMetalTextureCapabilities? = nil) {
        self.device = device
        self.capabilities = capabilities ?? WPEMetalTextureCapabilities(device: device)
    }

    func makeTexture(from payload: WPETexTexturePayload, label: String) throws -> MTLTexture {
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
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw WPEMetalTextureLoaderError.textureAllocationFailed
        }
        texture.label = label

        let bytesPerRow: Int
        if let bytesPerPixel = mapping.bytesPerPixel {
            bytesPerRow = mip.width * bytesPerPixel
        } else if let bytesPerBlock = mapping.bytesPerBlock {
            bytesPerRow = max((mip.width + 3) / 4, 1) * bytesPerBlock
        } else {
            throw WPEMetalTextureLoaderError.malformedPayload("missing row-stride information")
        }
        let expected = format.expectedByteCount(width: mip.width, height: mip.height)
        guard mip.bytes.count >= expected else {
            throw WPEMetalTextureLoaderError.malformedPayload("mip bytes \(mip.bytes.count) smaller than expected \(expected)")
        }
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
}
```

- [ ] **Step 4: Run texture loader tests**

```bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPEMetalTextureLoaderTests
```

Expected: loader tests pass on Macs with Metal. If `MTLCreateSystemDefaultDevice()` returns nil, Swift Testing reports the device requirement as a skipped requirement.

---

## Task 5: Add Built-In Metal Shaders And Offscreen Executor

**Files:**
- Create: `LiveWallpaper/VideoPlayback/WPEMetalBuiltins.metal`
- Create: `LiveWallpaper/Runtime/WPEMetalRenderExecutor.swift`
- Test: `LiveWallpaperTests/WPEMetalRenderExecutorTests.swift`

- [ ] **Step 1: Write failing offscreen executor tests**

Create `LiveWallpaperTests/WPEMetalRenderExecutorTests.swift`:

```swift
import Metal
import Testing
@testable import LiveWallpaper

@Suite("WPE Metal render executor")
struct WPEMetalRenderExecutorTests {
    @Test("Renders solidcolor pass to offscreen texture")
    func rendersSolidColor() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let pipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(
                graphLayer: graphLayer(pass: solidPass()),
                passes: [WPEPreparedRenderPass(
                    pass: solidPass(),
                    shader: WPEShaderProgram(name: "solidcolor", vertexSource: "", fragmentSource: "", isBuiltin: true),
                    textureBindings: [:],
                    comboValues: [:],
                    uniformValues: ["g_Color": .vector([1, 0, 0, 1])]
                )]
            )
        ])

        let output = try executor.render(pipeline: pipeline, size: CGSize(width: 4, height: 4), textures: [:])
        let pixel = try readPixel(output, x: 2, y: 2)

        #expect(pixel.r >= 250)
        #expect(pixel.g <= 5)
        #expect(pixel.b <= 5)
        #expect(pixel.a >= 250)
    }

    @Test("Fails closed for non-built-in shader programs")
    func rejectsCustomShader() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let pass = WPERenderPass(
            id: "1.0",
            phase: .effect(file: "effects/custom/effect.json"),
            shader: "effects/custom",
            source: .image("materials/base.png"),
            target: .scene,
            textures: [:],
            binds: [:],
            constants: [:],
            combos: [:],
            blending: "normal",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )
        let pipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(
                graphLayer: graphLayer(pass: pass),
                passes: [WPEPreparedRenderPass(
                    pass: pass,
                    shader: WPEShaderProgram(name: "effects/custom", vertexSource: "", fragmentSource: "", isBuiltin: false),
                    textureBindings: [:],
                    comboValues: [:],
                    uniformValues: [:]
                )]
            )
        ])

        #expect(throws: WPEMetalRenderExecutorError.unsupportedShader("effects/custom")) {
            _ = try executor.render(pipeline: pipeline, size: CGSize(width: 4, height: 4), textures: [:])
        }
    }

    @Test("Copies sampled input texture to offscreen output")
    func copiesInputTexture() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let input = try makeRGBAInputTexture(device: device, bytes: Data([
            0, 255, 0, 255,
            0, 255, 0, 255,
            0, 255, 0, 255,
            0, 255, 0, 255
        ]))
        let pass = copyPass()
        let pipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(
                graphLayer: graphLayer(pass: pass),
                passes: [WPEPreparedRenderPass(
                    pass: pass,
                    shader: WPEShaderProgram(name: "genericimage2", vertexSource: "", fragmentSource: "", isBuiltin: true),
                    textureBindings: [0: .image("materials/base.png")],
                    comboValues: [:],
                    uniformValues: [:]
                )]
            )
        ])

        let output = try executor.render(
            pipeline: pipeline,
            size: CGSize(width: 2, height: 2),
            textures: ["materials/base.png": input]
        )
        let pixel = try readPixel(output, x: 1, y: 1)

        #expect(pixel.r <= 5)
        #expect(pixel.g >= 250)
        #expect(pixel.b <= 5)
        #expect(pixel.a >= 250)
    }
}
```

Add helpers in the same test file:

```swift
private struct Pixel {
    let r: UInt8
    let g: UInt8
    let b: UInt8
    let a: UInt8
}

private func readPixel(_ texture: MTLTexture, x: Int, y: Int) throws -> Pixel {
    var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
    texture.getBytes(
        &bytes,
        bytesPerRow: texture.width * 4,
        from: MTLRegionMake2D(0, 0, texture.width, texture.height),
        mipmapLevel: 0
    )
    let index = (y * texture.width + x) * 4
    return Pixel(r: bytes[index], g: bytes[index + 1], b: bytes[index + 2], a: bytes[index + 3])
}

private func solidPass() -> WPERenderPass {
    WPERenderPass(
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
}

private func copyPass() -> WPERenderPass {
    WPERenderPass(
        id: "copy.0",
        phase: .material,
        shader: "genericimage2",
        source: .image("materials/base.png"),
        target: .scene,
        textures: [0: .image("materials/base.png")],
        binds: [:],
        constants: [:],
        combos: [:],
        blending: "normal",
        cullMode: "nocull",
        depthTest: "disabled",
        depthWrite: "disabled"
    )
}

private func makeRGBAInputTexture(device: MTLDevice, bytes: Data) throws -> MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba8Unorm,
        width: 2,
        height: 2,
        mipmapped: false
    )
    descriptor.usage = [.shaderRead]
    let texture = try #require(device.makeTexture(descriptor: descriptor))
    bytes.withUnsafeBytes { raw in
        texture.replace(
            region: MTLRegionMake2D(0, 0, 2, 2),
            mipmapLevel: 0,
            withBytes: raw.baseAddress!,
            bytesPerRow: 8
        )
    }
    return texture
}

private func graphLayer(pass: WPERenderPass) -> WPERenderLayer {
    WPERenderLayer(
        objectID: "layer",
        objectName: "Layer",
        imagePath: "materials/base.png",
        materialPath: nil,
        compositeA: "a",
        compositeB: "b",
        localFBOs: [],
        passes: [pass]
    )
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPEMetalRenderExecutorTests
```

Expected: compile failure because executor types do not exist.

- [ ] **Step 3: Add built-in MSL shaders**

Create `LiveWallpaper/VideoPlayback/WPEMetalBuiltins.metal`:

```metal
#include <metal_stdlib>
using namespace metal;

struct WPEVertexOut {
    float4 position [[position]];
    float2 uv;
};

struct WPESolidUniforms {
    float4 color;
};

vertex WPEVertexOut wpe_fullscreen_vertex(uint vertexID [[vertex_id]]) {
    float2 positions[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0)
    };
    float2 uvs[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0)
    };
    WPEVertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.uv = uvs[vertexID];
    return out;
}

fragment half4 wpe_solidcolor_fragment(
    WPEVertexOut in [[stage_in]],
    constant WPESolidUniforms& uniforms [[buffer(0)]]
) {
    return half4(uniforms.color);
}

fragment half4 wpe_copy_fragment(
    WPEVertexOut in [[stage_in]],
    texture2d<half, access::sample> texture0 [[texture(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    return texture0.sample(linearSampler, in.uv);
}
```

- [ ] **Step 4: Add executor implementation**

Create `LiveWallpaper/Runtime/WPEMetalRenderExecutor.swift`:

```swift
import CoreGraphics
import Metal

enum WPEMetalRenderExecutorError: Error, Equatable, LocalizedError, Sendable {
    case commandQueueUnavailable
    case libraryUnavailable
    case pipelineUnavailable(String)
    case unsupportedShader(String)
    case unsupportedTarget(WPERenderTarget)
    case missingTexture(WPETextureReference)
    case commandBufferFailed

    var errorDescription: String? {
        switch self {
        case .commandQueueUnavailable: return "Metal command queue is unavailable."
        case .libraryUnavailable: return "WPE Metal built-in shader library is unavailable."
        case .pipelineUnavailable(let name): return "WPE Metal pipeline is unavailable for \(name)."
        case .unsupportedShader(let name): return "WPE Metal executor does not support shader \(name)."
        case .unsupportedTarget(let target): return "WPE Metal executor does not support target \(target)."
        case .missingTexture(let reference): return "WPE Metal executor is missing texture \(reference)."
        case .commandBufferFailed: return "WPE Metal command buffer failed."
        }
    }
}

struct WPESolidUniforms {
    var color: SIMD4<Float>
}

final class WPEMetalRenderExecutor {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let library: MTLLibrary
    private var pipelines: [String: MTLRenderPipelineState] = [:]

    init(device: MTLDevice) throws {
        guard let queue = device.makeCommandQueue() else {
            throw WPEMetalRenderExecutorError.commandQueueUnavailable
        }
        guard let library = device.makeDefaultLibrary() else {
            throw WPEMetalRenderExecutorError.libraryUnavailable
        }
        self.device = device
        self.commandQueue = queue
        self.library = library
    }

    func render(
        pipeline: WPEPreparedRenderPipeline,
        size: CGSize,
        textures: [String: MTLTexture]
    ) throws -> MTLTexture {
        let output = try makeOutputTexture(size: size)
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }

        for layer in pipeline.layers {
            for pass in layer.passes {
                try encode(pass: pass, output: output, textures: textures, commandBuffer: commandBuffer)
            }
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if commandBuffer.status == .error {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }
        return output
    }

    private func encode(
        pass: WPEPreparedRenderPass,
        output: MTLTexture,
        textures: [String: MTLTexture],
        commandBuffer: MTLCommandBuffer
    ) throws {
        guard pass.pass.target == .scene else {
            throw WPEMetalRenderExecutorError.unsupportedTarget(pass.pass.target)
        }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = output
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }
        defer { encoder.endEncoding() }

        if pass.pass.shader == "solidcolor" {
            encoder.setRenderPipelineState(try renderPipeline(fragmentName: "wpe_solidcolor_fragment"))
            let vector = pass.uniformValues["g_Color"]?.vectorValue ?? pass.pass.constants["g_Color"]?.vectorValue ?? [1, 1, 1, 1]
            var uniforms = WPESolidUniforms(color: SIMD4<Float>(
                Float(vector[safe: 0] ?? 1),
                Float(vector[safe: 1] ?? 1),
                Float(vector[safe: 2] ?? 1),
                Float(vector[safe: 3] ?? 1)
            ))
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPESolidUniforms>.stride, index: 0)
        } else if pass.pass.shader == "commands/copy" || pass.pass.shader.hasPrefix("genericimage") {
            encoder.setRenderPipelineState(try renderPipeline(fragmentName: "wpe_copy_fragment"))
            let reference = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
            let texture = try resolve(reference: reference, textures: textures)
            encoder.setFragmentTexture(texture, index: 0)
        } else {
            throw WPEMetalRenderExecutorError.unsupportedShader(pass.pass.shader)
        }

        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func renderPipeline(fragmentName: String) throws -> MTLRenderPipelineState {
        if let cached = pipelines[fragmentName] { return cached }
        guard let vertex = library.makeFunction(name: "wpe_fullscreen_vertex"),
              let fragment = library.makeFunction(name: fragmentName) else {
            throw WPEMetalRenderExecutorError.pipelineUnavailable(fragmentName)
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
        let state = try device.makeRenderPipelineState(descriptor: descriptor)
        pipelines[fragmentName] = state
        return state
    }

    private func makeOutputTexture(size: CGSize) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: max(Int(size.width), 1),
            height: max(Int(size.height), 1),
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw WPEMetalTextureLoaderError.textureAllocationFailed
        }
        return texture
    }

    private func resolve(reference: WPETextureReference, textures: [String: MTLTexture]) throws -> MTLTexture {
        switch reference {
        case .image(let path), .asset(let path), .fbo(let path):
            guard let texture = textures[path] else {
                throw WPEMetalRenderExecutorError.missingTexture(reference)
            }
            return texture
        case .previous:
            throw WPEMetalRenderExecutorError.missingTexture(reference)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
```

- [ ] **Step 5: Run executor tests**

```bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPEMetalRenderExecutorTests
```

Expected: executor tests pass on Macs with Metal. If the default library does not include `WPEMetalBuiltins.metal`, update the target membership/build phase so the file is compiled into the app Metal library, then rerun.

---

## Task 6: Add Opt-In WPEMetalSceneRenderer And Builder Routing

**Files:**
- Create: `LiveWallpaper/Runtime/WPEMetalSceneRenderer.swift`
- Modify: `LiveWallpaper/Runtime/AmbientWallpaperSessionBuilder.swift`
- Modify: `LiveWallpaper/Views/ScreenDetail/WPESceneDetailView.swift`
- Test: `LiveWallpaperTests/WPEMetalSceneRendererTests.swift`
- Test: `LiveWallpaperTests/WPESceneRendererBoundaryTests.swift`

- [ ] **Step 1: Write failing Metal scene renderer tests**

Create `LiveWallpaperTests/WPEMetalSceneRendererTests.swift`:

```swift
import MetalKit
import Testing
@testable import LiveWallpaper

@MainActor
@Suite("WPE Metal scene renderer")
struct WPEMetalSceneRendererTests {
    @Test("Initializes with an MTKView when Metal is available")
    func initializesWithMTKView() throws {
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

        #expect(renderer.nsView is MTKView)
        #expect(renderer.hasPresentedFrame == false)
    }

    @Test("Loads solidcolor scene through Metal executor")
    func loadsSolidColorScene() async throws {
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

        #expect(renderer.hasPresentedFrame)
        #expect(renderer.renderGraph?.layers.count == 1)
        #expect(renderer.renderPipeline?.layers.first?.passes.first?.pass.shader == "solidcolor")
    }
}
```

Add fixture helper:

```swift
private struct MetalSceneFixture {
    let root: URL
    let descriptor: SceneDescriptor

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    static func solidColorScene() throws -> MetalSceneFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEMetalSceneRenderer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let scene = """
        {
          "camera": { "center": "0 0 0" },
          "general": { "orthogonalprojection": { "width": 64, "height": 64, "auto": true } },
          "objects": [{
            "id": "solid",
            "name": "Solid",
            "type": "image",
            "image": "models/util/solidlayer.json",
            "color": "1 0 0",
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
            )
        )
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPEMetalSceneRendererTests
```

Expected: compile failure because `WPEMetalSceneRenderer` does not exist.

- [ ] **Step 3: Add WPEMetalSceneRenderer**

Create `LiveWallpaper/Runtime/WPEMetalSceneRenderer.swift`:

```swift
import AppKit
import MetalKit

@MainActor
final class WPEMetalSceneRenderer: NSObject, WPESceneRenderer, MTKViewDelegate {
    private let descriptor: SceneDescriptor
    private let cacheRootURL: URL
    private let dependencyMounts: [WPEAssetMount]
    private let resolver: SceneResourceResolver
    private let mtkView: MTKView
    private let device: MTLDevice
    private let executor: WPEMetalRenderExecutor
    private var outputTexture: MTLTexture?
    private var currentProfile: WallpaperPerformanceProfile = .quality
    private var didLoad = false
    private(set) var hasPresentedFrame = false
    private(set) var loadDiagnostics: SceneLoadDiagnostic?
    private(set) var renderGraph: WPERenderGraph?
    private(set) var renderPipeline: WPEPreparedRenderPipeline?
    var onProgress: (@MainActor (String) -> Void)?

    init(
        descriptor: SceneDescriptor,
        cacheRootURL: URL,
        dependencyMounts: [WPEAssetMount],
        frame: CGRect,
        device: MTLDevice
    ) throws {
        self.descriptor = descriptor
        self.cacheRootURL = cacheRootURL
        self.dependencyMounts = dependencyMounts
        self.resolver = SceneResourceResolver(cacheRootURL: cacheRootURL)
        self.device = device
        self.executor = try WPEMetalRenderExecutor(device: device)
        self.mtkView = MTKView(frame: frame, device: device)
        super.init()
        mtkView.delegate = self
        mtkView.colorPixelFormat = .rgba8Unorm
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        mtkView.preferredFramesPerSecond = SceneRenderingController.defaultPreferredFPS
        mtkView.autoresizingMask = [.width, .height]
    }

    var nsView: NSView { mtkView }

    func load() async throws {
        guard !didLoad else { return }
        let entryURL = try resolver.resolveExistingFileURL(relativePath: descriptor.entryFile)
        let document = try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: entryURL)
            return try WPESceneDocumentParser.parse(data: data)
        }.value
        let graph = try await Task.detached(priority: .userInitiated) { [cacheRootURL] in
            try WPERenderGraphBuilder(cacheRootURL: cacheRootURL).build(document: document)
        }.value
        let pipeline = try await Task.detached(priority: .userInitiated) { [cacheRootURL] in
            try WPERenderPipelineBuilder(cacheRootURL: cacheRootURL).build(graph: graph)
        }.value
        renderGraph = graph
        renderPipeline = pipeline
        let projection = document.general.orthogonalProjection
        outputTexture = try executor.render(
            pipeline: pipeline,
            size: CGSize(width: max(projection.width, 1), height: max(projection.height, 1)),
            textures: [:]
        )
        hasPresentedFrame = true
        didLoad = true
        mtkView.setNeedsDisplay(mtkView.bounds)
    }

    func reload() async throws {
        didLoad = false
        hasPresentedFrame = false
        outputTexture = nil
        try await load()
    }

    func setThrottled(_ throttled: Bool) {
        mtkView.preferredFramesPerSecond = throttled ? SceneRenderingController.throttledPreferredFPS : SceneRenderingController.defaultPreferredFPS
    }

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        currentProfile = profile
        switch profile {
        case .quality:
            mtkView.isPaused = false
            mtkView.preferredFramesPerSecond = SceneRenderingController.defaultPreferredFPS
        case .suspended:
            mtkView.isPaused = true
            mtkView.releaseDrawables()
        }
    }

    func cleanup() {
        mtkView.delegate = nil
        outputTexture = nil
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard outputTexture != nil else { return }
        // Phase 2A proves renderer construction + offscreen execution.
        // Presenting the offscreen texture to the drawable is covered by the
        // follow-up executor composition plan once FBO/copy paths are broader.
        SystemMonitor.shared.tickFrame()
    }
}
```

- [ ] **Step 4: Add builder routing**

Modify `AmbientWallpaperSessionBuilder.makeSceneSession` signature:

```swift
func makeSceneSession(
    descriptor: SceneDescriptor,
    frame: CGRect,
    dependencyMounts: [WPEAssetMount] = [],
    rendererBackend: WPESceneRendererBackend = .spriteKit,
    applicationSupportRootURL: URL? = nil,
    fileManager: FileManager = .default
) -> SceneWallpaperSession?
```

Replace controller construction:

```swift
let renderer: WPESceneRenderer
switch rendererBackend {
case .spriteKit:
    renderer = SceneRenderingController(
        descriptor: descriptor,
        cacheRootURL: cacheURL,
        dependencyMounts: dependencyMounts,
        frame: CGRect(origin: .zero, size: frame.size)
    )
case .metalExperimental:
    guard let device = MTLCreateSystemDefaultDevice(),
          let metalRenderer = try? WPEMetalSceneRenderer(
              descriptor: descriptor,
              cacheRootURL: cacheURL,
              dependencyMounts: dependencyMounts,
              frame: CGRect(origin: .zero, size: frame.size),
              device: device
          ) else {
        Logger.warning("WPE Metal scene renderer unavailable; refusing experimental Metal session", category: .screenManager)
        return nil
    }
    renderer = metalRenderer
}
window.contentView = renderer.nsView
let session = SceneWallpaperSession(window: window, renderer: renderer)
```

Keep `ScreenManager` calls unchanged so production uses `.spriteKit`.

- [ ] **Step 5: Update scene detail view state**

Modify `WPESceneDetailView.refreshState()`:

```swift
guard let renderer = session.sceneRenderer else {
    state = .idle
    return
}
if !renderer.hasPresentedFrame {
    state = .loading(progress: session.loadProgress)
    return
}
renderer.applyPerformanceProfile(reduceMotion ? .suspended : .quality)
if reduceMotion || session.isThrottled {
    state = .paused(reason: reduceMotion ? .reduceMotion : .throttled)
    return
}
if let controller = session.sceneController {
    state = .playing(controller)
} else {
    state = .paused(reason: .previewUnavailable)
}
```

Add a non-user-alarming pause reason to `PausedReason`:

```swift
case previewUnavailable
```

Render it as `"Preview unavailable for experimental renderer"` while keeping the live wallpaper session active:

```swift
case .previewUnavailable: return "Preview Unavailable"
```

- [ ] **Step 6: Run renderer tests**

```bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPEMetalSceneRendererTests -only-testing:LiveWallpaperTests/WPESceneRendererBoundaryTests
```

Expected: tests pass on Macs with Metal; Metal-specific tests skip through `#require` if no device exists.

---

## Final Verification

Run all Phase 2A targeted tests:

```bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO \
  -only-testing:LiveWallpaperTests/WPESceneRendererBoundaryTests \
  -only-testing:LiveWallpaperTests/WPEMetalTextureFormatMapperTests \
  -only-testing:LiveWallpaperTests/WPETexTexturePayloadTests \
  -only-testing:LiveWallpaperTests/WPEMetalTextureLoaderTests \
  -only-testing:LiveWallpaperTests/WPEMetalRenderExecutorTests \
  -only-testing:LiveWallpaperTests/WPEMetalSceneRendererTests
```

Then run the non-UI regression suite:

```bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -skip-testing:LiveWallpaperUITests
```

Expected:

- Phase 2A targeted suites pass on machines with Metal.
- Metal-only tests use `#require(MTLCreateSystemDefaultDevice())` to skip when Metal is absent.
- Non-UI regression suite still passes.
- SpriteKit remains the default scene renderer from `ScreenManager`.

---

## Main Improvements Delivered By This Plan

- **Renderer architecture:** replaces concrete `SceneRenderingController` session ownership with a stable non-generic renderer boundary.
- **Safe rollout:** keeps SpriteKit as default while allowing opt-in Metal experiments without breaking restore/import flows.
- **Metal testability:** adds offscreen pixel tests, so renderer work can be verified without UI automation or manual wallpaper inspection.
- **Texture correctness:** removes the misleading BC transcode concept and maps BC1/2/3/7 to native Metal compressed formats when the device supports them.
- **WPE IR reuse:** consumes existing `WPERenderGraph` and `WPEPreparedRenderPipeline`, avoiding a second parser path.
- **Fail-closed behavior:** unsupported custom shaders and targets return typed errors instead of black frames.

## Self-Review

- Spec coverage: this plan addresses the Phase 2 entry point, renderer boundary, BC texture fact correction, minimal render graph execution, and verification strategy.
- Placeholder scan: no task uses broad "implement feature" steps without file paths, test names, commands, or expected behavior.
- Type consistency: renderer types are `WPESceneRenderer`, `WPESceneRendererBackend`, `WPEMetalTextureFormatMapper`, `WPETexTexturePayload`, `WPEMetalTextureLoader`, `WPEMetalRenderExecutor`, and `WPEMetalSceneRenderer`.
- Deferred systems are explicitly out of scope: shader translator, particles, audio, complex effects, and web compatibility each need separate plans after Phase 2A lands.
