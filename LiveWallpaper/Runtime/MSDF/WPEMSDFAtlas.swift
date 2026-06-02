#if !LITE_BUILD
import CoreGraphics
import CoreText
import Foundation
import Metal

struct WPEMSDFGlyphKey: Hashable {
    let fontID: String
    let glyph: CGGlyph
    let pixelSize: Int

    init(fontID: String, glyph: CGGlyph, pixelSize: Int) {
        self.fontID = fontID
        self.glyph = glyph
        self.pixelSize = max(pixelSize, 1)
    }
}

struct WPEMSDFAtlasEntry {
    let page: Int
    let uvRect: CGRect
    let pixelRect: CGRect
    let metrics: WPEMSDFGlyphMetrics
}

@MainActor
final class WPEMSDFAtlas {
    private struct SkylineNode {
        var x: Int
        var y: Int
        var width: Int
    }

    private final class Page {
        let id: Int
        let size: Int
        var skyline: [SkylineNode]
        var keys: Set<WPEMSDFGlyphKey> = []
        var texture: MTLTexture?
        var lastUsed: UInt64 = 0

        init(id: Int, size: Int) {
            self.id = id
            self.size = size
            self.skyline = [SkylineNode(x: 0, y: 0, width: size)]
        }

        func allocate(width: Int, height: Int) -> (x: Int, y: Int)? {
            guard width > 0, height > 0, width <= size, height <= size else { return nil }
            guard let position = findPosition(width: width, height: height) else { return nil }
            addSkylineLevel(index: position.index, x: position.x, y: position.y, width: width, height: height)
            return (x: position.x, y: position.y)
        }

        func reset() {
            // Keep the MTLTexture across eviction: only the packing state is
            // reset. New glyphs overwrite their own sub-rects; stale pixels are
            // never sampled (their entries are removed and glyphs carry padding).
            // Avoids reallocating + re-registering a 1024² texture under LRU churn.
            skyline = [SkylineNode(x: 0, y: 0, width: size)]
            keys.removeAll(keepingCapacity: true)
            lastUsed = 0
        }

        func ensureTexture(device: MTLDevice) -> MTLTexture? {
            if let texture { return texture }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: size,
                height: size,
                mipmapped: false
            )
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .shared
            guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
            texture.label = "WPE MSDF atlas page \(id)"
            WPEMetalTextureMetadataRegistry.shared.register(texture: texture)
            self.texture = texture
            return texture
        }

        private func findPosition(width: Int, height: Int) -> (index: Int, x: Int, y: Int)? {
            var best: (index: Int, x: Int, y: Int)?
            for index in skyline.indices {
                let x = skyline[index].x
                guard let y = fitY(index: index, width: width, height: height) else { continue }
                if best == nil || y < best!.y || (y == best!.y && x < best!.x) {
                    best = (index: index, x: x, y: y)
                }
            }
            return best
        }

        private func fitY(index: Int, width: Int, height: Int) -> Int? {
            let x = skyline[index].x
            guard x + width <= size else { return nil }

            var widthLeft = width
            var y = skyline[index].y
            var cursor = index
            while widthLeft > 0 {
                guard cursor < skyline.count else { return nil }
                y = max(y, skyline[cursor].y)
                guard y + height <= size else { return nil }
                widthLeft -= skyline[cursor].width
                cursor += 1
            }
            return y
        }

        private func addSkylineLevel(index: Int, x: Int, y: Int, width: Int, height: Int) {
            skyline.insert(SkylineNode(x: x, y: y + height, width: width), at: index)

            var cursor = index + 1
            while cursor < skyline.count {
                let previous = skyline[cursor - 1]
                var current = skyline[cursor]
                let previousEnd = previous.x + previous.width
                guard current.x < previousEnd else { break }

                let shrink = previousEnd - current.x
                current.x += shrink
                current.width -= shrink
                if current.width <= 0 {
                    skyline.remove(at: cursor)
                } else {
                    skyline[cursor] = current
                    cursor += 1
                }
            }
            mergeSkyline()
        }

        private func mergeSkyline() {
            var index = 0
            while index + 1 < skyline.count {
                if skyline[index].y == skyline[index + 1].y {
                    skyline[index].width += skyline[index + 1].width
                    skyline.remove(at: index + 1)
                } else {
                    index += 1
                }
            }
        }
    }

    private struct GeneratedGlyph: @unchecked Sendable {
        let bitmap: WPEMSDFBitmap
        let metrics: WPEMSDFGlyphMetrics
    }

    /// Wraps the (non-Sendable) CTFont + generator so the background generation
    /// task can capture them across the @Sendable boundary safely (the inputs
    /// are only read, and the generator is immutable).
    private struct GlyphGenerationRequest: @unchecked Sendable {
        let key: WPEMSDFGlyphKey
        let generator: WPEMSDFGlyphGenerator
        let font: CTFont
        let maxCellSide: Int
    }

    /// Outcome of a non-blocking glyph request.
    enum GlyphRequest {
        /// Glyph is ready in the atlas — draw a quad.
        case ready(WPEMSDFAtlasEntry)
        /// Generation is in flight — caller should fall back this frame and retry.
        case pending
        /// Glyph has no drawable outline (whitespace) or permanently failed —
        /// advance past it but draw nothing, and never schedule it again.
        case skip
    }

    private let device: MTLDevice
    private let pageSize: Int
    private let maxPages: Int
    private var pages: [Page] = []
    private var entries: [WPEMSDFGlyphKey: WPEMSDFAtlasEntry] = [:]
    private var pending: Set<WPEMSDFGlyphKey> = []
    /// Glyphs with no outline (whitespace / unsupported) or that exhausted their
    /// store retries. Returned as `.skip` so they are never re-scheduled (fixes
    /// per-frame background-task churn) and never drawn as a bogus 0.5 quad.
    private var skipped: Set<WPEMSDFGlyphKey> = []
    /// Transient store-failure (e.g. texture allocation) retry counts; a glyph is
    /// only moved to `skipped` after exhausting these, so a temporary failure can
    /// recover instead of being permanently dropped.
    private var storeFailures: [WPEMSDFGlyphKey: Int] = [:]
    private var clock: UInt64 = 0

    init(device: MTLDevice, pageSize: Int = 1024, maxPages: Int = 4) {
        self.device = device
        self.pageSize = max(pageSize, 1)
        self.maxPages = max(maxPages, 1)
    }

    func entry(
        for key: WPEMSDFGlyphKey,
        generator: WPEMSDFGlyphGenerator,
        font: CTFont
    ) -> WPEMSDFAtlasEntry? {
        if let cached = cachedEntry(for: key) {
            return cached
        }
        guard let generated = generator.generate(glyph: key.glyph, font: font, maxCellSide: pageSize) else { return nil }
        return store(
            generated: GeneratedGlyph(bitmap: generated.bitmap, metrics: generated.metrics),
            for: key
        )
    }

    /// Cache-only lookup (no generation). Cheap; safe to call every frame.
    func cachedEntry(for key: WPEMSDFGlyphKey) -> WPEMSDFAtlasEntry? {
        if let cached = entries[key], let page = page(for: cached.page) {
            touch(page)
            return cached
        }
        return nil
    }

    /// Non-blocking request: returns `.ready` if cached, `.skip` for known
    /// no-outline/failed glyphs, otherwise schedules deduplicated background
    /// generation and returns `.pending` so the caller falls back this frame.
    func requestEntry(
        for key: WPEMSDFGlyphKey,
        generator: WPEMSDFGlyphGenerator,
        font: CTFont
    ) -> GlyphRequest {
        if let cached = cachedEntry(for: key) {
            return .ready(cached)
        }
        if skipped.contains(key) {
            return .skip
        }
        guard !pending.contains(key) else { return .pending }
        pending.insert(key)
        let request = GlyphGenerationRequest(
            key: key,
            generator: generator,
            font: font,
            maxCellSide: pageSize
        )
        Task.detached(priority: .utility) { [request, weak self] in
            let generated = request.generator.generate(
                glyph: request.key.glyph,
                font: request.font,
                maxCellSide: request.maxCellSide
            ).map { GeneratedGlyph(bitmap: $0.bitmap, metrics: $0.metrics) }
            await MainActor.run { [weak self] in
                self?.completeGeneration(generated, for: request.key)
            }
        }
        return .pending
    }

    private func completeGeneration(_ generated: GeneratedGlyph?, for key: WPEMSDFGlyphKey) {
        defer { pending.remove(key) }
        guard entries[key] == nil else { return }
        // No outline (whitespace / unsupported glyph) is a PERMANENT skip — never
        // re-schedule it and never draw it as a 0.5 box.
        guard let generated else {
            skipped.insert(key)
            return
        }
        if store(generated: generated, for: key) != nil {
            storeFailures[key] = nil
            return
        }
        // Store failed (transient, e.g. texture allocation under pressure): retry
        // a bounded number of times, then give up so we don't regenerate forever.
        let failures = (storeFailures[key] ?? 0) + 1
        if failures >= 3 {
            storeFailures[key] = nil
            skipped.insert(key)
        } else {
            storeFailures[key] = failures
        }
    }

    @discardableResult
    private func store(generated: GeneratedGlyph, for key: WPEMSDFGlyphKey) -> WPEMSDFAtlasEntry? {
        let bitmap = generated.bitmap
        guard bitmap.width <= pageSize, bitmap.height <= pageSize else { return nil }
        guard let allocation = allocate(width: bitmap.width, height: bitmap.height) else { return nil }
        guard let texture = allocation.page.ensureTexture(device: device) else {
            if allocation.page.keys.isEmpty {
                allocation.page.reset()
            }
            return nil
        }

        let bytes = bitmap.rgba8Data()
        let region = MTLRegionMake2D(allocation.x, allocation.y, bitmap.width, bitmap.height)
        bytes.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            texture.replace(
                region: region,
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: bitmap.width * 4
            )
        }

        let inverseSize = 1.0 / CGFloat(pageSize)
        let pixelRect = CGRect(
            x: CGFloat(allocation.x),
            y: CGFloat(allocation.y),
            width: CGFloat(bitmap.width),
            height: CGFloat(bitmap.height)
        )
        let entry = WPEMSDFAtlasEntry(
            page: allocation.page.id,
            uvRect: CGRect(
                x: CGFloat(allocation.x) * inverseSize,
                y: CGFloat(allocation.y) * inverseSize,
                width: CGFloat(bitmap.width) * inverseSize,
                height: CGFloat(bitmap.height) * inverseSize
            ),
            pixelRect: pixelRect,
            metrics: generated.metrics
        )
        allocation.page.keys.insert(key)
        entries[key] = entry
        touch(allocation.page)
        return entry
    }

    func texture(page id: Int) -> MTLTexture? {
        guard let page = page(for: id), let texture = page.texture else { return nil }
        touch(page)
        return texture
    }

    func livePages() -> [(page: Int, texture: MTLTexture)] {
        pages.compactMap { page in
            guard let texture = page.texture else { return nil }
            return (page: page.id, texture: texture)
        }
    }

    private func allocate(width: Int, height: Int) -> (page: Page, x: Int, y: Int)? {
        for page in pages.sorted(by: { $0.id < $1.id }) {
            if let origin = page.allocate(width: width, height: height) {
                return (page: page, x: origin.x, y: origin.y)
            }
        }

        if pages.count < maxPages {
            let page = Page(id: pages.count, size: pageSize)
            pages.append(page)
            guard let origin = page.allocate(width: width, height: height) else { return nil }
            return (page: page, x: origin.x, y: origin.y)
        }

        guard let page = leastRecentlyUsedPage() else { return nil }
        evict(page)
        guard let origin = page.allocate(width: width, height: height) else { return nil }
        return (page: page, x: origin.x, y: origin.y)
    }

    private func evict(_ page: Page) {
        for key in page.keys {
            entries[key] = nil
        }
        page.reset()
    }

    private func touch(_ page: Page) {
        clock &+= 1
        page.lastUsed = clock
    }

    private func leastRecentlyUsedPage() -> Page? {
        pages.min { lhs, rhs in
            if lhs.lastUsed == rhs.lastUsed {
                return lhs.id < rhs.id
            }
            return lhs.lastUsed < rhs.lastUsed
        }
    }

    private func page(for id: Int) -> Page? {
        pages.first { $0.id == id }
    }
}
#endif
