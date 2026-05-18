import AppKit
import WebKit

/// `WKWebView` 子类：开启 first-mouse 接收（Plash 模式），关闭 Force-Touch 链接预览，
/// 过滤右键菜单中无意义项（下载图片 / 分享 / 在新窗口打开等）。
final class HTMLWebView: WKWebView {
    /// 关键：交互态首次点击就生效，不需要先把 wallpaper window 激活成 key window。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 借鉴 Plash：右键菜单里这些项在壁纸场景下完全无意义，直接拿掉。
    private static let blockedMenuTitles: Set<String> = [
        "Download Image",
        "Download Linked File",
        "Download Video",
        "Open Image in New Window",
        "Open Video in New Window",
        "Open Frame in New Window",
        "Open Link in New Window",
        "Share",
        "Enter Full Screen",
        "Enter Enhanced Full Screen"
    ]

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        menu.items.removeAll { item in
            HTMLWebView.blockedMenuTitles.contains(item.title)
        }
    }
}

enum HTMLWallpaperRuntimeScript {
    static func physicalPixelState(enabled: Bool, backingScale: CGFloat) -> String {
        let scale = max(Double(backingScale), 1.0)
        let scaleLiteral = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), scale)
        let dprGetter = enabled
            ? "get: function () { return 1; }"
            : "get: function () { return window.__liveWallpaperNativeDevicePixelRatio || \(scaleLiteral); }"

        return """
        (function () {
            window.__liveWallpaperNativeDevicePixelRatio = \(scaleLiteral);
            window.__liveWallpaperPhysicalPixelLayout = \(enabled ? "true" : "false");
            try {
                Object.defineProperty(window, 'devicePixelRatio', {
                    configurable: true,
                    \(dprGetter)
                });
            } catch (e) {}
            try { window.dispatchEvent(new Event('resize')); } catch (e) {}
            try {
                if (window.visualViewport) {
                    window.visualViewport.dispatchEvent(new Event('resize'));
                }
            } catch (e) {}
        })();
        """
    }

    static func wallpaperEngineGeneralProperties(fps: Int) -> String {
        let clampedFPS = min(max(fps, 1), 240)
        return """
        (function () {
            var properties = {"fps":\(clampedFPS)};
            var listener = window.wallpaperPropertyListener;
            if (listener && typeof listener.applyGeneralProperties === 'function') {
                try {
                    listener.applyGeneralProperties(properties);
                } catch (error) {
                    console.error('LiveWallpaper failed to apply Wallpaper Engine general properties', error);
                }
            }
        })();
        """
    }
}

/// WKWebView-backed HTML wallpaper host.
@MainActor
final class HTMLWallpaperView: NSView, HTMLWallpaperConfigApplying {

    // MARK: - Properties
    private let webView: HTMLWebView
    private let folderHandler: FolderURLSchemeHandler
    private var allowMouseInteraction = false
    private var compiledTrackerRuleList: WKContentRuleList?
    private var hasTrackerRulesAttached = false
    private var trackerBlockingRequested = false
    private var activeSecurityScopedURL: URL?
    /// `WKWebsiteDataStore` is locked at WKWebView init time. We track which
    /// store the live view is using vs what config now requests so subsequent
    /// `apply(_:)` calls can warn the caller that the swap will only take
    /// effect on the next session rebuild.
    private var currentDataStoreIsEphemeral: Bool
    private var pendingEphemeral: Bool
    /// Tracks the last applied `HTMLConfig` so re-`apply()` calls with the
    /// same toggles skip the user-script teardown / re-install.
    private var lastAppliedConfig: HTMLConfig?
    private var wallpaperEnginePropertyBootstrapScript: String?
    /// Replays into `loadSource(_:)` for retry / re-entry (sleep wake, error banner).
    private var lastSource: HTMLSource?
    /// Counts consecutive navigation failures since the last successful load.
    /// Capped by `HTMLConfig.maxRetries`; used to drive exponential backoff.
    private var consecutiveFailureCount: Int = 0
    private var pendingRetryTask: Task<Void, Never>?
    private var isCleaningUp = false
    private var mediaPlaybackSuspended = false

    /// Forwarded to the owning `AmbientWallpaperSession` so failures surface as
    /// `RuntimeErrorBanner` and can be retried from the screen-detail UI.
    var onError: (@MainActor (WallpaperRuntimeError) -> Void)?

    // MARK: - Initialization

    init(frame frameRect: NSRect, initialEphemeral: Bool = false) {
        let configuration = WKWebViewConfiguration()
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = preferences
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.websiteDataStore = initialEphemeral
            ? .nonPersistent()
            : .default()

        let handler = FolderURLSchemeHandler()
        configuration.setURLSchemeHandler(handler, forURLScheme: FolderURLSchemeHandler.scheme)
        self.folderHandler = handler
        self.currentDataStoreIsEphemeral = initialEphemeral
        self.pendingEphemeral = initialEphemeral

        webView = HTMLWebView(frame: NSRect(origin: .zero, size: frameRect.size), configuration: configuration)

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
        webView.allowsLinkPreview = false

        installBaselineUserScripts(for: nil)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.autoresizingMask = [.width, .height]
    }

    /// 注入静态基线脚本 + 反映当前配置的状态脚本。
    private func installBaselineUserScripts(for config: HTMLConfig?) {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()

        let cssLiteral = jsStringLiteral(config?.customCSS ?? "")
        let isBrowsing = (config?.allowMouseInteraction ?? false) ? "true" : "false"
        let isMuted = (config?.muteAudio ?? false) ? "true" : "false"
        let physicalPixelBootstrap = (config?.physicalPixelLayout ?? false)
            ? HTMLWallpaperRuntimeScript.physicalPixelState(
                enabled: true,
                backingScale: effectiveBackingScaleFactor
            )
            : ""

        let baseline = """
        (function () {
            \(physicalPixelBootstrap)

            function bootstrap() {
                if (!document.documentElement) return;
                document.documentElement.classList.add('is-livewallpaper');
                document.documentElement.classList.toggle('lw-browsing-mode', \(isBrowsing));

                if (!document.getElementById('lw-base-css')) {
                    var base = document.createElement('style');
                    base.id = 'lw-base-css';
                    base.textContent = '::-webkit-scrollbar{display:none;}html,body{overflow:hidden;}';
                    (document.head || document.documentElement).appendChild(base);
                }
                if (!document.getElementById('lw-user-css')) {
                    var user = document.createElement('style');
                    user.id = 'lw-user-css';
                    user.textContent = \(cssLiteral);
                    (document.head || document.documentElement).appendChild(user);
                }
            }
            bootstrap();
            // <head> 在 documentStart 时可能尚未就绪 — 用 MutationObserver 做兜底。
            if (!document.head) {
                var mo = new MutationObserver(function () {
                    if (document.head) { bootstrap(); mo.disconnect(); }
                });
                mo.observe(document.documentElement, { childList: true });
            }
            // 静音状态：通过 JS 在 DOMContentLoaded 时统一施加；后续元素由 navigation finish 兜底。
            if (\(isMuted)) {
                document.addEventListener('DOMContentLoaded', function () {
                    document.querySelectorAll('audio,video').forEach(function (el) { el.muted = true; });
                });
            }
        })();
        """

        controller.addUserScript(WKUserScript(
            source: baseline,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))

        if let wallpaperEnginePropertyBootstrapScript {
            controller.addUserScript(WKUserScript(
                source: wallpaperEnginePropertyBootstrapScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            ))
        }
    }

    // MARK: - Hit Testing

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard allowMouseInteraction else { return nil }
        return super.hitTest(point)
    }

    // MARK: - Scroll Forwarding
    //
    // macOS 在桌面图标层之上的自定义 window level 下，scroll wheel 事件
    // 偶发不会直接命中 WKWebView（hitTest 返回 self 或事件由 NSWindow 自身
    // 吞掉），双指上下滑动失效。这里强制把 scroll 事件转发给 webView，
    // 同时对 swipe / magnify / rotate 一并兜底，保证 trackpad 手势可用。

    override func scrollWheel(with event: NSEvent) {
        guard allowMouseInteraction else {
            super.scrollWheel(with: event)
            return
        }
        webView.scrollWheel(with: event)
    }

    override func swipe(with event: NSEvent) {
        guard allowMouseInteraction else {
            super.swipe(with: event)
            return
        }
        webView.swipe(with: event)
    }

    override func magnify(with event: NSEvent) {
        guard allowMouseInteraction else {
            super.magnify(with: event)
            return
        }
        webView.magnify(with: event)
    }

    override func rotate(with event: NSEvent) {
        guard allowMouseInteraction else {
            super.rotate(with: event)
            return
        }
        webView.rotate(with: event)
    }

    // MARK: - Public API

    func apply(_ config: HTMLConfig) {
        pendingEphemeral = config.useEphemeralStorage
        if let previous = lastAppliedConfig, previous == config {
            return
        }

        let previous = lastAppliedConfig
        webView.configuration.defaultWebpagePreferences.allowsContentJavaScript = config.allowJavaScript
        allowMouseInteraction = config.allowMouseInteraction

        if currentDataStoreIsEphemeral != pendingEphemeral {
            let requested = pendingEphemeral ? "ephemeral" : "persistent"
            let active = currentDataStoreIsEphemeral ? "ephemeral" : "persistent"
            Logger.warning(
                "HTML wallpaper requested \(requested) storage but the live WKWebView still uses the \(active) data store; the change applies on next session rebuild.",
                category: .screenManager
            )
        }

        applyRuntimeState(previous: previous, current: config)

        let needsScriptRebuild = (previous?.customCSS != config.customCSS)
            || (previous?.allowMouseInteraction != config.allowMouseInteraction)
            || (previous?.muteAudio != config.muteAudio)
            || (previous?.allowJavaScript != config.allowJavaScript)
            || (previous?.useEphemeralStorage != config.useEphemeralStorage)
            || (previous?.physicalPixelLayout != config.physicalPixelLayout)

        if needsScriptRebuild {
            installBaselineUserScripts(for: config)
        }

        if previous?.blockTrackers != config.blockTrackers {
            applyTrackerBlocking(enabled: config.blockTrackers)
        }

        if previous?.physicalPixelLayout != config.physicalPixelLayout {
            applyPhysicalPixelZoom()
        }

        if config.allowMouseInteraction, let host = webView.window {
            host.makeFirstResponder(webView)
        }

        lastAppliedConfig = config
    }

    func applyHTMLConfig(_ config: HTMLConfig) -> Bool {
        if currentDataStoreIsEphemeral != config.useEphemeralStorage {
            return false
        }
        if let previous = lastAppliedConfig, previous.useEphemeralStorage != config.useEphemeralStorage {
            return false
        }
        apply(config)
        return true
    }

    /// 当前页面已经渲染时的热更新路径：直接改 DOM，不动 user script。
    private func applyRuntimeState(previous: HTMLConfig?, current: HTMLConfig) {
        var statements: [String] = []

        if previous?.customCSS != current.customCSS {
            let literal = jsStringLiteral(current.customCSS ?? "")
            statements.append("""
            (function(){var el=document.getElementById('lw-user-css');if(el){el.textContent=\(literal);}})();
            """)
        }

        if previous?.allowMouseInteraction != current.allowMouseInteraction {
            let flag = current.allowMouseInteraction ? "true" : "false"
            statements.append("""
            document.documentElement&&document.documentElement.classList.toggle('lw-browsing-mode',\(flag));
            """)
        }

        if previous?.muteAudio != current.muteAudio {
            let flag = current.muteAudio ? "true" : "false"
            statements.append("""
            document.querySelectorAll('audio,video').forEach(function(e){e.muted=\(flag);});
            """)
        }

        if previous?.physicalPixelLayout != current.physicalPixelLayout {
            statements.append(HTMLWallpaperRuntimeScript.physicalPixelState(
                enabled: current.physicalPixelLayout,
                backingScale: effectiveBackingScaleFactor
            ))
        }

        guard !statements.isEmpty else { return }
        webView.evaluateJavaScript(statements.joined(separator: "\n"), completionHandler: nil)
    }

    func loadSource(_ source: HTMLSource) {
        loadSource(source, resetFailureCount: true)
    }

    /// Internal entry point distinguishing user-driven loads (which reset the retry budget) from `scheduleRetry` continuations (which keep the counter so backoff progresses).
    private func loadSource(_ source: HTMLSource, resetFailureCount: Bool) {
        lastSource = source
        if resetFailureCount {
            resetNavigationFailureState()
        }
        stopActiveSecurityScope()
        if case .folder = source {
        } else {
            updateWallpaperEnginePropertyBridge(for: nil)
            folderHandler.folderURL = nil
        }
        switch source {
        case .file(let bookmarkData):
            guard let url = HTMLWallpaperView.resolveBookmark(bookmarkData) else {
                reportError(.sandboxRevoked)
                return
            }
            activeSecurityScopedURL = url
            webView.loadFileURL(url, allowingReadAccessTo: Self.readAccessRoot(forFileURL: url))
        case .folder(let bookmarkData, let indexFileName):
            guard let folderURL = HTMLWallpaperView.resolveBookmark(bookmarkData) else {
                reportError(.sandboxRevoked)
                return
            }
            activeSecurityScopedURL = folderURL
            updateWallpaperEnginePropertyBridge(for: folderURL)
            folderHandler.folderURL = folderURL
            guard let nonce = folderHandler.currentSessionNonce else {
                Logger.error("HTML folder load: missing session nonce for \(indexFileName)", category: .screenManager)
                return
            }
            let escapedIndex = indexFileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? indexFileName
            let urlString = "\(FolderURLSchemeHandler.scheme)://\(FolderURLSchemeHandler.host)/\(escapedIndex)?n=\(nonce)"
            guard let url = URL(string: urlString) else {
                Logger.error("HTML folder load: failed to build scheme URL for \(indexFileName)", category: .screenManager)
                return
            }
            Logger.info("HTML folder load: \(url.absoluteString) (folder=\(folderURL.lastPathComponent))", category: .screenManager)
            webView.load(URLRequest(url: url))
        case .url(let url):
            guard HTMLWallpaperView.isAllowedRemoteURL(url) else { return }
            webView.load(URLRequest(url: url))
        case .inline(let html):
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    private func updateWallpaperEnginePropertyBridge(for folderURL: URL?) {
        let nextScript = folderURL.flatMap {
            WallpaperEngineWebPropertyBridge.bootstrapScript(forFolder: $0)
        }
        guard wallpaperEnginePropertyBootstrapScript != nextScript else { return }
        wallpaperEnginePropertyBootstrapScript = nextScript
        installBaselineUserScripts(for: lastAppliedConfig)
    }

    /// Re-applies the most recent `HTMLSource`.
    func reloadCurrentSource() {
        guard let lastSource else { return }
        loadSource(lastSource, resetFailureCount: false)
    }

    private func stopActiveSecurityScope() {
        activeSecurityScopedURL?.stopAccessingSecurityScopedResource()
        activeSecurityScopedURL = nil
    }

    nonisolated static func isAllowedRemoteURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    nonisolated static func isExternallyOpenableURL(_ url: URL) -> Bool {
        isAllowedRemoteURL(url)
    }

    nonisolated static func isSameOrigin(navigationURL: URL, current: URL?) -> Bool {
        guard let current,
              let lhsScheme = navigationURL.scheme?.lowercased(),
              let rhsScheme = current.scheme?.lowercased(),
              let lhsHost = navigationURL.host?.lowercased(),
              let rhsHost = current.host?.lowercased(),
              lhsScheme == rhsScheme,
              lhsHost == rhsHost else { return false }

        return effectivePort(for: navigationURL, scheme: lhsScheme)
            == effectivePort(for: current, scheme: rhsScheme)
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

    /// Sleep / wake suspend hook.
    func suspend() {
        setMediaPlaybackSuspended(true)
    }

    func resume() {
        setMediaPlaybackSuspended(false)
    }

    private func setMediaPlaybackSuspended(_ suspended: Bool) {
        guard !isCleaningUp else { return }
        mediaPlaybackSuspended = suspended
        webView.setAllMediaPlaybackSuspended(suspended) {}
        notifyWallpaperEngineGeneralProperties(fps: suspended ? 1 : 60)
    }

    private func notifyWallpaperEngineGeneralProperties(fps: Int) {
        webView.evaluateJavaScript(
            HTMLWallpaperRuntimeScript.wallpaperEngineGeneralProperties(fps: fps),
            completionHandler: nil
        )
    }

    private func reportError(_ error: WallpaperRuntimeError) {
        onError?(error)
    }

    /// Returns `true` when a retry was scheduled and the caller should skip `reportError`.
    private func shouldRetryNavigationFailure() -> Bool {
        let maxRetries = max(0, lastAppliedConfig?.maxRetries ?? 0)
        guard consecutiveFailureCount < maxRetries else { return false }
        scheduleRetry()
        return true
    }

    private func scheduleRetry() {
        consecutiveFailureCount += 1
        let delaySeconds = pow(2.0, Double(consecutiveFailureCount - 1))
        pendingRetryTask?.cancel()
        pendingRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delaySeconds))
            guard !Task.isCancelled, let self else { return }
            self.pendingRetryTask = nil
            self.reloadCurrentSource()
        }
    }

    private func resetNavigationFailureState() {
        consecutiveFailureCount = 0
        pendingRetryTask?.cancel()
        pendingRetryTask = nil
    }

    private func navigationFailureURL(webView: WKWebView, error: NSError) -> URL {
        if let url = webView.url {
            return url
        }
        if let url = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL {
            return url
        }
        return URL(string: "about:blank") ?? URL(fileURLWithPath: "/")
    }

    // MARK: - Tracker Blocking

    /// App 启动时调用一次：把 tracker 规则编译进 `WKContentRuleListStore`， 后续每个实例直接 `lookUp`，省去 50–200ms 的同步编译。
    static func precompileTrackerRules() {
        WKContentRuleListStore.default()?.compileContentRuleList(
            forIdentifier: trackerRuleListIdentifier,
            encodedContentRuleList: trackerRuleListJSON
        ) { _, error in
            if let error {
                Logger.warning(
                    "Tracker rule list precompile failed: \(error.localizedDescription)",
                    category: .screenManager
                )
            }
        }
    }

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
        WKContentRuleListStore.default()?.lookUpContentRuleList(
            forIdentifier: HTMLWallpaperView.trackerRuleListIdentifier
        ) { [weak self] list, _ in
            Task { @MainActor [weak self] in
                guard let self, self.trackerBlockingRequested else { return }
                if let list {
                    self.attachTrackerList(list)
                } else {
                    self.compileAndAttachTrackerList()
                }
            }
        }
    }

    private func compileAndAttachTrackerList() {
        WKContentRuleListStore.default()?.compileContentRuleList(
            forIdentifier: HTMLWallpaperView.trackerRuleListIdentifier,
            encodedContentRuleList: HTMLWallpaperView.trackerRuleListJSON
        ) { [weak self] list, error in
            Task { @MainActor [weak self] in
                guard let self, self.trackerBlockingRequested else { return }
                if let error {
                    Logger.warning(
                        "Tracker rule list compile failed: \(error.localizedDescription)",
                        category: .screenManager
                    )
                }
                guard let list else { return }
                self.attachTrackerList(list)
            }
        }
    }

    private func attachTrackerList(_ list: WKContentRuleList) {
        compiledTrackerRuleList = list
        guard !hasTrackerRulesAttached else { return }
        webView.configuration.userContentController.add(list)
        hasTrackerRulesAttached = true
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        webView.frame = bounds
    }

    /// Re-apply pageZoom whenever the host display's backing scale changes (window dragged across screens, resolution changed, Spaces switched).
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyPhysicalPixelZoom()
        applyPhysicalPixelRuntimeStateIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyPhysicalPixelZoom()
        applyPhysicalPixelRuntimeStateIfNeeded()
    }

    // MARK: - Physical-pixel layout (WPE compatibility)

    /// Maps logical points → physical pixels for `window.innerWidth/Height`.
    private func applyPhysicalPixelZoom() {
        let enabled = lastAppliedConfig?.physicalPixelLayout ?? false
        let scale = effectiveBackingScaleFactor
        guard enabled, scale > 0 else {
            if webView.pageZoom != 1.0 { webView.pageZoom = 1.0 }
            return
        }
        let target = 1.0 / scale
        if abs(webView.pageZoom - target) > 0.001 {
            Logger.info("HTML wallpaper pageZoom → \(target) (backingScale=\(scale))", category: .screenManager)
            webView.pageZoom = target
        }
    }

    private var effectiveBackingScaleFactor: CGFloat {
        webView.window?.backingScaleFactor
            ?? window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 1
    }

    private func applyPhysicalPixelRuntimeStateIfNeeded() {
        guard lastAppliedConfig?.physicalPixelLayout == true else { return }
        webView.evaluateJavaScript(
            HTMLWallpaperRuntimeScript.physicalPixelState(
                enabled: true,
                backingScale: effectiveBackingScaleFactor
            ),
            completionHandler: nil
        )
    }

    // MARK: - Cleanup

    func cleanup() {
        isCleaningUp = true
        trackerBlockingRequested = false
        pendingRetryTask?.cancel()
        pendingRetryTask = nil
        onError = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeAllUserScripts()
        if let list = compiledTrackerRuleList, hasTrackerRulesAttached {
            webView.configuration.userContentController.remove(list)
            hasTrackerRulesAttached = false
        }
        folderHandler.folderURL = nil
        stopActiveSecurityScope()
    }

    private func shouldIgnoreNavigationFailure(_ error: NSError) -> Bool {
        if isCleaningUp { return true }
        return error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled
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
               HTMLWallpaperView.isAllowedRemoteURL(url)
                || url.isFileURL
                || url.scheme?.lowercased() == FolderURLSchemeHandler.scheme {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        case .linkActivated:
            guard allowMouseInteraction,
                  let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if HTMLWallpaperView.isSameOrigin(navigationURL: url, current: webView.url) || url.isFileURL {
                decisionHandler(.allow)
            } else if HTMLWallpaperView.isExternallyOpenableURL(url) {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.cancel)
            }
        case .formSubmitted, .backForward, .formResubmitted:
            decisionHandler(.cancel)
        @unknown default:
            decisionHandler(.cancel)
        }
    }

    /// 导航完成后兜底：autoplay nudge + 静音状态再施加一次（覆盖晚到的元素）。
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Logger.info("HTML wallpaper finished loading: \(webView.url?.absoluteString ?? "<no url>")", category: .screenManager)
        resetNavigationFailureState()
        let muted = lastAppliedConfig?.muteAudio == true ? "true" : "false"
        let nudge = """
        (function() {
            var elements = document.querySelectorAll('video, audio');
            elements.forEach(function(el) {
                el.muted = \(muted);
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
        notifyWallpaperEngineGeneralProperties(fps: mediaPlaybackSuspended ? 1 : 60)
    }

    /// Server-side / authentication failures.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        guard !shouldIgnoreNavigationFailure(nsError) else { return }
        Logger.error(
            "HTML wallpaper didFail [domain=\(nsError.domain) code=\(nsError.code)] url=\(webView.url?.absoluteString ?? "<no url>") — \(nsError.localizedDescription); userInfo=\(nsError.userInfo)",
            category: .screenManager
        )
        if shouldRetryNavigationFailure() { return }
        reportError(.webNavigationFailed(
            navigationFailureURL(webView: webView, error: nsError),
            code: nsError.code,
            description: nsError.localizedDescription
        ))
    }

    /// Pre-commit failures (file not found, sandbox denial, scheme blocked).
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        guard !shouldIgnoreNavigationFailure(nsError) else { return }
        Logger.error(
            "HTML wallpaper didFailProvisionalNavigation [domain=\(nsError.domain) code=\(nsError.code)] url=\(webView.url?.absoluteString ?? "<no url>") — \(nsError.localizedDescription); userInfo=\(nsError.userInfo)",
            category: .screenManager
        )
        if shouldRetryNavigationFailure() { return }
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorNotConnectedToInternet {
            reportError(.networkOffline)
        } else {
            reportError(.webNavigationFailed(
                navigationFailureURL(webView: webView, error: nsError),
                code: nsError.code,
                description: nsError.localizedDescription
            ))
        }
    }

    /// Captures unhandled JS exceptions + console messages from the page.
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        if let response = navigationResponse.response as? HTTPURLResponse, response.statusCode >= 400 {
            Logger.warning("HTML wallpaper response: HTTP \(response.statusCode) for \(response.url?.absoluteString ?? "?")", category: .screenManager)
            let failingURL = response.url ?? webView.url ?? URL(string: "about:blank") ?? URL(fileURLWithPath: "/")
            reportError(.webNavigationFailed(failingURL, code: response.statusCode, description: "HTTP \(response.statusCode)"))
        }
        decisionHandler(.allow)
    }
}

// MARK: - WKUIDelegate

extension HTMLWallpaperView: WKUIDelegate {
    /// 页面调用 `window.open()` 时，导航当前 webView 而不是开 popup（壁纸场景没有 popup 窗）。
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url,
           allowMouseInteraction,
           HTMLWallpaperView.isExternallyOpenableURL(url) {
            NSWorkspace.shared.open(url)
        }
        return nil
    }
}

// MARK: - JS literal helper

/// 把任意 Swift 字符串转成可直接嵌入 JS 源码的字符串字面量（含外层引号）。
private func jsStringLiteral(_ value: String) -> String {
    if let data = try? JSONEncoder().encode(value),
       let literal = String(data: data, encoding: .utf8) {
        return literal
    }
    return "\"\""
}

private func effectivePort(for url: URL, scheme: String) -> Int? {
    if let port = url.port { return port }
    switch scheme {
    case "http": return 80
    case "https": return 443
    default: return nil
    }
}
