#if !LITE_BUILD
import AppKit
import CoreGraphics
import CoreText
import Foundation
import Metal

/// CoreText-based text rasterizer producing a coverage mask (opaque white
/// glyphs); the overlay shader applies color + alpha. Cache keyed by the
/// layout-affecting fields only (not color/alpha) so animated-alpha/tint text
/// still hits the cache; bounded by `cacheLimit`.
@MainActor
final class WPETextRenderer {
    private struct CacheKey: Hashable {
        let text: String
        let fontPath: String?
        let pointSize: Int
        let alignment: String
        let maxWidth: Int               // 0 = unbounded
    }

    private struct CachedTexture {
        let texture: MTLTexture
        let renderedSize: CGSize
    }

    /// Inputs that determine `effectiveFontSize` — text geometry only, no
    /// color/alpha. Lets the box-fit measurement (two CoreText layouts) be
    /// memoized so a cache-HIT frame pays nothing; box-fit text otherwise
    /// re-ran CTFramesetter every frame even when the texture was cached.
    private struct FontSizeKey: Hashable {
        let text: String
        let fontPath: String?
        let basePointSize: Double
        let boxWidth: Double
        let boxHeight: Double
        let padding: Double
        let maxWidth: Double             // <0 = unbounded
        let alignment: String
    }

    private let device: MTLDevice
    private let resolver: WPEMultiRootResourceResolver
    private var cache: [CacheKey: CachedTexture] = [:]
    private var cacheOrder: [CacheKey] = []
    private var fontSizeCache: [FontSizeKey: CGFloat] = [:]
    private var fontDescriptorCache: [String: CTFontDescriptor] = [:]
    private var registeredFonts: Set<String> = []
    private let cacheLimit = 128

    init(device: MTLDevice, resolver: WPEMultiRootResourceResolver) {
        self.device = device
        self.resolver = resolver
    }

    func rasterize(_ object: WPESceneTextObject) -> (texture: MTLTexture, size: CGSize)? {
        ensureFontRegistered(object.fontRelativePath)
        let fontSize = effectiveFontSize(for: object)
        let key = CacheKey(
            text: object.text,
            fontPath: object.fontRelativePath,
            pointSize: Int(fontSize.rounded()),
            alignment: object.horizontalAlignment,
            maxWidth: Int((object.maxWidth ?? 0).rounded())
        )
        if let cached = cache[key] {
            return (cached.texture, cached.renderedSize)
        }

        let attrString = makeAttributedString(object: object, fontSize: fontSize)
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

    /// Register a packaged .ttf/.otf with the system font manager so the rasterizer can find it by Display Name.
    private func ensureFontRegistered(_ relativePath: String?) {
        guard let path = relativePath, !WPESystemFont.isReference(path), !registeredFonts.contains(path) else { return }
        registeredFonts.insert(path)
        guard let url = try? resolver.resolveExistingFileURL(relativePath: path) else { return }
        var unmanagedError: Unmanaged<CFError>?
        _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &unmanagedError)
        unmanagedError?.release()
    }

    /// When the object carries a WPE `boxSize`, scale the font so the text fills
    /// the box minus `padding` (preserving aspect), matching WPE which renders
    /// text as an image whose texture is `size`. Without a box, use raw `pointSize`.
    private func effectiveFontSize(for object: WPESceneTextObject) -> CGFloat {
        let base = CGFloat(max(object.pointSize, 1))
        guard let box = object.boxSize, box.x > 0, box.y > 0 else { return base }
        let key = FontSizeKey(
            text: object.text,
            fontPath: object.fontRelativePath,
            basePointSize: object.pointSize,
            boxWidth: box.x,
            boxHeight: box.y,
            padding: object.padding,
            maxWidth: object.maxWidth ?? -1,
            alignment: object.horizontalAlignment
        )
        if let cached = fontSizeCache[key] { return cached }
        let baseAttr = makeAttributedString(object: object, fontSize: base)
        let natural = measureBounds(baseAttr, maxWidth: object.maxWidth)
        let innerW = max(box.x - 2 * object.padding, 1)
        let innerH = max(box.y - 2 * object.padding, 1)
        let nw = max(Double(natural.width), 0.5)
        let nh = max(Double(natural.height), 0.5)
        let fit = min(innerW / nw, innerH / nh)
        guard fit.isFinite, fit > 0 else { return base }
        let result = base * CGFloat(fit)
        if fontSizeCache.count >= cacheLimit { fontSizeCache.removeAll(keepingCapacity: true) }
        fontSizeCache[key] = result
        return result
    }

    private func makeAttributedString(object: WPESceneTextObject, fontSize: CGFloat) -> NSAttributedString {
        let font = resolveFont(
            relativePath: object.fontRelativePath,
            size: fontSize
        )
        // Rasterize a neutral coverage mask (opaque white glyphs); the overlay
        // shader applies the object's color + alpha once, premultiplied. Keeps
        // the texture independent of color/alpha so animated-alpha/tint text hits
        // the cache, and fixes the prior double-application (color/alpha were
        // baked here AND multiplied again in the shader).
        let color = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
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
        // Cache the size-independent descriptor per path: resolving the file URL
        // (stat/symlink) + CTFontManagerCreateFontDescriptorsFromURL is the costly
        // part and re-ran on every cache miss (e.g. a clock's once-a-second text).
        // CTFontCreateWithFontDescriptor at the current size is cheap.
        if let path = relativePath {
            if WPESystemFont.isReference(path) {
                return WPESystemFont.font(for: path, size: size)
            }
            if let descriptor = fontDescriptorCache[path] {
                return CTFontCreateWithFontDescriptor(descriptor, size, nil)
            }
            if let url = try? resolver.resolveExistingFileURL(relativePath: path),
               let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
               let descriptor = descriptors.first {
                fontDescriptorCache[path] = descriptor
                return CTFontCreateWithFontDescriptor(descriptor, size, nil)
            }
        }
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
        WPEMetalTextureMetadataRegistry.shared.register(texture: texture)
        let region = MTLRegionMake2D(0, 0, width, height)
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
        fontSizeCache.removeAll(keepingCapacity: false)
        fontDescriptorCache.removeAll(keepingCapacity: false)
    }
}
#endif
