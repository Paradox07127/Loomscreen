import AppKit
import WebKit

/// A non-interactive WKWebView wrapper for rendering HTML-based wallpapers.
/// Supports inline HTML strings, remote URLs, and local HTML files.
final class HTMLWallpaperView: NSView {

    // MARK: - Properties

    private let webView: WKWebView

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        let configuration = WKWebViewConfiguration()

        // Suppress JavaScript alerts / confirm / prompt dialogs.
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = preferences

        // Disable media playback restrictions so animated backgrounds work.
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
        // Transparent background.
        webView.wantsLayer = true
        webView.layer?.backgroundColor = NSColor.clear.cgColor
        webView.setValue(false, forKey: "drawsBackground")

        // Disable user interaction -- wallpaper should not be clickable.
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false

        // Hide scrollbars and disable scrolling via JS injection.
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

        // Navigation delegate to block external navigation.
        webView.navigationDelegate = self

        // Autoresizing.
        webView.autoresizingMask = [.width, .height]
    }

    // MARK: - Public API

    /// Loads an inline HTML string as the wallpaper content.
    func loadHTML(_ htmlString: String) {
        webView.loadHTMLString(htmlString, baseURL: nil)
    }

    /// Loads a remote web URL as the wallpaper content.
    func loadURL(_ url: URL) {
        let request = URLRequest(url: url)
        webView.load(request)
    }

    /// Loads a local HTML file from disk as the wallpaper content.
    func loadFile(_ fileURL: URL) {
        webView.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        webView.frame = bounds
    }

    // MARK: - Cleanup

    deinit {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeAllUserScripts()
    }
}

// MARK: - WKNavigationDelegate

extension HTMLWallpaperView: WKNavigationDelegate {

    /// Allow only the initial page load; block all subsequent navigation attempts
    /// so the wallpaper content stays in place.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        switch navigationAction.navigationType {
        case .other, .reload:
            // .other covers the initial programmatic load.
            decisionHandler(.allow)
        case .linkActivated, .formSubmitted, .backForward, .formResubmitted:
            decisionHandler(.cancel)
        @unknown default:
            decisionHandler(.cancel)
        }
    }

    /// Suppress JavaScript alert() dialogs.
    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }

    /// Suppress JavaScript confirm() dialogs -- always returns false.
    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(false)
    }

    /// Suppress JavaScript prompt() dialogs -- always returns nil.
    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        completionHandler(nil)
    }
}
