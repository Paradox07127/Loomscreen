#if !LITE_BUILD
import SwiftUI
import AppKit
import ImageIO

/// Square (1:1) preview tile for a Wallpaper Engine project.
///
/// Renders into a CALayer with `contentsGravity = .resizeAspectFill` so
/// previews of any source aspect (square — WPE editor's 512×512 default,
/// 16:9 wallpapers, 9:16 vertical, etc.) fill the slot without dead bars.
/// GIF animation is preserved by stepping `CGImageSource` frames manually
/// (NSImageView's built-in `.animates` cannot pair with `.aspectFill`).
/// Whether the preview auto-plays its animation or only plays while hovered.
/// `.autoPlay` is the back-compatible default for single-item detail surfaces;
/// grid / list call sites pass `.hoverToPlay` to match the macOS Photos idiom.
enum WPEPreviewPlaybackMode {
    case autoPlay
    case hoverToPlay
}

struct WPEPreviewView: View {
    let imageURL: URL?
    let securityScopedBookmarkData: Data?
    let playbackMode: WPEPreviewPlaybackMode

    @State private var loadAttempt: Int = 0
    @State private var loadFailed: Bool = false
    @State private var isHovering: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        imageURL: URL?,
        securityScopedBookmarkData: Data? = nil,
        playbackMode: WPEPreviewPlaybackMode = .autoPlay
    ) {
        self.imageURL = imageURL
        self.securityScopedBookmarkData = securityScopedBookmarkData
        self.playbackMode = playbackMode
    }

    /// In `.autoPlay` the animation always runs; in `.hoverToPlay` it runs only
    /// while hovered. Reduce Motion forces the poster frame in every mode.
    private var shouldAnimate: Bool {
        guard !reduceMotion else { return false }
        switch playbackMode {
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
        .aspectRatio(1, contentMode: .fit)
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

    /// Non-blocking corner chip so the failed-load state is visible without
    /// hiding whatever fragment of the preview did manage to render. Modeled
    /// as a tap-gesture'd view (not a `Button`) because the parent grid cell
    /// is itself a `Button` and AppKit-bridged buttons nested inside another
    /// SwiftUI button race for hit-tests + confuse VoiceOver focus.
    @ViewBuilder
    private var retryBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
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

// MARK: - Aspect-fill bridge

/// In-memory cache of raw image bytes keyed by URL. WorkshopGallery renders
/// dozens of previews in a single grid; pulling the same Wallpaper Engine
/// thumbnail off disk N times per scroll was the root cause of the audit
/// P0-D main-thread stall. `NSCache` evicts under memory pressure on its own.
private enum WPEPreviewDataCache {
    // NSCache is thread-safe internally; the unsafe annotation here just
    // suppresses the Swift 6 Sendable diagnostic since NSCache isn't formally
    // marked Sendable.
    nonisolated(unsafe) static let shared: NSCache<NSURL, NSData> = {
        let cache = NSCache<NSURL, NSData>()
        cache.countLimit = 256
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()
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

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func updateNSView(_ nsView: AspectFillAnimatedImageView, context: Context) {
        // Apply the desired playback state every pass so a hover toggle alone
        // (with an unchanged URL) starts / freezes the animation.
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
            // Defer the binding callback to the next runloop tick — this
            // updateNSView runs inside SwiftUI's view-update pass, so a
            // synchronous `onLoadResult(ok)` would mutate the parent's
            // `loadFailed` @State while the parent is still rendering and
            // trip "Modifying state during view update" undefined-behavior
            // warnings. The async path below is already deferred via Task.
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

    /// Reads the image off the main thread.
    private static func loadData(url: URL, bookmarkData: Data?) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            var scopedURL: URL?
            if let bookmarkData {
                var isStale = false
                scopedURL = try? URL(
                    resolvingBookmarkData: bookmarkData,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
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

/// CALayer-backed image view with aspect-fill semantics + manual GIF/APNG
/// frame stepping. We use this instead of `NSImageView` because the latter
/// only offers fit-style scaling — we need fill-with-crop ("Apple Photos
/// thumbnail mode") so square 512×512 WPE previews don't render with
/// horizontal letterbox bars.
private final class AspectFillAnimatedImageView: NSView {
    private var imageSource: CGImageSource?
    private var frameCount: Int = 0
    private var currentFrameIndex: Int = 0
    private var frameDelays: [TimeInterval] = []
    private var animationTimer: Timer?
    /// Whether playback is currently desired. Toggled by `setAnimating` so a
    /// hover-driven host can freeze the loop on the poster frame without
    /// reloading the image. Defaults to `true` for auto-play callers.
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

    // No deinit-side timer invalidation: every Timer is captured weakly
    // (closures use `[weak self]`), and `setImage` / `clearImage` invalidate
    // the prior timer before scheduling new work or tearing down. Swift 6
    // disallows touching non-Sendable Timer from a nonisolated deinit anyway.

    /// Returns `true` on success, `false` on decode failure.
    @discardableResult
    func setImage(data: Data) -> Bool {
        animationTimer?.invalidate()
        animationTimer = nil
        currentFrameIndex = 0
        frameCount = 0
        frameDelays = []

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            layer?.contents = nil
            imageSource = nil
            return false
        }

        let count = CGImageSourceGetCount(source)
        guard count > 0,
              let firstFrame = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            layer?.contents = nil
            imageSource = nil
            return false
        }

        imageSource = source
        frameCount = count
        layer?.contents = firstFrame

        if count > 1 {
            frameDelays = Self.readFrameDelays(from: source, frameCount: count)
            if wantsAnimation { scheduleNextFrame() }
        }
        return true
    }

    /// Starts or freezes playback without reloading the image. Freezing
    /// restores the poster (frame 0) so a hovered-out tile reads as static.
    func setAnimating(_ animate: Bool) {
        guard wantsAnimation != animate else {
            // Already in the requested state — but recover if a multi-frame
            // image was installed while frozen and now wants to animate.
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
               let poster = CGImageSourceCreateImageAtIndex(source, 0, nil) {
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
        if let next = CGImageSourceCreateImageAtIndex(source, currentFrameIndex, nil) {
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
                    return max(unclamped, 0.02)
                }
                if let delay = (gif[kCGImagePropertyGIFDelayTime as String] as? NSNumber)?.doubleValue, delay > 0 {
                    return max(delay, 0.02)
                }
            }
            if let png = props[kCGImagePropertyPNGDictionary as String] as? [String: Any] {
                if let delay = (png[kCGImagePropertyAPNGUnclampedDelayTime as String] as? NSNumber)?.doubleValue, delay > 0 {
                    return max(delay, 0.02)
                }
                if let delay = (png[kCGImagePropertyAPNGDelayTime as String] as? NSNumber)?.doubleValue, delay > 0 {
                    return max(delay, 0.02)
                }
            }
            return 0.1
        }
    }
}
#endif
