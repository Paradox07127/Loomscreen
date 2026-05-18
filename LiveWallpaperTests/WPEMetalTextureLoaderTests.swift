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
