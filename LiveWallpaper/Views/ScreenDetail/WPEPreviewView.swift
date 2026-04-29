import SwiftUI
import AppKit

/// 16:9 preview tile for a Wallpaper Engine project. Wraps `NSImageView` so
/// `preview.gif` plays its frames natively; static jpg/png are also rendered.
/// Eagerly loads bytes inside the caller's security-scoped bookmark so the
/// image survives sandbox restrictions (`NSImage(byReferencing:)` is lazy
/// and would fail after scope expiration).
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
                AnimatedImage(
                    imageURL: imageURL,
                    securityScopedBookmarkData: securityScopedBookmarkData,
                    loadAttempt: loadAttempt,
                    onLoadResult: { success in
                        loadFailed = !success
                    }
                )

                if loadFailed {
                    retryOverlay
                }
            }
        }
        .aspectRatio(16/9, contentMode: .fit)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Color.black.opacity(0.12), radius: 6, y: 2)
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

private struct AnimatedImage: NSViewRepresentable {
    let imageURL: URL?
    let securityScopedBookmarkData: Data?
    let loadAttempt: Int
    let onLoadResult: (Bool) -> Void

    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = true
        // Layer-back so SwiftUI's clipShape reliably clips animated-GIF frames
        // drawn through CoreAnimation. Without this, AppKit-side layers can
        // paint past the SwiftUI clip during animated transitions.
        imageView.wantsLayer = true
        imageView.layer?.masksToBounds = true
        return imageView
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        guard let url = imageURL else {
            context.coordinator.reset()
            nsView.image = nil
            return
        }

        // Re-evaluate whenever URL OR loadAttempt changes; otherwise skip.
        if context.coordinator.currentURL == url,
           context.coordinator.lastAttempt == loadAttempt {
            return
        }

        context.coordinator.currentURL = url
        context.coordinator.lastAttempt = loadAttempt

        let image = loadImage(from: url)
        nsView.image = image
        // Defer state mutation off the current render frame to avoid
        // "modifying state during view update" warnings.
        DispatchQueue.main.async {
            onLoadResult(image != nil)
        }
    }

    private func loadImage(from url: URL) -> NSImage? {
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

        guard let data = try? Data(contentsOf: url) else { return nil }
        return NSImage(data: data)
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
