import SwiftUI
import LiveWallpaperCore

/// Renders a 36×36 rounded thumbnail for a playlist bookmark.
///
/// First-frame poster delegated to `WallpaperThumbnailService` (already
/// in-flight-deduplicated + NSCache-backed). Until the image resolves the
/// view shows a film placeholder so the layout doesn't reflow on load.
struct AsyncRowThumbnail: View {
    let bookmark: Data
    var size: CGFloat = 36
    var cornerRadius: CGFloat = 6

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .transition(.opacity)
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .animation(.easeOut(duration: 0.18), value: image != nil)
        .task(id: bookmark) {
            await loadThumbnail()
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.primary.opacity(0.08))
            .overlay(
                Image(systemName: "film")
                    .font(.system(size: size * 0.4, weight: .regular))
                    .foregroundStyle(.secondary)
            )
    }

    private func loadThumbnail() async {
        if let cached = WallpaperThumbnailService.shared.cachedThumbnail(forKey: cacheKey) {
            image = cached
            return
        }
        let resolverResult = SecurityScopedBookmarkResolver.shared.resolve(
            bookmark,
            target: .transient
        )
        guard case .success(let resolved) = resolverResult else { return }
        let loaded = await WallpaperThumbnailService.shared.videoPosterImage(
            for: resolved.url,
            cacheKey: cacheKey
        )
        guard !Task.isCancelled else { return }
        image = loaded
    }

    private var cacheKey: String {
        Self.cacheKey(for: bookmark)
    }

    /// Stable key used by the row + by external invalidate paths
    /// (e.g. removing a playlist entry). Kept centralized so callers
    /// don't drift out of sync with the row's own derivation.
    static func cacheKey(for bookmark: Data) -> String {
        "playlist-row-thumb::\(bookmark.base64EncodedString())"
    }
}
