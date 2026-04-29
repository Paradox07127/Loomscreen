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
                    securityScopedBookmarkData: securityScopedBookmarkData
                )
            }
        }
        .aspectRatio(16/9, contentMode: .fill)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Color.black.opacity(0.12), radius: 6, y: 2)
    }
}

private struct AnimatedImage: NSViewRepresentable {
    let imageURL: URL?
    let securityScopedBookmarkData: Data?

    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = true
        return imageView
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        guard let url = imageURL else {
            context.coordinator.currentURL = nil
            nsView.image = nil
            return
        }
        guard context.coordinator.currentURL != url else { return }
        context.coordinator.currentURL = url
        nsView.image = loadImage(from: url)
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
    }
}
