# WPE Phase 2E Animated And Video TEX Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Support WPE Workshop moving textures in the experimental Metal renderer: multi-frame animated `.tex` payloads and MP4 video payloads embedded in `.tex` containers.

**Architecture:** Phase 2E keeps `WPEMetalRenderExecutor` consuming `[String: MTLTexture]` so Phase 2C texture-binding plumbing remains the boundary. Static `.tex` files still upload as one `MTLTexture`; animated/video `.tex` files create retained dynamic texture sources that return the current `MTLTexture` for `g_Time` each render frame. Video frames are decoded on a dedicated background queue through `AVAssetReader` and published through `CVMetalTextureCache`.

**Tech Stack:** Swift 6 strict concurrency, Foundation, AVFoundation, CoreVideo, CoreMedia, Metal, MetalKit, Swift Testing, `xcodebuild`.

---

## Suitability Assessment

Phase 2E is executable after Phase 2A, Phase 2A holdovers, Phase 2B, and Phase 2C are on `main`:

- `WPETexDecoder` already parses `TEXV` / `TEXI` / `TEXB` containers and detects MP4-like payloads, but it currently throws `.unsupportedAnimation` for MP4 and keeps only the first image when `TEXB.imageCount > 1`.
- `WPETexTexturePayload` already exists as the Metal-facing texture payload, so animation/video metadata can extend that contract without changing the SpriteKit fallback decode path.
- `WPEMetalTextureLoader` already maps WPE texture formats to Metal pixel formats and uploads raw mip bytes; animated TEX can reuse this upload path per frame.
- Phase 2B provides `WPEMetalFrameClock`, `WPEMetalRuntimeUniforms.time`, renderer-side `renderCurrentFrame()`, and repeated Metal rendering from `draw(in:)`, which are required for time-driven texture advancement.
- Phase 2C keeps source resolution keyed by `WPETextureReference.image(path)` / `.asset(path)` and executor texture dictionaries, so dynamic sources only need to refresh the texture dictionary before each `executor.render(...)`.
- Swift Testing fixtures already use `#require(MTLCreateSystemDefaultDevice())`, so Metal-dependent tests skip on CI hosts without Metal.
- There is no `.context/` directory in the current checkout, so no `.context/prefs/coding-style.md`, `.context/prefs/workflow.md`, or `.context/history/commits.jsonl` constraints apply.
- The local checkout may be behind the Phase 2C merge. Execute this plan only after rebasing onto `main` that includes PR #20, then adjust line-local snippets to the merged signatures.

Reverse-engineering references used for TEX layout cross-checks:

- RePKG `TexFlags`: `IsGif = 4`, `IsVideoTexture = 32`.
- RePKG `TexFrameInfoContainerReader`: `TEXS0001` integer frame rects, `TEXS0002/0003` float frame rects, `TEXS0003` GIF width/height.
- RePKG `TexImageContainerReader`: `TEXB0004` carries `imageFormat` and `isVideoMp4`.
- RePKG `TexToImageConverter`: MP4 payloads are emitted as video bytes, GIF/TEXS frames carry `imageId` plus per-frame time.

---

## Architecture Decision

### Rationale

Phase 2E adds three bounded runtime concepts:

- **Payload metadata:** `WPETexTexturePayload` gains optional `animationTrack` and `videoPayload`. Static callers keep using `mipmaps` and `largestMipmap`.
- **Animated source:** `WPETexAnimatedTextureSource` owns pre-uploaded frame textures and computes `frameIndex = floor((time * frameRate) % frameCount)`. Default frame rate is 25 FPS when TEXS timings are absent or unusable.
- **Video source:** `WPEVideoTextureSource` owns a temp-file-backed `AVURLAsset`, background `AVAssetReader`, and `CVMetalTextureCache`. `texture(at:)` is non-blocking and returns the latest published frame while the reader decodes asynchronously.

The renderer owns dynamic sources strongly in `dynamicTextureSources: [String: WPEDynamicTextureSource]`. Before each render it computes runtime uniforms, asks each source for `texture(at: uniforms.time)`, and overlays those current textures into the dictionary passed to `WPEMetalRenderExecutor`.

### URL-Backed AVAsset

Use a URL-backed asset, not a hypothetical in-memory `AVAsset`:

- Persist MP4 bytes under the app caches directory: `Caches/wpe-tex-video/<uuid>.mp4`.
- Create `AVURLAsset(url: persistedURL)`.
- Keep the temp URL in `WPEVideoTextureSource`.
- Remove the temp file on `invalidate()`, `reload()`, and `cleanup()`.

This matches macOS AVFoundation behavior: reliable `AVAssetReader` construction needs a URL-backed asset. The file is not user-visible and is scoped to the source lifecycle.

### CVMetalTextureCache Lifecycle

Create one `CVMetalTextureCache` per `WPEVideoTextureSource` with the same `MTLDevice` used by `WPEMetalRenderExecutor`:

- Add an internal executor property such as `textureSourceDevice: MTLDevice { device }`.
- Pass that device from `WPEMetalSceneRenderer` into `WPEVideoTextureSource`.
- Convert `CVPixelBuffer` frames with `CVMetalTextureCacheCreateTextureFromImage`.
- Store the `CVMetalTexture` next to its `MTLTexture` so the Metal texture remains valid.
- On `.suspended`, `reload()`, and `cleanup()`: cancel and nil the reader, clear retained frame buffers, and call `CVMetalTextureCacheFlush(cache, 0)`.

### Animation Track Storage

Store animation as frame-owned mip arrays:

~~~swift
struct WPETexAnimationTrack: Sendable, Equatable {
    static let defaultFrameRate: Double = 25

    let frames: [WPETexAnimationFrame]
    let frameRate: Double
    let loop: Bool
}

struct WPETexAnimationFrame: Sendable, Equatable {
    let imageID: Int
    let duration: TimeInterval
    let mipmaps: [WPETexTextureMipmap]
}
~~~

`TEXB.imageCount` is the primary frame source. `TEXS` frame info is parsed when present to recover `imageID` and `frametime`; Phase 2E stores crop/rotation metadata only if needed for diagnostics or future work, but runtime frame selection initially uses full-frame textures and the constant frame-rate formula required by acceptance.

### Rejected Alternatives

- **Do not convert animated TEX to GIF.** That would regress Metal-native texture binding and add CPU/image transcoding.
- **Do not add a second render executor.** Phase 2C already centralizes source resolution in `WPEMetalRenderExecutor`; dynamic sources can feed the existing texture dictionary.
- **Do not block `texture(at:)` waiting for video decode.** The renderer must stay responsive; video may return the previous frame while the reader catches up.
- **Do not use `AVPlayerItemVideoOutput`.** It is simpler for playback but less explicit about reader lifecycle and harder to assert reader release on `.suspended`.
- **Do not touch `WPESceneDetailView`.** Phase 2E has no UI surface.
- **Do not add HAP/ProRes/alpha-video support.** Workshop scope for this phase is MP4.

### Assumptions

- `TEXB.imageCount > 1` means animated frames even when `TEXS` is absent.
- Missing or invalid frame timing defaults to 25 FPS.
- `WPETexInfo.flags & 4 != 0` indicates animated/GIF-style frame metadata may follow `TEXB`.
- `WPETexInfo.flags & 32 != 0`, `TEXB0004.isVideoMP4 == 1`, or an `ftyp` payload header identifies MP4-in-TEX.
- Video color should be exposed as `.bgra8Unorm_srgb` when `CVMetalTextureCache` accepts it; fallback to `.bgra8Unorm` only if needed after testing.
- Animated BC textures are allowed only if the current Metal device supports BC sampling, using the existing format mapper.
- The renderer can tolerate a one-frame stale video texture while the background reader publishes the next frame.

### Potential Side Effects

- Animated textures multiply GPU memory by frame count. Phase 2E keeps full pre-uploaded frame textures for deterministic lookup and simpler lifecycle.
- Large MP4 TEX payloads are copied once into `Caches/wpe-tex-video`; disk cache pressure increases until source invalidation.
- Suspending a video source cancels the reader. Resuming restarts decode and may display the latest retained frame or nil for one render frame.
- If real Workshop animated TEX uses atlas crop/rotation heavily, Phase 2E may need a follow-up to pass frame UV transforms into the shader path. This plan stores enough frame info to make that follow-up local.

---

## Scope

### In Scope

- Parse all image groups in `TEXB`, not only image index 0.
- Parse `TEXS0001`, `TEXS0002`, and `TEXS0003` frame timing metadata.
- Expose `WPETexTexturePayload.animationTrack`.
- Expose `WPETexTexturePayload.videoPayload` with extracted MP4 bytes.
- Upload animated TEX frames into `MTLTexture` arrays.
- Add `WPETexAnimatedTextureSource.texture(at:)`.
- Add `WPEVideoTextureSource.texture(at:)` backed by `AVAssetReader` and `CVMetalTextureCache`.
- Persist MP4 bytes to `Caches/wpe-tex-video/` and delete them on invalidation.
- Keep strong renderer references to animated/video texture sources.
- Refresh dynamic textures before every executor render using Phase 2B `g_Time`.
- Pause/release video readers and flush texture caches on `.suspended`.
- Release all dynamic sources on `reload()` and `cleanup()`.
- Add deterministic tests for 25 FPS animated frame indexing.
- Add automated non-blocking video lookup and suspended-reader-release tests.
- Preserve Phase 2A/2B/2C tests.

### Out Of Scope

- Alpha video.
- HAP.
- ProRes.
- Video audio extraction.
- Parallax interaction with animated TEX.
- Custom GLSL effects consuming multi-frame textures.
- Per-frame readback timer for detail-view snapshots.
- `WPESceneDetailView` changes.
- New third-party dependencies.

---

## File Structure

### New Files

- `LiveWallpaper/Runtime/WPEDynamicTextureSource.swift`
  - Shared dynamic source protocol plus small value wrappers used by animated and video sources.
- `LiveWallpaper/Runtime/WPETexAnimatedTextureSource.swift`
  - Pre-uploaded frame texture source and deterministic frame-index math.
- `LiveWallpaper/Runtime/WPEVideoTextureSource.swift`
  - URL-backed `AVAssetReader`, background decode queue, `CVMetalTextureCache`, suspend/invalidate lifecycle.
- `LiveWallpaperTests/WPETexAnimatedTextureSourceTests.swift`
  - Frame index and texture lookup tests.
- `LiveWallpaperTests/WPEVideoTextureSourceTests.swift`
  - MP4 source non-blocking lookup and suspended reader release tests.

### Existing Files To Modify

- `LiveWallpaper/Models/WPETexErrors.swift`
  - Add animation/video payload value types and extend `WPETexTexturePayload`.
- `LiveWallpaper/Infrastructure/WPETexDecoder.swift`
  - Keep all `TEXB` image groups, parse `TEXS`, extract MP4 bytes instead of throwing from Metal payload extraction.
- `LiveWallpaper/Infrastructure/WPEMetalTextureLoader.swift`
  - Add animated-source upload helper and guard static upload against video payloads.
- `LiveWallpaper/Runtime/WPEMetalRenderExecutor.swift`
  - Expose internal device handle for texture sources; no source resolution behavior change.
- `LiveWallpaper/Runtime/WPEMetalSceneRenderer.swift`
  - Store `loadedTextures`, dynamic sources, and per-frame dynamic texture refresh; release sources on lifecycle transitions.
- `LiveWallpaperTests/WPETexDecoderTests.swift`
  - Keep SpriteKit decode rejecting MP4 as `.unsupportedAnimation`.
- `LiveWallpaperTests/WPETexTexturePayloadTests.swift`
  - Add animated and video payload extraction tests; update old MP4 rejection test.
- `LiveWallpaperTests/WPEMetalTextureLoaderTests.swift`
  - Add animated upload test.
- `LiveWallpaperTests/WPEMetalSceneRendererTests.swift`
  - Add dynamic source retention and suspended release tests.

---

## Task 1: Decode Animated And Video TEX Payload Metadata

**Files:**

- Modify: `LiveWallpaper/Models/WPETexErrors.swift`
- Modify: `LiveWallpaper/Infrastructure/WPETexDecoder.swift`
- Test: `LiveWallpaperTests/WPETexTexturePayloadTests.swift`
- Test: `LiveWallpaperTests/WPETexDecoderTests.swift`

- [ ] **Step 1: Write failing animated/video extraction tests**

Append to `LiveWallpaperTests/WPETexTexturePayloadTests.swift`:

~~~swift
@Test("Extracts all TEXB image groups as animation frames with 25 FPS default")
func extractsAnimationFramesFromMultiImageTEXB() throws {
    let red = Data([255, 0, 0, 255])
    let green = Data([0, 255, 0, 255])
    let blue = Data([0, 0, 255, 255])
    let white = Data([255, 255, 255, 255])
    let tex = makeAnimatedImage(width: 1, height: 1, framePayloads: [red, green, blue, white])

    let payload = try WPETexDecoder().extractTexturePayload(data: tex).get()

    let animation = try #require(payload.animationTrack)
    #expect(payload.hasAnimationFrames)
    #expect(animation.frames.count == 4)
    #expect(animation.frameRate == WPETexAnimationTrack.defaultFrameRate)
    #expect(animation.loop)
    #expect(animation.frames.map(\.imageID) == [0, 1, 2, 3])
    #expect(animation.frames[0].mipmaps[0].bytes == red)
    #expect(animation.frames[1].mipmaps[0].bytes == green)
    #expect(animation.frames[2].mipmaps[0].bytes == blue)
    #expect(animation.frames[3].mipmaps[0].bytes == white)
}

@Test("Extracts TEXS frame timing when present")
func extractsTEXSFrameTiming() throws {
    let frame0 = Data([10, 20, 30, 255])
    let frame1 = Data([40, 50, 60, 255])
    let tex = makeAnimatedImage(
        width: 1,
        height: 1,
        framePayloads: [frame0, frame1],
        frameTimes: [0.10, 0.20]
    )

    let payload = try WPETexDecoder().extractTexturePayload(data: tex).get()

    let animation = try #require(payload.animationTrack)
    #expect(animation.frames.count == 2)
    #expect(abs(animation.frames[0].duration - 0.10) < 0.0001)
    #expect(abs(animation.frames[1].duration - 0.20) < 0.0001)
    #expect(abs(animation.frameRate - (1.0 / 0.15)) < 0.0001)
}

@Test("Extracts MP4 bytes for Metal video texture source")
func extractsVideoPayload() throws {
    let mp4 = mp4HeaderPayload()
    let tex = makeVideoImage(width: 1920, height: 1080, payload: mp4)

    let payload = try WPETexDecoder().extractTexturePayload(data: tex).get()

    let video = try #require(payload.videoPayload)
    #expect(video.bytes == mp4)
    #expect(payload.animationTrack == nil)
    #expect(payload.mipmaps.isEmpty)
}
~~~

Add helpers to the same test suite:

~~~swift
private func makeAnimatedImage(
    width: Int,
    height: Int,
    framePayloads: [Data],
    frameTimes: [Float]? = nil
) -> Data {
    var buffer = Data()
    appendMagic(&buffer, magic: "TEXV0005")
    appendMagic(&buffer, magic: "TEXI0001")
    appendInt32(&buffer, Int32(WPETexFormat.rgba8888.rawValue))
    appendUInt32(&buffer, frameTimes == nil ? 0 : 4)
    appendInt32(&buffer, Int32(width))
    appendInt32(&buffer, Int32(height))
    appendInt32(&buffer, Int32(width))
    appendInt32(&buffer, Int32(height))
    appendInt32(&buffer, 0)

    appendMagic(&buffer, magic: "TEXB0003")
    appendInt32(&buffer, Int32(framePayloads.count))
    appendInt32(&buffer, -1)

    for payload in framePayloads {
        appendInt32(&buffer, 1)
        appendInt32(&buffer, Int32(width))
        appendInt32(&buffer, Int32(height))
        appendUInt32(&buffer, 0)
        appendUInt32(&buffer, UInt32(payload.count))
        appendUInt32(&buffer, UInt32(payload.count))
        buffer.append(payload)
    }

    if let frameTimes {
        appendMagic(&buffer, magic: "TEXS0002")
        appendInt32(&buffer, Int32(frameTimes.count))
        for (index, frameTime) in frameTimes.enumerated() {
            appendInt32(&buffer, Int32(index))
            appendFloat32(&buffer, frameTime)
            appendFloat32(&buffer, 0)
            appendFloat32(&buffer, 0)
            appendFloat32(&buffer, Float(width))
            appendFloat32(&buffer, 0)
            appendFloat32(&buffer, 0)
            appendFloat32(&buffer, Float(height))
        }
    }

    return buffer
}

private func makeVideoImage(width: Int, height: Int, payload: Data) -> Data {
    var buffer = Data()
    appendMagic(&buffer, magic: "TEXV0005")
    appendMagic(&buffer, magic: "TEXI0001")
    appendInt32(&buffer, Int32(WPETexFormat.rgba8888.rawValue))
    appendUInt32(&buffer, 32)
    appendInt32(&buffer, Int32(width))
    appendInt32(&buffer, Int32(height))
    appendInt32(&buffer, Int32(width))
    appendInt32(&buffer, Int32(height))
    appendInt32(&buffer, 0)

    appendMagic(&buffer, magic: "TEXB0004")
    appendInt32(&buffer, 1)
    appendInt32(&buffer, -1)
    appendInt32(&buffer, 1)
    appendInt32(&buffer, 1)
    appendInt32(&buffer, 1)
    appendNullTerminatedString(&buffer, "")
    appendInt32(&buffer, 1)
    appendInt32(&buffer, Int32(width))
    appendInt32(&buffer, Int32(height))
    appendUInt32(&buffer, 0)
    appendUInt32(&buffer, UInt32(payload.count))
    appendUInt32(&buffer, UInt32(payload.count))
    buffer.append(payload)
    return buffer
}

private func appendFloat32(_ data: inout Data, _ value: Float) {
    var le = value.bitPattern.littleEndian
    withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
}

private func appendNullTerminatedString(_ data: inout Data, _ value: String) {
    data.append(contentsOf: value.utf8)
    data.append(0)
}
~~~

Keep the existing `WPETexDecoderTests.mp4PayloadIsUnsupportedAnimation` unchanged. SpriteKit decode still rejects MP4 because Phase 2E only enables the Metal texture path.

- [ ] **Step 2: Run tests to verify failure**

Run:

~~~bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPETexTexturePayloadTests -only-testing:LiveWallpaperTests/WPETexDecoderTests
~~~

Expected: FAIL because `animationTrack` and `videoPayload` do not exist, and MP4 extraction still throws `.unsupportedAnimation`.

- [ ] **Step 3: Add payload value types**

Modify `LiveWallpaper/Models/WPETexErrors.swift` near `WPETexTexturePayload`:

~~~swift
struct WPETexAnimationTrack: Sendable, Equatable {
    static let defaultFrameRate: Double = 25

    let frames: [WPETexAnimationFrame]
    let frameRate: Double
    let loop: Bool

    var frameCount: Int { frames.count }
}

struct WPETexAnimationFrame: Sendable, Equatable {
    let imageID: Int
    let duration: TimeInterval
    let mipmaps: [WPETexTextureMipmap]
}

struct WPETexVideoPayload: Sendable, Equatable {
    let bytes: Data
    let fileExtension: String

    init(bytes: Data, fileExtension: String = "mp4") {
        self.bytes = bytes
        self.fileExtension = fileExtension
    }
}

struct WPETexTexturePayload: Sendable, Equatable {
    let info: WPETexInfo
    let mipmaps: [WPETexTextureMipmap]
    let animationTrack: WPETexAnimationTrack?
    let videoPayload: WPETexVideoPayload?

    private let explicitAnimationFlag: Bool

    init(
        info: WPETexInfo,
        mipmaps: [WPETexTextureMipmap],
        hasAnimationFrames: Bool,
        animationTrack: WPETexAnimationTrack? = nil,
        videoPayload: WPETexVideoPayload? = nil
    ) {
        self.info = info
        self.mipmaps = mipmaps
        self.explicitAnimationFlag = hasAnimationFrames
        self.animationTrack = animationTrack
        self.videoPayload = videoPayload
    }

    var hasAnimationFrames: Bool {
        explicitAnimationFlag || animationTrack != nil
    }

    var largestMipmap: WPETexTextureMipmap? {
        mipmaps.first
    }
}
~~~

- [ ] **Step 4: Preserve all TEXB image groups and parse TEXS**

Modify `WPETexBitmapBlock` in `LiveWallpaper/Models/WPETexErrors.swift`:

~~~swift
struct WPETexBitmapBlock: Sendable, Equatable {
    let version: Int
    let sourceImageFormatCode: Int?
    let isVideoPayload: Bool
    let frames: [[WPETexMipmap]]

    var mipmaps: [WPETexMipmap] {
        frames.first ?? []
    }

    var largestMipmap: WPETexMipmap? {
        mipmaps.first
    }

    var usesEncodedImagePayload: Bool {
        guard let sourceImageFormatCode else { return false }
        return sourceImageFormatCode != -1 && !isVideoPayload
    }
}
~~~

In `WPETexDecoder.swift`, extend `ParsedTex` and add frame-info types:

~~~swift
private struct ParsedTex {
    let info: WPETexInfo
    let bitmap: WPETexBitmapBlock
    let frameInfo: WPETexFrameInfoBlock?
    let hasAnimationFrames: Bool
}

private struct WPETexFrameInfoBlock {
    let version: Int
    let gifWidth: Int?
    let gifHeight: Int?
    let frames: [WPETexFrameInfo]
}

private struct WPETexFrameInfo {
    let imageID: Int
    let frameTime: TimeInterval
    let x: Float
    let y: Float
    let width: Float
    let widthY: Float
    let heightX: Float
    let height: Float
}
~~~

Replace the parser loop so it continues after `TEXB` when a `TEXS` block exists:

~~~swift
private func parse(data: Data) throws -> ParsedTex {
    var reader = WPETexByteReader(data: data)
    let containerMagic = try reader.readMagic()
    guard containerMagic.hasPrefix("TEXV") else {
        throw WPETexDecodeError.unsupportedContainer(magic: containerMagic)
    }
    let containerVersion = parseTrailingVersion(containerMagic)

    var info: WPETexInfo?
    var bitmap: WPETexBitmapBlock?
    var frameInfo: WPETexFrameInfoBlock?

    while !reader.isAtEnd {
        let blockMagic = try reader.readMagic()
        switch blockMagic.prefix(4) {
        case "TEXI":
            info = try parseInfoBlock(
                versionedMagic: blockMagic,
                containerVersion: containerVersion,
                reader: &reader
            )

        case "TEXB":
            guard let parsedInfo = info else {
                throw WPETexDecodeError.missingInfoBlock
            }
            bitmap = try parseBitmapBlock(
                versionedMagic: blockMagic,
                info: parsedInfo,
                reader: &reader
            )

        case "TEXS":
            frameInfo = try parseFrameInfoBlock(
                versionedMagic: blockMagic,
                reader: &reader
            )

        default:
            throw WPETexDecodeError.unsupportedBlock(magic: blockMagic)
        }
    }

    guard let parsedInfo = info else { throw WPETexDecodeError.missingInfoBlock }
    guard let parsedBitmap = bitmap else { throw WPETexDecodeError.missingBitmapBlock }

    let hasAnimation = parsedBitmap.frames.count > 1 || frameInfo != nil
    return ParsedTex(
        info: parsedInfo,
        bitmap: parsedBitmap,
        frameInfo: frameInfo,
        hasAnimationFrames: hasAnimation
    )
}
~~~

Update `parseBitmapBlock(...)` to retain every image group:

~~~swift
var frames: [[WPETexMipmap]] = []
frames.reserveCapacity(imageCount)

for _ in 0..<imageCount {
    let mipmapCount = Int(try reader.readInt32(blockName: "TEXB.mipCount"))
    guard mipmapCount > 0 && mipmapCount <= 32 else {
        throw WPETexDecodeError.mipmapOutOfBounds(index: mipmapCount)
    }

    var frameMipmaps: [WPETexMipmap] = []
    frameMipmaps.reserveCapacity(mipmapCount)
    for mipmapIndex in 0..<mipmapCount {
        frameMipmaps.append(try parseMipmap(
            version: effectiveBitmapVersion,
            index: mipmapIndex,
            reader: &reader
        ))
    }
    frames.append(frameMipmaps)
}

return WPETexBitmapBlock(
    version: bitmapVersion,
    sourceImageFormatCode: sourceImageFormatCode,
    isVideoPayload: isVideoPayload,
    frames: frames
)
~~~

Add `parseFrameInfoBlock(...)`:

~~~swift
private func parseFrameInfoBlock(
    versionedMagic: String,
    reader: inout WPETexByteReader
) throws -> WPETexFrameInfoBlock {
    let version = parseTrailingVersion(versionedMagic)
    let frameCount = Int(try reader.readInt32(blockName: "TEXS.frameCount"))
    guard frameCount > 0 && frameCount <= 4_096 else {
        throw WPETexDecodeError.mipmapOutOfBounds(index: frameCount)
    }

    let gifWidth: Int?
    let gifHeight: Int?
    if version == 3 {
        gifWidth = Int(try reader.readInt32(blockName: "TEXS.gifWidth"))
        gifHeight = Int(try reader.readInt32(blockName: "TEXS.gifHeight"))
    } else {
        gifWidth = nil
        gifHeight = nil
    }

    var frames: [WPETexFrameInfo] = []
    frames.reserveCapacity(frameCount)

    for _ in 0..<frameCount {
        let imageID = Int(try reader.readInt32(blockName: "TEXS.imageID"))
        let frameTime = TimeInterval(try reader.readFloat32(blockName: "TEXS.frameTime"))

        if version == 1 {
            frames.append(WPETexFrameInfo(
                imageID: imageID,
                frameTime: frameTime,
                x: Float(try reader.readInt32(blockName: "TEXS.x")),
                y: Float(try reader.readInt32(blockName: "TEXS.y")),
                width: Float(try reader.readInt32(blockName: "TEXS.width")),
                widthY: Float(try reader.readInt32(blockName: "TEXS.widthY")),
                heightX: Float(try reader.readInt32(blockName: "TEXS.heightX")),
                height: Float(try reader.readInt32(blockName: "TEXS.height"))
            ))
        } else if version == 2 || version == 3 {
            frames.append(WPETexFrameInfo(
                imageID: imageID,
                frameTime: frameTime,
                x: try reader.readFloat32(blockName: "TEXS.x"),
                y: try reader.readFloat32(blockName: "TEXS.y"),
                width: try reader.readFloat32(blockName: "TEXS.width"),
                widthY: try reader.readFloat32(blockName: "TEXS.widthY"),
                heightX: try reader.readFloat32(blockName: "TEXS.heightX"),
                height: try reader.readFloat32(blockName: "TEXS.height")
            ))
        } else {
            throw WPETexDecodeError.unsupportedBlock(magic: versionedMagic)
        }
    }

    return WPETexFrameInfoBlock(
        version: version,
        gifWidth: gifWidth,
        gifHeight: gifHeight,
        frames: frames
    )
}
~~~

Add `readFloat32` to the local byte reader if it does not already exist:

~~~swift
mutating func readFloat32(blockName: String) throws -> Float {
    let bits = try readUInt32(blockName: blockName)
    return Float(bitPattern: bits)
}
~~~

- [ ] **Step 5: Build animation/video payloads in `extractTexturePayload`**

Replace the MP4 rejection branch in `extractTexturePayload(data:)`:

~~~swift
let parsed = try parse(data: data)

if let videoPayload = try makeVideoPayload(from: parsed) {
    return .success(WPETexTexturePayload(
        info: parsed.info,
        mipmaps: [],
        hasAnimationFrames: false,
        videoPayload: videoPayload
    ))
}

guard !parsed.bitmap.usesEncodedImagePayload else {
    throw WPETexDecodeError.unsupportedFormat(code: parsed.info.textureFormatCode)
}

let firstFrameMipmaps = try normalizedTextureMipmaps(
    parsed.bitmap.mipmaps,
    info: parsed.info
)
let animationTrack = try makeAnimationTrack(from: parsed)

return .success(WPETexTexturePayload(
    info: parsed.info,
    mipmaps: firstFrameMipmaps,
    hasAnimationFrames: parsed.hasAnimationFrames,
    animationTrack: animationTrack
))
~~~

Add helpers:

~~~swift
private func normalizedTextureMipmaps(
    _ mipmaps: [WPETexMipmap],
    info: WPETexInfo
) throws -> [WPETexTextureMipmap] {
    try mipmaps.map { mipmap in
        WPETexTextureMipmap(
            index: mipmap.index,
            width: mipmap.width,
            height: mipmap.height,
            bytes: try normalizedBytes(
                for: mipmap,
                format: info.format,
                textureFormatCode: info.textureFormatCode
            )
        )
    }
}

private func makeAnimationTrack(from parsed: ParsedTex) throws -> WPETexAnimationTrack? {
    guard parsed.bitmap.frames.count > 1 else { return nil }

    let frameInfos = parsed.frameInfo?.frames
    let defaultDuration = 1.0 / WPETexAnimationTrack.defaultFrameRate

    let frames = try parsed.bitmap.frames.enumerated().map { index, frameMipmaps in
        let frameInfo = frameInfos?[safe: index]
        let imageID = frameInfo?.imageID ?? index
        let duration = (frameInfo?.frameTime ?? 0) > 0 ? frameInfo!.frameTime : defaultDuration
        let sourceIndex = parsed.bitmap.frames.indices.contains(imageID) ? imageID : index
        return WPETexAnimationFrame(
            imageID: sourceIndex,
            duration: duration,
            mipmaps: try normalizedTextureMipmaps(parsed.bitmap.frames[sourceIndex], info: parsed.info)
        )
    }

    let validDurations = frames.map(\.duration).filter { $0 > 0 }
    let averageDuration = validDurations.isEmpty
        ? defaultDuration
        : validDurations.reduce(0, +) / Double(validDurations.count)
    let frameRate = averageDuration > 0
        ? 1.0 / averageDuration
        : WPETexAnimationTrack.defaultFrameRate

    return WPETexAnimationTrack(
        frames: frames,
        frameRate: frameRate,
        loop: true
    )
}

private func makeVideoPayload(from parsed: ParsedTex) throws -> WPETexVideoPayload? {
    guard let mip = parsed.bitmap.largestMipmap else { return nil }
    guard parsed.bitmap.isVideoPayload || looksLikeMP4Payload(mip.payload) else {
        return nil
    }
    return WPETexVideoPayload(bytes: mip.payload)
}
~~~

Add local safe-array helper if needed:

~~~swift
private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
~~~

- [ ] **Step 6: Run decoder tests**

Run:

~~~bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPETexTexturePayloadTests -only-testing:LiveWallpaperTests/WPETexDecoderTests
~~~

Expected: PASS. Static decode still rejects MP4 with `.unsupportedAnimation`; Metal payload extraction returns `videoPayload`.

---

## Task 2: Upload Animated TEX Frames And Add Runtime Frame Selection

**Files:**

- Create: `LiveWallpaper/Runtime/WPEDynamicTextureSource.swift`
- Create: `LiveWallpaper/Runtime/WPETexAnimatedTextureSource.swift`
- Modify: `LiveWallpaper/Infrastructure/WPEMetalTextureLoader.swift`
- Test: `LiveWallpaperTests/WPETexAnimatedTextureSourceTests.swift`
- Test: `LiveWallpaperTests/WPEMetalTextureLoaderTests.swift`

- [ ] **Step 1: Write failing animated source tests**

Create `LiveWallpaperTests/WPETexAnimatedTextureSourceTests.swift`:

~~~swift
import Foundation
import Metal
import Testing
@testable import LiveWallpaper

@Suite("WPE TEX animated texture source")
struct WPETexAnimatedTextureSourceTests {
    @Test("Selects frames at 25 FPS from runtime time")
    func selectsFramesAt25FPS() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let textures = try (0..<4).map { index in
            try makeTexture(device: device, value: UInt8(index))
        }
        let source = WPETexAnimatedTextureSource(
            frames: textures,
            frameRate: 25,
            loop: true
        )

        #expect(source.frameIndex(at: 0.000) == 0)
        #expect(source.frameIndex(at: 0.039) == 0)
        #expect(source.frameIndex(at: 0.040) == 1)
        #expect(source.frameIndex(at: 0.079) == 1)
        #expect(source.frameIndex(at: 0.080) == 2)
        #expect(source.frameIndex(at: 0.120) == 3)
        #expect(source.frameIndex(at: 0.160) == 0)
    }

    @Test("Returns current frame texture for runtime time")
    func returnsCurrentFrameTexture() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let textures = try (0..<4).map { index in
            try makeTexture(device: device, value: UInt8(index))
        }
        let source = WPETexAnimatedTextureSource(
            frames: textures,
            frameRate: 25,
            loop: true
        )

        #expect(source.texture(at: 0.000) === textures[0])
        #expect(source.texture(at: 0.040) === textures[1])
        #expect(source.texture(at: 0.080) === textures[2])
        #expect(source.texture(at: 0.120) === textures[3])
    }

    private func makeTexture(device: MTLDevice, value: UInt8) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        var bytes = [value, 0, 0, 255]
        texture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0,
            withBytes: &bytes,
            bytesPerRow: 4
        )
        return texture
    }
}
~~~

Append to `LiveWallpaperTests/WPEMetalTextureLoaderTests.swift`:

~~~swift
@Test("Uploads every animation frame into an animated texture source")
func uploadsAnimatedTextureSource() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let payload = WPETexTexturePayload(
        info: WPETexInfo(
            containerVersion: 5,
            infoVersion: 1,
            width: 1,
            height: 1,
            textureFormatCode: WPETexFormat.rgba8888.rawValue,
            format: .rgba8888,
            mipmapCount: 1,
            flags: 4
        ),
        mipmaps: [WPETexTextureMipmap(index: 0, width: 1, height: 1, bytes: Data([255, 0, 0, 255]))],
        hasAnimationFrames: true,
        animationTrack: WPETexAnimationTrack(
            frames: [
                WPETexAnimationFrame(imageID: 0, duration: 0.04, mipmaps: [
                    WPETexTextureMipmap(index: 0, width: 1, height: 1, bytes: Data([255, 0, 0, 255]))
                ]),
                WPETexAnimationFrame(imageID: 1, duration: 0.04, mipmaps: [
                    WPETexTextureMipmap(index: 0, width: 1, height: 1, bytes: Data([0, 255, 0, 255]))
                ])
            ],
            frameRate: 25,
            loop: true
        )
    )

    let source = try WPEMetalTextureLoader(device: device)
        .makeAnimatedTextureSource(from: payload, label: "animated-test")

    #expect(source.frameCount == 2)
    #expect(source.texture(at: 0.00) != nil)
    #expect(source.texture(at: 0.04) != nil)
}
~~~

- [ ] **Step 2: Run tests to verify failure**

Run:

~~~bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPETexAnimatedTextureSourceTests -only-testing:LiveWallpaperTests/WPEMetalTextureLoaderTests
~~~

Expected: FAIL because animated source and loader helper do not exist.

- [ ] **Step 3: Add the dynamic source protocol**

Create `LiveWallpaper/Runtime/WPEDynamicTextureSource.swift`:

~~~swift
import Foundation
import Metal

@MainActor
protocol WPEDynamicTextureSource: AnyObject {
    func texture(at time: TimeInterval) -> MTLTexture?
    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile)
    func invalidate()
}
~~~

- [ ] **Step 4: Add `WPETexAnimatedTextureSource`**

Create `LiveWallpaper/Runtime/WPETexAnimatedTextureSource.swift`:

~~~swift
import Foundation
import Metal

@MainActor
final class WPETexAnimatedTextureSource: WPEDynamicTextureSource {
    private let frames: [MTLTexture]
    private let frameRate: Double
    private let loop: Bool

    var frameCount: Int { frames.count }

    init(frames: [MTLTexture], frameRate: Double, loop: Bool) {
        self.frames = frames
        self.frameRate = frameRate > 0 ? frameRate : WPETexAnimationTrack.defaultFrameRate
        self.loop = loop
    }

    func texture(at time: TimeInterval) -> MTLTexture? {
        guard !frames.isEmpty else { return nil }
        return frames[frameIndex(at: time)]
    }

    func frameIndex(at time: TimeInterval) -> Int {
        guard !frames.isEmpty else { return 0 }
        let rawIndex = Int(floor(max(time, 0) * frameRate))
        if loop {
            return rawIndex % frames.count
        }
        return min(rawIndex, frames.count - 1)
    }

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        // Animated TEX frames are pre-uploaded GPU textures. There is no
        // decoder worker to pause; renderer-level references control release.
    }

    func invalidate() {
        // No explicit Metal release hook. Clearing renderer references releases frames.
    }
}
~~~

- [ ] **Step 5: Add animated upload helper to texture loader**

Modify `LiveWallpaper/Infrastructure/WPEMetalTextureLoader.swift`:

~~~swift
func makeAnimatedTextureSource(
    from payload: WPETexTexturePayload,
    label: String
) throws -> WPETexAnimatedTextureSource {
    guard let animation = payload.animationTrack else {
        throw WPEMetalTextureLoaderError.malformedPayload("missing animation track")
    }

    let frameTextures = try animation.frames.enumerated().map { frameIndex, frame in
        let framePayload = WPETexTexturePayload(
            info: payload.info,
            mipmaps: frame.mipmaps,
            hasAnimationFrames: false
        )
        return try makeTexture(
            from: framePayload,
            label: "\(label) frame \(frameIndex)"
        )
    }

    return WPETexAnimatedTextureSource(
        frames: frameTextures,
        frameRate: animation.frameRate,
        loop: animation.loop
    )
}
~~~

Guard static texture upload from video payloads:

~~~swift
func makeTexture(from payload: WPETexTexturePayload, label: String) throws -> MTLTexture {
    if payload.videoPayload != nil {
        throw WPEMetalTextureLoaderError.malformedPayload("video payload must be routed through WPEVideoTextureSource")
    }
    if payload.animationTrack != nil {
        throw WPEMetalTextureLoaderError.malformedPayload("animated payload must be routed through WPETexAnimatedTextureSource")
    }

    guard let format = payload.info.format else {
        throw WPEMetalTextureLoaderError.malformedPayload("unknown texture format \(payload.info.textureFormatCode)")
    }
    ...
}
~~~

- [ ] **Step 6: Run animated source and loader tests**

Run:

~~~bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPETexAnimatedTextureSourceTests -only-testing:LiveWallpaperTests/WPEMetalTextureLoaderTests
~~~

Expected: PASS. The deterministic frame-index test proves the 40 ms cadence at 25 FPS.

---

## Task 3: Add MP4 Video Texture Source

**Files:**

- Create: `LiveWallpaper/Runtime/WPEVideoTextureSource.swift`
- Modify: `LiveWallpaper/Runtime/WPEMetalRenderExecutor.swift`
- Test: `LiveWallpaperTests/WPEVideoTextureSourceTests.swift`

- [ ] **Step 1: Write failing video source tests**

Create `LiveWallpaperTests/WPEVideoTextureSourceTests.swift`:

~~~swift
import AVFoundation
import CoreGraphics
import Foundation
import Metal
import Testing
@testable import LiveWallpaper

@MainActor
@Suite("WPE video texture source")
struct WPEVideoTextureSourceTests {
    @Test("Texture lookup is non-blocking on the main actor")
    func textureLookupIsNonBlockingOnMainActor() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let data = try await makeTinyMP4Data()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEVideoTextureSourceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try await WPEVideoTextureSource.persistVideoData(data, cacheDirectory: directory)
        let source = try WPEVideoTextureSource(device: device, videoURL: url)

        let start = CFAbsoluteTimeGetCurrent()
        for index in 0..<500 {
            _ = source.texture(at: Double(index) / 60.0)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        #expect(elapsed < 0.020)
        source.invalidate()
    }

    @Test("Suspended profile releases AVAssetReader within one frame")
    func suspendedProfileReleasesReaderWithinOneFrame() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let data = try await makeTinyMP4Data()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEVideoTextureSourceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try await WPEVideoTextureSource.persistVideoData(data, cacheDirectory: directory)
        let source = try WPEVideoTextureSource(device: device, videoURL: url)

        _ = source.texture(at: 0)
        try await waitUntil(timeout: 1.0) {
            source.readerHandleForTests != nil
        }

        source.applyPerformanceProfile(.suspended)
        try await Task.sleep(nanoseconds: 20_000_000)

        #expect(source.readerHandleForTests == nil)
        source.invalidate()
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let start = CFAbsoluteTimeGetCurrent()
        while !condition() {
            if CFAbsoluteTimeGetCurrent() - start > timeout {
                Issue.record("Timed out waiting for condition")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
~~~

Add an MP4 fixture helper in the same file:

~~~swift
private func makeTinyMP4Data() async throws -> Data {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("tiny-\(UUID().uuidString).mp4")
    try? FileManager.default.removeItem(at: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let settings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: 16,
        AVVideoHeightKey: 16
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false

    let attributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 16,
        kCVPixelBufferHeightKey as String: 16,
        kCVPixelBufferMetalCompatibilityKey as String: true
    ]
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: attributes
    )

    precondition(writer.canAdd(input))
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    let queue = DispatchQueue(label: "WPEVideoTextureSourceTests.writer")
    try await withCheckedThrowingContinuation { continuation in
        var didResume = false
        func finish(_ result: Result<Void, Error>) {
            guard !didResume else { return }
            didResume = true
            continuation.resume(with: result)
        }

        input.requestMediaDataWhenReady(on: queue) {
            for frameIndex in 0..<2 where input.isReadyForMoreMediaData {
                guard let buffer = makePixelBuffer(
                    width: 16,
                    height: 16,
                    color: frameIndex == 0 ? [255, 0, 0, 255] : [0, 255, 0, 255]
                ) else {
                    finish(.failure(NSError(domain: "mp4-fixture", code: -1)))
                    return
                }
                let time = CMTime(value: CMTimeValue(frameIndex), timescale: 30)
                if !adaptor.append(buffer, withPresentationTime: time) {
                    finish(.failure(writer.error ?? NSError(domain: "mp4-fixture", code: -2)))
                    return
                }
            }

            input.markAsFinished()
            writer.finishWriting {
                if let error = writer.error {
                    finish(.failure(error))
                } else {
                    finish(.success(()))
                }
            }
        }
    }

    return try Data(contentsOf: url)
}

private func makePixelBuffer(width: Int, height: Int, color: [UInt8]) -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    let attributes: [String: Any] = [
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
    ]
    CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        attributes as CFDictionary,
        &buffer
    )
    guard let buffer else { return nil }

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    for y in 0..<height {
        let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
        for x in 0..<width {
            let offset = x * 4
            row[offset + 0] = color[2]
            row[offset + 1] = color[1]
            row[offset + 2] = color[0]
            row[offset + 3] = color[3]
        }
    }
    return buffer
}
~~~

- [ ] **Step 2: Run tests to verify failure**

Run:

~~~bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPEVideoTextureSourceTests
~~~

Expected: FAIL because `WPEVideoTextureSource` does not exist.

- [ ] **Step 3: Expose the executor device for source creation**

Modify `LiveWallpaper/Runtime/WPEMetalRenderExecutor.swift`:

~~~swift
var textureSourceDevice: MTLDevice {
    device
}
~~~

Keep it internal. Do not expose `device` publicly outside the module.

- [ ] **Step 4: Implement the video source**

Create `LiveWallpaper/Runtime/WPEVideoTextureSource.swift`:

~~~swift
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Metal

final class WPEVideoTextureSource: @unchecked Sendable {
    private struct PublishedFrame {
        let texture: MTLTexture
        let cvTexture: CVMetalTexture
        let presentationTime: TimeInterval
    }

    private final class State {
        var reader: AVAssetReader?
        var output: AVAssetReaderTrackOutput?
        var latestFrame: PublishedFrame?
        var requestedTime: TimeInterval = 0
        var isRunning = false
        var isSuspended = false
        var duration: TimeInterval = 0
    }

    private let device: MTLDevice
    private let videoURL: URL
    private let asset: AVURLAsset
    private let queue = DispatchQueue(label: "LiveWallpaper.WPEVideoTextureSource.reader", qos: .userInitiated)
    private let lock = NSLock()
    private let state = State()
    private var textureCache: CVMetalTextureCache?

    init(device: MTLDevice, videoURL: URL) throws {
        self.device = device
        self.videoURL = videoURL
        self.asset = AVURLAsset(url: videoURL)

        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else {
            throw WPEMetalTextureLoaderError.textureAllocationFailed
        }
        self.textureCache = cache
    }

    static func persistVideoData(_ data: Data, cacheDirectory: URL) async throws -> URL {
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(
                at: cacheDirectory,
                withIntermediateDirectories: true
            )
            let url = cacheDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
            try data.write(to: url, options: [.atomic])
            return url
        }.value
    }

    @MainActor
    var readerHandleForTests: AVAssetReader? {
        lock.withLock { state.reader }
    }

    @MainActor
    func texture(at time: TimeInterval) -> MTLTexture? {
        let shouldStart: Bool
        let latest: MTLTexture?

        lock.lock()
        state.requestedTime = max(time, 0)
        shouldStart = !state.isRunning && !state.isSuspended
        latest = state.latestFrame?.texture
        if shouldStart {
            state.isRunning = true
        }
        lock.unlock()

        if shouldStart {
            queue.async { [weak self] in
                self?.readerLoop()
            }
        }

        return latest
    }

    @MainActor
    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        switch profile {
        case .quality:
            lock.withLock { state.isSuspended = false }
        case .suspended:
            lock.withLock { state.isSuspended = true }
            queue.async { [weak self] in
                self?.stopReaderAndFlush()
            }
        }
    }

    @MainActor
    func invalidate() {
        lock.withLock { state.isSuspended = true }
        queue.sync {
            stopReaderAndFlush()
        }
        try? FileManager.default.removeItem(at: videoURL)
    }

    private func readerLoop() {
        defer {
            lock.withLock { state.isRunning = false }
        }

        while true {
            if lock.withLock({ state.isSuspended }) {
                stopReaderAndFlush()
                return
            }

            do {
                try configureReaderIfNeeded()
            } catch {
                stopReaderAndFlush()
                return
            }

            guard let output = lock.withLock({ state.output }) else {
                stopReaderAndFlush()
                return
            }

            guard let sample = output.copyNextSampleBuffer() else {
                restartReaderForLoop()
                continue
            }

            autoreleasepool {
                publish(sampleBuffer: sample)
            }
        }
    }

    private func configureReaderIfNeeded() throws {
        if lock.withLock({ state.reader != nil }) {
            return
        }

        let tracks = asset.tracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw WPEMetalTextureLoaderError.malformedPayload("MP4 TEX has no video track")
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
        )
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else {
            throw WPEMetalTextureLoaderError.malformedPayload("AVAssetReader cannot add video output")
        }
        reader.add(output)

        let requestedTime = lock.withLock { state.requestedTime }
        if requestedTime > 0 {
            let start = CMTime(seconds: requestedTime, preferredTimescale: 600)
            reader.timeRange = CMTimeRange(start: start, duration: .positiveInfinity)
        }

        guard reader.startReading() else {
            throw reader.error ?? WPEMetalTextureLoaderError.malformedPayload("AVAssetReader failed to start")
        }

        let duration = asset.duration.seconds.isFinite ? asset.duration.seconds : 0

        lock.lock()
        state.reader = reader
        state.output = output
        state.duration = max(duration, 0)
        lock.unlock()
    }

    private func publish(sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let textureCache else {
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        var status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm_srgb,
            width,
            height,
            0,
            &cvTexture
        )

        if status != kCVReturnSuccess {
            status = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                textureCache,
                pixelBuffer,
                nil,
                .bgra8Unorm,
                width,
                height,
                0,
                &cvTexture
            )
        }

        guard status == kCVReturnSuccess,
              let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else {
            return
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let frame = PublishedFrame(
            texture: texture,
            cvTexture: cvTexture,
            presentationTime: pts.isFinite ? pts : 0
        )

        lock.withLock {
            state.latestFrame = frame
        }
    }

    private func restartReaderForLoop() {
        lock.lock()
        state.reader?.cancelReading()
        state.reader = nil
        state.output = nil
        state.requestedTime = 0
        lock.unlock()
    }

    private func stopReaderAndFlush() {
        let cache = textureCache

        lock.lock()
        state.reader?.cancelReading()
        state.reader = nil
        state.output = nil
        state.latestFrame = nil
        lock.unlock()

        if let cache {
            CVMetalTextureCacheFlush(cache, 0)
        }
    }
}

extension WPEVideoTextureSource: WPEDynamicTextureSource {}
~~~

Add an `NSLock` helper if one does not already exist:

~~~swift
private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
~~~

- [ ] **Step 5: Run video source tests**

Run:

~~~bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPEVideoTextureSourceTests
~~~

Expected: PASS. The lookup loop must stay under 20 ms on the main actor, and `.suspended` must nil the reader after the one-frame wait.

---

## Task 4: Integrate Dynamic Texture Sources Into Scene Renderer Lifecycle

**Files:**

- Modify: `LiveWallpaper/Runtime/WPEMetalSceneRenderer.swift`
- Modify: `LiveWallpaper/Infrastructure/WPEMetalTextureLoader.swift`
- Test: `LiveWallpaperTests/WPEMetalSceneRendererTests.swift`

- [ ] **Step 1: Write failing renderer integration tests**

Append to `LiveWallpaperTests/WPEMetalSceneRendererTests.swift`:

~~~swift
@Test("Loads animated TEX source and advances frame from deterministic clock")
func loadsAnimatedTEXSourceAndAdvancesFrame() async throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let fixture = try MetalSceneFixture.animatedTEXScene()
    defer { fixture.cleanup() }

    let renderer = try WPEMetalSceneRenderer(
        descriptor: fixture.descriptor,
        cacheRootURL: fixture.root,
        dependencyMounts: [],
        frame: CGRect(x: 0, y: 0, width: 64, height: 64),
        device: device,
        frameClock: WPEMetalFrameClock(
            loadTime: 100,
            currentMediaTime: { 100.04 },
            currentDate: { Date(timeIntervalSince1970: 0) },
            calendar: Calendar(identifier: .gregorian)
        ),
        pointerSampler: .fixed(SIMD2<Double>(0.5, 0.5))
    )

    try await renderer.load()

    #expect(renderer.dynamicTextureSourceCountForTests == 1)
}

@Test("Suspended profile releases dynamic video readers")
func suspendedProfileReleasesDynamicVideoReaders() async throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let fixture = try MetalSceneFixture.videoTEXScene()
    defer { fixture.cleanup() }

    let renderer = try WPEMetalSceneRenderer(
        descriptor: fixture.descriptor,
        cacheRootURL: fixture.root,
        dependencyMounts: [],
        frame: CGRect(x: 0, y: 0, width: 64, height: 64),
        device: device
    )

    try await renderer.load()
    _ = renderer.renderedTexture

    try await Task.sleep(nanoseconds: 50_000_000)
    renderer.applyPerformanceProfile(.suspended)
    try await Task.sleep(nanoseconds: 20_000_000)

    #expect(renderer.dynamicVideoReaderCountForTests == 0)
}
~~~

Add fixture helpers to `MetalSceneFixture`:

~~~swift
static func animatedTEXScene() throws -> MetalSceneFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WPEMetalSceneRenderer-\(UUID().uuidString)", isDirectory: true)
    let materials = root.appendingPathComponent("materials", isDirectory: true)
    try FileManager.default.createDirectory(at: materials, withIntermediateDirectories: true)

    let tex = makeAnimatedTestTex()
    try tex.write(to: materials.appendingPathComponent("anim.tex"))
    try Data(#"{ "passes": [{ "shader": "genericimage2", "textures": ["materials/anim.tex"] }] }"#.utf8)
        .write(to: materials.appendingPathComponent("base.json"))
    try Data(#"{ "material": "materials/base.json" }"#.utf8)
        .write(to: root.appendingPathComponent("model.json"))
    try writeScene(imagePath: "model.json", to: root)

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

static func videoTEXScene() throws -> MetalSceneFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WPEMetalSceneRenderer-\(UUID().uuidString)", isDirectory: true)
    let materials = root.appendingPathComponent("materials", isDirectory: true)
    try FileManager.default.createDirectory(at: materials, withIntermediateDirectories: true)

    let mp4 = try Data(contentsOf: makePrebuiltTinyMP4URL())
    let tex = makeVideoTestTex(mp4: mp4)
    try tex.write(to: materials.appendingPathComponent("video.tex"))
    try Data(#"{ "passes": [{ "shader": "genericimage2", "textures": ["materials/video.tex"] }] }"#.utf8)
        .write(to: materials.appendingPathComponent("base.json"))
    try Data(#"{ "material": "materials/base.json" }"#.utf8)
        .write(to: root.appendingPathComponent("model.json"))
    try writeScene(imagePath: "model.json", to: root)

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
~~~

Use the same TEX builders from Task 1 and MP4 writer from Task 3 as private helpers in this test file. Keep them private to avoid changing production API.

- [ ] **Step 2: Run renderer tests to verify failure**

Run:

~~~bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPEMetalSceneRendererTests
~~~

Expected: FAIL because renderer does not keep dynamic sources or expose test counters.

- [ ] **Step 3: Add renderer dynamic source state**

Modify `LiveWallpaper/Runtime/WPEMetalSceneRenderer.swift` stored properties:

~~~swift
private var loadedTextures: [String: MTLTexture] = [:]
private var dynamicTextureSources: [String: WPEDynamicTextureSource] = [:]
private var videoCacheDirectory: URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("wpe-tex-video", isDirectory: true)
}

var dynamicTextureSourceCountForTests: Int {
    dynamicTextureSources.count
}

var dynamicVideoReaderCountForTests: Int {
    dynamicTextureSources.values.compactMap { source in
        (source as? WPEVideoTextureSource)?.readerHandleForTests
    }.count
}
~~~

If test-only accessors are gated in this repo, wrap the last two computed properties in the established `#if DEBUG` or test-only pattern used elsewhere.

- [ ] **Step 4: Return texture resources from loading**

Add a private enum in `WPEMetalSceneRenderer.swift`:

~~~swift
private enum WPELoadedTextureResource {
    case staticTexture(MTLTexture)
    case dynamicSource(WPEDynamicTextureSource)
}
~~~

Change `loadTextures(for:)` to async if Phase 2B has not already done so:

~~~swift
private func loadTextures(for pipeline: WPEPreparedRenderPipeline) async throws -> [String: MTLTexture] {
    loadedTextures = [:]
    dynamicTextureSources = [:]

    for layer in pipeline.layers {
        if layer.passes.isEmpty {
            try await loadTexture(reference: .image(layer.graphLayer.imagePath))
            continue
        }
        for preparedPass in layer.passes {
            for reference in requiredTextureReferences(for: preparedPass) {
                try await loadTexture(reference: reference)
            }
        }
    }

    return loadedTextures
}
~~~

Replace `loadTexture(reference:into:)` with:

~~~swift
private func loadTexture(reference: WPETextureReference) async throws {
    guard let path = externalTexturePath(for: reference),
          loadedTextures[path] == nil,
          dynamicTextureSources[path] == nil else {
        return
    }

    do {
        let resource = try await makeTextureResource(relativePath: path, label: "WPE texture \(path)")
        switch resource {
        case .staticTexture(let texture):
            loadedTextures[path] = texture
        case .dynamicSource(let source):
            dynamicTextureSources[path] = source
            if let texture = source.texture(at: lastRuntimeUniforms?.time ?? 0) {
                loadedTextures[path] = texture
            }
        }
    } catch {
        throw WPEMetalTextureLoadContextError(path: path, underlying: error)
    }
}
~~~

- [ ] **Step 5: Route payload kinds to static, animated, or video**

Add `makeTextureResource(...)`:

~~~swift
private func makeTextureResource(relativePath: String, label: String) async throws -> WPELoadedTextureResource {
    var lastError: Error?

    for candidate in textureCandidates(for: relativePath) {
        do {
            if shouldTryTexturePayload(candidate) {
                do {
                    let payload = try resourceResolver.resolveTexturePayload(relativePath: candidate)

                    if payload.videoPayload != nil {
                        let source = try await makeVideoTextureSource(from: payload, label: label)
                        return .dynamicSource(source)
                    }

                    if payload.animationTrack != nil {
                        let source = try textureLoader.makeAnimatedTextureSource(from: payload, label: label)
                        return .dynamicSource(source)
                    }

                    return .staticTexture(try textureLoader.makeTexture(from: payload, label: label))
                } catch {
                    lastError = error
                }
            }

            let image = try resourceResolver.resolveImage(relativePath: candidate)
            return .staticTexture(try textureLoader.makeTexture(from: image, label: label))
        } catch {
            lastError = error
        }
    }

    throw lastError ?? WPEMetalRenderExecutorError.missingTexture(.image(relativePath))
}

private func makeVideoTextureSource(
    from payload: WPETexTexturePayload,
    label: String
) async throws -> WPEVideoTextureSource {
    guard let videoPayload = payload.videoPayload else {
        throw WPEMetalTextureLoaderError.malformedPayload("missing video payload")
    }

    let url = try await WPEVideoTextureSource.persistVideoData(
        videoPayload.bytes,
        cacheDirectory: videoCacheDirectory
    )
    return try WPEVideoTextureSource(
        device: executor.textureSourceDevice,
        videoURL: url
    )
}
~~~

- [ ] **Step 6: Refresh dynamic textures before rendering each frame**

In Phase 2B `renderCurrentFrame()`, after computing `uniforms` and before calling `executor.render(...)`, add:

~~~swift
private func texturesForCurrentFrame(time: TimeInterval) -> [String: MTLTexture] {
    var textures = loadedTextures
    for (path, source) in dynamicTextureSources {
        if let texture = source.texture(at: time) {
            textures[path] = texture
            loadedTextures[path] = texture
        }
    }
    return textures
}
~~~

Use it in render:

~~~swift
let uniforms = frameClock.runtimeUniforms(
    profile: currentProfile,
    pointerPosition: pointerSampler.sample(mtkView)
)
lastRuntimeUniforms = uniforms
let currentTextures = texturesForCurrentFrame(time: uniforms.time)

return try executor.render(
    pipeline: pipeline,
    size: sceneRenderSize,
    textures: currentTextures,
    runtimeUniforms: uniforms,
    cameraUniforms: cameraUniforms
)
~~~

- [ ] **Step 7: Release sources on suspended, reload, and cleanup**

Modify `applyPerformanceProfile(_:)`:

~~~swift
func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
    currentProfile = profile
    switch profile {
    case .quality:
        dynamicTextureSources.values.forEach { $0.applyPerformanceProfile(.quality) }
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = true
        mtkView.preferredFramesPerSecond = isThrottled
            ? SceneRenderingController.throttledPreferredFPS
            : SceneRenderingController.defaultPreferredFPS

    case .suspended:
        dynamicTextureSources.values.forEach { $0.applyPerformanceProfile(.suspended) }
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = false
        mtkView.releaseDrawables()
    }
}
~~~

Add helper:

~~~swift
private func releaseDynamicTextureSources() {
    dynamicTextureSources.values.forEach { $0.invalidate() }
    dynamicTextureSources.removeAll()
    loadedTextures.removeAll()
}
~~~

Call it in `reload()` before `try await load()`:

~~~swift
releaseDynamicTextureSources()
outputTexture = nil
renderGraph = nil
renderPipeline = nil
loadDiagnostics = nil
lastRuntimeUniforms = nil
~~~

Call it in `cleanup()`:

~~~swift
func cleanup() {
    mtkView.delegate = nil
    releaseDynamicTextureSources()
    outputTexture = nil
}
~~~

- [ ] **Step 8: Run renderer integration tests**

Run:

~~~bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -only-testing:LiveWallpaperTests/WPEMetalSceneRendererTests
~~~

Expected: PASS. Renderer keeps one dynamic source for animated/video fixtures and releases video reader handles on `.suspended`.

---

## Task 5: Acceptance Fixtures And Regression Coverage

**Files:**

- Modify: `LiveWallpaperTests/WPETexTexturePayloadTests.swift`
- Modify: `LiveWallpaperTests/WPETexAnimatedTextureSourceTests.swift`
- Modify: `LiveWallpaperTests/WPEVideoTextureSourceTests.swift`
- Modify: `LiveWallpaperTests/WPEMetalRenderExecutorTests.swift`
- Modify: `LiveWallpaperTests/WPEMetalSceneRendererTests.swift`

- [ ] **Step 1: Add 25 FPS tolerance acceptance test**

Append to `WPETexAnimatedTextureSourceTests.swift`:

~~~swift
@Test("Four-frame animation advances once per 40ms within tolerance")
func fourFrameAnimationAdvancesEvery40ms() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let textures = try (0..<4).map { index in
        try makeTexture(device: device, value: UInt8(index))
    }
    let source = WPETexAnimatedTextureSource(frames: textures, frameRate: 25, loop: true)

    let samples: [(TimeInterval, Int)] = [
        (0.000, 0),
        (0.038, 0),
        (0.040, 1),
        (0.042, 1),
        (0.078, 1),
        (0.080, 2),
        (0.082, 2),
        (0.118, 2),
        (0.120, 3),
        (0.122, 3),
        (0.158, 3),
        (0.160, 0)
    ]

    for (time, expectedIndex) in samples {
        #expect(source.frameIndex(at: time) == expectedIndex)
    }
}
~~~

- [ ] **Step 2: Add executor regression guard for unchanged static texture resolution**

Append to `WPEMetalRenderExecutorTests.swift` only if Phase 2C source tests do not already cover this exact path:

~~~swift
@Test("Dynamic source plumbing does not change static image texture lookup")
func staticImageTextureLookupStillCopiesInputTexture() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let executor = try WPEMetalRenderExecutor(device: device)
    let input = try makeRGBAInputTexture(device: device, bytes: Data([
        255, 255, 0, 255,
        255, 255, 0, 255,
        255, 255, 0, 255,
        255, 255, 0, 255
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
        textures: ["materials/base.png": input],
        runtimeUniforms: .zero,
        cameraUniforms: .identity
    )
    let pixel = try readPixel(output, x: 1, y: 1)

    #expect(pixel.r >= 250)
    #expect(pixel.g >= 250)
    #expect(pixel.b <= 5)
    #expect(pixel.a >= 250)
}
~~~

- [ ] **Step 3: Add video source manual-performance note test**

Keep the automated test non-blocking and do not assert FPS in CI. Add a test comment to `WPEVideoTextureSourceTests.swift` near `textureLookupIsNonBlockingOnMainActor`:

~~~swift
// Manual acceptance still required with a 30-second 1080p MP4 TEX fixture:
// run the app on an M1-class Mac and confirm sustained >=55 FPS while this
// automated test pins the main-thread contract for per-frame texture lookup.
~~~

- [ ] **Step 4: Run targeted Phase 2E tests**

Run:

~~~bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO \
  -only-testing:LiveWallpaperTests/WPETexDecoderTests \
  -only-testing:LiveWallpaperTests/WPETexTexturePayloadTests \
  -only-testing:LiveWallpaperTests/WPEMetalTextureLoaderTests \
  -only-testing:LiveWallpaperTests/WPETexAnimatedTextureSourceTests \
  -only-testing:LiveWallpaperTests/WPEVideoTextureSourceTests \
  -only-testing:LiveWallpaperTests/WPEMetalRenderExecutorTests \
  -only-testing:LiveWallpaperTests/WPEMetalSceneRendererTests
~~~

Expected: PASS.

- [ ] **Step 5: Run Phase 2A/2B/2C regression slice**

Run:

~~~bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO \
  -only-testing:LiveWallpaperTests/WPEMetalRuntimeUniformsTests \
  -only-testing:LiveWallpaperTests/WPERenderPipelineBuilderTests \
  -only-testing:LiveWallpaperTests/WPERenderGraphBuilderTests \
  -only-testing:LiveWallpaperTests/WPEMetalRenderExecutorTests \
  -only-testing:LiveWallpaperTests/WPEMetalSceneRendererTests \
  -only-testing:LiveWallpaperTests/WPETexMetalTranscoderTests \
  -only-testing:LiveWallpaperTests/WPEMetalTextureFormatMapperTests
~~~

Expected: PASS.

---

## Final Verification

Run the complete Phase 2E targeted command:

~~~bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO \
  -only-testing:LiveWallpaperTests/WPETexDecoderTests \
  -only-testing:LiveWallpaperTests/WPETexTexturePayloadTests \
  -only-testing:LiveWallpaperTests/WPEMetalTextureLoaderTests \
  -only-testing:LiveWallpaperTests/WPETexAnimatedTextureSourceTests \
  -only-testing:LiveWallpaperTests/WPEVideoTextureSourceTests \
  -only-testing:LiveWallpaperTests/WPEMetalRuntimeUniformsTests \
  -only-testing:LiveWallpaperTests/WPEMetalRenderExecutorTests \
  -only-testing:LiveWallpaperTests/WPEMetalSceneRendererTests
~~~

Then run the app/test target excluding UI tests:

~~~bash
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -destination 'platform=macOS,arch=arm64,name=My Mac' -parallel-testing-enabled NO -skip-testing:LiveWallpaperUITests
~~~

Manual performance acceptance:

1. Use a real 30-second 1080p MP4-in-TEX Workshop fixture.
2. Load it through the experimental Metal renderer on an M1-class Mac.
3. Confirm sustained renderer FPS is at least 55 FPS for the full 30 seconds.
4. Confirm the main thread is not doing `AVAssetReader.copyNextSampleBuffer()` or `CVMetalTextureCacheCreateTextureFromImage`.
5. Suspend the wallpaper and confirm reader handles are released within one frame and cache memory drops after `CVMetalTextureCacheFlush`.

Expected:

- 4-frame animated TEX advances at 25 FPS with 40 ms cadence.
- MP4 TEX payload extraction no longer throws `.unsupportedAnimation` on the Metal payload path.
- SpriteKit/CGImage decode still rejects MP4 TEX as `.unsupportedAnimation`.
- `texture(at:)` for video is non-blocking on the main actor.
- `.suspended`, `reload()`, and `cleanup()` release readers, retained video frames, temp MP4 files, and dynamic source references.
- No `WPESceneDetailView` changes.
- No new dependencies.
- Swift 6 strict concurrency produces no new warnings.

---

## Main Improvements

- Animated `.tex` files no longer silently truncate to the first TEXB image in the Metal path.
- Animation tracks preserve frame mipmaps, frame durations, frame count, frame rate, and loop metadata.
- Animated TEX playback is deterministic from Phase 2B `g_Time`.
- MP4-in-TEX payloads are extracted and decoded through AVFoundation instead of rejected.
- Video frames become Metal textures through `CVMetalTextureCache`, avoiding CPU readback/copy into `MTLTexture.replace(...)`.
- Renderer texture binding remains compatible with Phase 2C: dynamic sources still feed `WPETextureReference.image(path)` lookups.
- Suspended lifecycle now actively releases video decode workers and flushes CoreVideo texture cache state.
- Reload/cleanup clear dynamic source references and temp cache files.

---

## Self-Review

### Spec Coverage

- Animated `.tex` decode: covered by Task 1.
- Animation payload storage as per-frame mipmap arrays: covered by Task 1.
- 25 FPS default and frame-index formula: covered by Task 2 and Task 5.
- Runtime `WPETexAnimatedTextureSource.texture(at:)`: covered by Task 2.
- MP4 byte extraction: covered by Task 1.
- URL-backed AVAsset temp file: covered by Task 3.
- `AVAssetReader` background worker: covered by Task 3.
- `CVMetalTextureCache` with executor device: covered by Tasks 3 and 4.
- Renderer strong references to animated/video sources: covered by Task 4.
- Suspended pause/release and cache flush: covered by Tasks 3 and 4.
- Reload/cleanup release: covered by Task 4.
- Acceptance tests: covered by Task 5.
- Out-of-scope exclusions: preserved in Scope and Final Verification.

### Placeholder Scan

This plan names exact files, types, tests, commands, and lifecycle hooks. It contains no deferred UI work, no new dependency request, and no instruction to modify `WPESceneDetailView`.

### Type Consistency

- `WPETexAnimationTrack`, `WPETexAnimationFrame`, and `WPETexVideoPayload` are introduced before later tasks use them.
- `WPEDynamicTextureSource` is the shared renderer-facing protocol for animated and video sources.
- `WPETexAnimatedTextureSource` is `@MainActor` because it only indexes retained `MTLTexture` frames.
- `WPEVideoTextureSource` is `@unchecked Sendable` with lock-protected state because `AVAssetReader` work runs on a dedicated `DispatchQueue`.
- `WPEMetalRenderExecutor.textureSourceDevice` is the only new executor boundary needed for `CVMetalTextureCache`.
- `WPEMetalSceneRenderer` continues to pass `[String: MTLTexture]` into `executor.render(...)`.

### Residual Risk

- TEXS crop/rotation metadata is parsed but not yet consumed by shaders; real atlas-heavy animated TEX may need a Phase 2E follow-up for UV transforms.
- Video frame color tagging may require device-specific validation between `.bgra8Unorm_srgb` and `.bgra8Unorm`.
- `AVAssetReader` restart-on-loop may show a stale frame for one render if decode falls behind; this is acceptable for Phase 2E because `texture(at:)` must never block the main actor.
- Pre-uploading every animated frame is simple and deterministic but can use substantial GPU memory on very large frame counts.
