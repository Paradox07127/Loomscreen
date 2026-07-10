import AppKit
import LiveWallpaperCore
import WebKit

/// Weak bridge between `WKUserContentController` (which retains its message
/// handlers) and the view, so the standard controller→handler→view retain
/// cycle can't pin the view alive after teardown.
private final class MonitorBridgeProxy: NSObject, WKScriptMessageHandler {
    weak var target: MonitorWallpaperView?

    func setTarget(_ target: MonitorWallpaperView?) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.handleBridgeMessage(message)
    }
}

/// Desktop wallpaper host for the bundled first-party monitor dashboard.
///
/// Unlike `HTMLWallpaperView` (which renders arbitrary user HTML with NO Swift
/// bridge), this view renders a TRUSTED app-owned page and therefore installs a
/// single `WKScriptMessageHandler` named `monitorBridge`. It loads only the
/// bundled `dashboard.html` (no custom scheme handler, no folder access) and a
/// navigation policy cancels anything that isn't that file URL / `about:blank`.
///
/// Data flow: after the page posts `{type:"ready"}`, a pump ticking at the
/// configured refresh rate pulls the newest `MonitorSnapshot` from the shared
/// `MonitorRuntime` broker and pushes it via `window.__monitorPush(<json>)`.
@MainActor
final class MonitorWallpaperView: NSView, WallpaperPerformanceConfigurable, WallpaperResourceCleanable {

    private static let bridgeName = "monitorBridge"
    private let webView: WKWebView
    private let bridgeProxy: MonitorBridgeProxy
    private let configuration: MonitorWallpaperConfiguration
    /// Whether the injected feature catalog unlocks the AI-agent modules. When
    /// false, `agents`/`usage` are hard-gated off regardless of the config.
    private let agentFleetEnabled: Bool

    /// Mirrors `configuration.mouseInteractionEnabled`; when false the wallpaper
    /// stays click-through (matching `HTMLWallpaperView`). The window's own
    /// `ignoresMouseEvents` is set alongside this in `makeMonitorSession`, so
    /// both the window pass-through and this view's `hitTest` agree.
    private var allowMouseInteraction: Bool

    /// The only URL the web content is ever allowed to sit at.
    private var allowedFileURL: URL?
    private var didLoadDashboard = false

    /// Data pump. `nil` while suspended / torn down / before the page is ready.
    private var pumpTask: Task<Void, Never>?
    private var lastGeneration: UInt64 = 0
    private var isReady = false
    private var isSuspended = false
    private var isCleaningUp = false
    /// True once we have issued a matching `MonitorRuntime.acquire` we still owe
    /// a `release` for. Consumed by whichever teardown path runs first
    /// (`cleanup()` or `deinit`) so the shared runtime is released exactly once.
    private var owesRuntimeRelease = false
    /// Identifies this view's runtime lease; the runtime tolerates the release
    /// task overtaking the acquire task as long as both carry this ID.
    private let runtimeLeaseID = UUID()

    /// Dark fallback shown when the bundled dashboard resource can't be found,
    /// so the wallpaper never flashes white.
    private let fallbackLayerView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 1).cgColor
        view.isHidden = true
        return view
    }()

    init(
        frame frameRect: NSRect,
        configuration: MonitorWallpaperConfiguration,
        agentFleetEnabled: Bool
    ) {
        self.configuration = configuration
        self.agentFleetEnabled = agentFleetEnabled
        self.allowMouseInteraction = configuration.mouseInteractionEnabled

        let webConfig = WKWebViewConfiguration()
        webConfig.websiteDataStore = .nonPersistent()
        webConfig.mediaTypesRequiringUserActionForPlayback = []
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        webConfig.defaultWebpagePreferences = preferences

        webView = WKWebView(frame: NSRect(origin: .zero, size: frameRect.size), configuration: webConfig)
        bridgeProxy = MonitorBridgeProxy()

        super.init(frame: frameRect)
        bridgeProxy.setTarget(self)

        configureWebView()
        addSubview(fallbackLayerView)
        fallbackLayerView.frame = bounds
        fallbackLayerView.autoresizingMask = [.width, .height]

        loadDashboard()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        // Balance the runtime acquire even if `cleanup()` was never called
        // (defensive; the session normally calls it). Security scopes are owned
        // by the runtime, not this view.
        pumpTask?.cancel()
        let stillOwesRelease = owesRuntimeRelease
        let leaseID = runtimeLeaseID
        if stillOwesRelease {
            Task { await MonitorRuntime.shared.release(leaseID: leaseID) }
        }
    }

    // MARK: - Setup

    private func configureWebView() {
        webView.wantsLayer = true
        webView.layer?.backgroundColor = NSColor.clear.cgColor
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.navigationDelegate = self
        webView.autoresizingMask = [.width, .height]

        let controller = webView.configuration.userContentController
        controller.add(bridgeProxy, name: Self.bridgeName)

        addSubview(webView)
    }

    private func loadDashboard() {
        guard let url = Bundle.main.url(forResource: "dashboard", withExtension: "html", subdirectory: "MonitorDashboard")
            ?? Bundle.main.url(forResource: "dashboard", withExtension: "html") else {
            Logger.error("Monitor dashboard.html missing from bundle; showing fallback", category: .general)
            fallbackLayerView.isHidden = false
            webView.isHidden = true
            return
        }
        allowedFileURL = url.standardizedFileURL
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        didLoadDashboard = true

        // Acquire the shared pipeline immediately so data is warm by the time
        // the page signals ready.
        MonitorSourceRegistration.registerDefaultFactories()
        let options = makeRuntimeOptions()
        owesRuntimeRelease = true
        let leaseID = runtimeLeaseID
        Task { await MonitorRuntime.shared.acquire(leaseID: leaseID, options: options) }
    }

    // MARK: - Runtime options

    private func makeRuntimeOptions() -> MonitorRuntimeOptions {
        let agents = configuration.agentsEnabled && agentFleetEnabled
        let usage = configuration.usageEnabled && agentFleetEnabled
        // Roots stay nil here: the runtime resolves the security-scoped grants
        // itself so scope lifetime matches pipeline (not view) lifetime.
        return MonitorRuntimeOptions(
            system: configuration.systemEnabled,
            agents: agents,
            usage: usage,
            topProcesses: configuration.showTopProcesses
        )
    }

    // MARK: - Bridge

    func handleBridgeMessage(_ message: WKScriptMessage) {
        guard message.name == Self.bridgeName else { return }
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        switch type {
        case "ready":
            isReady = true
            pushConfig()
            pushLatestSnapshot(force: true)
            startPump()
        case "focusSession":
            let id = (body["id"] as? String) ?? "<unknown>"
            Logger.info("Monitor: focusSession requested", category: .general)
            if let sessionID = body["id"] as? String {
                MonitorFocusRouter.focus(sessionID: sessionID)
            }
        default:
            break
        }
    }

    private func pushConfig() {
        var modules: [String: Bool] = ["system": configuration.systemEnabled]
        // Advertise agent/usage modules only when actually unlocked so the page
        // picks the SYSTEM HERO layout for Lite users.
        modules["agents"] = configuration.agentsEnabled && agentFleetEnabled
        modules["usage"] = configuration.usageEnabled && agentFleetEnabled

        let payload: [String: Any] = [
            "locale": Self.currentLocaleIdentifier(),
            "reduceMotion": Self.systemReduceMotion(),
            "modules": modules,
            "refreshHz": MonitorWallpaperConfiguration.clampedRefreshHz(configuration.refreshHz)
        ]
        guard let json = Self.jsonString(from: payload) else { return }
        webView.evaluateJavaScript("window.__monitorConfig(\(json))", completionHandler: nil)
    }

    /// Pushes the newest snapshot when it is newer than the last one we sent.
    /// `force` re-sends the current newest even if the generation is unchanged
    /// (used right after `ready` / resume so the page paints immediately).
    private func pushLatestSnapshot(force: Bool) {
        guard isReady, !isCleaningUp else { return }
        let broker = MonitorRuntime.shared.broker
        let after = force ? 0 : lastGeneration
        guard let update = broker.latest(after: after) else { return }
        lastGeneration = update.generation
        guard let json = update.snapshot.jsonString() else { return }
        // The JSON object literal is itself a valid JS expression — no extra
        // quoting; the page accepts either a string or an object.
        webView.evaluateJavaScript("window.__monitorPush(\(json))", completionHandler: nil)
    }

    // MARK: - Data pump

    private func startPump() {
        pumpTask?.cancel()
        guard isReady, !isSuspended, !isCleaningUp else { return }
        let interval = Self.pumpInterval(forHz: configuration.refreshHz)
        pumpTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled, !self.isCleaningUp, !self.isSuspended else { return }
                self.pushLatestSnapshot(force: false)
            }
        }
    }

    private func stopPump() {
        pumpTask?.cancel()
        pumpTask = nil
    }

    private static func pumpInterval(forHz hz: Double) -> Duration {
        let clamped = MonitorWallpaperConfiguration.clampedRefreshHz(hz)
        let seconds = 1.0 / clamped
        return .milliseconds(Int((seconds * 1000).rounded()))
    }

    // MARK: - Performance profile (suspend / resume)

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        switch profile {
        case .quality:
            resume()
        case .suspended:
            suspend()
        }
    }

    private func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        stopPump()
        // Stopping the pump only halts native snapshot delivery; the page's own
        // rAF loop + CSS `infinite` animations keep waking the compositor every
        // vsync. Tell dashboard.html to park them, and suspend any media too.
        webView.setAllMediaPlaybackSuspended(true) {}
        webView.evaluateJavaScript("window.__monitorSuspend && window.__monitorSuspend()", completionHandler: nil)
    }

    private func resume() {
        guard isSuspended else { return }
        isSuspended = false
        webView.setAllMediaPlaybackSuspended(false) {}
        webView.evaluateJavaScript("window.__monitorResume && window.__monitorResume()", completionHandler: nil)
        // Force one immediate push so the desktop reflects the current state the
        // instant playback resumes, then restart the cadence.
        pushLatestSnapshot(force: true)
        startPump()
    }

    // MARK: - Hit testing

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard allowMouseInteraction else { return nil }
        return super.hitTest(point)
    }

    override func layout() {
        super.layout()
        webView.frame = bounds
        fallbackLayerView.frame = bounds
    }

    // MARK: - Cleanup

    func cleanup() {
        guard !isCleaningUp else { return }
        isCleaningUp = true
        stopPump()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.bridgeName)
        bridgeProxy.setTarget(nil)
        if owesRuntimeRelease {
            owesRuntimeRelease = false
            let leaseID = runtimeLeaseID
            Task { await MonitorRuntime.shared.release(leaseID: leaseID) }
        }
    }

    // MARK: - Helpers

    private static func currentLocaleIdentifier() -> String {
        Locale.current.identifier
    }

    private static func systemReduceMotion() -> Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private static func jsonString(from object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }
}

// MARK: - WKNavigationDelegate

extension MonitorWallpaperView: WKNavigationDelegate {
    /// Defense-in-depth for the trusted page: allow only the initial bundled
    /// file URL and `about:blank`; cancel any other navigation.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if url.absoluteString == "about:blank" {
            decisionHandler(.allow)
            return
        }
        if url.isFileURL, let allowed = allowedFileURL,
           url.standardizedFileURL == allowed {
            decisionHandler(.allow)
            return
        }
        Logger.warning("Monitor: blocked navigation to \(url.absoluteString)", category: .general)
        decisionHandler(.cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !isCleaningUp, let url = allowedFileURL else { return }
        Logger.error("Monitor: WebContent process terminated; reloading dashboard", category: .general)
        isReady = false
        stopPump()
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }
}
