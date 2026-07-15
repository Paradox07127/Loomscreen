#if !LITE_BUILD
import CoreGraphics
import Foundation

/// CPU-side sub-rect cropper shared by the eager and lazy animated `.tex`
/// paths so both produce pixel-identical crops. Mirrors
/// `WPETexLazyAnimatedTextureSource.crop`:
/// - TEXS frames carry integer pixel coords stored as Float; snap-to-nearest
///   before clamping so 2415.9999 doesn't drop a row and introduce a 1px seam.
/// - BC1/BC2/BC3/BC7 atlases require 4×4 block alignment; non-aligned
///   sub-rects throw rather than silently emit a torn output.
enum WPETexSubRectCropper {
    struct CroppedTextureBytes: Sendable, Equatable {
        let bytes: Data
        let width: Int
        let height: Int
        let bytesPerRow: Int
    }

    enum Failure: Error, Equatable, Sendable {
        case truncatedImageBytes
        case subRectNotBlockAligned(CGRect, blockSize: Int)
        case missingFormatMapping
    }

    struct PixelRect: Sendable, Equatable {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }

    static func pixelRect(_ rect: CGRect, atlasWidth: Int, atlasHeight: Int) -> PixelRect {
        let snappedX = rect.origin.x.rounded(.toNearestOrAwayFromZero)
        let snappedY = rect.origin.y.rounded(.toNearestOrAwayFromZero)
        let snappedW = rect.width.rounded(.toNearestOrAwayFromZero)
        let snappedH = rect.height.rounded(.toNearestOrAwayFromZero)

        let x = min(max(Int(snappedX), 0), max(atlasWidth - 1, 0))
        let y = min(max(Int(snappedY), 0), max(atlasHeight - 1, 0))
        let w = min(max(Int(snappedW), 1), max(atlasWidth - x, 1))
        let h = min(max(Int(snappedH), 1), max(atlasHeight - y, 1))
        return PixelRect(x: x, y: y, width: w, height: h)
    }

    /// A nil `subRect` returns the atlas unchanged — pass-through for `.tex`
    /// files that omit a TEXS block (no per-frame layout to apply).
    static func crop(
        atlasBytes: Data,
        atlasWidth: Int,
        atlasHeight: Int,
        subRect: CGRect?,
        mapping: WPEMetalTextureFormatMapping
    ) throws -> CroppedTextureBytes {
        guard atlasWidth > 0, atlasHeight > 0 else {
            throw Failure.truncatedImageBytes
        }
        guard let subRect else {
            return try wholeAtlas(
                atlasBytes: atlasBytes,
                atlasWidth: atlasWidth,
                atlasHeight: atlasHeight,
                mapping: mapping
            )
        }

        let rect = pixelRect(subRect, atlasWidth: atlasWidth, atlasHeight: atlasHeight)

        if let bytesPerPixel = mapping.bytesPerPixel {
            return try cropRowMajor(
                atlasBytes: atlasBytes,
                atlasWidth: atlasWidth,
                atlasHeight: atlasHeight,
                rect: rect,
                bytesPerPixel: bytesPerPixel
            )
        }

        guard let bytesPerBlock = mapping.bytesPerBlock else {
            throw Failure.missingFormatMapping
        }
        return try cropBlockCompressed(
            atlasBytes: atlasBytes,
            atlasWidth: atlasWidth,
            atlasHeight: atlasHeight,
            rect: rect,
            bytesPerBlock: bytesPerBlock
        )
    }

    private static func wholeAtlas(
        atlasBytes: Data,
        atlasWidth: Int,
        atlasHeight: Int,
        mapping: WPEMetalTextureFormatMapping
    ) throws -> CroppedTextureBytes {
        if let bytesPerPixel = mapping.bytesPerPixel {
            let bytesPerRow = atlasWidth * bytesPerPixel
            guard atlasBytes.count >= bytesPerRow * atlasHeight else {
                throw Failure.truncatedImageBytes
            }
            return CroppedTextureBytes(
                bytes: atlasBytes,
                width: atlasWidth,
                height: atlasHeight,
                bytesPerRow: bytesPerRow
            )
        }
        guard let bytesPerBlock = mapping.bytesPerBlock else {
            throw Failure.missingFormatMapping
        }
        let blocksW = max((atlasWidth + 3) / 4, 1)
        let blocksH = max((atlasHeight + 3) / 4, 1)
        let bytesPerRow = blocksW * bytesPerBlock
        guard atlasBytes.count >= bytesPerRow * blocksH else {
            throw Failure.truncatedImageBytes
        }
        return CroppedTextureBytes(
            bytes: atlasBytes,
            width: atlasWidth,
            height: atlasHeight,
            bytesPerRow: bytesPerRow
        )
    }

    private static func cropRowMajor(
        atlasBytes: Data,
        atlasWidth: Int,
        atlasHeight: Int,
        rect: PixelRect,
        bytesPerPixel: Int
    ) throws -> CroppedTextureBytes {
        let sourceBytesPerRow = atlasWidth * bytesPerPixel
        let outputBytesPerRow = rect.width * bytesPerPixel
        guard atlasBytes.count >= sourceBytesPerRow * atlasHeight else {
            throw Failure.truncatedImageBytes
        }
        var output = Data(count: outputBytesPerRow * rect.height)
        atlasBytes.withUnsafeBytes { srcRaw in
            output.withUnsafeMutableBytes { dstRaw in
                guard let src = srcRaw.bindMemory(to: UInt8.self).baseAddress,
                      let dst = dstRaw.bindMemory(to: UInt8.self).baseAddress else { return }
                for row in 0..<rect.height {
                    let srcOffset = (rect.y + row) * sourceBytesPerRow + rect.x * bytesPerPixel
                    let dstOffset = row * outputBytesPerRow
                    dst.advanced(by: dstOffset).update(from: src.advanced(by: srcOffset), count: outputBytesPerRow)
                }
            }
        }
        return CroppedTextureBytes(
            bytes: output,
            width: rect.width,
            height: rect.height,
            bytesPerRow: outputBytesPerRow
        )
    }

    private static func cropBlockCompressed(
        atlasBytes: Data,
        atlasWidth: Int,
        atlasHeight: Int,
        rect: PixelRect,
        bytesPerBlock: Int
    ) throws -> CroppedTextureBytes {
        let blockSize = 4
        guard rect.x % blockSize == 0,
              rect.y % blockSize == 0,
              rect.width % blockSize == 0,
              rect.height % blockSize == 0 else {
            throw Failure.subRectNotBlockAligned(
                CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height),
                blockSize: blockSize
            )
        }
        let sourceBlocksX = max((atlasWidth + blockSize - 1) / blockSize, 1)
        let sourceBlocksY = max((atlasHeight + blockSize - 1) / blockSize, 1)
        let cropBlocksX = rect.width / blockSize
        let cropBlocksY = rect.height / blockSize
        let originBlockX = rect.x / blockSize
        let originBlockY = rect.y / blockSize
        let sourceBytesPerBlockRow = sourceBlocksX * bytesPerBlock
        let outputBytesPerBlockRow = cropBlocksX * bytesPerBlock
        guard atlasBytes.count >= sourceBytesPerBlockRow * sourceBlocksY else {
            throw Failure.truncatedImageBytes
        }
        var output = Data(count: outputBytesPerBlockRow * cropBlocksY)
        atlasBytes.withUnsafeBytes { srcRaw in
            output.withUnsafeMutableBytes { dstRaw in
                guard let src = srcRaw.bindMemory(to: UInt8.self).baseAddress,
                      let dst = dstRaw.bindMemory(to: UInt8.self).baseAddress else { return }
                for blockRow in 0..<cropBlocksY {
                    let srcOffset = (originBlockY + blockRow) * sourceBytesPerBlockRow + originBlockX * bytesPerBlock
                    let dstOffset = blockRow * outputBytesPerBlockRow
                    dst.advanced(by: dstOffset).update(from: src.advanced(by: srcOffset), count: outputBytesPerBlockRow)
                }
            }
        }
        return CroppedTextureBytes(
            bytes: output,
            width: rect.width,
            height: rect.height,
            bytesPerRow: outputBytesPerBlockRow
        )
    }
}
#endif
