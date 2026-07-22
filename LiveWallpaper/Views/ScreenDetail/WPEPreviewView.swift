#if !LITE_BUILD
import SwiftUI
import AppKit
import ImageIO
import LiveWallpaperCore

/// `.autoPlay` is the back-compatible default; grid / list call sites pass `.hoverToPlay`.
enum WPEPreviewPlaybackMode {
    case staticPoster
    case autoPlay
    case hoverToPlay
}

/// CALayer-backed with manual `CGImageSource` frame stepping — NSImageView
/// can't pair its built-in `.animates` with aspect-fill scaling.
struct WPEPreviewView: View {
    let imageURL: URL?
    let securityScopedBookmarkData: Data?
    let playbackMode: WPEPreviewPlaybackMode
    /// `1` (default) yields the square gallery / history tile; `nil` lets the
    /// preview fill the parent's bounds (16:9 inspector cards) and aspect-fill crop.
    let aspectRatio: CGFloat?

    @State private var loadAttempt: Int = 0
    @State private var loadFailed: Bool = false
    @State private var isHovering: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        imageURL: URL?,
        securityScopedBookmarkData: Data? = nil,
        playbackMode: WPEPreviewPlaybackMode = .autoPlay,
        aspectRatio: CGFloat? = 1
    ) {
        self.imageURL = imageURL
        self.securityScopedBookmarkData = securityScopedBookmarkData
        self.playbackMode = playbackMode
        self.aspectRatio = aspectRatio
    }

    private var shouldAnimate: Bool {
        guard !reduceMotion else { return false }
        switch playbackMode {
        case .staticPoster: return false
        case .autoPlay: return true
        case .hoverToPlay: return isHovering
        }
    }

    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor).opacity(0.5)
            if imageURL == nil {
                Image(systemName: "cube.transparent")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
            } else {
                AspectFillImage(
                    imageURL: imageURL,
                    securityScopedBookmarkData: securityScopedBookmarkData,
                    loadAttempt: loadAttempt,
                    shouldAnimate: shouldAnimate,
                    onLoadResult: { success in
                        loadFailed = !success
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .modifier(OptionalAspectRatio(aspectRatio))
        .clipped()
        .onHover { hovering in
            if playbackMode == .hoverToPlay { isHovering = hovering }
        }
        .overlay(alignment: .bottomTrailing) {
            if loadFailed {
                retryBadge
                    .padding(6)
            }
        }
        .onChange(of: imageURL) { _, _ in
            loadFailed = false
        }
    }

    /// Tap-gesture'd view, not a `Button`: the parent grid cell is itself a `Button`, and AppKit-bridged buttons nested inside another SwiftUI button race for hit-tests + confuse VoiceOver focus.
    @ViewBuilder
    private var retryBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DesignTokens.Colors.Status.warning)
            Image(systemName: "arrow.clockwise")
        }
        .font(.system(size: 10, weight: .semibold))
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .adaptiveGlassSurface(.capsule, interactive: true)
        .contentShape(Capsule())
        .onTapGesture {
            retryLoad()
        }
        .help(Text(
            "Preview unavailable. Tap to retry.",
            comment: "Tooltip on the WPE preview retry badge that surfaces when the preview image failed to load."
        ))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(
            "Retry preview",
            comment: "A11y label for the corner badge that retries a failed preview load."
        ))
        .accessibilityHint(Text(
            "Re-attempt to load this preview",
            comment: "A11y hint describing what the retry preview badge does."
        ))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { retryLoad() }
    }

    private func retryLoad() {
        loadFailed = false
        loadAttempt &+= 1
    }
}

/// The ratio is constant per call site, so the `if`/`else` never flips at runtime and the CALayer-backed image view keeps a stable identity.
private struct OptionalAspectRatio: ViewModifier {
    let ratio: CGFloat?

    init(_ ratio: CGFloat?) { self.ratio = ratio }

    @ViewBuilder
    func body(content: Content) -> some View {
        if let ratio {
            content.aspectRatio(ratio, contentMode: .fit)
        } else {
            content
        }
    }
}

// MARK: - Aspect-fill bridge

/// In-memory cache of raw image bytes keyed by URL.
private enum WPEPreviewDataCache {
    // NSCache is thread-safe internally; `nonisolated(unsafe)` just suppresses
    // the Swift 6 Sendable diagnostic since NSCache isn't formally Sendable.
    nonisolated(unsafe) static let shared: NSCache<NSURL, NSData> = {
        let cache = NSCache<NSURL, NSData>()
        cache.countLimit = 256
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()
}

private enum WPEPreviewImageDecodeBudget {
    static let maxFrameCount = 120
    static let maxDecodedPixelBytes = 96 * 1024 * 1024
    static let minFrameDelay: TimeInterval = 0.033
    nonisolated(unsafe) static let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    nonisolated(unsafe) static let frameOptions = [
        kCGImageSourceShouldCache: false,
        kCGImageSourceShouldCacheImmediately: false
    ] as CFDictionary

    static func allowsAnimation(width: Int, height: Int, frameCount: Int) -> Bool {
        frameCount <= maxFrameCount && isWithinPixelBudget(width: width, height: height, frameCount: frameCount)
    }

    static func isWithinPixelBudget(width: Int, height: Int, frameCount: Int) -> Bool {
        guard width > 0, height > 0, frameCount > 0 else { return false }
        let w = UInt64(width)
        let h = UInt64(height)
        let n = UInt64(frameCount)
        guard w <= UInt64.max / h else { return false }
        let pixelsPerFrame = w * h
        guard pixelsPerFrame <= UInt64.max / n else { return false }
        let totalPixels = pixelsPerFrame * n
        guard totalPixels <= UInt64.max / 4 else { return false }
        return totalPixels * 4 <= UInt64(maxDecodedPixelBytes)
    }

    static func imageDimensions(from source: CGImageSource, index: Int) -> (width: Int, height: Int)? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any],
              let width = (props[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue,
              let height = (props[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue else {
            return nil
        }
        return (width, height)
    }
}

private struct AspectFillImage: NSViewRepresentable {
    let imageURL: URL?
    let securityScopedBookmarkData: Data?
    let loadAttempt: Int
    let shouldAnimate: Bool
    let onLoadResult: (Bool) -> Void

    func makeNSView(context: Context) -> AspectFillAnimatedImageView {
        AspectFillAnimatedImageView()
    }

    static func dismantleNSView(_ nsView: AspectFillAnimatedImageView, coordinator: Coordinator) {
        coordinator.cancelInflight()
        coordinator.reset()
        nsView.clearImage()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func updateNSView(_ nsView: AspectFillAnimatedImageView, context: Context) {
        nsView.setAnimating(shouldAnimate)

        guard let url = imageURL else {
            context.coordinator.cancelInflight()
            context.coordinator.reset()
            nsView.clearImage()
            return
        }

        if context.coordinator.currentURL == url,
           context.coordinator.lastAttempt == loadAttempt {
            return
        }

        context.coordinator.currentURL = url
        context.coordinator.lastAttempt = loadAttempt
        context.coordinator.cancelInflight()

        if let cached = WPEPreviewDataCache.shared.object(forKey: url as NSURL) {
            let ok = nsView.setImage(data: cached as Data)
            let resultHandler = onLoadResult
            Task { @MainActor in resultHandler(ok) }
            return
        }

        let bookmarkData = securityScopedBookmarkData
        let coordinator = context.coordinator
        let resultHandler = onLoadResult
        let task = Task { @MainActor in
            let data = await Self.loadData(url: url, bookmarkData: bookmarkData)
            guard !Task.isCancelled, coordinator.currentURL == url else { return }
            if let data {
                WPEPreviewDataCache.shared.setObject(data as NSData, forKey: url as NSURL, cost: data.count)
                let ok = nsView.setImage(data: data)
                resultHandler(ok)
            } else {
                nsView.clearImage()
                resultHandler(false)
            }
        }
        coordinator.inflightTask = task
    }

    private static func loadData(url: URL, bookmarkData: Data?) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            var scopedURL: URL?
            if let bookmarkData {
                scopedURL = try? SecurityScopedBookmarkResolver.shared
                    .resolve(bookmarkData, target: .transient).get().url
            }
            let didStart = scopedURL?.startAccessingSecurityScopedResource() ?? false
            defer { if didStart { scopedURL?.stopAccessingSecurityScopedResource() } }
            return try? Data(contentsOf: url)
        }.value
    }

    @MainActor
    final class Coordinator {
        var currentURL: URL?
        var lastAttempt: Int = 0
        var inflightTask: Task<Void, Never>?

        func reset() {
            currentURL = nil
            lastAttempt = 0
        }

        func cancelInflight() {
            inflightTask?.cancel()
            inflightTask = nil
        }
    }
}

/// Used instead of `NSImageView` because the latter only offers fit-style scaling — we need fill-with-crop so square 512×512 WPE previews don't render with horizontal letterbox bars.
private final class AspectFillAnimatedImageView: NSView {
    private var imageSource: CGImageSource?
    private var frameCount: Int = 0
    private var currentFrameIndex: Int = 0
    private var frameDelays: [TimeInterval] = []
    private var animationTimer: Timer?
    /// Toggled by `setAnimating` so a hover-driven host can freeze the loop on
    /// the poster frame without reloading the image.
    private var wantsAnimation = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let imageLayer = CALayer()
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        imageLayer.frame = bounds
        imageLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer = imageLayer
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize { .zero }


    /// Returns `true` on success, `false` on decode failure.
    @discardableResult
    func setImage(data: Data) -> Bool {
        animationTimer?.invalidate()
        animationTimer = nil
        currentFrameIndex = 0
        frameCount = 0
        frameDelays = []

        guard let source = CGImageSourceCreateWithData(data as CFData, WPEPreviewImageDecodeBudget.sourceOptions) else {
            layer?.contents = nil
            imageSource = nil
            return false
        }

        let count = CGImageSourceGetCount(source)
        guard count > 0,
              let dimensions = WPEPreviewImageDecodeBudget.imageDimensions(from: source, index: 0),
              WPEPreviewImageDecodeBudget.isWithinPixelBudget(width: dimensions.width, height: dimensions.height, frameCount: 1),
              let firstFrame = CGImageSourceCreateImageAtIndex(source, 0, WPEPreviewImageDecodeBudget.frameOptions) else {
            layer?.contents = nil
            imageSource = nil
            return false
        }

        layer?.contents = firstFrame

        if count > 1,
           WPEPreviewImageDecodeBudget.allowsAnimation(
               width: dimensions.width,
               height: dimensions.height,
               frameCount: count
           ) {
            imageSource = source
            frameCount = count
            frameDelays = Self.readFrameDelays(from: source, frameCount: count)
            if wantsAnimation { scheduleNextFrame() }
        } else {
            imageSource = nil
            frameCount = 1
        }
        return true
    }

    /// Starts or freezes playback without reloading the image. Freezing
    /// restores the poster (frame 0) so a hovered-out tile reads as static.
    func setAnimating(_ animate: Bool) {
        guard wantsAnimation != animate else {
            if animate, frameCount > 1, animationTimer == nil { scheduleNextFrame() }
            return
        }
        wantsAnimation = animate
        if animate {
            if frameCount > 1, animationTimer == nil { scheduleNextFrame() }
        } else {
            animationTimer?.invalidate()
            animationTimer = nil
            if frameCount > 1, currentFrameIndex != 0,
               let source = imageSource,
               let poster = CGImageSourceCreateImageAtIndex(source, 0, WPEPreviewImageDecodeBudget.frameOptions) {
                currentFrameIndex = 0
                layer?.contents = poster
            }
        }
    }

    func clearImage() {
        animationTimer?.invalidate()
        animationTimer = nil
        imageSource = nil
        frameCount = 0
        currentFrameIndex = 0
        frameDelays = []
        layer?.contents = nil
    }

    private func scheduleNextFrame() {
        guard wantsAnimation, frameCount > 1, imageSource != nil else { return }
        let delay = frameDelays.indices.contains(currentFrameIndex)
            ? frameDelays[currentFrameIndex]
            : 0.1
        animationTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.advanceFrame()
            }
        }
    }

    private func advanceFrame() {
        guard let source = imageSource, frameCount > 1 else { return }
        currentFrameIndex = (currentFrameIndex + 1) % frameCount
        if let next = CGImageSourceCreateImageAtIndex(source, currentFrameIndex, WPEPreviewImageDecodeBudget.frameOptions) {
            layer?.contents = next
        }
        scheduleNextFrame()
    }

    private static func readFrameDelays(from source: CGImageSource, frameCount: Int) -> [TimeInterval] {
        (0..<frameCount).map { idx in
            guard let props = CGImageSourceCopyPropertiesAtIndex(source, idx, nil) as? [String: Any] else {
                return 0.1
            }
            if let gif = props[kCGImagePropertyGIFDictionary as String] as? [String: Any] {
                if let unclamped = (gif[kCGImagePropertyGIFUnclampedDelayTime as String] as? NSNumber)?.doubleValue, unclamped > 0 {
                    return max(unclamped, WPEPreviewImageDecodeBudget.minFrameDelay)
                }
                if let delay = (gif[kCGImagePropertyGIFDelayTime as String] as? NSNumber)?.doubleValue, delay > 0 {
                    return max(delay, WPEPreviewImageDecodeBudget.minFrameDelay)
                }
            }
            if let png = props[kCGImagePropertyPNGDictionary as String] as? [String: Any] {
                if let delay = (png[kCGImagePropertyAPNGUnclampedDelayTime as String] as? NSNumber)?.doubleValue, delay > 0 {
                    return max(delay, WPEPreviewImageDecodeBudget.minFrameDelay)
                }
                if let delay = (png[kCGImagePropertyAPNGDelayTime as String] as? NSNumber)?.doubleValue, delay > 0 {
                    return max(delay, WPEPreviewImageDecodeBudget.minFrameDelay)
                }
            }
            return 0.1
        }
    }
}
#endif
