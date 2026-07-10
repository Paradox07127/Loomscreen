import AppKit
import LiveWallpaperCore
import WebKit

// HTMLWebView (the context-menu-filtering WKWebView subclass) lives in
// LiveWallpaperVideoWeb — see its header for why (warn-long importer cost).

/// WKWebView-backed HTML wallpaper host.
@MainActor
final class HTMLWallpaperView: NSView, HTMLWallpaperConfigApplying {

    // MARK: - Properties
    private let webView: HTMLWebView
    private let folderHandler: FolderURLSchemeHandler
    private var allowMouseInteraction = false
    /// Re-entry guard for trackpad-gesture forwarders. When we forward
    /// `scrollWheel/swipe/magnify/rotate` to `webView`, AppKit propagates
    /// the unhandled event up through the responder chain — and our nextResponder
    /// for `webView` is `self`, which would re-invoke this override and
    /// recurse until the stack overflows (`EXC_BAD_ACCESS` in `magnify`
    /// was the first reproducer; the other three were latent).
    private var isForwardingGesture = false
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
    /// Cached schema for the active project's `project.json`. Re-read on
    /// folder swap inside `updateWallpaperEnginePropertyBridge(for:)`, so
    /// the hot apply path can re-serialize WPE property payloads without
    /// touching disk on every slider drag.
    private var wallpaperEnginePropertySchema: WallpaperEngineProjectPropertySchema?
    /// Folder the cached schema was parsed from, used to detect stale
    /// caches when the source switches.
    private var wallpaperEnginePropertySchemaFolder: URL?
    /// Current project-key bucket for WPE web user property overrides.
    private var wallpaperEngineProjectKey: String?
    private var lastSource: HTMLSource?
    /// Capped by `HTMLConfig.maxRetries`; drives exponential backoff.
    private var consecutiveFailureCount: Int = 0
    /// Generation-scoped package-index load. PKGV parsing is blocking file I/O,
    /// so folder navigation waits for the utility-queue loader instead of doing
    /// that work synchronously on MainActor.
    private var packageBackingTask: Task<Void, Never>?
    private var packageBackingGeneration: UInt64 = 0
    private var restartPackageBackingAfterResume = false
    /// Refresh/retry timing is kept outside the WebKit host so suspend can
    /// cancel all live tasks and resume from a fresh interval without catch-up.
    private lazy var reloadScheduler = HTMLReloadScheduler { [weak self] in
        self?.reloadCurrentSource()
    }
    private var isCleaningUp = false
    private var mediaPlaybackSuspended = false
    /// Observer token for `Notification.Name.developerModeDidChange`.
    /// Held so live HTML wallpapers can flip `WKWebView.isInspectable` in
    /// place without rebuilding the session. Removed in `cleanup()` and
    /// `deinit` so the closure can't outlive the view.
    /// `nonisolated(unsafe)` mirrors the `AppDelegate.showOnboardingObserver`
    /// pattern so the deinit can release it from any thread. Compile-gated
    /// out of Lite — Lite forces `isInspectable = false` and never reads
    /// the persisted toggle, so an imported settings bundle cannot smuggle
    /// the Web Inspector into the Lite runtime.
    #if !LITE_BUILD
    nonisolated(unsafe) private var developerModeObserver: NSObjectProtocol?
    #endif
    /// Tracks the directory the current source is allowed to read from when
    /// it is local (`.file` / `.folder`). Remote (`.url`) and `.inline`
    /// sources leave this nil so the navigation policy can deny `file://`
    /// requests originating from untrusted content.
    private var currentLocalReadAccessRoot: URL?
    /// The wallpaper's declared origin when the active source is a remote
    /// `.url` (nil for `.file` / `.folder` / `.inline`). The navigation policy
    /// uses it to allow same-host scripted redirects for remote wallpapers
    /// while denying any external `.other` navigation for local/inline ones.
    private var currentRemoteSourceOrigin: URL?

    /// Snapshot overlay shown on top of the WKWebView while suspended, so
    /// the desktop keeps a static last-frame image even though the
    /// renderer is fully paused. Hidden under normal playback.
    private let snapshotOverlay: NSImageView = {
        let view = NSImageView()
        view.imageScaling = .scaleAxesIndependently
        view.imageAlignment = .alignCenter
        view.isHidden = true
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        return view
    }()
    /// Generation counter for snapshot capture — async snapshot replies
    /// older than the latest profile-flip request are discarded so a stale
    /// `webView.takeSnapshot` callback can't overwrite a fresh resume.
    private var snapshotGeneration: UInt64 = 0
    /// Observer token for `ProcessInfo.thermalStateDidChangeNotification`.
    /// HTMLWallpaperView subscribes directly so it can drive the RAF
    /// throttle on `.fair` independently of the global suspend/quality
    /// signal that ScreenManager pushes through the runtime session.
    nonisolated(unsafe) private var thermalObserver: NSObjectProtocol?
    /// Last RAF throttle ratio pushed into the page. Tracked so a no-op
    /// thermal-change notification doesn't re-issue redundant JS.
    private var lastRafThrottleRatio: Int = 1

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
        snapshotOverlay.frame = bounds
        snapshotOverlay.autoresizingMask = [.width, .height]
        addSubview(snapshotOverlay)
        #if !LITE_BUILD
        startObservingDeveloperMode()
        #endif
        startObservingThermalState()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        packageBackingTask?.cancel()
        let url = activeSecurityScopedURL
        if let url {
            Task { @MainActor in
                url.stopAccessingSecurityScopedResource()
            }
        }
        #if !LITE_BUILD
        if let token = developerModeObserver {
            NotificationCenter.default.removeObserver(token)
        }
        #endif
        if let token = thermalObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - Configuration

    private func configureWebView() {
        webView.wantsLayer = true
        webView.layer?.backgroundColor = NSColor.clear.cgColor
        webView.setValue(false, forKey: "drawsBackground")

        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false

        applyDeveloperMode(currentDeveloperModeEnabled())

        installBaselineUserScripts(for: nil)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.autoresizingMask = [.width, .height]
    }

    #if !LITE_BUILD
    /// Flips `isInspectable` on the live view without rebuilding the session
    /// (WebKit allows it), so a Settings toggle takes effect immediately.
    private func startObservingDeveloperMode() {
        developerModeObserver = NotificationCenter.default.addObserver(
            forName: .developerModeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isCleaningUp else { return }
                self.applyDeveloperMode(self.currentDeveloperModeEnabled())
            }
        }
    }
    #endif

    /// Reads the persisted Developer Mode flag in Pro; always returns
    /// `false` in Lite so an imported settings bundle can never smuggle
    /// the Web Inspector into the lightweight runtime.
    private func currentDeveloperModeEnabled() -> Bool {
        #if DEBUG && !LITE_BUILD
        return SettingsManager.shared.loadGlobalSettings().developerModeEnabled
        #else
        return false
        #endif
    }

    /// Web Inspector is a DEBUG-only affordance: Release and Lite pin
    /// `isInspectable` to `false` regardless of the requested state or any
    /// persisted/imported Developer Mode flag.
    func applyDeveloperMode(_ enabled: Bool) {
        if #available(macOS 13.3, *) {
            #if DEBUG && !LITE_BUILD
            webView.isInspectable = enabled
            #else
            webView.isInspectable = false
            #endif
        }
    }

    /// Idempotent: every injected script guards with a `window.__lw…Installed__`
    /// sentinel so re-installation on the same page is a no-op.
    private func installBaselineUserScripts(for config: HTMLConfig?) {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()

        let baseline = makeBaselineScript(for: config)
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

    private func makeBaselineScript(for config: HTMLConfig?) -> String {
        let cssLiteral = jsStringLiteral(config?.customCSS ?? "")
        let isBrowsing = (config?.allowMouseInteraction ?? false) ? "true" : "false"
        let physicalPixel = config?.physicalPixelLayout ?? false
        let physicalPixelBootstrap = physicalPixel
            ? HTMLWallpaperRuntimeScript.physicalPixelState(
                enabled: true,
                backingScale: effectiveBackingScaleFactor
            )
            : ""
        let canvasUpgrader = physicalPixel
            ? HTMLWallpaperRuntimeScript.canvasBackingStoreUpgrader()
            : ""
        let cspInjection = (config?.cspEnforcementEnabled ?? false)
            ? HTMLWallpaperRuntimeScript.cspInjection()
            : ""

        let audioController = HTMLWallpaperRuntimeScript.masterAudioController(
            initialVolume: config?.audioVolume ?? 1.0,
            initialMuted: config?.muteAudio ?? false
        )
        let transformController = HTMLWallpaperRuntimeScript.transformController(
            scale: config?.transformScale ?? 1.0,
            translateX: config?.transformTranslateX ?? 0,
            translateY: config?.transformTranslateY ?? 0,
            rotation: config?.transformRotationDegrees ?? 0
        )

        let msaaForcer = HTMLWallpaperRuntimeScript.gpuCanvasMSAAForcer()
        let lifecycle = HTMLWallpaperRuntimeScript.lifecycleController(
            aggressiveSuspend: config?.aggressiveSuspend ?? false
        )

        return """
        \(cspInjection)
        \(msaaForcer)
        \(lifecycle)
        (function () {
            \(physicalPixelBootstrap)
            \(canvasUpgrader)

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
            // <head> may not be ready at documentStart — fall back to a
            // MutationObserver that re-runs once it appears.
            if (!document.head) {
                var mo = new MutationObserver(function () {
                    if (document.head) { bootstrap(); mo.disconnect(); }
                });
                mo.observe(document.documentElement, { childList: true });
            }
        })();
        \(audioController)
        \(transformController)
        """
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

        // `webView.scrollWheel(with:)` forwarding was unreliable at our
        // wallpaper window level (events sometimes never reach WKWebView's
        // internal scroller, and when WKWebView bubbled the unhandled event
        // back up the responder chain it landed on this very override —
        // the source of the `magnify` stack overflow we just fixed).
        //
        // Drive the document scroll through JavaScript instead: it works
        // regardless of how the event was hit-tested, requires no responder
        // dance, and matches the user's natural-scroll direction.
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1.0 : 40.0
        let dx = -Double(event.scrollingDeltaX * scale)
        let dy = -Double(event.scrollingDeltaY * scale)
        guard abs(dx) > 0.1 || abs(dy) > 0.1 else { return }
        let dxLit = HTMLWallpaperRuntimeScript.jsNumber(dx)
        let dyLit = HTMLWallpaperRuntimeScript.jsNumber(dy)
        webView.evaluateJavaScript(
            "window.scrollBy(\(dxLit), \(dyLit));",
            completionHandler: nil
        )
    }

    override func swipe(with event: NSEvent) {
        guard allowMouseInteraction, !isForwardingGesture else {
            super.swipe(with: event)
            return
        }
        isForwardingGesture = true
        defer { isForwardingGesture = false }
        webView.swipe(with: event)
    }

    override func magnify(with event: NSEvent) {
        guard allowMouseInteraction, !isForwardingGesture else {
            super.magnify(with: event)
            return
        }
        isForwardingGesture = true
        defer { isForwardingGesture = false }
        webView.magnify(with: event)
    }

    override func rotate(with event: NSEvent) {
        guard allowMouseInteraction, !isForwardingGesture else {
            super.rotate(with: event)
            return
        }
        isForwardingGesture = true
        defer { isForwardingGesture = false }
        webView.rotate(with: event)
    }

    // MARK: - Public API

    func apply(_ config: HTMLConfig) {
        pendingEphemeral = config.requiresEphemeralStorage
        if let previous = lastAppliedConfig, previous == config {
            return
        }

        let previous = lastAppliedConfig

        // Origin downgrade (workshopImport → userLocal) cannot be hot-swapped
        // because `WKWebsiteDataStore` is locked at WKWebView init. The
        // session coordinator is supposed to tear down and rebuild the view
        // when origin changes — surface the breach loudly so the bad path
        // doesn't ship silently. `assertionFailure` in debug; a structured
        // warning in release.
        if let previous, previous.originKind != config.originKind {
            let message = "HTMLWallpaperView.apply called across an originKind change (\(previous.originKind.rawValue) → \(config.originKind.rawValue)); the session must be torn down instead of hot-swapped."
            assertionFailure(message)
            Logger.error(message, category: .screenManager)
        }

        webView.configuration.defaultWebpagePreferences.allowsContentJavaScript = config.allowJavaScript
        allowMouseInteraction = config.allowMouseInteraction
        // Same opt-in flag as the script-side CSP meta tag: folder/WPE scheme
        // responses carry the CSP header only when enforcement is enabled.
        // A flip lands in `needsDocumentStartReload` below, so the reloaded
        // page's requests observe the new value.
        folderHandler.cspEnforcementEnabled = config.cspEnforcementEnabled

        if currentDataStoreIsEphemeral != pendingEphemeral {
            let requested = pendingEphemeral ? "ephemeral" : "persistent"
            let active = currentDataStoreIsEphemeral ? "ephemeral" : "persistent"
            let reason = config.originKind == .workshopImport
                ? "Workshop content requires ephemeral storage"
                : "user toggled the ephemeral storage preference"
            Logger.warning(
                "HTML wallpaper requested \(requested) storage (\(reason)) but the live WKWebView still uses the \(active) data store; the change applies on next session rebuild.",
                category: .screenManager
            )
        }

        applyRuntimeState(previous: previous, current: config)

        if wallpaperEnginePropertySchema != nil {
            let previousProjectOverrides = previous?.projectWallpaperEngineProperties(
                forProjectKey: wallpaperEngineProjectKey
            ) ?? [:]
            let currentProjectOverrides = config.projectWallpaperEngineProperties(
                forProjectKey: wallpaperEngineProjectKey
            )
            if previous?.muteAudio != config.muteAudio
                || previous?.audioVolume != config.audioVolume
                || previousProjectOverrides != currentProjectOverrides {
                updateWallpaperEnginePropertyBridge(
                    for: wallpaperEnginePropertySchemaFolder,
                    config: config
                )
            }
        }

        let needsScriptRebuild = (previous?.customCSS != config.customCSS)
            || (previous?.allowMouseInteraction != config.allowMouseInteraction)
            || (previous?.allowJavaScript != config.allowJavaScript)
            || (previous?.requiresEphemeralStorage != config.requiresEphemeralStorage)
            || (previous?.physicalPixelLayout != config.physicalPixelLayout)
            || (previous?.cspEnforcementEnabled != config.cspEnforcementEnabled)
            || (previous?.aggressiveSuspend != config.aggressiveSuspend)

        if needsScriptRebuild {
            installBaselineUserScripts(for: config)
        }

        if previous?.blockTrackers != config.blockTrackers {
            applyTrackerBlocking(enabled: config.blockTrackers)
        }

        if previous?.refreshIntervalSeconds != config.refreshIntervalSeconds {
            applyRefreshInterval(config.refreshIntervalSeconds)
        }

        if config.allowMouseInteraction, let host = webView.window {
            host.makeFirstResponder(webView)
        }

        let needsDocumentStartReload = previous != nil && (
            previous?.physicalPixelLayout != config.physicalPixelLayout
            || previous?.cspEnforcementEnabled != config.cspEnforcementEnabled
            || previous?.aggressiveSuspend != config.aggressiveSuspend
        )
        lastAppliedConfig = config

        if needsDocumentStartReload {
            // documentStart-only hooks (canvas upgrader, CSP meta tag,
            // GPU-context release plumbing) cannot be retro-installed on
            // a page that's already running. Reload so the freshly
            // re-registered user scripts execute against a clean DOM.
            reloadCurrentSource()
        }
    }

    func applyHTMLConfig(_ config: HTMLConfig) -> Bool {
        if currentDataStoreIsEphemeral != config.requiresEphemeralStorage {
            return false
        }
        if let previous = lastAppliedConfig,
           previous.requiresEphemeralStorage != config.requiresEphemeralStorage {
            return false
        }
        // Workshop content cannot transition into a session that wasn't
        // built ephemeral; the data store is locked at init. Force a rebuild.
        if let previous = lastAppliedConfig, previous.originKind != config.originKind {
            return false
        }
        apply(config)
        return true
    }

    func captureLivePreviewSnapshot(maxWidth: CGFloat = 960) async -> NSImage? {
        if !snapshotOverlay.isHidden, let image = snapshotOverlay.image {
            return image
        }

        let snapshotBounds = webView.bounds
        guard snapshotBounds.width > 0, snapshotBounds.height > 0 else { return nil }

        let snapshotConfig = WKSnapshotConfiguration()
        snapshotConfig.rect = snapshotBounds
        snapshotConfig.snapshotWidth = NSNumber(value: Double(min(maxWidth, snapshotBounds.width)))
        snapshotConfig.afterScreenUpdates = false

        return await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: snapshotConfig) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    /// 当前页面已经渲染时的热更新路径：直接改 DOM，不动 user script。
    private func applyRuntimeState(previous: HTMLConfig?, current: HTMLConfig) {
        var statements: [String] = []
        let audioChanged = previous?.muteAudio != current.muteAudio
            || previous?.audioVolume != current.audioVolume
        let previousProjectOverrides = previous?.projectWallpaperEngineProperties(
            forProjectKey: wallpaperEngineProjectKey
        ) ?? [:]
        let currentProjectOverrides = current.projectWallpaperEngineProperties(
            forProjectKey: wallpaperEngineProjectKey
        )
        let projectOverridesChanged = previousProjectOverrides != currentProjectOverrides

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

        if audioChanged {
            let volumeLiteral = HTMLWallpaperRuntimeScript.jsNumber(current.audioVolume)
            let mutedLiteral = current.muteAudio ? "true" : "false"
            statements.append("""
            if (typeof window.__lwUpdateAudio__ === 'function') { window.__lwUpdateAudio__(\(volumeLiteral), \(mutedLiteral)); }
            """)
        }

        if previous?.transformScale != current.transformScale
            || previous?.transformTranslateX != current.transformTranslateX
            || previous?.transformTranslateY != current.transformTranslateY
            || previous?.transformRotationDegrees != current.transformRotationDegrees {
            let scaleLiteral = HTMLWallpaperRuntimeScript.jsNumber(current.transformScale)
            let txLiteral = HTMLWallpaperRuntimeScript.jsNumber(current.transformTranslateX)
            let tyLiteral = HTMLWallpaperRuntimeScript.jsNumber(current.transformTranslateY)
            let rLiteral = HTMLWallpaperRuntimeScript.jsNumber(current.transformRotationDegrees)
            statements.append("""
            if (typeof window.__lwUpdateTransform__ === 'function') { window.__lwUpdateTransform__(\(scaleLiteral), \(txLiteral), \(tyLiteral), \(rLiteral)); }
            """)
        }

        if projectOverridesChanged,
           let schema = wallpaperEnginePropertySchema,
           let script = WallpaperEngineWebPropertyBridge.applyScript(
               schema: schema,
               previousOverrides: previousProjectOverrides,
               overrides: currentProjectOverrides
        ) {
            statements.append(script)
        }
        if (audioChanged || (projectOverridesChanged && (current.muteAudio || current.audioVolume < 0.999))),
           let script = wallpaperEngineAudioControlScript(for: current) {
            statements.append(script)
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

    // MARK: - Auto-Refresh

    /// Each tick adds ±10% jitter to the wait duration so multiple screens
    /// configured with the same refresh interval don't reload in lockstep —
    /// useful for dashboard-style wallpapers that hit a single API.
    private func applyRefreshInterval(_ seconds: Int) {
        guard !isCleaningUp else { return }
        reloadScheduler.setRefreshInterval(seconds: TimeInterval(seconds))
    }

    func loadSource(_ source: HTMLSource) {
        loadSource(source, resetFailureCount: true)
    }

    /// Internal entry point distinguishing user-driven loads (which reset the retry budget) from `scheduleRetry` continuations (which keep the counter so backoff progresses).
    private func loadSource(_ source: HTMLSource, resetFailureCount: Bool) {
        packageBackingTask?.cancel()
        packageBackingTask = nil
        packageBackingGeneration &+= 1
        let packageGeneration = packageBackingGeneration
        lastSource = source
        wallpaperEngineProjectKey = WallpaperEngineProjectIdentity.key(source: source)
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
            let readRoot = Self.readAccessRoot(forFileURL: url)
            currentLocalReadAccessRoot = readRoot
            currentRemoteSourceOrigin = nil
            webView.loadFileURL(url, allowingReadAccessTo: readRoot)
        case .folder(let bookmarkData, let indexFileName):
            guard let folderURL = HTMLWallpaperView.resolveBookmark(bookmarkData) else {
                reportError(.sandboxRevoked)
                return
            }
            activeSecurityScopedURL = folderURL
            currentLocalReadAccessRoot = folderURL
            currentRemoteSourceOrigin = nil
            updateWallpaperEnginePropertyBridge(for: folderURL)
            folderHandler.folderURL = folderURL
            // In-place package serving: when the source folder holds a
            // `scene.pkg`, the handler reads web assets straight from it
            // (loose siblings like `project.json` still fall back to the
            // folder). Must be set after `folderURL` (which clears it).
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
            let request = URLRequest(url: url)
            let pkgURL = folderURL.appendingPathComponent("scene.pkg")
            guard FileManager.default.fileExists(atPath: pkgURL.path) else {
                webView.load(request)
                return
            }
            guard !mediaPlaybackSuspended else {
                restartPackageBackingAfterResume = true
                return
            }

            packageBackingTask = Task { [weak self] in
                let backing: FolderURLSchemeHandler.PackageBacking?
                do {
                    backing = try await Self.packageBacking(forPackageURL: pkgURL)
                } catch is CancellationError {
                    return
                } catch {
                    let reasonCode = (error as? WPEPackageError)?.stableReasonCode
                        ?? "PKG_INDEX_LOAD_FAILED"
                    Logger.info(
                        "HTML folder load: scene.pkg rejected [\(reasonCode)] — serving loose files only",
                        category: .screenManager
                    )
                    backing = nil
                }
                guard !Task.isCancelled,
                      let self,
                      !self.isCleaningUp,
                      self.packageBackingGeneration == packageGeneration,
                      self.folderHandler.folderURL == folderURL else { return }
                self.packageBackingTask = nil
                self.folderHandler.setPackageBacking(backing)
                self.webView.load(request)
            }
        case .url(let url):
            guard HTMLWallpaperView.isAllowedRemoteURL(url) else { return }
            currentLocalReadAccessRoot = nil
            currentRemoteSourceOrigin = url
            webView.load(URLRequest(url: url))
        case .inline(let html):
            currentLocalReadAccessRoot = nil
            currentRemoteSourceOrigin = nil
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    /// Parses a known in-place `scene.pkg` on the utility loader so the scheme
    /// handler can serve web assets directly from it. The caller maps a typed
    /// rejection to loose-file fallback. Cost scales with bounded index fields,
    /// not payload size, and cancellation closes the prepared handle.
    private static func packageBacking(
        forPackageURL pkgURL: URL
    ) async throws -> FolderURLSchemeHandler.PackageBacking {
        let prepared = try await WPEPackageIndexLoader.load(from: pkgURL)
        defer { try? prepared.handle.close() }
        try Task.checkCancellation()
        return FolderURLSchemeHandler.PackageBacking(url: pkgURL, package: prepared.package)
    }

    private func updateWallpaperEnginePropertyBridge(for folderURL: URL?, config: HTMLConfig? = nil) {
        // Re-parse the manifest only when the active folder actually
        // changes; subsequent override edits reuse the cached schema and
        // hit zero disk I/O on the runtime apply path.
        if folderURL != wallpaperEnginePropertySchemaFolder {
            wallpaperEnginePropertySchemaFolder = folderURL
            wallpaperEnginePropertySchema = folderURL.flatMap {
                WallpaperEngineWebPropertyBridge.parseSchema(forFolder: $0)
            }
        }

        let activeConfig = config ?? lastAppliedConfig
        let nextScript: String? = {
            guard let schema = wallpaperEnginePropertySchema else { return nil }
            var overrides = activeConfig?.projectWallpaperEngineProperties(
                forProjectKey: wallpaperEngineProjectKey
            ) ?? [:]
            if let activeConfig {
                overrides.merge(WallpaperEngineWebPropertyBridge.audioBootstrapOverrides(
                    schema: schema,
                    projectOverrides: overrides,
                    volume: activeConfig.audioVolume,
                    muted: activeConfig.muteAudio
                )) { _, audioOverride in audioOverride }
            }
            return WallpaperEngineWebPropertyBridge.bootstrapScript(
                schema: schema,
                overrides: overrides
            )
        }()
        guard wallpaperEnginePropertyBootstrapScript != nextScript else { return }
        wallpaperEnginePropertyBootstrapScript = nextScript
        installBaselineUserScripts(for: activeConfig)
    }

    private func wallpaperEngineAudioControlScript(for config: HTMLConfig?) -> String? {
        guard let config,
              let schema = wallpaperEnginePropertySchema else { return nil }
        return WallpaperEngineWebPropertyBridge.audioControlScript(
            schema: schema,
            projectOverrides: config.projectWallpaperEngineProperties(
                forProjectKey: wallpaperEngineProjectKey
            ),
            volume: config.audioVolume,
            muted: config.muteAudio
        )
    }

    func reloadCurrentSource() {
        guard let lastSource else { return }
        loadSource(lastSource, resetFailureCount: false)
    }

    private func stopActiveSecurityScope() {
        activeSecurityScopedURL?.stopAccessingSecurityScopedResource()
        activeSecurityScopedURL = nil
        currentLocalReadAccessRoot = nil
        currentRemoteSourceOrigin = nil
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

    /// Result of evaluating a `WKNavigationAction` against the current source's
    /// access policy. Side-effects (`NSWorkspace.shared.open`) are reified into
    /// `.openExternally` so `decidePolicyFor` stays a pure dispatcher.
    enum NavigationDecision: Equatable {
        case allow
        case cancel
        case openExternally(URL)
    }

    /// Returns true when `url` is a file URL whose standardized path is
    /// contained inside `root` (also standardized). Used to keep local
    /// wallpapers from escaping their granted directory via `../` traversal
    /// or symlinks.
    nonisolated static func fileURL(_ url: URL, isContainedIn root: URL?) -> Bool {
        guard let root, url.isFileURL, root.isFileURL else { return false }
        let target = url.resolvingSymlinksInPath().standardizedFileURL.path
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let normalizedBase = base.hasSuffix("/") ? base : base + "/"
        return target == base || target.hasPrefix(normalizedBase)
    }

    /// Pure navigation policy used by `decidePolicyFor`. Remote and inline
    /// sources can never navigate to `file://`; local sources may, but only
    /// inside their granted read root.
    ///
    /// `remoteSourceOrigin` is the wallpaper's declared origin when the source
    /// is a remote `.url` (nil for local `.file`/`.folder`/`.inline`). It gates
    /// script-driven main-frame navigations (`.other`/`.reload`, e.g.
    /// `location.href = …`): a remote wallpaper is already a user-chosen web
    /// origin and may follow only redirects/navigation that preserve its exact
    /// scheme, host, and effective port. Local/inline content may never silently
    /// swap itself out for an external `http(s)` page.
    nonisolated static func navigationDecision(
        for url: URL?,
        navigationType: WKNavigationType,
        currentURL: URL?,
        allowMouseInteraction: Bool,
        localReadAccessRoot: URL?,
        remoteSourceOrigin: URL? = nil
    ) -> NavigationDecision {
        switch navigationType {
        case .other, .reload:
            guard let url else { return .cancel }
            if url.isFileURL {
                return fileURL(url, isContainedIn: localReadAccessRoot) ? .allow : .cancel
            }
            if url.scheme?.lowercased() == FolderURLSchemeHandler.scheme { return .allow }
            if isAllowedRemoteURL(url) {
                if let remoteSourceOrigin {
                    return isSameOrigin(
                        navigationURL: url,
                        current: remoteSourceOrigin
                    ) ? .allow : .cancel
                }
                return isSameOrigin(navigationURL: url, current: currentURL) ? .allow : .cancel
            }
            return .cancel

        case .linkActivated:
            guard allowMouseInteraction, let url else { return .cancel }
            if url.isFileURL {
                return fileURL(url, isContainedIn: localReadAccessRoot) ? .allow : .cancel
            }
            if isSameOrigin(navigationURL: url, current: currentURL) { return .allow }
            if isExternallyOpenableURL(url) { return .openExternally(url) }
            return .cancel

        case .formSubmitted, .backForward, .formResubmitted:
            return .cancel

        @unknown default:
            return .cancel
        }
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

    /// Suspends or resumes the page's render loop, JS RAF, CSS animations,
    /// Web Audio graphs, and `<audio>/<video>` playback.
    ///
    /// On suspend we kick three independent mechanisms in sequence so the
    /// page actually stops consuming CPU/GPU instead of just freezing the
    /// `<video>` track:
    /// 1. `webView.setAllMediaPlaybackSuspended(true)` — native API,
    ///    handles `<audio>` / `<video>` elements.
    /// 2. `__lwSuspend__()` — JS-side page-lifecycle controller (see
    ///    `HTMLWallpaperRuntimeScript.lifecycleController`).
    /// 3. Snapshot-on-pause — capture the last frame and hang it over the
    ///    WKWebView so WebKit can park the compositor.
    ///
    /// Resume reverses the order. Idempotent on repeat calls.
    private func setMediaPlaybackSuspended(_ suspended: Bool) {
        guard !isCleaningUp else { return }
        guard mediaPlaybackSuspended != suspended else { return }
        mediaPlaybackSuspended = suspended
        reloadScheduler.setSuspended(suspended)
        if suspended {
            if packageBackingTask != nil {
                packageBackingGeneration &+= 1
                packageBackingTask?.cancel()
                packageBackingTask = nil
                restartPackageBackingAfterResume = true
            }
            invokeLifecycleHook(.suspend)
            webView.setAllMediaPlaybackSuspended(true) {}
            captureSuspendSnapshot()
            notifyWallpaperEngineGeneralProperties(fps: 1)
        } else {
            hideSnapshotOverlay()
            webView.setAllMediaPlaybackSuspended(false) {}
            invokeLifecycleHook(.resume)
            notifyWallpaperEngineGeneralProperties(fps: 60)
            // Re-push the throttle ratio in case thermals shifted while suspended.
            applyRafThrottleRatio(rafThrottleRatio(for: ProcessInfo.processInfo.thermalState))
            if restartPackageBackingAfterResume {
                restartPackageBackingAfterResume = false
                reloadCurrentSource()
            }
        }
    }

    private enum LifecycleHook: String {
        case suspend = "__lwSuspend__"
        case resume = "__lwResume__"
    }

    private func invokeLifecycleHook(_ hook: LifecycleHook) {
        webView.evaluateJavaScript(
            "if (typeof window.\(hook.rawValue) === 'function') { try { window.\(hook.rawValue)(); } catch (e) {} }",
            completionHandler: nil
        )
    }

    private func notifyWallpaperEngineGeneralProperties(fps: Int) {
        webView.evaluateJavaScript(
            HTMLWallpaperRuntimeScript.wallpaperEngineGeneralProperties(fps: fps),
            completionHandler: nil
        )
    }

    // MARK: - Snapshot Overlay

    /// Upper bound on the suspend-snapshot bitmap width in pixels. The overlay
    /// only shows a static last-frame stretched to the view's point size, so
    /// there's no visible gain in retaining a full backing-pixel capture — on a
    /// 5K panel that would be a ~50 MB `NSImage` held per suspended screen,
    /// working against the very memory-relief the suspend is meant to provide.
    private static let maxSuspendSnapshotWidth: CGFloat = 1920

    /// Hides the webView behind the snapshot so WebKit can stop updating the
    /// compositor surface. Generation-counted to discard stale captures that
    /// arrive after a resume.
    private func captureSuspendSnapshot() {
        snapshotGeneration &+= 1
        let generation = snapshotGeneration
        let snapshotConfig = WKSnapshotConfiguration()
        snapshotConfig.afterScreenUpdates = false
        // Cap the capture to point-width (downsampled from backing pixels) and
        // an absolute ceiling so multiple high-DPI screens can't each pin a
        // full-resolution bitmap while suspended.
        let pointWidth = webView.bounds.width
        if pointWidth > 0 {
            snapshotConfig.snapshotWidth = NSNumber(
                value: Double(min(pointWidth, Self.maxSuspendSnapshotWidth))
            )
        }
        webView.takeSnapshot(with: snapshotConfig) { [weak self] image, _ in
            Task { @MainActor [weak self] in
                guard let self,
                      !self.isCleaningUp,
                      self.mediaPlaybackSuspended,
                      self.snapshotGeneration == generation,
                      let image else { return }
                self.applySnapshotOverlay(image: image)
            }
        }
    }

    private func applySnapshotOverlay(image: NSImage) {
        snapshotOverlay.image = image
        snapshotOverlay.frame = bounds
        snapshotOverlay.isHidden = false
        webView.isHidden = true
    }

    private func hideSnapshotOverlay() {
        snapshotOverlay.isHidden = true
        snapshotOverlay.image = nil
        webView.isHidden = false
    }

    // MARK: - Thermal Throttle (P2)

    /// Subscribes to `ProcessInfo.thermalStateDidChangeNotification` so the
    /// HTML page can self-throttle on `.fair` without waiting for the
    /// global policy engine to push a profile change. The engine only
    /// flips between `.quality` and `.suspended`; the intermediate
    /// `.fair` tier is handled here by halving the RAF callback rate.
    private func startObservingThermalState() {
        let token = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.applyRafThrottleRatio(self.rafThrottleRatio(for: ProcessInfo.processInfo.thermalState))
            }
        }
        thermalObserver = token
    }

    private func rafThrottleRatio(for thermalState: ProcessInfo.ThermalState) -> Int {
        switch thermalState {
        case .nominal:  return 1
        case .fair:     return 2
        case .serious, .critical: return 1 // engine already suspended the page
        @unknown default: return 1
        }
    }

    private func applyRafThrottleRatio(_ ratio: Int) {
        guard !isCleaningUp else { return }
        guard ratio != lastRafThrottleRatio else { return }
        lastRafThrottleRatio = ratio
        let literal = String(ratio)
        webView.evaluateJavaScript(
            "if (typeof window.__lwSetRafThrottle__ === 'function') { try { window.__lwSetRafThrottle__(\(literal)); } catch (e) {} }",
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
        reloadScheduler.scheduleRetry(after: delaySeconds)
    }

    private func resetNavigationFailureState() {
        consecutiveFailureCount = 0
        reloadScheduler.cancelRetry()
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
        snapshotOverlay.frame = bounds
    }

    /// Re-pushes `__liveWallpaperNativeDevicePixelRatio` whenever the host
    /// display's backing scale changes (window dragged across screens,
    /// resolution changed, Spaces switched) so the canvas backing-store
    /// upgrader keeps multiplying by the right factor.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyPhysicalPixelRuntimeStateIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyPhysicalPixelRuntimeStateIfNeeded()
    }

    // MARK: - Physical-pixel layout (WPE compatibility)

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
        packageBackingGeneration &+= 1
        packageBackingTask?.cancel()
        packageBackingTask = nil
        restartPackageBackingAfterResume = false
        trackerBlockingRequested = false
        reloadScheduler.invalidate()
        onError = nil
        #if !LITE_BUILD
        if let token = developerModeObserver {
            NotificationCenter.default.removeObserver(token)
            developerModeObserver = nil
        }
        #endif
        if let token = thermalObserver {
            NotificationCenter.default.removeObserver(token)
            thermalObserver = nil
        }
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
        snapshotOverlay.image = nil
        snapshotOverlay.isHidden = true
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
        // Pin only the top-level document. Cross-origin subframes retain normal
        // WebKit isolation and are required by legitimate dashboard widgets;
        // they cannot replace the privileged wallpaper document itself.
        if navigationAction.targetFrame?.isMainFrame == false {
            decisionHandler(.allow)
            return
        }
        let decision = HTMLWallpaperView.navigationDecision(
            for: navigationAction.request.url,
            navigationType: navigationAction.navigationType,
            currentURL: webView.url,
            allowMouseInteraction: allowMouseInteraction,
            localReadAccessRoot: currentLocalReadAccessRoot,
            remoteSourceOrigin: currentRemoteSourceOrigin
        )
        switch decision {
        case .allow:
            decisionHandler(.allow)
        case .cancel:
            decisionHandler(.cancel)
        case .openExternally(let url):
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }
    }

    /// 导航完成后兜底：autoplay nudge + 重新应用音量/静音（覆盖晚到的元素）。
    /// 真正的状态保活由 `masterAudioController` 注入的 MutationObserver 完成；
    /// 这里仅做 autoplay 推动，并对刚渲染好的元素再调一次 `__lwUpdateAudio__`
    /// 以保证 navigation-finish 时刻的状态与 `lastAppliedConfig` 同步。
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Successful navigations don't need a per-load INFO entry —
        // the inspector already shows the active URL and a healthy load
        // produces zero failures. Surface only the failure / retry events.
        resetNavigationFailureState()
        let volume = HTMLWallpaperRuntimeScript.jsNumber(lastAppliedConfig?.audioVolume ?? 1.0)
        let muted = lastAppliedConfig?.muteAudio == true ? "true" : "false"
        let wallpaperEngineAudioNudge = wallpaperEngineAudioControlScript(for: lastAppliedConfig) ?? ""
        let nudge = """
        (function() {
            if (typeof window.__lwUpdateAudio__ === 'function') {
                try { window.__lwUpdateAudio__(\(volume), \(muted)); } catch (e) {}
            }
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
        \(wallpaperEngineAudioNudge)
        """
        webView.evaluateJavaScript(nudge, completionHandler: nil)
        notifyWallpaperEngineGeneralProperties(fps: mediaPlaybackSuspended ? 1 : 60)
        // Reload while suspended (refresh timer / programmatic reload) needs
        // the lifecycle controller re-suspended now that the user scripts
        // have re-initialised on a fresh DOM.
        if mediaPlaybackSuspended {
            invokeLifecycleHook(.suspend)
            captureSuspendSnapshot()
        }
        // Re-push the current thermal RAF throttle so the new page picks
        // up the right ratio without waiting for the next thermal change.
        lastRafThrottleRatio = 1
        applyRafThrottleRatio(rafThrottleRatio(for: ProcessInfo.processInfo.thermalState))
    }

    /// Server-side / authentication failures.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        guard !shouldIgnoreNavigationFailure(nsError) else { return }
        Logger.error(
            "HTML wallpaper didFail [domain=\(nsError.domain) code=\(nsError.code)] url=\(webView.url?.absoluteString ?? "<no url>") — \(nsError.localizedDescription)",
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
            "HTML wallpaper didFailProvisionalNavigation [domain=\(nsError.domain) code=\(nsError.code)] url=\(webView.url?.absoluteString ?? "<no url>") — \(nsError.localizedDescription)",
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

    /// WebContent process crash leaves the WKWebView blank/transparent with no
    /// `didFail` callback. Reload the current source so the wallpaper recovers
    /// instead of staying permanently white — but through the shared retry
    /// budget so a page that crashes on every load backs off exponentially and
    /// finally surfaces a terminal error instead of hot-looping the renderer.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !isCleaningUp else { return }
        Logger.error(
            "HTML wallpaper WebContent process terminated; reloading source. url=\(webView.url?.absoluteString ?? "<no url>")",
            category: .screenManager
        )
        if shouldRetryNavigationFailure() { return }
        reportError(.webNavigationFailed(
            webView.url ?? URL(string: "about:blank") ?? URL(fileURLWithPath: "/"),
            code: nil,
            description: String(
                localized: "The web renderer process crashed repeatedly.",
                comment: "Runtime error detail shown when an HTML wallpaper's WebKit content process keeps crashing and the retry budget is exhausted."
            )
        ))
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        if let response = navigationResponse.response as? HTTPURLResponse, response.statusCode >= 400 {
            Logger.warning("HTML wallpaper response: HTTP \(response.statusCode) for host \(response.url?.host ?? "?")", category: .screenManager)
            let failingURL = response.url ?? webView.url ?? URL(string: "about:blank") ?? URL(fileURLWithPath: "/")
            reportError(.webNavigationFailed(failingURL, code: response.statusCode, description: "HTTP \(response.statusCode)"))
        }
        decisionHandler(.allow)
    }
}

// MARK: - WKUIDelegate

extension HTMLWallpaperView: WKUIDelegate {
    /// `window.open()` fires here with no user-gesture guarantee (e.g. from a
    /// timer), so unlike `.linkActivated` navigation it can't be trusted to
    /// open external URLs — always refuse the popup.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // Log scheme+host only: full URLs from untrusted wallpaper content can
        // carry tokens/userinfo into the persistent log.
        let target = navigationAction.request.url
        Logger.warning(
            "HTML wallpaper blocked window.open() to \(target.map { "\($0.scheme ?? "?")://\($0.host ?? "?")" } ?? "<no url>")",
            category: .screenManager
        )
        return nil
    }
}

// MARK: - JS literal helper

/// 返回可直接嵌入 JS 源码的字符串字面量（含外层引号）。
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
