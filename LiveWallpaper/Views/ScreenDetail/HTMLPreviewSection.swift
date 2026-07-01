import AppKit
import LiveWallpaperCore
import LiveWallpaperSharedUI
import SwiftUI

/// Inspector-side preview for HTML wallpapers. The selected screen's live
/// `WKWebView` is captured first so WPE web projects show the current rendered
/// page, matching the scene preview's live-frame behavior. Static WPE preview
/// assets and the shared offscreen thumbnail service are fallbacks.
struct HTMLPreviewSection: View {
    let screen: Screen
    let source: HTMLSource?
    let config: HTMLConfig
    /// Non-nil only for WPE web projects that ship a preview asset. Always
    /// `nil` in Lite builds (WPE is Pro-only).
    let wpePreviewURL: URL?
    let wpePreviewBookmark: Data?

    @State private var snapshot: NSImage?
    @State private var isLoading = false
    @State private var loadFailed = false

    init(
        screen: Screen,
        source: HTMLSource?,
        config: HTMLConfig,
        wpePreviewURL: URL? = nil,
        wpePreviewBookmark: Data? = nil
    ) {
        self.screen = screen
        self.source = source
        self.config = config
        self.wpePreviewURL = wpePreviewURL
        self.wpePreviewBookmark = wpePreviewBookmark
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            snapshotCard
                .screenPreviewChrome()

            if source != nil {
                HTMLInformationOverlay(source: source, config: config)
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)

                HTMLRenderingDiagnosticsOverlay(screen: screen, source: source, config: config)
                    .padding(14)
                    .padding(.trailing, 44)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .allowsHitTesting(false)

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

    /// Guarded for Lite since `WPEPreviewView` is Pro-only — but
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
        placeholder(systemImage: "photo", title: "Preview unavailable")
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
                Rectangle().fill(DesignTokens.Colors.pageBackground)
                LiquidGlassSpinner()
            }
        } else if let wpePreviewURL {
            wpePreviewCard(url: wpePreviewURL)
        } else if loadFailed {
            placeholder(systemImage: "exclamationmark.triangle", title: "Preview unavailable")
        } else if source != nil {
            placeholder(systemImage: "globe", title: "Tap refresh to capture preview")
        } else {
            placeholder(systemImage: "globe", title: "No web source")
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
            if let key = cacheKey {
                WallpaperThumbnailService.shared.invalidate(cacheKey: key)
            }
            snapshot = nil
            loadFailed = false
            startLoadIfNeeded(force: true)
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .semibold))
                .padding(7)
                .adaptiveGlassSurface(.circle, interactive: true)
        }
        .buttonStyle(.plain)
        .help(Text("Refresh web snapshot"))
        .accessibilityLabel(Text("Refresh web preview"))
    }

    // MARK: - Loading

    private var cacheKey: String? {
        source.map(HTMLPreviewKey.key(for:))
    }

    private func startLoadIfNeeded(force: Bool = false) {
        guard let source, let key = cacheKey else { return }
        guard !isLoading else { return }
        isLoading = true
        loadFailed = false
        Task { @MainActor in
            let liveImage = await captureLiveHTMLSnapshot()
            let cachedImage = force ? nil : WallpaperThumbnailService.shared.cachedThumbnail(forKey: key)
            let image: NSImage?
            if let liveImage {
                image = liveImage
            } else if let cachedImage {
                image = cachedImage
            } else {
                image = await HTMLPreviewKey.fetchSnapshot(for: source, cacheKey: key)
            }
            isLoading = false
            if let image {
                snapshot = image
            } else if wpePreviewURL == nil {
                loadFailed = true
            }
        }
    }

    @MainActor
    private func captureLiveHTMLSnapshot() async -> NSImage? {
        guard let session = screen.runtimeSession as? AmbientWallpaperSession else { return nil }
        return await session.captureLiveHTMLSnapshot()
    }
}

/// Resolves an `HTMLSource` into a `(URL, cacheKey)` pair that
/// `WallpaperThumbnailService` can snapshot. File/folder bookmark resolution
/// opens a security scope for the duration of the call.
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

/// Floating capsule on the web preview: source kind, identifier, and the
/// runtime-mode badges that meaningfully change how the page is drawn (insecure
/// URL, physical-pixel layout, JavaScript off).
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
                tag("HTTP", background: DesignTokens.Colors.Status.warning.opacity(0.55))
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
                    tag("NO JS", background: DesignTokens.Colors.Status.danger.opacity(0.55))
                }
            } else if !config.allowJavaScript {
                tag("NO JS", background: DesignTokens.Colors.Status.danger.opacity(0.55))
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
        .thumbnailBadgeGlass()
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
            return "Inline web content"
        }
    }
}

/// Floating capsule on the web preview for render geometry. Kept in the preview
/// rather than the inspector list so it is attached to the image it describes.
struct HTMLRenderingDiagnosticsOverlay: View {
    let screen: Screen
    let source: HTMLSource?
    let config: HTMLConfig
    private let columns = [
        GridItem(.adaptive(minimum: 104), spacing: 4, alignment: .leading)
    ]

    @ViewBuilder
    var body: some View {
        if source != nil {
            let diagnostics = HTMLRenderingDiagnostics(screen: screen, source: source, config: config)
            content(diagnostics: diagnostics)
            .font(DesignTokens.Typography.code)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .thumbnailBadgeGlass()
            .accessibilityElement(children: .combine)
        }
    }

    private func content(diagnostics: HTMLRenderingDiagnostics) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "ruler")
                Text("Web Rendering")
                    .fontWeight(.semibold)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                diagnosticTag("Measurement", diagnostics.measurementText)
                diagnosticTag("Points", diagnostics.pointSizeText)
                diagnosticTag("Backing", diagnostics.backingPixelSizeText)
                diagnosticTag("Scale", diagnostics.scaleText)
                diagnosticTag("Viewport", diagnostics.viewportText)
                diagnosticTag("DPR", diagnostics.devicePixelRatioText)
                diagnosticTag("Mode", diagnostics.modeText)
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    private func diagnosticTag(_ label: String, _ value: String) -> some View {
        Text(verbatim: "\(label) \(value)")
            .font(DesignTokens.Typography.badge)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.white.opacity(0.18), in: Capsule())
    }
}
