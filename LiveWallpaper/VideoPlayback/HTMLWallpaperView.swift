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

/// WKWebView-backed HTML wallpaper host.
@MainActor
final class HTMLWallpaperView: NSView {

    // MARK: - Shared Resources

    /// 跨屏 / 跨实例共享，避免每个壁纸都拉起独立的 WebContent 进程。
    private static let sharedProcessPool = WKProcessPool()

    // MARK: - Properties

    private let webView: HTMLWebView
    private var allowMouseInteraction = false
    private var compiledTrackerRuleList: WKContentRuleList?
    private var hasTrackerRulesAttached = false
    private var trackerBlockingRequested = false
    private var activeSecurityScopedURL: URL?
    /// Tracks the last applied `HTMLConfig` so re-`apply()` calls with the
    /// same toggles skip the user-script teardown / re-install.
    private var lastAppliedConfig: HTMLConfig?

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        let configuration = WKWebViewConfiguration()
        configuration.processPool = HTMLWallpaperView.sharedProcessPool
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = preferences
        configuration.mediaTypesRequiringUserActionForPlayback = []

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
    /// - Parameter config: 决定 `lw-browsing-mode` class、自定义 CSS 内容、静音等运行时状态。
    ///   传 `nil` 表示首次安装（init 阶段，配置未知）。
    private func installBaselineUserScripts(for config: HTMLConfig?) {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()

        // documentStart：尽早注入避免页面闪烁。
        // 1) 隐藏滚动条 + 锁定 body overflow
        // 2) 给 root 加 `is-livewallpaper` class（用户 CSS / 站点适配可用）
        // 3) 预先建好两个 <style> 占位（用户 CSS 与基线 CSS），运行时只改 textContent
        let cssLiteral = jsStringLiteral(config?.customCSS ?? "")
        let isBrowsing = (config?.allowMouseInteraction ?? false) ? "true" : "false"
        let isMuted = (config?.muteAudio ?? false) ? "true" : "false"

        let baseline = """
        (function () {
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
    }

    // MARK: - Hit Testing

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard allowMouseInteraction else { return nil }
        return super.hitTest(point)
    }

    // MARK: - Public API

    func apply(_ config: HTMLConfig) {
        if let previous = lastAppliedConfig, previous == config {
            // 完全相同 — 跳过任何注入操作，避免 WebKit 重新评估脚本包。
            return
        }

        let previous = lastAppliedConfig
        webView.configuration.defaultWebpagePreferences.allowsContentJavaScript = config.allowJavaScript
        allowMouseInteraction = config.allowMouseInteraction

        // 任何运行时状态变化都先尝试通过 evaluateJavaScript 热更新 — 不重建 user script。
        applyRuntimeState(previous: previous, current: config)

        // 仅当下次 reload 时需要的"持久化"状态变化，才重建 user script。
        let needsScriptRebuild = (previous?.customCSS != config.customCSS)
            || (previous?.allowMouseInteraction != config.allowMouseInteraction)
            || (previous?.muteAudio != config.muteAudio)
            || (previous?.allowJavaScript != config.allowJavaScript)

        if needsScriptRebuild {
            installBaselineUserScripts(for: config)
        }

        if previous?.blockTrackers != config.blockTrackers {
            applyTrackerBlocking(enabled: config.blockTrackers)
        }
        lastAppliedConfig = config
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

        guard !statements.isEmpty else { return }
        webView.evaluateJavaScript(statements.joined(separator: "\n"), completionHandler: nil)
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

    // MARK: - Tracker Blocking

    /// App 启动时调用一次：把 tracker 规则编译进 `WKContentRuleListStore`，
    /// 后续每个实例直接 `lookUp`，省去 50–200ms 的同步编译。
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
        // 优先 lookUp（命中由 precompile 写入的 store entry）— 失败再编译。
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

    // MARK: - Cleanup

    func cleanup() {
        trackerBlockingRequested = false
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
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
        case .linkActivated:
            // 交互态：跨域链接交给系统默认浏览器，同源 / file 允许。
            // 非交互态：所有链接点击都被取消（页面应当只是壁纸，无导航）。
            guard allowMouseInteraction,
                  let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if isSameOrigin(navigationURL: url, current: webView.url) || url.isFileURL {
                decisionHandler(.allow)
            } else {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            }
        case .formSubmitted, .backForward, .formResubmitted:
            decisionHandler(.cancel)
        @unknown default:
            decisionHandler(.cancel)
        }
    }

    /// 同源判断 — host 一致即视为同源；缺 host（例如 about:blank）当作不同源。
    private func isSameOrigin(navigationURL: URL, current: URL?) -> Bool {
        guard let current,
              let lhsHost = navigationURL.host,
              let rhsHost = current.host else { return false }
        return lhsHost == rhsHost
    }

    /// 导航完成后兜底：autoplay nudge + 静音状态再施加一次（覆盖晚到的元素）。
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
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
        if let url = navigationAction.request.url, allowMouseInteraction {
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
