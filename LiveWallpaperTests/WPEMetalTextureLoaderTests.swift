import CoreGraphics
import Foundation
import Metal
import Testing
@testable import LiveWallpaper

@Suite("WPE Metal texture loader")
struct WPEMetalTextureLoaderTests {

    @Test("Uploads RGBA texture payload into an MTLTexture")
    func uploadsRGBA8888Payload() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let bytes = Data([
            255, 0, 0, 255,
            0, 255, 0, 255,
            0, 0, 255, 255,
            255, 255, 255, 255
        ])
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
            mipmaps: [WPETexTextureMipmap(index: 0, width: 2, height: 2, bytes: bytes)],
            hasAnimationFrames: false
        )

        let texture = try await WPEMetalTextureLoader(device: device).makeTexture(from: payload, label: "test-rgba")

        #expect(texture.width == 2)
        #expect(texture.height == 2)
        #expect(texture.pixelFormat == .rgba8Unorm_srgb)
    }

    @Test("RG88 alpha-channel-priority uploads .rg8Unorm with (R,R,R,G) swizzle")
    func rg88AlphaPrioritySwizzle() async throws {
        // This is the REAL on-device particle path (payload → .rg8Unorm),
        // the one that produced the "red square": .rg8Unorm samples as
        // (R,G,0,1) — opaque. The swizzle must remap it to (R,R,R,G) so the
        // glow keeps its G-channel alpha falloff.
        let device = try #require(MTLCreateSystemDefaultDevice())
        let bytes = Data([200, 50, 10, 255, 0, 128, 64, 32]) // 2x2 RG88 = 8 bytes
        let payload = WPETexTexturePayload(
            info: WPETexInfo(
                containerVersion: 5,
                infoVersion: 1,
                width: 2,
                height: 2,
                textureFormatCode: WPETexFormat.rg88.rawValue,
                format: .rg88,
                mipmapCount: 1,
                flags: WPETexInfo.alphaChannelPriorityFlag
            ),
            mipmaps: [WPETexTextureMipmap(index: 0, width: 2, height: 2, bytes: bytes)],
            hasAnimationFrames: false
        )

        let texture = try await WPEMetalTextureLoader(device: device).makeTexture(from: payload, label: "test-rg88-glow")

        #expect(texture.pixelFormat == .rg8Unorm)
        #expect(texture.swizzle.red == .red)
        #expect(texture.swizzle.green == .red)
        #expect(texture.swizzle.blue == .red)
        #expect(texture.swizzle.alpha == .green)
    }

    @Test("RG88 without alpha-priority keeps default (R,G,0,1) sampling")
    func rg88NormalMapDefaultSwizzle() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let bytes = Data([200, 50, 10, 255, 0, 128, 64, 32])
        let payload = WPETexTexturePayload(
            info: WPETexInfo(
                containerVersion: 5,
                infoVersion: 1,
                width: 2,
                height: 2,
                textureFormatCode: WPETexFormat.rg88.rawValue,
                format: .rg88,
                mipmapCount: 1,
                flags: 0
            ),
            mipmaps: [WPETexTextureMipmap(index: 0, width: 2, height: 2, bytes: bytes)],
            hasAnimationFrames: false
        )

        let texture = try await WPEMetalTextureLoader(device: device).makeTexture(from: payload, label: "test-rg88-normal")

        #expect(texture.pixelFormat == .rg8Unorm)
        #expect(texture.swizzle.red == .red)
        #expect(texture.swizzle.green == .green)
        #expect(texture.swizzle.blue == .blue)
        #expect(texture.swizzle.alpha == .alpha)
    }

    @Test("Rejects BC payload when current device cannot sample BC")
    func rejectsBCWithoutDeviceSupport() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let payload = WPETexTexturePayload(
            info: WPETexInfo(
                containerVersion: 5,
                infoVersion: 1,
                width: 4,
                height: 4,
                textureFormatCode: WPETexFormat.bc7.rawValue,
                format: .bc7,
                mipmapCount: 1,
                flags: 0
            ),
            mipmaps: [WPETexTextureMipmap(index: 0, width: 4, height: 4, bytes: Data(count: 16))],
            hasAnimationFrames: false
        )
        let loader = WPEMetalTextureLoader(
            device: device,
            capabilities: WPEMetalTextureCapabilities(supportsBCTextureCompression: false)
        )

        await #expect(throws: WPEMetalTextureLoaderError.unsupportedCompressedFormat(.bc7)) {
            _ = try await loader.makeTexture(from: payload, label: "test-bc7")
        }
    }

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

    // Eager animated payload returns the source atlas per TEXS frame
    // and dedups MTLTexture uploads by imageID. Sub-rect data is kept
    // on `WPETexAnimatedFrame.sourceSubRect` for future shader-aware
    // consumers — the particle renderer relies on the atlas-sized
    // texture to recover sprite-sheet `cols/rows` from .tex-json frame
    // dimensions; per-frame cropping breaks that math (1×1 grid).
    @MainActor
    @Test("Eager animated payload shares one MTLTexture per imageID across frames")
    func eagerAnimatedPayloadSharesOneTexturePerImageID() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var atlasBytes: [UInt8] = []
        atlasBytes.reserveCapacity(4 * 4 * 4)
        for row in 0..<4 {
            for col in 0..<4 {
                atlasBytes.append(contentsOf: [UInt8(row << 4 | col), 0, 0, 0xff])
            }
        }
        let atlasMipmap = WPETexTextureMipmap(index: 0, width: 4, height: 4, bytes: Data(atlasBytes))
        let secondAtlas = WPETexTextureMipmap(
            index: 0,
            width: 4,
            height: 4,
            bytes: Data(repeating: 0x55, count: 4 * 4 * 4)
        )

        let track = WPETexAnimationTrack(
            frames: [
                WPETexAnimationFrame(
                    imageID: 0,
                    duration: 0.04,
                    mipmaps: [atlasMipmap],
                    subRect: CGRect(x: 0, y: 0, width: 2, height: 2)
                ),
                WPETexAnimationFrame(
                    imageID: 0,
                    duration: 0.04,
                    mipmaps: [atlasMipmap],
                    subRect: CGRect(x: 2, y: 0, width: 2, height: 2)
                ),
                WPETexAnimationFrame(
                    imageID: 1,
                    duration: 0.04,
                    mipmaps: [secondAtlas],
                    subRect: CGRect(x: 0, y: 2, width: 2, height: 2)
                )
            ],
            frameRate: 25,
            loop: true
        )
        let payload = WPETexTexturePayload(
            info: WPETexInfo(
                containerVersion: 5,
                infoVersion: 1,
                width: 4,
                height: 4,
                textureFormatCode: WPETexFormat.rgba8888.rawValue,
                format: .rgba8888,
                mipmapCount: 1,
                flags: 0
            ),
            mipmaps: [],
            hasAnimationFrames: true,
            animationTrack: track
        )

        let source = try await WPEMetalTextureLoader(device: device)
            .makeAnimatedTextureSource(from: payload, label: "test-animated")

        let frame0 = try #require(source.texture(at: 0.0))
        let frame1 = try #require(source.texture(at: 0.05))
        let frame2 = try #require(source.texture(at: 0.09))

        // All textures stay the atlas size — no per-frame cropping.
        #expect(frame0.width == 4)
        #expect(frame0.height == 4)
        #expect(frame1.width == 4)
        #expect(frame2.width == 4)
        // imageID=0 frames share the same MTLTexture; imageID=1 gets its own.
        #expect(frame0 === frame1)
        #expect(frame0 !== frame2)
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
