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
///
/// Wallpaper Engine *web* projects are different: they ship a `preview.gif`
/// (or jpg/png) alongside `project.json`, so when `wpePreviewURL` is set we
/// render that asset directly and skip the expensive WKWebView snapshot pass
/// entirely. Plain HTML wallpapers (no WPE origin) still capture a first frame.
struct HTMLPreviewSection: View {
    let source: HTMLSource?
    let config: HTMLConfig
    /// Non-nil only for Wallpaper Engine web projects that ship a preview
    /// asset. Always `nil` in Lite builds (WPE is Pro-only).
    let wpePreviewURL: URL?
    let wpePreviewBookmark: Data?

    @State private var snapshot: NSImage?
    @State private var isLoading = false
    @State private var loadFailed = false

    init(
        source: HTMLSource?,
        config: HTMLConfig,
        wpePreviewURL: URL? = nil,
        wpePreviewBookmark: Data? = nil
    ) {
        self.source = source
        self.config = config
        self.wpePreviewURL = wpePreviewURL
        self.wpePreviewBookmark = wpePreviewBookmark
    }

    /// Whether the card shows the WPE preview asset instead of a WKWebView
    /// snapshot. When true, the snapshot pipeline and refresh button stand down.
    private var showsWPEPreview: Bool { wpePreviewURL != nil }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            cardBody
                .screenPreviewChrome()

            VStack {
                HStack {
                    HTMLInformationOverlay(source: source, config: config)
                    Spacer()
                }
                Spacer()
            }
            .padding(14)
            .allowsHitTesting(false)

            if !showsWPEPreview {
                refreshButton
                    .padding(10)
            }
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
        if let wpePreviewURL {
            wpePreviewCard(url: wpePreviewURL)
        } else {
            snapshotCard
        }
    }

    /// WPE web project: render the shipped preview GIF/jpg/png, aspect-filling
    /// the 16:9 card. Guarded for Lite since `WPEPreviewView` is Pro-only — but
    /// `wpePreviewURL` is always `nil` there anyway, so this branch never runs.
    @ViewBuilder
    private func wpePreviewCard(url: URL) -> some View {
        #if !LITE_BUILD
        WPEPreviewView(
            imageURL: url,
            securityScopedBookmarkData: wpePreviewBookmark,
            aspectRatio: nil
        )
        #else
        snapshotCard
        #endif
    }

    @ViewBuilder
    private var snapshotCard: some View {
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
                    .font(DesignTokens.Typography.body)
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
        // WPE web projects render their shipped preview asset — no WKWebView
        // snapshot needed, which is the whole point of this path.
        guard !showsWPEPreview else { return }
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

/// Floating capsule shown on the HTML preview, parallel to
/// `VideoInformationOverlay`. Surfaces the same kind of "what is this"
/// glance information that the video overlay does — source kind, source
/// identifier, and the runtime-mode badges that meaningfully change how
/// the page is drawn (insecure URL, physical-pixel layout, JavaScript
/// off).
///
/// Deliberately omits anything that already lives in a banner inside
/// `HTMLSourceSection` (trust state for remote URLs) or the HTML
/// Rendering inspector card (viewport / DPR / scale), so the overlay
/// stays a one-line summary rather than a duplicate diagnostic surface.
struct HTMLInformationOverlay: View {
    let source: HTMLSource?
    let config: HTMLConfig

    @ViewBuilder
    var body: some View {
        if let source {
            content(for: source)
        }
    }

    private func content(for source: HTMLSource) -> some View {
        HStack(spacing: 10) {
            if source.isInsecureURL {
                tag("HTTP", background: Color.orange.opacity(0.55))
            }

            HStack(spacing: 4) {
                Image(systemName: icon(for: source))
                Text(verbatim: identifier(for: source))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: 200, alignment: .leading)

            if case .url = source {
                if config.allowJavaScript {
                    tag("JS")
                } else {
                    tag("NO JS", background: Color.red.opacity(0.55))
                }
            } else if !config.allowJavaScript {
                tag("NO JS", background: Color.red.opacity(0.55))
            }

            if config.physicalPixelLayout {
                tag("PHYS PX")
            }
            if config.allowMouseInteraction {
                tag("CLICKS")
            }
        }
        .font(DesignTokens.Typography.code)
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.6))
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.3), radius: 5, x: 0, y: 2)
        .accessibilityElement(children: .combine)
    }

    private func tag(_ text: String, background: Color = Color.white.opacity(0.18)) -> some View {
        Text(verbatim: text)
            .font(DesignTokens.Typography.badge)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(background, in: Capsule())
    }

    private func icon(for source: HTMLSource) -> String {
        switch source {
        case .url:    return "globe"
        case .file:   return "doc.richtext"
        case .folder: return "folder"
        case .inline: return "curlybraces"
        }
    }

    private func identifier(for source: HTMLSource) -> String {
        switch source {
        case .url(let url):
            return url.host ?? url.absoluteString
        case .file, .folder:
            return source.displayName
        case .inline:
            return "Inline HTML"
        }
    }
}
