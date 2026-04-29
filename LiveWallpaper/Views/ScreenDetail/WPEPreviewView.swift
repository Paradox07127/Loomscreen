import SwiftUI
import AppKit
import ImageIO

/// 16:9 preview tile for a Wallpaper Engine project.
///
/// Renders into a CALayer with `contentsGravity = .resizeAspectFill` so
/// previews of any source aspect (square — WPE editor's 512×512 default,
/// 16:9 wallpapers, 9:16 vertical, etc.) fill the slot without dead bars.
/// GIF animation is preserved by stepping `CGImageSource` frames manually
/// (NSImageView's built-in `.animates` cannot pair with `.aspectFill`).
struct WPEPreviewView: View {
    let imageURL: URL?
    let securityScopedBookmarkData: Data?

    @State private var loadAttempt: Int = 0
    @State private var loadFailed: Bool = false

    init(imageURL: URL?, securityScopedBookmarkData: Data? = nil) {
        self.imageURL = imageURL
        self.securityScopedBookmarkData = securityScopedBookmarkData
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
                    onLoadResult: { success in
                        loadFailed = !success
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if loadFailed {
                    retryOverlay
                }
            }
        }
        // 1:1 matches Wallpaper Engine editor's "Generate preview" default
        // (512×512). Combined with `.resizeAspectFill` inside the layer, the
        // image fully covers the slot — square sources draw flush, 16:9
        // sources crop top/bottom equally, vertical sources crop sides.
        //
        // Clipping + shadow are intentionally delegated to the parent so
        // cards can apply uneven (top-only) corner radii without double-clip.
        .aspectRatio(1, contentMode: .fit)
        .clipped()
        .onChange(of: imageURL) { _, _ in
            loadFailed = false
        }
    }

    @ViewBuilder
    private var retryOverlay: some View {
        VStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.orange)
            Text("Preview unavailable")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                loadFailed = false
                loadAttempt &+= 1
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .accessibilityHint("Re-attempt to load this preview")
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Aspect-fill bridge

private struct AspectFillImage: NSViewRepresentable {
    let imageURL: URL?
    let securityScopedBookmarkData: Data?
    let loadAttempt: Int
    let onLoadResult: (Bool) -> Void

    func makeNSView(context: Context) -> AspectFillAnimatedImageView {
        AspectFillAnimatedImageView()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func updateNSView(_ nsView: AspectFillAnimatedImageView, context: Context) {
        guard let url = imageURL else {
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

        let success = loadInto(view: nsView, url: url)
        DispatchQueue.main.async {
            onLoadResult(success)
        }
    }

    private func loadInto(view: AspectFillAnimatedImageView, url: URL) -> Bool {
        var scopedURL: URL?
        if let securityScopedBookmarkData {
            var isStale = false
            scopedURL = try? URL(
                resolvingBookmarkData: securityScopedBookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        }

        let didStart = scopedURL?.startAccessingSecurityScopedResource() ?? false
        defer { if didStart { scopedURL?.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else {
            view.clearImage()
            return false
        }
        return view.setImage(data: data)
    }

    final class Coordinator {
        var currentURL: URL?
        var lastAttempt: Int = 0

        func reset() {
            currentURL = nil
            lastAttempt = 0
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
            scheduleNextFrame()
        }
        return true
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
        guard frameCount > 1, imageSource != nil else { return }
        let delay = frameDelays.indices.contains(currentFrameIndex)
            ? frameDelays[currentFrameIndex]
            : 0.1
        animationTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.advanceFrame()
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
            // GIF
            if let gif = props[kCGImagePropertyGIFDictionary as String] as? [String: Any] {
                if let unclamped = (gif[kCGImagePropertyGIFUnclampedDelayTime as String] as? NSNumber)?.doubleValue, unclamped > 0 {
                    return max(unclamped, 0.02)
                }
                if let delay = (gif[kCGImagePropertyGIFDelayTime as String] as? NSNumber)?.doubleValue, delay > 0 {
                    return max(delay, 0.02)
                }
            }
            // APNG
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
