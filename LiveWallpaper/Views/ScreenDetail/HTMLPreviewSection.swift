import AppKit
import LiveWallpaperCore
import LiveWallpaperSharedUI
import SwiftUI

/// Inspector-side preview for HTML wallpapers. Mirrors the layout of
/// `VideoPreviewSection`: a 16:9 card with the latest snapshot, a refresh
/// button to retake the snapshot, and a fall-through skeleton while loading.
///
/// Snapshots come from `WallpaperThumbnailService` so the inspector and
/// the bookmark grid share the same render pass + NSCache entry per source.
struct HTMLPreviewSection: View {
    let source: HTMLSource?

    @State private var snapshot: NSImage?
    @State private var isLoading = false
    @State private var loadFailed = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            cardBody
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: Color.black.opacity(0.15), radius: 10, x: 0, y: 4)

            refreshButton
                .padding(10)
        }
        .aspectRatio(16/9, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .onChange(of: cacheKey) { _, _ in
            snapshot = nil
            loadFailed = false
            startLoadIfNeeded()
        }
        .onAppear { startLoadIfNeeded() }
    }

    @ViewBuilder
    private var cardBody: some View {
        if let snapshot {
            Image(nsImage: snapshot)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
        } else if isLoading {
            ZStack {
                Rectangle().fill(.regularMaterial)
                LiquidGlassSpinner()
            }
        } else if loadFailed {
            placeholder(systemImage: "exclamationmark.triangle", title: "Preview unavailable")
        } else if source != nil {
            placeholder(systemImage: "globe", title: "Tap refresh to capture preview")
        } else {
            placeholder(systemImage: "globe", title: "No HTML source")
        }
    }

    private func placeholder(systemImage: String, title: LocalizedStringKey) -> some View {
        ZStack {
            Rectangle().fill(Color(NSColor.windowBackgroundColor))
            VStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var refreshButton: some View {
        Button {
            guard let key = cacheKey else { return }
            WallpaperThumbnailService.shared.invalidate(cacheKey: key)
            snapshot = nil
            loadFailed = false
            startLoadIfNeeded(force: true)
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .semibold))
                .padding(7)
                .background(.thinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .opacity(source == nil ? 0 : 1)
        .help(Text("Refresh HTML snapshot"))
        .accessibilityLabel(Text("Refresh HTML preview"))
    }

    // MARK: - Loading

    private var cacheKey: String? {
        source.map(HTMLPreviewKey.key(for:))
    }

    private func startLoadIfNeeded(force: Bool = false) {
        guard let source, let key = cacheKey else { return }
        if !force, let cached = WallpaperThumbnailService.shared.cachedThumbnail(forKey: key) {
            snapshot = cached
            return
        }
        guard !isLoading else { return }
        isLoading = true
        loadFailed = false
        Task { @MainActor in
            let image = await HTMLPreviewKey.fetchSnapshot(for: source, cacheKey: key)
            isLoading = false
            if let image {
                snapshot = image
            } else {
                loadFailed = true
            }
        }
    }
}

/// Helper that resolves an `HTMLSource` into a `(URL, cacheKey)` pair that
/// `WallpaperThumbnailService` can snapshot. Folder sources point at their
/// resolved index.html; URL sources use the URL directly. File/folder
/// bookmark resolution opens a security scope for the duration of the call.
enum HTMLPreviewKey {
    static func key(for source: HTMLSource) -> String {
        switch source {
        case .url(let url):
            return "html.url::" + url.absoluteString
        case .file(let bookmark):
            return "html.file::" + String(bookmark.base64EncodedString().prefix(40))
        case .folder(let bookmark, let index):
            return "html.folder::" + String(bookmark.base64EncodedString().prefix(40)) + "::" + index
        case .inline(let html):
            // Inline HTML strings rarely change in practice; hashing keeps
            // the cache key short while still invalidating when the user
            // edits the markup.
            return "html.inline::" + String(html.hashValue)
        }
    }

    @MainActor
    static func fetchSnapshot(
        for source: HTMLSource,
        cacheKey: String
    ) async -> NSImage? {
        switch source {
        case .url(let url):
            return await WallpaperThumbnailService.shared.htmlSnapshotImage(
                for: url,
                cacheKey: cacheKey
            )
        case .file(let bookmarkData):
            return await snapshotFromBookmark(
                bookmarkData: bookmarkData,
                appendingIndex: nil,
                cacheKey: cacheKey
            )
        case .folder(let bookmarkData, let indexFileName):
            return await snapshotFromBookmark(
                bookmarkData: bookmarkData,
                appendingIndex: indexFileName,
                cacheKey: cacheKey
            )
        case .inline:
            // Inline HTML cannot be loaded by WKWebView from a URL without
            // first writing it to disk; skip preview for now rather than
            // shipping a temp-file dance with its own cleanup story.
            return nil
        }
    }

    @MainActor
    private static func snapshotFromBookmark(
        bookmarkData: Data,
        appendingIndex: String?,
        cacheKey: String
    ) async -> NSImage? {
        guard case .success(let resolved) = SecurityScopedBookmarkResolver.shared.resolve(
            bookmarkData,
            target: .transient
        ) else { return nil }
        let url = resolved.url
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        let target: URL
        if let index = appendingIndex {
            target = url.appendingPathComponent(index)
            guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        } else {
            target = url
        }
        return await WallpaperThumbnailService.shared.htmlSnapshotImage(
            for: target,
            cacheKey: cacheKey
        )
    }
}
