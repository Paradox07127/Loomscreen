#if !LITE_BUILD
import AppKit
import Metal

/// Background readback helper that converts the Metal renderer's offscreen
/// `MTLTexture` into an `NSImage` for `WPESceneDetailView`. Phase 2A's
/// renderer left the Metal backend without a thumbnail; the detail view
/// then fell into `.previewUnavailable`. Phase 2B Task 5 wires this
/// snapshotter through `WPESceneRenderer.previewSnapshot`.
///
/// The readback runs on a dedicated utility-QoS queue so a 4K mip-chain
/// readback never blocks the main thread on a multi-display setup; the
/// snapshotter is `@unchecked Sendable` because every closure it owns is
/// either pure or hops onto the main actor explicitly via the calling
/// renderer.
final class WPEMetalTextureSnapshotter: @unchecked Sendable {
    static let shared = WPEMetalTextureSnapshotter()

    private let queue: DispatchQueue

    init(label: String = "com.livewallpaper.wpe-metal.snapshot-readback") {
        self.queue = DispatchQueue(label: label, qos: .utility)
    }

    /// Synchronous readback.
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
#endif
