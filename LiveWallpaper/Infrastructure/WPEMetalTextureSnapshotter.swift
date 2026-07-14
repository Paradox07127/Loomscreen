#if !LITE_BUILD
import AppKit
import Metal

/// CPU twin of `wpe_present_tonemap_fragment` (WPEMetalBuiltins.metal) — the
/// flag-gated (`WPEMetalHDRTonemapEnabled`) hue-preserving soft-knee compression
/// of overbright HDR pixels, applied here so the snapshotter's poster matches
/// what the tonemapped present pass puts on screen. Peak m = max(r,g,b) maps to
/// 2 - 1/m (slope 1 at m = 1 ⇒ C1-continuous knee, asymptote 2) and all channels
/// scale by the same factor; m <= 1 (and NaN) passes through untouched. GPU and
/// CPU cannot share source — WPEPresentTonemapTests locks both to the same
/// sample points; change them together.
enum WPEHDRTonemapCurve {
    /// Opt-in: `defaults write Taijia.LiveWallpaper WPEMetalHDRTonemapEnabled -bool YES`.
    /// Mac-only enhancement, NOT a WPE-fidelity fix — Windows WPE has no tonemap
    /// operator; on SDR displays its combine_hdr.frag hard-clamps (`saturate`) just
    /// like our unorm drawable write does. OFF (the default) keeps the byte-identical
    /// legacy present + snapshot paths. Lives here (Infrastructure) so the Runtime
    /// executor depends inward, not the other way (ADR-002 boundary).
    static let isEnabled: Bool =
        UserDefaults.standard.bool(forKey: "WPEMetalHDRTonemapEnabled")

    static func scale(forPeak peak: Float) -> Float {
        guard peak > 1 else { return 1 }
        // half-max guard, mirroring the MSL: an inf peak must not zero the scale.
        let clamped = min(peak, 65504)
        return (2 - 1 / clamped) / clamped
    }

    static func apply(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        rgb * scale(forPeak: max(rgb.x, max(rgb.y, rgb.z)))
    }
}

/// Reads back the renderer's offscreen `MTLTexture` into an `NSImage` for
/// `WPESceneDetailView` (without it the detail view falls into
/// `.previewUnavailable`). Runs on a dedicated utility-QoS queue so a 4K
/// mip-chain readback never blocks the main thread on multi-display setups;
/// `@unchecked Sendable` because every owned closure is pure or hops onto the
/// main actor explicitly.
final class WPEMetalTextureSnapshotter: @unchecked Sendable {
    static let shared = WPEMetalTextureSnapshotter()

    struct SnapshotSource: @unchecked Sendable {
        let texture: MTLTexture
    }

    private let queue: DispatchQueue

    init(label: String = "com.livewallpaper.wpe-metal.snapshot-readback") {
        self.queue = DispatchQueue(label: label, qos: .utility)
    }

    func snapshot(from texture: MTLTexture) -> NSImage? {
        Self.makeImage(from: texture)
    }

    func snapshotAsync(from source: SnapshotSource) async -> NSImage? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: Self.makeImage(from: source.texture))
            }
        }
    }

    private static func makeImage(from texture: MTLTexture) -> NSImage? {
        guard texture.width > 0, texture.height > 0 else {
            return nil
        }

        let bytes: [UInt8]
        switch texture.pixelFormat {
        case .rgba8Unorm, .rgba8Unorm_srgb:
            bytes = readRGBA8(texture)
        case .bgra8Unorm, .bgra8Unorm_srgb:
            var swizzled = readRGBA8(texture)
            for index in stride(from: 0, to: swizzled.count, by: 4) {
                swizzled.swapAt(index, index + 2)
            }
            bytes = swizzled
        case .rgba16Float:
            // Linear HDR output (bloom scenes): clamp to SDR and sRGB-encode so
            // the poster approximates the frame the user sees. With the HDR
            // tonemap flag ON the same soft-knee curve as the present pass runs
            // first, keeping the poster in step with the screen.
            bytes = convertRGBA16FloatToSRGB8(texture)
        default:
            Logger.warning(
                "[snapshot] unsupported pixel format \(texture.pixelFormat.rawValue) (\(texture.width)x\(texture.height)) — no poster",
                category: .wpeRender
            )
            return nil
        }

        let bytesPerRow = texture.width * 4
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

    private static func readRGBA8(_ texture: MTLTexture) -> [UInt8] {
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

    /// Internal (not private) + injectable flag so WPEPresentTonemapTests can pin
    /// both the legacy clamp path and the tonemapped path without touching defaults.
    static func convertRGBA16FloatToSRGB8(
        _ texture: MTLTexture,
        tonemapEnabled: Bool = WPEHDRTonemapCurve.isEnabled
    ) -> [UInt8] {
        let pixelCount = texture.width * texture.height
        var halves = [UInt16](repeating: 0, count: pixelCount * 4)
        texture.getBytes(
            &halves,
            bytesPerRow: texture.width * 8,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height),
            mipmapLevel: 0
        )
        var out = [UInt8](repeating: 0, count: pixelCount * 4)
        for pixel in 0..<pixelCount {
            let base = pixel * 4
            var rgb = SIMD3<Float>(
                Float(Float16(bitPattern: halves[base])),
                Float(Float16(bitPattern: halves[base + 1])),
                Float(Float16(bitPattern: halves[base + 2]))
            )
            if tonemapEnabled {
                rgb = WPEHDRTonemapCurve.apply(rgb)
            }
            for channel in 0..<3 {
                out[base + channel] = UInt8(sRGBEncode(clampedUnit(rgb[channel])) * 255 + 0.5)
            }
            let alpha = clampedUnit(Float(Float16(bitPattern: halves[base + 3])))
            out[base + 3] = UInt8(alpha * 255 + 0.5)
        }
        return out
    }

    /// NaN-safe clamp: a NaN texel would trap the UInt8 conversion.
    private static func clampedUnit(_ value: Float) -> Float {
        value.isFinite ? min(max(value, 0), 1) : 0
    }

    private static func sRGBEncode(_ linear: Float) -> Float {
        linear <= 0.0031308 ? linear * 12.92 : 1.055 * pow(linear, 1 / 2.4) - 0.055
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

/// Float-texture (rgba16Float) companion to `WPEMetalTextureVisualStats` for the
/// HDR-tonemap evidence path: quantifies how much of the frame is overbright
/// (any channel > 1.0) and how far the peak goes — exactly the information an
/// 8-bit PNG export destroys. Logged next to the `WPEDumpScenePasses` present
/// dumps so a tonemap A/B has numbers, not just eyeballed pixels.
struct WPEMetalTextureFloatStats: Codable, Equatable, Sendable, CustomStringConvertible {
    let width: Int
    let height: Int
    /// Pixels with any finite RGB channel strictly above 1.0 (pre-tonemap linear).
    let overbrightPixelCount: Int
    /// Largest finite RGB channel value seen anywhere in the frame.
    let maxChannelValue: Float

    var oneLineDescription: String {
        "size=\(width)x\(height) overbright=\(overbrightPixelCount) maxChannel=\(maxChannelValue)"
    }

    var description: String { oneLineDescription }

    static func analyze(texture: MTLTexture) -> WPEMetalTextureFloatStats? {
        guard texture.width > 0, texture.height > 0, texture.pixelFormat == .rgba16Float else {
            return nil
        }
        let pixelCount = texture.width * texture.height
        var halves = [UInt16](repeating: 0, count: pixelCount * 4)
        texture.getBytes(
            &halves,
            bytesPerRow: texture.width * 8,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height),
            mipmapLevel: 0
        )
        var overbright = 0
        var maxChannel: Float = 0
        for pixel in 0..<pixelCount {
            let base = pixel * 4
            var pixelPeak: Float = 0
            for channel in 0..<3 {
                let value = Float(Float16(bitPattern: halves[base + channel]))
                if value.isFinite {
                    pixelPeak = max(pixelPeak, value)
                }
            }
            if pixelPeak > 1 {
                overbright += 1
            }
            maxChannel = max(maxChannel, pixelPeak)
        }
        return WPEMetalTextureFloatStats(
            width: texture.width,
            height: texture.height,
            overbrightPixelCount: overbright,
            maxChannelValue: maxChannel
        )
    }
}
#endif
