import AppKit
import CoreGraphics
import CoreText
import Foundation
import Metal

/// CoreText-based text rasterizer. Lays out a `WPESceneTextObject` into
/// a CGContext and uploads the result as an MTLTexture. The runtime
/// composites the texture as if it were a regular image layer.
///
/// Caching: each rasterization is keyed by `(text, font, size, color,
/// alpha, horizontalAlign, maxWidth)` so repeated frames with static
/// text amortize the CoreText layout. The cache is bounded; oldest
/// entries get evicted when the store grows past `cacheLimit`.
@MainActor
final class WPETextRenderer {
    private struct CacheKey: Hashable {
        let text: String
        let fontPath: String?
        let pointSize: Int
        let colorRGB: SIMD3<Int>      // 0..255
        let alpha: Int                  // 0..255
        let alignment: String
        let maxWidth: Int               // 0 = unbounded
    }

    private struct CachedTexture {
        let texture: MTLTexture
        let renderedSize: CGSize
    }

    private let device: MTLDevice
    private let resolver: WPEMultiRootResourceResolver
    private var cache: [CacheKey: CachedTexture] = [:]
    private var cacheOrder: [CacheKey] = []
    private var registeredFonts: Set<String> = []
    private let cacheLimit = 128

    init(device: MTLDevice, resolver: WPEMultiRootResourceResolver) {
        self.device = device
        self.resolver = resolver
    }

    /// Rasterize `object` to an MTLTexture sized to its measured bounds.
    /// Returns nil only when the layout produces an empty (zero-area)
    /// glyph run, which the caller treats as "skip this layer".
    func rasterize(_ object: WPESceneTextObject) -> (texture: MTLTexture, size: CGSize)? {
        ensureFontRegistered(object.fontRelativePath)
        let key = CacheKey(
            text: object.text,
            fontPath: object.fontRelativePath,
            pointSize: Int(object.pointSize.rounded()),
            colorRGB: SIMD3<Int>(
                Int((object.color.x * 255).rounded()),
                Int((object.color.y * 255).rounded()),
                Int((object.color.z * 255).rounded())
            ),
            alpha: Int((object.alpha * 255).rounded()),
            alignment: object.horizontalAlignment,
            maxWidth: Int((object.maxWidth ?? 0).rounded())
        )
        if let cached = cache[key] {
            return (cached.texture, cached.renderedSize)
        }

        let attrString = makeAttributedString(object: object)
        let bounds = measureBounds(attrString, maxWidth: object.maxWidth)
        let width = max(1, ceil(bounds.width))
        let height = max(1, ceil(bounds.height))
        guard width >= 1, height >= 1 else { return nil }

        guard let texture = drawTexture(
            attrString: attrString,
            width: Int(width),
            height: Int(height),
            object: object
        ) else { return nil }

        let entry = CachedTexture(texture: texture, renderedSize: CGSize(width: width, height: height))
        cache[key] = entry
        cacheOrder.append(key)
        evictIfNeeded()
        return (texture, entry.renderedSize)
    }

    private func evictIfNeeded() {
        while cacheOrder.count > cacheLimit {
            let oldest = cacheOrder.removeFirst()
            cache[oldest] = nil
        }
    }

    /// Register a packaged .ttf/.otf with the system font manager so the
    /// rasterizer can find it by Display Name. WPE bundles fonts inside
    /// the scene package (e.g. `fonts/p5hatty.ttf`); without registration
    /// CoreText falls back to the system font and the visual diverges.
    private func ensureFontRegistered(_ relativePath: String?) {
        guard let path = relativePath, !registeredFonts.contains(path) else { return }
        registeredFonts.insert(path)
        guard let url = try? resolver.resolveExistingFileURL(relativePath: path) else { return }
        var unmanagedError: Unmanaged<CFError>?
        _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &unmanagedError)
        // Ignore errors — duplicate registration is fine; the rasterizer
        // falls back to the system font when the registered family
        // can't be found.
        unmanagedError?.release()
    }

    private func makeAttributedString(object: WPESceneTextObject) -> NSAttributedString {
        let font = resolveFont(
            relativePath: object.fontRelativePath,
            size: CGFloat(object.pointSize)
        )
        let color = CGColor(
            srgbRed: CGFloat(object.color.x),
            green: CGFloat(object.color.y),
            blue: CGFloat(object.color.z),
            alpha: CGFloat(object.alpha)
        )
        let paragraph = NSMutableParagraphStyle()
        switch object.horizontalAlignment {
        case "left":   paragraph.alignment = .left
        case "right":  paragraph.alignment = .right
        default:       paragraph.alignment = .center
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        return NSAttributedString(string: object.text, attributes: attributes)
    }

    private func resolveFont(relativePath: String?, size: CGFloat) -> CTFont {
        // Try resolved family first (registration walks scene package).
        if let path = relativePath,
           let url = try? resolver.resolveExistingFileURL(relativePath: path),
           let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
           let descriptor = descriptors.first {
            return CTFontCreateWithFontDescriptor(descriptor, size, nil)
        }
        // System fallback — sufficient to keep rendering when the bundled
        // font is missing or cannot be loaded.
        return CTFontCreateWithName("HelveticaNeue" as CFString, size, nil)
    }

    private func measureBounds(_ attrString: NSAttributedString, maxWidth: Double?) -> CGRect {
        let framesetter = CTFramesetterCreateWithAttributedString(attrString)
        let widthConstraint: CGFloat = maxWidth.map { CGFloat($0) } ?? CGFloat.greatestFiniteMagnitude
        let constraint = CGSize(
            width: widthConstraint,
            height: CGFloat.greatestFiniteMagnitude
        )
        var fitRange = CFRange()
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: attrString.length),
            nil,
            constraint,
            &fitRange
        )
        // Add a 4px padding so the last glyph's antialiased edge isn't
        // clipped at the texture boundary.
        return CGRect(x: 0, y: 0, width: size.width + 4, height: size.height + 4)
    }

    private func drawTexture(
        attrString: NSAttributedString,
        width: Int,
        height: Int,
        object: WPESceneTextObject
    ) -> MTLTexture? {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let alignedRow = ((bytesPerRow + 255) / 256) * 256
        var pixels = [UInt8](repeating: 0, count: alignedRow * height)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: alignedRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        // CoreText draws with origin at lower-left; we want top-left so
        // the runtime can sample with the same UV convention as image
        // layers. Flip the CTM before framing.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)

        let framesetter = CTFramesetterCreateWithAttributedString(attrString)
        let path = CGMutablePath()
        path.addRect(CGRect(x: 2, y: 2, width: CGFloat(width) - 4, height: CGFloat(height) - 4))
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: attrString.length),
            path,
            nil
        )
        CTFrameDraw(frame, ctx)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.label = "WPE text \(object.id)"
        let region = MTLRegionMake2D(0, 0, width, height)
        // Use the unaligned bytesPerRow because Metal's replace expects
        // exactly width*4 in shared storage; CoreText wrote into the
        // 256-aligned buffer so we copy row-by-row.
        var packed = [UInt8](repeating: 0, count: bytesPerRow * height)
        for row in 0..<height {
            let src = row * alignedRow
            let dst = row * bytesPerRow
            packed.withUnsafeMutableBufferPointer { pBuf in
                pixels.withUnsafeBufferPointer { sBuf in
                    pBuf.baseAddress!.advanced(by: dst).update(
                        from: sBuf.baseAddress!.advanced(by: src),
                        count: bytesPerRow
                    )
                }
            }
        }
        packed.withUnsafeBytes { raw in
            texture.replace(region: region, mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: bytesPerRow)
        }
        return texture
    }

    func releaseAll() {
        cache.removeAll(keepingCapacity: false)
        cacheOrder.removeAll(keepingCapacity: false)
    }
}
