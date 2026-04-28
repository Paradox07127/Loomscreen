import AppKit
import WebKit

/// WKWebView-backed HTML wallpaper host.
@MainActor
final class HTMLWallpaperView: NSView {

    // MARK: - Properties

    private let webView: WKWebView
    private var allowMouseInteraction = false
    private var compiledTrackerRuleList: WKContentRuleList?
    private var hasTrackerRulesAttached = false
    private var trackerBlockingRequested = false
    private var activeSecurityScopedURL: URL?
    /// Tracks the last applied `HTMLConfig` so re-`apply()` calls with the
    /// same toggles skip the user-script teardown / re-install (which forces
    /// WKWebView to re-evaluate scripts and was a source of GPU churn when
    /// upstream emitters re-published frequently).
    private var lastAppliedConfig: HTMLConfig?

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

        installBaselineUserScripts()
        webView.navigationDelegate = self
        webView.autoresizingMask = [.width, .height]
    }

    private func installBaselineUserScripts() {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        let hideScrollbar = """
        var style = document.createElement('style');
        style.textContent = '::-webkit-scrollbar { display: none; } body { overflow: hidden; }';
        document.head.appendChild(style);
        """
        controller.addUserScript(WKUserScript(
            source: hideScrollbar,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
    }

    // MARK: - Hit Testing

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard allowMouseInteraction else { return nil }
        return super.hitTest(point)
    }

    // MARK: - Public API

    func apply(_ config: HTMLConfig) {
        if let previous = lastAppliedConfig, previous == config {
            // No-op fast path: avoids `removeAllUserScripts` + `addUserScript`
            // churn that forces WebKit to re-evaluate the injection bundle.
            return
        }

        let previous = lastAppliedConfig
        webView.configuration.defaultWebpagePreferences.allowsContentJavaScript = config.allowJavaScript
        allowMouseInteraction = config.allowMouseInteraction

        // Only rebuild user-script bundle when CSS or JS toggle actually changed.
        if previous?.customCSS != config.customCSS || previous?.allowJavaScript != config.allowJavaScript {
            applyCustomCSS(config.customCSS)
        }
        if previous?.blockTrackers != config.blockTrackers {
            applyTrackerBlocking(enabled: config.blockTrackers)
        }
        lastAppliedConfig = config
    }

    func loadSource(_ source: HTMLSource) {
        stopActiveSecurityScope()
        switch source {
        case .file(let bookmarkData):
            guard let url = HTMLWallpaperView.resolveBookmark(bookmarkData) else { return }
            activeSecurityScopedURL = url
            webView.loadFileURL(url, allowingReadAccessTo: Self.readAccessRoot(forFileURL: url))
        case .folder(let bookmarkData, let indexFileName):
            guard let folderURL = HTMLWallpaperView.resolveBookmark(bookmarkData) else { return }
            activeSecurityScopedURL = folderURL
            let indexURL = folderURL.appendingPathComponent(indexFileName)
            webView.loadFileURL(indexURL, allowingReadAccessTo: folderURL)
        case .url(let url):
            guard HTMLWallpaperView.isAllowedRemoteURL(url) else { return }
            webView.load(URLRequest(url: url))
        case .inline(let html):
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    private func stopActiveSecurityScope() {
        activeSecurityScopedURL?.stopAccessingSecurityScopedResource()
        activeSecurityScopedURL = nil
    }

    fileprivate static func isAllowedRemoteURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    func loadHTML(_ htmlString: String) {
        loadSource(.inline(htmlString))
    }

    func loadURL(_ url: URL) {
        loadSource(.url(url))
    }

    func loadFile(_ fileURL: URL) {
        webView.loadFileURL(fileURL, allowingReadAccessTo: Self.readAccessRoot(forFileURL: fileURL))
    }

    static func readAccessRoot(forFileURL url: URL) -> URL {
        url.deletingLastPathComponent()
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
        webView.setAllMediaPlaybackSuspended(suspended) {}
    }

    // MARK: - Custom CSS

    private func applyCustomCSS(_ css: String?) {
        installBaselineUserScripts()
        guard let css, !css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // JSON encoding keeps the CSS body a string literal, not script text.
        guard let encoded = try? JSONEncoder().encode(css),
              let cssLiteral = String(data: encoded, encoding: .utf8) else { return }
        let injection = """
        (function() {
            var s = document.createElement('style');
            s.textContent = \(cssLiteral);
            document.head.appendChild(s);
        })();
        """
        webView.configuration.userContentController.addUserScript(WKUserScript(
            source: injection,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
    }

    // MARK: - Tracker Blocking

    private func applyTrackerBlocking(enabled: Bool) {
        trackerBlockingRequested = enabled
        let controller = webView.configuration.userContentController
        if !enabled {
            if let existing = compiledTrackerRuleList, hasTrackerRulesAttached {
                controller.remove(existing)
                hasTrackerRulesAttached = false
            }
            return
        }
        if let cached = compiledTrackerRuleList {
            if !hasTrackerRulesAttached {
                controller.add(cached)
                hasTrackerRulesAttached = true
            }
            return
        }
        WKContentRuleListStore.default()?.compileContentRuleList(
            forIdentifier: HTMLWallpaperView.trackerRuleListIdentifier,
            encodedContentRuleList: HTMLWallpaperView.trackerRuleListJSON
        ) { [weak self] list, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.trackerBlockingRequested, let list else {
                    if let error {
                        Logger.warning(
                            "Tracker rule list compile failed: \(error.localizedDescription)",
                            category: .screenManager
                        )
                    }
                    return
                }
                self.compiledTrackerRuleList = list
                if !self.hasTrackerRulesAttached {
                    self.webView.configuration.userContentController.add(list)
                    self.hasTrackerRulesAttached = true
                }
            }
        }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        webView.frame = bounds
    }

    // MARK: - Cleanup

    func cleanup() {
        trackerBlockingRequested = false
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeAllUserScripts()
        if let list = compiledTrackerRuleList, hasTrackerRulesAttached {
            webView.configuration.userContentController.remove(list)
            hasTrackerRulesAttached = false
        }
        stopActiveSecurityScope()
    }

    // MARK: - Bookmark Resolution

    private static func resolveBookmark(_ data: Data) -> URL? {
        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            Logger.warning("HTMLWallpaperView: bookmark resolution failed — \(error.localizedDescription)", category: .screenManager)
            return nil
        }
        if isStale {
            Logger.warning("HTMLWallpaperView: bookmark for \(url.lastPathComponent) is stale (file may have moved). Re-pick the source to refresh.", category: .screenManager)
        }
        guard url.startAccessingSecurityScopedResource() else {
            Logger.warning("HTMLWallpaperView: startAccessingSecurityScopedResource failed for \(url.lastPathComponent) — sandbox extension is no longer valid; user must re-pick the source.", category: .screenManager)
            return nil
        }
        return url
    }

    // MARK: - Tracker Rule List

    private static let trackerRuleListIdentifier = "LiveWallpaper.HTMLWallpaper.TrackerRules.v1"

    /// Common analytics/ad hosts blocked before the renderer sees them.
    private static let trackerRuleListJSON = """
    [
      {
        "trigger": {
          "url-filter": ".*",
          "if-domain": [
            "*google-analytics.com",
            "*googletagmanager.com",
            "*doubleclick.net",
            "*facebook.net",
            "*scorecardresearch.com",
            "*hotjar.com",
            "*mixpanel.com",
            "*segment.com",
            "*segment.io",
            "*amplitude.com",
            "*fullstory.com",
            "*adservice.google.com",
            "*adsystem.com"
          ]
        },
        "action": { "type": "block" }
      }
    ]
    """
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
            if let url = navigationAction.request.url,
               HTMLWallpaperView.isAllowedRemoteURL(url) || url.isFileURL {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        case .linkActivated, .formSubmitted, .backForward, .formResubmitted:
            decisionHandler(.cancel)
        @unknown default:
            decisionHandler(.cancel)
        }
    }

    /// Nudges autoplay media after navigation finishes.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let nudge = """
        (function() {
            var elements = document.querySelectorAll('video, audio');
            elements.forEach(function(el) {
                if (el.paused && el.autoplay !== false) {
                    try {
                        var promise = el.play();
                        if (promise && typeof promise.catch === 'function') {
                            promise.catch(function() {});
                        }
                    } catch (e) {}
                }
            });
        })();
        """
        webView.evaluateJavaScript(nudge, completionHandler: nil)
    }
}
