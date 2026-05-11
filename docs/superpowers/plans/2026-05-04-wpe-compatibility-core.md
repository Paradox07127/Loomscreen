# WPE Phase 1 Compatibility Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make current WPE scene import and SpriteKit image fallback truthful and regression-safe before starting the native Metal WPE renderer.

**Architecture:** Phase 1 stays inside the current architecture: `WallpaperEngineImportService` imports and classifies, `SceneDescriptor` persists runtime metadata, `AmbientWallpaperSessionBuilder` creates the scene session, and `SceneRenderingController` renders the SpriteKit fallback. This plan hardens those existing paths and explicitly moves Metal/shader/particle work into later standalone plans.

**Tech Stack:** Swift 6, AppKit, SpriteKit, ImageIO, existing WPE cache/import models, XCTest/Swift Testing.

---

## Review Suitability Assessment

The review is suitable and should be applied before implementation.

- Phase 1 approval is reasonable: the parser/probe/transform/dependency changes address visible correctness bugs without forcing a renderer rewrite.
- Task 1 needed an ambiguity rule: shape-key detection cannot blindly prefer `image` when an object also carries `sound`, `particle`, `text`, or `light`.
- Task 3 needed regression protection: the existing alignment and 0...1 origin heuristics may encode real Workshop compatibility. Phase 1 will not remove them; it will move them behind a mapper and fix radians only.
- Task 4 needed schema detail: dependency IDs must be persisted and migrated with default empty arrays. Runtime mount resolution must be owned by `ScreenManager`, because only `ScreenConfiguration` carries `wpeOrigin` and its source-folder bookmark.
- Task 2 needed cache migration behavior: after full-chain probing, old optimistic `.imageOnly` descriptors must be reclassified when rebuilt from cache/origin.
- Phase 2/3 were not implementation plans. They are now roadmap notes only. Separate plans are required for Metal renderer boundary, graph executor, texture loader, shader translator, audio uniforms, particles, and web compatibility.
- The BC texture note is corrected: on devices where `MTLDevice.supportsBCTextureCompression` is true, BC1/2/3/7 should be loaded as native compressed `MTLPixelFormat` textures and sampled directly. The current "Metal transcoder" concept should be removed or renamed because blit-copy does not transcode compressed texture formats.
- A renderer protocol with `associatedtype ViewType` is not appropriate for session routing because it cannot be stored as a simple existential. Future renderer plans should use `var nsView: NSView { get }`, a type-erased wrapper, or an enum backend.

## Current Framework vs Phase 1 Target

| Area | Current framework | Phase 1 target | Why change | Concrete improvement |
| --- | --- | --- | --- | --- |
| Object parsing | Missing `type` defaults to image. | Detect all shape keys, emit ambiguity diagnostics, preserve renderable image layer when safe. | Real WPE objects can omit `type` or carry multiple feature blocks. | Capability tier stops under-reporting unsupported sound/particle/text/light features. |
| Capability probe | Non-`.tex` image paths use shallow existence checks. | A shared classifier probes the full model -> material -> texture chain. | JSON wrappers can exist while terminal textures are missing or unsupported. | Imports no longer claim `.imageOnly` for scenes that cannot render all layers. |
| Cached scene rebuild | Rebuilt scene descriptors use optimistic `.imageOnly`. | Cached scenes are reclassified from `scene.json` during rebuild. | New classifier semantics must apply to existing cached imports. | Existing users get silent correctness improvement on next restore/history activation. |
| Transforms | SpriteKit node creation owns angle/position heuristics and converts radians as degrees. | `WPESceneTransformMapper` centralizes current positioning heuristics and changes z angle to radians. | Immediate angle bug can be fixed without deleting sample-derived alignment behavior. | Fewer rotation bugs with lower risk of position regressions. |
| Dependencies | Import can pass if dependencies exist, but runtime rejects `../<workshopID>/...`. | Persist dependency IDs and mount declared cache/source roots explicitly. | WPE dependency references are intentional cross-package asset links. | Dependency assets can load without weakening path traversal protections. |

## Files

### Existing files to modify

- `LiveWallpaper/Models/SceneDescriptor.swift`
  - Add `dependencyWorkshopIDs: [String]` with decode default `[]`.
- `LiveWallpaper/Models/WPEOrigin.swift`
  - Add `dependencyWorkshopIDs: [String]` with decode default `[]` so history/cache rebuild can reconstruct descriptors.
- `LiveWallpaper/Models/ScreenConfiguration.swift`
  - Legacy scene backfill should set `dependencyWorkshopIDs: []` and keep schema-compatible defaults.
- `LiveWallpaper/Infrastructure/WPESceneDocumentParser.swift`
  - Shape-key object detection and ambiguity diagnostics.
- `LiveWallpaper/Infrastructure/SceneResourceResolver.swift`
  - Public renderability probe that follows image reference chains.
- `LiveWallpaper/Infrastructure/WallpaperEngineImportService.swift`
  - Extract shared capability classifier, persist dependency IDs, reclassify cached scenes.
- `LiveWallpaper/Runtime/SceneRenderingController.swift`
  - Accept dependency mounts and use `WPESceneTransformMapper`.
- `LiveWallpaper/Runtime/AmbientWallpaperSessionBuilder.swift`
  - Accept dependency mounts from `ScreenManager` and pass them to the controller.
- `LiveWallpaper/Runtime/WallpaperSessionDefinition.swift`
  - No dependency mount ownership here; keep it as persisted content shape only.
- `LiveWallpaper/ScreenManager.swift`
  - Resolve dependency mounts from `SceneDescriptor` + `WPEOrigin` before creating scene sessions.

### New files to create

- `LiveWallpaper/Models/WPESceneObjectKind.swift`
  - Object-kind enum plus shape-resolution result.
- `LiveWallpaper/Infrastructure/WPESceneCapabilityClassifier.swift`
  - Shared full-chain classifier used by import and cached rebuild.
- `LiveWallpaper/Runtime/WPESceneTransformMapper.swift`
  - Pure transform adapter for SpriteKit fallback.
- `LiveWallpaper/Infrastructure/WPEAssetMount.swift`
  - Describes a declared dependency root.
- `LiveWallpaper/Infrastructure/WPEMultiRootResourceResolver.swift`
  - Path-safe resolver for primary and dependency roots.
- `LiveWallpaper/Infrastructure/WPEDependencyMountResolver.swift`
  - Resolves dependency IDs to cached roots and source sibling roots.

### Tests to create or extend

- `LiveWallpaperTests/WPESceneDocumentParserTests.swift`
- `LiveWallpaperTests/SceneDescriptorCodableTests.swift`
- `LiveWallpaperTests/SceneResourceResolverTests.swift`
- `LiveWallpaperTests/WallpaperEngineImportServiceTests.swift`
- `LiveWallpaperTests/SceneRenderingControllerTests.swift`
- `LiveWallpaperTests/WPESceneCapabilityClassifierTests.swift`
- `LiveWallpaperTests/WPESceneTransformMapperTests.swift`
- `LiveWallpaperTests/WPEMultiRootResourceResolverTests.swift`
- `LiveWallpaperTests/WPEDependencyMountResolverTests.swift`

---

## Task 1: Parse WPE Object Kinds By Shape With Ambiguity Diagnostics

**Files:**
- Create: `LiveWallpaper/Models/WPESceneObjectKind.swift`
- Modify: `LiveWallpaper/Infrastructure/WPESceneDocumentParser.swift`
- Test: `LiveWallpaperTests/WPESceneDocumentParserTests.swift`

- [ ] **Step 1: Write failing tests for missing type and ambiguous shape**

Add to `WPESceneDocumentParserTests`:

```swift
@Test("Shape-based object kind detection handles WPE objects without type")
func shapeBasedObjectKindDetection() throws {
    let payload: [String: Any] = [
        "camera": ["center": "0 0 0"],
        "general": ["orthogonalprojection": ["width": 1, "height": 1, "auto": true]],
        "objects": [
            ["name": "BG", "image": "materials/bg.png"],
            ["name": "Loop", "sound": ["file": "sounds/loop.ogg"]],
            ["name": "Sparks", "particle": ["emitters": []]],
            ["name": "Title", "text": "Hello"],
            ["name": "Lamp", "light": ["color": "1 1 1"]]
        ]
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])

    let document = try WPESceneDocumentParser.parse(data: data)

    #expect(document.imageObjects.count == 1)
    #expect(document.imageObjects.first?.name == "BG")
    #expect(document.diagnostics.contains(where: { $0.message.contains("Sound object Loop") }))
    #expect(document.diagnostics.contains(where: { $0.message.contains("Particle object Sparks") }))
    #expect(document.diagnostics.contains(where: { $0.message.contains("Text object Title") }))
    #expect(document.diagnostics.contains(where: { $0.message.contains("Light object Lamp") }))
    #expect(!document.diagnostics.contains(where: { $0.message.contains("has no image path") }))
}

@Test("Ambiguous WPE object emits warning and preserves renderable image layer")
func ambiguousObjectEmitsWarningAndPreservesImage() throws {
    let payload: [String: Any] = [
        "camera": ["center": "0 0 0"],
        "general": ["orthogonalprojection": ["width": 1, "height": 1, "auto": true]],
        "objects": [[
            "name": "ImageWithSound",
            "image": "materials/bg.png",
            "sound": ["file": "sounds/loop.ogg"]
        ]]
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])

    let document = try WPESceneDocumentParser.parse(data: data)

    #expect(document.imageObjects.count == 1)
    #expect(document.diagnostics.contains(where: {
        $0.severity == .warning && $0.message.contains("Ambiguous object ImageWithSound")
    }))
    #expect(document.diagnostics.contains(where: { $0.message.contains("Sound object ImageWithSound") }))
}
```

- [ ] **Step 2: Run the targeted test and confirm failure**

```bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -only-testing:LiveWallpaperTests/WPESceneDocumentParserTests
```

Expected: failure because missing-type sound/particle/text/light objects are currently parsed as image objects.

- [ ] **Step 3: Add object-kind shape model**

Create `LiveWallpaper/Models/WPESceneObjectKind.swift`:

```swift
import Foundation

enum WPESceneObjectKind: String, Equatable, Sendable {
    case image
    case sound
    case particle
    case text
    case light
    case unknown

    var displayName: String {
        switch self {
        case .image: return "Image"
        case .sound: return "Sound"
        case .particle: return "Particle"
        case .text: return "Text"
        case .light: return "Light"
        case .unknown: return "Unknown"
        }
    }
}

struct WPESceneObjectKindResolution: Equatable, Sendable {
    let primary: WPESceneObjectKind
    let candidates: [WPESceneObjectKind]

    var isAmbiguous: Bool { candidates.count > 1 }
}
```

- [ ] **Step 4: Implement shape resolution**

Add helpers in `WPESceneDocumentParser`:

```swift
private static func objectKindResolution(for entry: [String: Any]) -> WPESceneObjectKindResolution {
    if let explicit = (entry["type"] as? String)?.lowercased(), !explicit.isEmpty {
        return WPESceneObjectKindResolution(
            primary: objectKind(explicitType: explicit),
            candidates: shapeCandidates(in: entry)
        )
    }

    let candidates = shapeCandidates(in: entry)
    if candidates.contains(.image) {
        return WPESceneObjectKindResolution(primary: .image, candidates: candidates)
    }
    return WPESceneObjectKindResolution(primary: candidates.first ?? .unknown, candidates: candidates)
}

private static func objectKind(explicitType: String) -> WPESceneObjectKind {
    switch explicitType {
    case "image": return .image
    case "sound": return .sound
    case "particle": return .particle
    case "text": return .text
    case "light": return .light
    default: return .unknown
    }
}

private static func shapeCandidates(in entry: [String: Any]) -> [WPESceneObjectKind] {
    var kinds: [WPESceneObjectKind] = []
    if entry["image"] != nil { kinds.append(.image) }
    if entry["sound"] != nil { kinds.append(.sound) }
    if entry["particle"] != nil { kinds.append(.particle) }
    if entry["text"] != nil { kinds.append(.text) }
    if entry["light"] != nil { kinds.append(.light) }
    return kinds
}
```

Replace the current `type` switch with logic that:

```swift
let resolution = objectKindResolution(for: entry)
if resolution.isAmbiguous {
    diagnostics.append(.init(
        severity: .warning,
        message: "Ambiguous object \(entry["name"] as? String ?? "?") declares \(resolution.candidates.map(\.rawValue).joined(separator: ", "))"
    ))
}

if resolution.primary == .image, let object = parseImageObject(entry, diagnostics: &diagnostics) {
    imageObjects.append(object)
}

for kind in resolution.candidates where kind != .image {
    diagnostics.append(.init(
        severity: .info,
        message: "\(kind.displayName) object \(entry["name"] as? String ?? "?") is unsupported in Phase 2.0"
    ))
}

if resolution.primary != .image && resolution.candidates.isEmpty {
    diagnostics.append(.init(severity: .info, message: "Object type missing is unsupported in Phase 2.0"))
}
```

- [ ] **Step 5: Run parser tests**

Run the targeted command again. Expected: parser tests pass.

- [ ] **Step 6: Commit**

```bash
git add LiveWallpaper/Models/WPESceneObjectKind.swift LiveWallpaper/Infrastructure/WPESceneDocumentParser.swift LiveWallpaperTests/WPESceneDocumentParserTests.swift
git commit -m "fix: detect WPE scene object shapes"
```

**Difference from current framework:** the parser no longer silently treats missing `type` as image.  
**Why:** WPE scenes can identify object kind by shape and can be ambiguous.  
**Improvement:** better diagnostics and safer capability classification without dropping renderable image layers.

---

## Task 2: Share Full-Chain Capability Classification And Reclassify Cached Scenes

**Files:**
- Create: `LiveWallpaper/Infrastructure/WPESceneCapabilityClassifier.swift`
- Modify: `LiveWallpaper/Infrastructure/SceneResourceResolver.swift`
- Modify: `LiveWallpaper/Infrastructure/WallpaperEngineImportService.swift`
- Test: `LiveWallpaperTests/SceneResourceResolverTests.swift`
- Test: `LiveWallpaperTests/WPESceneCapabilityClassifierTests.swift`
- Test: `LiveWallpaperTests/WallpaperEngineImportServiceTests.swift`

- [ ] **Step 1: Write resolver probe test for missing terminal asset**

Add to `SceneResourceResolverTests`:

```swift
@Test("Renderable probe follows model material chain to terminal asset")
func renderableProbeFollowsMaterialChain() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let modelsDir = fixture.cacheRoot.appendingPathComponent("models", isDirectory: true)
    let materialsDir = fixture.cacheRoot.appendingPathComponent("materials", isDirectory: true)
    try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: materialsDir, withIntermediateDirectories: true)
    try Data(#"{ "material": "materials/foo.json" }"#.utf8).write(to: modelsDir.appendingPathComponent("foo.json"))
    try Data(#"{ "passes": [{ "textures": ["missing"], "shader": "genericimage4" }] }"#.utf8).write(to: materialsDir.appendingPathComponent("foo.json"))

    let resolver = SceneResourceResolver(cacheRootURL: fixture.cacheRoot)
    let result = resolver.probeRenderableImage(relativePath: "models/foo.json")

    guard case .failure(.fileMissing) = result else {
        Issue.record("Expected missing terminal texture, got \(result)")
        return
    }
}
```

- [ ] **Step 2: Run resolver tests and confirm failure**

```bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -only-testing:LiveWallpaperTests/SceneResourceResolverTests
```

Expected: compile failure because `probeRenderableImage` does not exist.

- [ ] **Step 3: Add public renderability probe**

In `SceneResourceResolver`, add:

```swift
func probeRenderableImage(relativePath: String) -> Result<Void, ResolveError> {
    guard !relativePath.isEmpty else { return .failure(.fileMissing) }
    let resolvedPath: String
    do {
        resolvedPath = try resolveImageReference(relativePath: relativePath, depth: 0)
    } catch let error as ResolveError {
        return .failure(error)
    } catch {
        return .failure(.fileMissing)
    }

    let lowered = (resolvedPath as NSString).pathExtension.lowercased()
    if lowered == "tex" {
        switch probeImage(relativePath: resolvedPath) {
        case .success(let info):
            return info.format?.isPhase21Decodable == true ? .success(()) : .failure(.unsupportedTexture)
        case .failure(let error):
            return .failure(error)
        }
    }

    do {
        _ = try resolveExistingFileURL(relativePath: resolvedPath)
        return .success(())
    } catch let error as ResolveError {
        return .failure(error)
    } catch {
        return .failure(.fileMissing)
    }
}
```

- [ ] **Step 4: Extract capability classifier**

Create `WPESceneCapabilityClassifier.swift`:

```swift
import Foundation

struct WPESceneCapabilityClassifier: Sendable {
    func capabilityTier(for document: WPESceneDocument, cacheURL: URL) -> SceneCapabilityTier {
        guard !document.imageObjects.isEmpty else { return .unsupported }

        let resolver = SceneResourceResolver(cacheRootURL: cacheURL)
        var resolvable = 0
        var unresolvable = 0

        for object in document.imageObjects {
            switch resolver.probeRenderableImage(relativePath: object.imageRelativePath) {
            case .success:
                resolvable += 1
            case .failure:
                unresolvable += 1
            }
        }

        if resolvable == 0 { return .unsupported }
        let blockingDiagnostics = document.diagnostics.filter { diagnostic in
            !diagnostic.message.contains(".tex texture")
        }
        if unresolvable == 0 && blockingDiagnostics.isEmpty {
            return .imageOnly
        }
        return .degraded
    }
}
```

- [ ] **Step 5: Replace import-service private classifier**

In `WallpaperEngineImportService.handleCachedSceneProject`, replace:

```swift
let tier = capabilityTier(for: document, cacheURL: cacheURL)
```

with:

```swift
let tier = WPESceneCapabilityClassifier().capabilityTier(for: document, cacheURL: cacheURL)
```

Remove the old private `capabilityTier(for:cacheURL:)` method from `WallpaperEngineImportService`.

- [ ] **Step 6: Add cached rebuild classification test**

Update `cachedContentResolverRebuildsSceneDescriptor` so the fixture has a valid `scene.json` with an unresolved model/material chain, then assert the rebuilt descriptor is not `.imageOnly`.

```swift
#expect(descriptor.capabilityTier == .unsupported)
```

- [ ] **Step 7: Reclassify cached scenes in `WPECachedContentResolver`**

In the `.scene` case of `WPECachedContentResolver.content(for:)`, replace the optimistic descriptor with:

```swift
let tier: SceneCapabilityTier
do {
    let data = try Data(contentsOf: entryURL)
    let document = try WPESceneDocumentParser.parse(data: data)
    tier = WPESceneCapabilityClassifier().capabilityTier(for: document, cacheURL: cacheURL)
} catch {
    tier = .unsupported
}

return .scene(SceneDescriptor(
    workshopID: origin.workshopID,
    cacheRelativePath: cacheRelativePath,
    entryFile: entryFile,
    capabilityTier: tier,
    dependencyWorkshopIDs: origin.dependencyWorkshopIDs
))
```

- [ ] **Step 8: Run targeted tests**

```bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -only-testing:LiveWallpaperTests/SceneResourceResolverTests -only-testing:LiveWallpaperTests/WPESceneCapabilityClassifierTests -only-testing:LiveWallpaperTests/WallpaperEngineImportServiceTests
```

Expected: targeted tests pass.

- [ ] **Step 9: Commit**

```bash
git add LiveWallpaper/Infrastructure/SceneResourceResolver.swift LiveWallpaper/Infrastructure/WPESceneCapabilityClassifier.swift LiveWallpaper/Infrastructure/WallpaperEngineImportService.swift LiveWallpaperTests/SceneResourceResolverTests.swift LiveWallpaperTests/WPESceneCapabilityClassifierTests.swift LiveWallpaperTests/WallpaperEngineImportServiceTests.swift
git commit -m "fix: classify WPE scenes through terminal assets"
```

**Difference from current framework:** import and cached rebuild use the same full-chain classifier.  
**Why:** classifier semantics changed; cached scenes must not stay optimistic forever.  
**Improvement:** existing cached scenes are corrected on restore/history activation.

---

## Task 3: Centralize Transform Mapping Without Removing Existing Position Heuristics

**Files:**
- Create: `LiveWallpaper/Runtime/WPESceneTransformMapper.swift`
- Modify: `LiveWallpaper/Runtime/SceneRenderingController.swift`
- Test: `LiveWallpaperTests/WPESceneTransformMapperTests.swift`
- Test: `LiveWallpaperTests/SceneRenderingControllerTests.swift`

- [ ] **Step 1: Write transform tests that lock current position behavior and fix radians**

Create `WPESceneTransformMapperTests.swift`:

```swift
import CoreGraphics
import Testing
@testable import LiveWallpaper

@Suite("WPESceneTransformMapper")
struct WPESceneTransformMapperTests {
    @Test("Angles are interpreted as radians")
    func angleUsesRadians() {
        let result = WPESceneTransformMapper.spriteTransform(
            origin: SIMD3<Double>(0.5, 0.5, 0),
            angles: SIMD3<Double>(0, 0, Double.pi / 2),
            alignment: .center,
            canvas: CGSize(width: 1920, height: 1080)
        )
        #expect(abs(result.zRotation - CGFloat(Double.pi / 2)) < 0.0001)
    }

    @Test("Existing normalized center origin heuristic is preserved in Phase 1")
    func normalizedOriginHeuristicIsPreserved() {
        let result = WPESceneTransformMapper.spriteTransform(
            origin: SIMD3<Double>(0.5, 0.5, 0),
            angles: SIMD3<Double>(0, 0, 0),
            alignment: .center,
            canvas: CGSize(width: 1920, height: 1080)
        )
        #expect(result.position == CGPoint(x: 960, y: 540))
    }

    @Test("Existing top-left alignment heuristic is preserved in Phase 1")
    func topLeftAlignmentHeuristicIsPreserved() {
        let result = WPESceneTransformMapper.spriteTransform(
            origin: SIMD3<Double>(100, 200, 0),
            angles: SIMD3<Double>(0, 0, 0),
            alignment: .topLeft,
            canvas: CGSize(width: 1920, height: 1080)
        )
        #expect(result.position == CGPoint(x: 100, y: 880))
    }
}
```

- [ ] **Step 2: Run transform tests and confirm failure**

```bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -only-testing:LiveWallpaperTests/WPESceneTransformMapperTests
```

Expected: compile failure because the mapper does not exist.

- [ ] **Step 3: Add mapper that preserves positioning and fixes angle units**

Create `WPESceneTransformMapper.swift`:

```swift
import CoreGraphics
import Foundation

struct WPESceneSpriteTransform: Equatable, Sendable {
    let position: CGPoint
    let zRotation: CGFloat
}

enum WPESceneTransformMapper {
    static func spriteTransform(
        origin: SIMD3<Double>,
        angles: SIMD3<Double>,
        alignment: WPESceneAlignment,
        canvas: CGSize
    ) -> WPESceneSpriteTransform {
        WPESceneSpriteTransform(
            position: position(for: origin, canvas: canvas, alignment: alignment),
            zRotation: CGFloat(angles.z)
        )
    }

    private static func position(
        for origin: SIMD3<Double>,
        canvas: CGSize,
        alignment: WPESceneAlignment
    ) -> CGPoint {
        let x = CGFloat(origin.x)
        let y = CGFloat(origin.y)
        let xPx = (x >= 0 && x <= 1) ? x * canvas.width : x
        let yPx = (y >= 0 && y <= 1) ? y * canvas.height : y

        switch alignment {
        case .center:       return CGPoint(x: xPx, y: yPx)
        case .topLeft:      return CGPoint(x: xPx, y: canvas.height - yPx)
        case .topRight:     return CGPoint(x: canvas.width - xPx, y: canvas.height - yPx)
        case .bottomLeft:   return CGPoint(x: xPx, y: yPx)
        case .bottomRight:  return CGPoint(x: canvas.width - xPx, y: yPx)
        case .top:          return CGPoint(x: xPx, y: canvas.height - yPx)
        case .bottom:       return CGPoint(x: xPx, y: yPx)
        case .left:         return CGPoint(x: xPx, y: yPx)
        case .right:        return CGPoint(x: canvas.width - xPx, y: yPx)
        }
    }
}
```

- [ ] **Step 4: Use mapper in `SceneRenderingController`**

Replace direct `zRotation` and `position(...)` calls with:

```swift
let transform = WPESceneTransformMapper.spriteTransform(
    origin: object.origin,
    angles: object.angles,
    alignment: object.alignment,
    canvas: canvas
)
node.zRotation = transform.zRotation
node.position = transform.position
```

Remove only the duplicated private `position(for:canvas:alignment:)` from `SceneRenderingController`; do not change the math in Phase 1.

- [ ] **Step 5: Add controller-level radians regression test**

Add a scene fixture with:

```json
"angles": "0 0 1.5707963267948966"
```

Assert:

```swift
let sprite = try #require(controller.view.scene?.childNode(withName: "Layer 0") as? SKSpriteNode)
#expect(abs(sprite.zRotation - CGFloat(Double.pi / 2)) < 0.0001)
```

- [ ] **Step 6: Run a fixture census before any future coordinate rewrite**

Before changing position math in a later plan, run a census over currently cached WPE scenes and save the output to an ignored local note:

```bash
find "$HOME/Library/Application Support/LiveWallpaper/wpe-cache" -name scene.json -print
```

For each available fixture, record object count, `origin`, `alignment`, `size`, and whether `origin` values are normalized or pixel-like. Do not replace the 9-case alignment branch until golden fixtures exist for the common distributions.

- [ ] **Step 7: Run targeted tests**

```bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -only-testing:LiveWallpaperTests/WPESceneTransformMapperTests -only-testing:LiveWallpaperTests/SceneRenderingControllerTests
```

Expected: targeted tests pass.

- [ ] **Step 8: Commit**

```bash
git add LiveWallpaper/Runtime/WPESceneTransformMapper.swift LiveWallpaper/Runtime/SceneRenderingController.swift LiveWallpaperTests/WPESceneTransformMapperTests.swift LiveWallpaperTests/SceneRenderingControllerTests.swift
git commit -m "fix: centralize WPE sprite transforms"
```

**Difference from current framework:** transform math moves from controller internals to a reusable mapper, but position behavior is preserved.  
**Why:** radians bug is known; coordinate rewrite needs fixture evidence.  
**Improvement:** fixes rotated layers while avoiding broad placement regressions.

---

## Task 4: Persist Dependency IDs And Mount Declared Roots Safely

**Files:**
- Create: `LiveWallpaper/Infrastructure/WPEAssetMount.swift`
- Create: `LiveWallpaper/Infrastructure/WPEMultiRootResourceResolver.swift`
- Create: `LiveWallpaper/Infrastructure/WPEDependencyMountResolver.swift`
- Modify: `LiveWallpaper/Models/SceneDescriptor.swift`
- Modify: `LiveWallpaper/Models/WPEOrigin.swift`
- Modify: `LiveWallpaper/Models/ScreenConfiguration.swift`
- Modify: `LiveWallpaper/Infrastructure/WallpaperEngineImportService.swift`
- Modify: `LiveWallpaper/Runtime/SceneRenderingController.swift`
- Modify: `LiveWallpaper/Runtime/AmbientWallpaperSessionBuilder.swift`
- Modify: `LiveWallpaper/ScreenManager.swift`
- Test: `LiveWallpaperTests/SceneDescriptorCodableTests.swift`
- Test: `LiveWallpaperTests/WallpaperEngineImportServiceTests.swift`
- Test: `LiveWallpaperTests/WPEMultiRootResourceResolverTests.swift`
- Test: `LiveWallpaperTests/WPEDependencyMountResolverTests.swift`
- Test: `LiveWallpaperTests/SceneRenderingControllerTests.swift`

- [ ] **Step 1: Add Codable migration tests**

In `SceneDescriptorCodableTests`, add:

```swift
@Test("SceneDescriptor decodes missing dependencyWorkshopIDs as empty")
func sceneDescriptorMissingDependenciesDecodeAsEmpty() throws {
    let payload: [String: Any] = [
        "workshopID": "abc",
        "cacheRelativePath": "wpe-cache/abc",
        "entryFile": "scene.json",
        "capabilityTier": "imageOnly"
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)

    let decoded = try JSONDecoder().decode(SceneDescriptor.self, from: data)

    #expect(decoded.dependencyWorkshopIDs == [])
}

@Test("SceneDescriptor round-trips dependencyWorkshopIDs")
func sceneDescriptorDependenciesRoundTrip() throws {
    let descriptor = SceneDescriptor(
        workshopID: "main",
        cacheRelativePath: "wpe-cache/main",
        entryFile: "scene.json",
        capabilityTier: .degraded,
        dependencyWorkshopIDs: ["111", "222"]
    )

    let data = try JSONEncoder().encode(descriptor)
    let decoded = try JSONDecoder().decode(SceneDescriptor.self, from: data)

    #expect(decoded == descriptor)
}
```

- [ ] **Step 2: Update `SceneDescriptor` schema**

Add:

```swift
let dependencyWorkshopIDs: [String]
```

Update init:

```swift
init(
    workshopID: String,
    cacheRelativePath: String,
    entryFile: String,
    capabilityTier: SceneCapabilityTier,
    dependencyWorkshopIDs: [String] = []
) {
    self.workshopID = workshopID
    self.cacheRelativePath = cacheRelativePath
    self.entryFile = entryFile
    self.capabilityTier = capabilityTier
    self.dependencyWorkshopIDs = dependencyWorkshopIDs
}
```

Update coding:

```swift
case dependencyWorkshopIDs
dependencyWorkshopIDs = (try? c.decodeIfPresent([String].self, forKey: .dependencyWorkshopIDs)) ?? []
```

- [ ] **Step 3: Add dependency IDs to `WPEOrigin` for history rebuild**

Add:

```swift
var dependencyWorkshopIDs: [String]
```

Default to `[]` in the init and decoder, mirroring `missingDependencyIDs`.

- [ ] **Step 4: Persist dependency IDs during import and cache rebuild**

In `WallpaperEngineImportService`, pass `project.dependencyWorkshopIDs` into both:

```swift
SceneDescriptor(..., dependencyWorkshopIDs: project.dependencyWorkshopIDs)
```

and:

```swift
makeOrigin(..., dependencyWorkshopIDs: project.dependencyWorkshopIDs)
```

In `WPECachedContentResolver.content(for:)`, rebuild:

```swift
SceneDescriptor(
    workshopID: origin.workshopID,
    cacheRelativePath: cacheRelativePath,
    entryFile: entryFile,
    capabilityTier: tier,
    dependencyWorkshopIDs: origin.dependencyWorkshopIDs
)
```

- [ ] **Step 5: Add mount types**

Create `WPEAssetMount.swift`:

```swift
import Foundation

struct WPEAssetMount: Equatable, Sendable {
    let workshopID: String
    let rootURL: URL

    init(workshopID: String, rootURL: URL) {
        self.workshopID = workshopID
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
    }
}
```

- [ ] **Step 6: Add multi-root resolver tests and implementation**

Create tests proving:

- `../123/materials/dep.png` resolves only when `123` is declared and mounted.
- undeclared `../123/...`, `../../...`, absolute paths, backslashes, and symlink escapes are rejected.

Implementation shape:

```swift
struct WPEMultiRootResourceResolver: Sendable {
    let primary: SceneResourceResolver
    let dependencyMounts: [String: SceneResourceResolver]

    init(primaryRootURL: URL, dependencyMounts: [WPEAssetMount]) {
        self.primary = SceneResourceResolver(cacheRootURL: primaryRootURL)
        self.dependencyMounts = Dictionary(
            uniqueKeysWithValues: dependencyMounts.map { ($0.workshopID, SceneResourceResolver(cacheRootURL: $0.rootURL)) }
        )
    }

    func resolveExistingFileURL(relativePath: String) throws -> URL {
        if relativePath.hasPrefix("../") {
            let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count >= 3, parts[0] == ".." else {
                throw SceneResourceResolver.ResolveError.pathEscape
            }
            let workshopID = String(parts[1])
            let childPath = parts.dropFirst(2).joined(separator: "/")
            guard let resolver = dependencyMounts[workshopID] else {
                throw SceneResourceResolver.ResolveError.pathEscape
            }
            return try resolver.resolveExistingFileURL(relativePath: childPath)
        }
        return try primary.resolveExistingFileURL(relativePath: relativePath)
    }
}
```

- [ ] **Step 7: Add dependency mount resolver**

Create `WPEDependencyMountResolver` that resolves in this order:

1. Cached root: `Application Support/LiveWallpaper/wpe-cache/<id>` when it exists and contains `project.json` or extracted scene assets.
2. Source sibling root: resolve `WPEOrigin.sourceFolderBookmark`, take its parent folder, then `<id>` if it exists and contains `project.json`.

The resolver must return only declared IDs:

```swift
func mounts(
    dependencyWorkshopIDs: [String],
    origin: WPEOrigin?,
    applicationSupportRootURL: URL,
    fileManager: FileManager = .default
) -> [WPEAssetMount]
```

- [ ] **Step 8: Make `ScreenManager` own mount resolution**

Change `activateAmbientWallpaper` to receive configuration:

```swift
private func activateAmbientWallpaper(
    _ definition: WallpaperSessionDefinition,
    for screen: Screen,
    configuration: ScreenConfiguration
)
```

For `.scene(let descriptor)`, compute:

```swift
let dependencyMounts = WPEDependencyMountResolver().mounts(
    dependencyWorkshopIDs: descriptor.dependencyWorkshopIDs,
    origin: configuration.wpeOrigin,
    applicationSupportRootURL: resolvedApplicationSupportRoot
)
```

Then call:

```swift
ambientSessionBuilder.makeSceneSession(
    descriptor: descriptor,
    frame: screen.frame,
    dependencyMounts: dependencyMounts
)
```

- [ ] **Step 9: Pass mounts into runtime**

Update signatures:

```swift
func makeSceneSession(..., dependencyMounts: [WPEAssetMount] = []) -> SceneWallpaperSession?
```

```swift
init(descriptor: SceneDescriptor, cacheRootURL: URL, dependencyMounts: [WPEAssetMount] = [], frame: CGRect)
```

Inside `SceneRenderingController`, use `WPEMultiRootResourceResolver` for image references. Unknown cross-package references still surface `.pathEscape`.

- [ ] **Step 10: Run targeted tests**

```bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -only-testing:LiveWallpaperTests/SceneDescriptorCodableTests -only-testing:LiveWallpaperTests/WallpaperEngineImportServiceTests -only-testing:LiveWallpaperTests/WPEMultiRootResourceResolverTests -only-testing:LiveWallpaperTests/WPEDependencyMountResolverTests -only-testing:LiveWallpaperTests/SceneRenderingControllerTests
```

Expected: targeted tests pass; old descriptors decode with empty dependency IDs.

- [ ] **Step 11: Commit**

```bash
git add LiveWallpaper/Models/SceneDescriptor.swift LiveWallpaper/Models/WPEOrigin.swift LiveWallpaper/Models/ScreenConfiguration.swift LiveWallpaper/Infrastructure/WPEAssetMount.swift LiveWallpaper/Infrastructure/WPEMultiRootResourceResolver.swift LiveWallpaper/Infrastructure/WPEDependencyMountResolver.swift LiveWallpaper/Infrastructure/WallpaperEngineImportService.swift LiveWallpaper/Runtime/SceneRenderingController.swift LiveWallpaper/Runtime/AmbientWallpaperSessionBuilder.swift LiveWallpaper/ScreenManager.swift LiveWallpaperTests/SceneDescriptorCodableTests.swift LiveWallpaperTests/WallpaperEngineImportServiceTests.swift LiveWallpaperTests/WPEMultiRootResourceResolverTests.swift LiveWallpaperTests/WPEDependencyMountResolverTests.swift LiveWallpaperTests/SceneRenderingControllerTests.swift
git commit -m "feat: mount declared WPE dependency roots"
```

**Difference from current framework:** dependencies become persisted runtime metadata instead of an import-time pass/fail check only.  
**Why:** runtime needs declared roots to safely resolve WPE cross-package references.  
**Improvement:** dependency-backed assets can load from cache or source siblings without opening path traversal holes.

---

## Verification Strategy For Phase 1

Run targeted tests after each task. Before claiming Phase 1 complete, run:

```bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -skip-testing:LiveWallpaperUITests
```

Run the full suite only when UI automation is available. Current observed blocker: `LiveWallpaperUITests-Runner` timed out while enabling automation mode.

## Phase 2/3 Roadmap, Not Implementation Plan

Phase 2A landed in `2026-05-05-wpe-metal-renderer-boundary.md` (renderer boundary + BC native mapping + raw `.tex` payloads + minimal built-in executor).

The remaining Phase 2 sub-plans (2B-2J) are decomposed in
**`2026-05-05-wpe-phase2-remaining-roadmap.md`**. That document supersedes
the 6-bullet stub that previously lived here. It covers:

- Phase 2A holdovers H1-H3 (`loadDiagnostics` parity, `dependencyMounts`
  plumbing, sRGB / color management) — bugs in shipped code, not new
  sub-phases.
- Phase 2B scene-runtime hardening (clock, camera, mouse parallax,
  off-main texture upload, Metal preview snapshot, diagnostics parity).
- Phase 2C multi-pass executor (FBO pool, blend modes, `previous` /
  `fbo:<name>` source resolution, util base passes).
- Phase 2D GLSL→MSL translator (with an explicit
  SPIRV-Cross-vs-hand-rolled pre-decision).
- Phase 2E animated and video TEX.
- Phase 2F particle system.
- Phase 2G audio uniforms and sound objects.
- Phase 2H model / light / text / puppet warp (split into 2H-static and
  2H-puppet).
- Phase 2I web compatibility (HTML + minimal WPE JS API shim).
- Phase 2J production cutover (default backend switch behind acceptance +
  soak gates).

Each sub-phase is sized for one PR and lists explicit dependencies,
fixtures, and acceptance criteria.

## Self-Review

- Spec coverage for Phase 1: parser honesty, full-chain capability probing, cached scene reclassification, transform regression safety, and dependency mount resolution are covered.
- Placeholder scan: Phase 1 tasks contain concrete file paths, test snippets, implementation snippets, commands, and expected results. Phase 2/3 are explicitly marked roadmap, not executable implementation tasks.
- Type consistency: Phase 1 types are `WPESceneObjectKind`, `WPESceneObjectKindResolution`, `WPESceneCapabilityClassifier`, `WPESceneTransformMapper`, `WPEAssetMount`, `WPEMultiRootResourceResolver`, and `WPEDependencyMountResolver`.
