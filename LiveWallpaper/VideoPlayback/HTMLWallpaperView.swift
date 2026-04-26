import AppKit
import WebKit

/// A non-interactive WKWebView wrapper for rendering HTML-based wallpapers.
@MainActor
final class HTMLWallpaperView: NSView {

    // MARK: - Properties

    private let webView: WKWebView

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        let configuration = WKWebViewConfiguration()
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = preferences
        configuration.mediaTypesRequiringUserActionForPlayback = []

        webView = WKWebView(frame: NSRect(origin: .zero, size: frameRect.size), configuration: configuration)

        super.init(frame: frameRect)

        configureWebView()
        addSubview(webView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Configuration

    private func configureWebView() {
        webView.wantsLayer = true
        webView.layer?.backgroundColor = NSColor.clear.cgColor
        webView.setValue(false, forKey: "drawsBackground")

        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false

        let hideScrollbarCSS = """
        var style = document.createElement('style');
        style.textContent = '::-webkit-scrollbar { display: none; } body { overflow: hidden; }';
        document.head.appendChild(style);
        """
        let userScript = WKUserScript(
            source: hideScrollbarCSS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        webView.configuration.userContentController.addUserScript(userScript)
        webView.navigationDelegate = self
        webView.autoresizingMask = [.width, .height]
    }

    // MARK: - Public API

    func loadHTML(_ htmlString: String) {
        webView.loadHTMLString(htmlString, baseURL: nil)
    }

    func loadURL(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    func loadFile(_ fileURL: URL) {
        webView.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
    }

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        switch profile {
        case .quality:
            setMediaPlaybackSuspended(false)
        case .suspended:
            setMediaPlaybackSuspended(true)
        }
    }

    private func setMediaPlaybackSuspended(_ suspended: Bool) {
        if #available(macOS 12.0, *) {
            webView.setAllMediaPlaybackSuspended(suspended) {}
        } else if suspended {
            webView.evaluateJavaScript("document.querySelectorAll('video,audio').forEach(function(el){ el.pause(); });")
        }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        webView.frame = bounds
    }

    // MARK: - Cleanup

    func cleanUp() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeAllUserScripts()
    }

    nonisolated deinit {}
}

extension HTMLWallpaperView: WallpaperPerformanceConfigurable {}

extension HTMLWallpaperView: WallpaperResourceCleanable {}

// MARK: - WKNavigationDelegate

extension HTMLWallpaperView: WKNavigationDelegate {

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        switch navigationAction.navigationType {
        case .other, .reload:
            decisionHandler(.allow)
        case .linkActivated, .formSubmitted, .backForward, .formResubmitted:
            decisionHandler(.cancel)
        @unknown default:
            decisionHandler(.cancel)
        }
    }
}
