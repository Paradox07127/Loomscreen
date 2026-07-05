import CoreGraphics
import Foundation
import Metal
import Testing
@testable import LiveWallpaper

@Suite("WPE .tex sub-rect cropper")
struct WPETexSubRectCropperTests {

    // MARK: - RGBA8 row-major

    @Test("nil sub-rect returns the whole RGBA8 atlas unchanged")
    func wholeAtlasPassthroughRGBA8() throws {
        let atlas = Self.rgbaAtlas4x4
        let mapping = WPEMetalTextureFormatMapping(pixelFormat: .rgba8Unorm, bytesPerPixel: 4, bytesPerBlock: nil)

        let result = try WPETexSubRectCropper.crop(
            atlasBytes: atlas,
            atlasWidth: 4,
            atlasHeight: 4,
            subRect: nil,
            mapping: mapping
        )

        #expect(result.width == 4)
        #expect(result.height == 4)
        #expect(result.bytesPerRow == 16)
        #expect(result.bytes == atlas)
    }

    @Test("Top-left 2×2 RGBA8 crop copies the expected four pixels")
    func topLeftCropRGBA8() throws {
        let atlas = Self.rgbaAtlas4x4
        let mapping = WPEMetalTextureFormatMapping(pixelFormat: .rgba8Unorm, bytesPerPixel: 4, bytesPerBlock: nil)

        let result = try WPETexSubRectCropper.crop(
            atlasBytes: atlas,
            atlasWidth: 4,
            atlasHeight: 4,
            subRect: CGRect(x: 0, y: 0, width: 2, height: 2),
            mapping: mapping
        )

        #expect(result.width == 2)
        #expect(result.height == 2)
        #expect(result.bytesPerRow == 8)
        #expect(Array(result.bytes) == [
            // row 0 (cols 0,1)
            0x00, 0x00, 0x00, 0xff, 0x01, 0x00, 0x00, 0xff,
            // row 1 (cols 0,1)
            0x10, 0x00, 0x00, 0xff, 0x11, 0x00, 0x00, 0xff
        ])
    }

    @Test("Bottom-right 2×2 RGBA8 crop copies the expected four pixels")
    func bottomRightCropRGBA8() throws {
        let atlas = Self.rgbaAtlas4x4
        let mapping = WPEMetalTextureFormatMapping(pixelFormat: .rgba8Unorm, bytesPerPixel: 4, bytesPerBlock: nil)

        let result = try WPETexSubRectCropper.crop(
            atlasBytes: atlas,
            atlasWidth: 4,
            atlasHeight: 4,
            subRect: CGRect(x: 2, y: 2, width: 2, height: 2),
            mapping: mapping
        )

        #expect(result.width == 2)
        #expect(result.height == 2)
        #expect(Array(result.bytes) == [
            // row 2 (cols 2,3)
            0x22, 0x00, 0x00, 0xff, 0x23, 0x00, 0x00, 0xff,
            // row 3 (cols 2,3)
            0x32, 0x00, 0x00, 0xff, 0x33, 0x00, 0x00, 0xff
        ])
    }

    @Test("Fractional float coords snap to nearest pixel to avoid 1px seams")
    func fractionalCoordsSnapToNearest() {
        let rect = WPETexSubRectCropper.pixelRect(
            CGRect(x: 0.4999, y: 1.5001, width: 2.5, height: 2.4999),
            atlasWidth: 8,
            atlasHeight: 8
        )

        // 0.4999 → 0, 1.5001 → 2, 2.5 → 3 (half-up via toNearestOrAwayFromZero), 2.4999 → 2
        #expect(rect.x == 0)
        #expect(rect.y == 2)
        #expect(rect.width == 3)
        #expect(rect.height == 2)
    }

    @Test("Out-of-bounds origin clamps inside the atlas")
    func outOfBoundsOriginClamps() {
        let rect = WPETexSubRectCropper.pixelRect(
            CGRect(x: 10, y: -5, width: 100, height: 100),
            atlasWidth: 4,
            atlasHeight: 4
        )

        #expect(rect.x == 3)
        #expect(rect.y == 0)
        #expect(rect.width == 1)
        #expect(rect.height == 4)
    }

    // MARK: - Block-compressed (BC3)

    @Test("nil sub-rect returns the whole BC3 atlas unchanged")
    func wholeAtlasPassthroughBC3() throws {
        let atlas = Self.bc3Atlas8x8  // 4 blocks × 16 bytes/block = 64 bytes
        let mapping = WPEMetalTextureFormatMapping(pixelFormat: .bc3_rgba, bytesPerPixel: nil, bytesPerBlock: 16)

        let result = try WPETexSubRectCropper.crop(
            atlasBytes: atlas,
            atlasWidth: 8,
            atlasHeight: 8,
            subRect: nil,
            mapping: mapping
        )

        #expect(result.width == 8)
        #expect(result.height == 8)
        #expect(result.bytesPerRow == 32)  // 2 blocks per row × 16
        #expect(result.bytes == atlas)
    }

    @Test("Block-aligned BC3 crop copies the expected single block")
    func blockAlignedCropBC3() throws {
        let atlas = Self.bc3Atlas8x8
        let mapping = WPEMetalTextureFormatMapping(pixelFormat: .bc3_rgba, bytesPerPixel: nil, bytesPerBlock: 16)

        let result = try WPETexSubRectCropper.crop(
            atlasBytes: atlas,
            atlasWidth: 8,
            atlasHeight: 8,
            subRect: CGRect(x: 4, y: 4, width: 4, height: 4),  // bottom-right block
            mapping: mapping
        )

        #expect(result.width == 4)
        #expect(result.height == 4)
        #expect(result.bytesPerRow == 16)
        // Bottom-right block is block index (1, 1) in a 2×2 grid → bytes 48..<64
        #expect(Array(result.bytes) == Array(atlas[48..<64]))
    }

    @Test("Non-aligned BC3 sub-rect throws subRectNotBlockAligned")
    func nonAlignedBC3SubRectThrows() {
        let atlas = Self.bc3Atlas8x8
        let mapping = WPEMetalTextureFormatMapping(pixelFormat: .bc3_rgba, bytesPerPixel: nil, bytesPerBlock: 16)

        #expect(throws: WPETexSubRectCropper.Failure.self) {
            _ = try WPETexSubRectCropper.crop(
                atlasBytes: atlas,
                atlasWidth: 8,
                atlasHeight: 8,
                subRect: CGRect(x: 2, y: 2, width: 4, height: 4),  // 2 is not a 4-block multiple
                mapping: mapping
            )
        }
    }

    // MARK: - Truncated bytes

    @Test("Truncated atlas bytes throw truncatedImageBytes")
    func truncatedAtlasThrows() {
        let truncated = Data(repeating: 0, count: 4)  // 4-byte buffer claiming to be a 4×4 RGBA atlas (needs 64)
        let mapping = WPEMetalTextureFormatMapping(pixelFormat: .rgba8Unorm, bytesPerPixel: 4, bytesPerBlock: nil)

        #expect(throws: WPETexSubRectCropper.Failure.truncatedImageBytes) {
            _ = try WPETexSubRectCropper.crop(
                atlasBytes: truncated,
                atlasWidth: 4,
                atlasHeight: 4,
                subRect: CGRect(x: 0, y: 0, width: 2, height: 2),
                mapping: mapping
            )
        }
    }

    // MARK: - Fixtures

    /// 4×4 RGBA8 atlas where each pixel encodes its (row, col) in the
    /// red channel: bits 7..4 = row, bits 3..0 = col. Lets every crop
    /// assertion check both the geometry and the pixel ordering.
    private static let rgbaAtlas4x4: Data = {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(4 * 4 * 4)
        for row in 0..<4 {
            for col in 0..<4 {
                bytes.append(UInt8(row << 4 | col))
                bytes.append(0)
                bytes.append(0)
                bytes.append(0xff)
            }
        }
        return Data(bytes)
    }()

    /// 8×8 BC3 atlas: 4 blocks × 16 bytes = 64 bytes. Block i has every
    /// byte set to `i`. Lets the crop assertion verify that the right
    /// block bytes land at the right output offset.
    private static let bc3Atlas8x8: Data = {
        var bytes = Data()
        for blockIndex in 0..<4 {
            bytes.append(Data(repeating: UInt8(blockIndex), count: 16))
        }
        return bytes
    }()
}
