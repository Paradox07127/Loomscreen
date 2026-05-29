import Compression
import Foundation
import Metal
import Testing
@testable import LiveWallpaper

@Suite("WPETexLazyAnimatedTextureSource")
@MainActor
struct WPETexLazyAnimatedTextureSourceTests {

    @Test("Uploads cropped sub-rects from streaming frames")
    func uploadsCroppedSubRectsFromStreamingFrames() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let source = try WPETexLazyAnimatedTextureSource(
            payload: makeStreamingPayload(),
            device: device,
            label: "lazy-test"
        )

        let firstFrame = try #require(source.texture(at: 0.0))
        #expect(firstFrame.width == 2)
        #expect(firstFrame.height == 2)
        #expect(readRGBA(firstFrame) == [
            0x00, 0x00, 0x00, 0xff, 0x01, 0x00, 0x00, 0xff,
            0x00, 0x01, 0x00, 0xff, 0x01, 0x01, 0x00, 0xff
        ])

        let secondFrame = try #require(source.texture(at: 0.11))
        #expect(secondFrame.width == 2)
        #expect(secondFrame.height == 2)
        #expect(readRGBA(secondFrame) == [
            0x02, 0x00, 0x00, 0xff, 0x03, 0x00, 0x00, 0xff,
            0x02, 0x01, 0x00, 0xff, 0x03, 0x01, 0x00, 0xff
        ])
    }

    @Test("Frame index respects per-frame durations and looping")
    func frameIndexRespectsDurationsAndLooping() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let source = try WPETexLazyAnimatedTextureSource(
            payload: makeStreamingPayload(),
            device: device,
            label: "lazy-index"
        )

        #expect(source.frameIndex(at: 0.00) == 0)
        #expect(source.frameIndex(at: 0.09) == 0)
        #expect(source.frameIndex(at: 0.10) == 1)
        #expect(source.frameIndex(at: 0.20) == 2)
        #expect(source.frameIndex(at: 0.40) == 0)
    }

    @Test("Same-imageID consecutive frames reuse decompressed image")
    func sameImageReuse() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let source = try WPETexLazyAnimatedTextureSource(
            payload: makeStreamingPayload(),
            device: device,
            label: "lazy-reuse"
        )
        _ = source.texture(at: 0.0)  // image 0 → cache
        _ = source.texture(at: 0.11) // image 0 sub-rect 2 → cache hit
        // No assertions for cache internals — just exercising the path
        // ensures the upload/decode chain stays consistent.
        let frame = try #require(source.texture(at: 0.0))
        #expect(frame.width == 2)
    }

    @Test("Rejects lazy frame uploads that exceed the Metal 2D texture size limit")
    func rejectsLazyFrameUploadsPastTextureLimit() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let image = makeImage(width: 8, height: 8, blue: 0)
        let mip = WPETexCompressedMipmap(
            index: 0,
            width: 8,
            height: 8,
            isCompressed: false,
            compressedBytes: image,
            decompressedByteCount: image.count
        )
        let payload = WPETexStreamingPayload(
            info: WPETexInfo(
                containerVersion: 5,
                infoVersion: 1,
                width: 8,
                height: 8,
                textureFormatCode: WPETexFormat.rgba8888.rawValue,
                format: .rgba8888,
                mipmapCount: 1,
                flags: 0
            ),
            compressedImages: [
                WPETexCompressedImage(width: 8, height: 8, payloads: [mip])
            ],
            frames: [
                WPETexStreamingFrame(imageID: 0, subRect: CGRect(x: 0, y: 0, width: 8, height: 8), duration: 0.1)
            ],
            frameRate: 10,
            loop: true
        )
        let source = try WPETexLazyAnimatedTextureSource(
            payload: payload,
            device: device,
            label: "lazy-too-large",
            maximumTextureDimension2D: 4
        )

        #expect(source.texture(at: 0) == nil)
    }

    @Test("LZ4-compressed source payload inflates correctly during playback")
    func lz4CompressedPayloadInflatesCorrectly() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let raw = makeImage(width: 4, height: 4, blue: 0)
        let compressed = try lz4RawCompress(raw)
        let mip = WPETexCompressedMipmap(
            index: 0,
            width: 4,
            height: 4,
            isCompressed: true,
            compressedBytes: compressed,
            decompressedByteCount: raw.count
        )
        let payload = WPETexStreamingPayload(
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
            compressedImages: [
                WPETexCompressedImage(width: 4, height: 4, payloads: [mip])
            ],
            frames: [
                WPETexStreamingFrame(imageID: 0, subRect: CGRect(x: 0, y: 0, width: 2, height: 2), duration: 0.1)
            ],
            frameRate: 10,
            loop: true
        )

        let source = try WPETexLazyAnimatedTextureSource(
            payload: payload,
            device: device,
            label: "lazy-lz4"
        )
        let texture = try #require(source.texture(at: 0))
        #expect(readRGBA(texture) == [
            0x00, 0x00, 0x00, 0xff, 0x01, 0x00, 0x00, 0xff,
            0x00, 0x01, 0x00, 0xff, 0x01, 0x01, 0x00, 0xff
        ])
    }

    /// Mirror of the helper in `WPETexDecoderTests`; kept private here
    /// so the lazy-source tests are self-contained.
    private func lz4RawCompress(_ data: Data) throws -> Data {
        let dstCapacity = data.count + 64
        var dst = Data(count: dstCapacity)
        let written = dst.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (input: UnsafeRawBufferPointer) -> Int in
                guard let dstPtr = out.bindMemory(to: UInt8.self).baseAddress,
                      let srcPtr = input.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return compression_encode_buffer(
                    dstPtr, dstCapacity,
                    srcPtr, data.count,
                    nil,
                    COMPRESSION_LZ4_RAW
                )
            }
        }
        guard written > 0 else {
            throw NSError(domain: "lz4", code: -1)
        }
        return dst.prefix(written)
    }

    private func makeStreamingPayload(frames: [WPETexStreamingFrame]? = nil) -> WPETexStreamingPayload {
        let image0 = makeImage(width: 4, height: 4, blue: 0)
        let image1 = makeImage(width: 4, height: 4, blue: 0x40)
        let mip0 = WPETexCompressedMipmap(
            index: 0,
            width: 4,
            height: 4,
            isCompressed: false,
            compressedBytes: image0,
            decompressedByteCount: image0.count
        )
        let mip1 = WPETexCompressedMipmap(
            index: 0,
            width: 4,
            height: 4,
            isCompressed: false,
            compressedBytes: image1,
            decompressedByteCount: image1.count
        )
        return WPETexStreamingPayload(
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
            compressedImages: [
                WPETexCompressedImage(width: 4, height: 4, payloads: [mip0]),
                WPETexCompressedImage(width: 4, height: 4, payloads: [mip1])
            ],
            frames: frames ?? [
                WPETexStreamingFrame(imageID: 0, subRect: CGRect(x: 0, y: 0, width: 2, height: 2), duration: 0.1),
                WPETexStreamingFrame(imageID: 0, subRect: CGRect(x: 2, y: 0, width: 2, height: 2), duration: 0.1),
                WPETexStreamingFrame(imageID: 1, subRect: CGRect(x: 0, y: 2, width: 2, height: 2), duration: 0.1),
                WPETexStreamingFrame(imageID: 1, subRect: CGRect(x: 2, y: 2, width: 2, height: 2), duration: 0.1)
            ],
            frameRate: 10,
            loop: true
        )
    }

    private func makeImage(width: Int, height: Int, blue: UInt8) -> Data {
        var bytes = Data(count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for y in 0..<height {
                for x in 0..<width {
                    let offset = (y * width + x) * 4
                    base[offset] = UInt8(x)
                    base[offset + 1] = UInt8(y)
                    base[offset + 2] = blue
                    base[offset + 3] = 0xff
                }
            }
        }
        return bytes
    }

    private func readRGBA(_ texture: MTLTexture) -> [UInt8] {
        let bytesPerRow = texture.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        texture.getBytes(
            &bytes,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height),
            mipmapLevel: 0
        )
        return bytes
    }
}
