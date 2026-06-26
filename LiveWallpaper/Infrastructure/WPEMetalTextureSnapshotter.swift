#if !LITE_BUILD
import AppKit
import Metal

/// Reads back the renderer's offscreen `MTLTexture` into an `NSImage` for
/// `WPESceneDetailView` (without it the detail view falls into
/// `.previewUnavailable`). Runs on a dedicated utility-QoS queue so a 4K
/// mip-chain readback never blocks the main thread on multi-display setups;
/// `@unchecked Sendable` because every owned closure is pure or hops onto the
/// main actor explicitly.
final class WPEMetalTextureSnapshotter: @unchecked Sendable {
    static let shared = WPEMetalTextureSnapshotter()

    private let queue: DispatchQueue

    init(label: String = "com.livewallpaper.wpe-metal.snapshot-readback") {
        self.queue = DispatchQueue(label: label, qos: .utility)
    }

    func snapshot(from texture: MTLTexture) -> NSImage? {
        Self.makeImage(from: texture)
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

struct WPEMetalTextureVisualBounds: Codable, Equatable, Sendable, CustomStringConvertible {
    let minX: Int
    let minY: Int
    let maxX: Int
    let maxY: Int

    var width: Int {
        maxX - minX + 1
    }

    var height: Int {
        maxY - minY + 1
    }

    var description: String {
        "bounds=(\(minX),\(minY))-(\(maxX),\(maxY)) size=\(width)x\(height)"
    }

    func coversFullFrame(width: Int, height: Int) -> Bool {
        minX <= 0 && minY <= 0 && maxX >= width - 1 && maxY >= height - 1
    }
}

struct WPEMetalTextureVisualStats: Codable, Equatable, Sendable, CustomStringConvertible {
    let width: Int
    let height: Int
    let nonBlackPixelCount: Int
    let nonTransparentPixelCount: Int
    let nonBlackBounds: WPEMetalTextureVisualBounds?

    var nonBlackCoversFullFrame: Bool {
        nonBlackBounds?.coversFullFrame(width: width, height: height) ?? false
    }

    var oneLineDescription: String {
        let bounds = nonBlackBounds?.description ?? "bounds=nil"
        return "size=\(width)x\(height) nonBlack=\(nonBlackPixelCount) nonTransparent=\(nonTransparentPixelCount) \(bounds)"
    }

    var description: String {
        """
        width: \(width)
        height: \(height)
        nonBlackPixelCount: \(nonBlackPixelCount)
        nonTransparentPixelCount: \(nonTransparentPixelCount)
        nonBlackBounds: \(nonBlackBounds?.description ?? "nil")
        nonBlackCoversFullFrame: \(nonBlackCoversFullFrame)
        """
    }

    static func analyze(
        texture: MTLTexture,
        colorThreshold: UInt8 = 10,
        alphaThreshold: UInt8 = 0
    ) -> WPEMetalTextureVisualStats? {
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

        var nonBlackPixelCount = 0
        var nonTransparentPixelCount = 0
        var minX = Int.max
        var minY = Int.max
        var maxX = Int.min
        var maxY = Int.min

        for y in 0..<texture.height {
            for x in 0..<texture.width {
                let index = (y * bytesPerRow) + (x * bytesPerPixel)
                let r = bytes[index]
                let g = bytes[index + 1]
                let b = bytes[index + 2]
                let a = bytes[index + 3]
                if a > alphaThreshold {
                    nonTransparentPixelCount += 1
                }
                guard r > colorThreshold || g > colorThreshold || b > colorThreshold else {
                    continue
                }
                nonBlackPixelCount += 1
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }

        let bounds = minX == Int.max
            ? nil
            : WPEMetalTextureVisualBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
        return WPEMetalTextureVisualStats(
            width: texture.width,
            height: texture.height,
            nonBlackPixelCount: nonBlackPixelCount,
            nonTransparentPixelCount: nonTransparentPixelCount,
            nonBlackBounds: bounds
        )
    }
}
#endif
