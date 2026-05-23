import AppKit
import LiveWallpaperCore
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
    /// Format a `Double` for JS literal embedding with stable decimal output
    /// (no locale-driven comma separators, no exponent notation).
    static func jsNumber(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        return String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    /// Bootstraps the master audio controller. Sets up:
    ///   1. MutationObserver — applies the current volume/mute to any `<audio>`
    ///      or `<video>` element added later. Without this, dynamically-created
    ///      media (the common case for game-style wallpapers) escapes the mute.
    ///   2. `HTMLMediaElement.prototype.play` patch — enforces volume right
    ///      before playback starts, in case the page set its own `volume`
    ///      between creation and play.
    ///   3. `new Audio()` patch — for standalone `Audio()` objects that never
    ///      get appended to the DOM (the MutationObserver can't see them).
    ///   4. `BaseAudioContext.destination` getter override — intercepts Web
    ///      Audio API graphs and routes them through a per-context `GainNode`
    ///      so audio synthesized via Web Audio respects the user's volume
    ///      slider. This is the only way to cover game audio engines that
    ///      bypass `<audio>` elements entirely.
    ///
    /// Exposes `window.__lwUpdateAudio__(volume, muted)` for runtime updates.
    static func masterAudioController(initialVolume: Double, initialMuted: Bool) -> String {
        let volumeLiteral = jsNumber(initialVolume)
        let mutedLiteral = initialMuted ? "true" : "false"
        return """
        (function () {
            if (window.__lwAudioInstalled__) {
                if (typeof window.__lwUpdateAudio__ === 'function') {
                    window.__lwUpdateAudio__(\(volumeLiteral), \(mutedLiteral));
                }
                return;
            }
            window.__lwAudioInstalled__ = true;
            var __lwVolume__ = \(volumeLiteral);
            var __lwMuted__ = \(mutedLiteral);
            var __lwAudioContexts__ = [];

            function effectiveLevel() { return __lwMuted__ ? 0 : __lwVolume__; }

            function applyToElement(el) {
                if (!el) return;
                var tag = el.tagName;
                if (tag !== 'AUDIO' && tag !== 'VIDEO') return;
                try { el.volume = __lwVolume__; } catch (e) {}
                try { el.muted = __lwMuted__; } catch (e) {}
            }

            function scanAndApply(root) {
                if (!root) return;
                if (root.nodeType === 1) applyToElement(root);
                if (root.querySelectorAll) {
                    var nodes = root.querySelectorAll('audio,video');
                    for (var i = 0; i < nodes.length; i++) applyToElement(nodes[i]);
                }
            }

            function startObserver() {
                if (!document.body || window.__lwAudioObserver__) return;
                try {
                    var observer = new MutationObserver(function (mutations) {
                        for (var m = 0; m < mutations.length; m++) {
                            var added = mutations[m].addedNodes;
                            for (var n = 0; n < added.length; n++) scanAndApply(added[n]);
                        }
                    });
                    observer.observe(document.body, { childList: true, subtree: true });
                    window.__lwAudioObserver__ = observer;
                } catch (e) {}
            }

            if (window.HTMLMediaElement && HTMLMediaElement.prototype.play) {
                var originalPlay = HTMLMediaElement.prototype.play;
                HTMLMediaElement.prototype.play = function () {
                    try { this.volume = __lwVolume__; } catch (e) {}
                    try { this.muted = __lwMuted__; } catch (e) {}
                    return originalPlay.apply(this, arguments);
                };
            }

            if (window.Audio) {
                var OriginalAudio = window.Audio;
                function PatchedAudio() {
                    var bound = Function.prototype.bind.apply(
                        OriginalAudio,
                        [null].concat(Array.prototype.slice.call(arguments))
                    );
                    var instance = new bound();
                    try { instance.volume = __lwVolume__; } catch (e) {}
                    try { instance.muted = __lwMuted__; } catch (e) {}
                    return instance;
                }
                PatchedAudio.prototype = OriginalAudio.prototype;
                try { window.Audio = PatchedAudio; } catch (e) {}
            }

            function findOriginalDestinationGetter(proto) {
                // `destination` lives on BaseAudioContext.prototype, NOT on
                // the AudioContext / webkitAudioContext subclass directly.
                // `getOwnPropertyDescriptor` only inspects the given object,
                // so walk the prototype chain until we find the getter.
                var cursor = proto;
                while (cursor && cursor !== Object.prototype) {
                    try {
                        var d = Object.getOwnPropertyDescriptor(cursor, 'destination');
                        if (d && typeof d.get === 'function') return d.get;
                    } catch (e) {}
                    cursor = Object.getPrototypeOf(cursor);
                }
                return null;
            }

            function patchAudioContext(Ctor) {
                if (!Ctor || !Ctor.prototype) return;
                var originalGetter = findOriginalDestinationGetter(Ctor.prototype);
                if (!originalGetter) return;
                try {
                    // Define on Ctor.prototype (most-derived) so we shadow the
                    // inherited getter for this specific class without touching
                    // BaseAudioContext directly — patching BaseAudioContext
                    // would cause infinite recursion when subclasses also try
                    // to install their own wrapper.
                    Object.defineProperty(Ctor.prototype, 'destination', {
                        configurable: true,
                        get: function () {
                            var real = originalGetter.call(this);
                            if (!this.__lwGainNode__) {
                                try {
                                    var gain = this.createGain();
                                    gain.gain.value = effectiveLevel();
                                    gain.connect(real);
                                    this.__lwGainNode__ = gain;
                                    __lwAudioContexts__.push(this);
                                } catch (e) {
                                    return real;
                                }
                            }
                            return this.__lwGainNode__;
                        }
                    });
                } catch (e) {}
            }
            patchAudioContext(window.AudioContext);
            patchAudioContext(window.webkitAudioContext);
            patchAudioContext(window.OfflineAudioContext);
            patchAudioContext(window.webkitOfflineAudioContext);

            window.__lwUpdateAudio__ = function (volume, muted) {
                if (typeof volume === 'number' && isFinite(volume)) {
                    __lwVolume__ = Math.max(0, Math.min(1, volume));
                }
                __lwMuted__ = !!muted;
                try {
                    var nodes = document.querySelectorAll('audio,video');
                    for (var i = 0; i < nodes.length; i++) applyToElement(nodes[i]);
                } catch (e) {}
                var level = effectiveLevel();
                for (var k = 0; k < __lwAudioContexts__.length; k++) {
                    var ctx = __lwAudioContexts__[k];
                    if (ctx && ctx.__lwGainNode__) {
                        try { ctx.__lwGainNode__.gain.value = level; } catch (e) {}
                    }
                }
            };

            if (document.body) {
                startObserver();
                scanAndApply(document);
            } else if (document.addEventListener) {
                document.addEventListener('DOMContentLoaded', function () {
                    startObserver();
                    scanAndApply(document);
                });
            }
        })();
        """
    }

    /// Applies a `transform: translate() rotate() scale()` chain to the
    /// document body via an injected `<style>` block. Skips touching the
    /// DOM when all four values are identity — avoids fighting layouts in
    /// pages that pin their own `body` transform.
    ///
    /// Exposes `window.__lwUpdateTransform__(scale, tx, ty, rotation)`.
    static func transformController(
        scale: Double,
        translateX: Double,
        translateY: Double,
        rotation: Double
    ) -> String {
        let s = jsNumber(scale)
        let tx = jsNumber(translateX)
        let ty = jsNumber(translateY)
        let r = jsNumber(rotation)
        return """
        (function () {
            function ensureStyle() {
                var el = document.getElementById('__lw-transform-style__');
                if (el) return el;
                el = document.createElement('style');
                el.id = '__lw-transform-style__';
                (document.head || document.documentElement).appendChild(el);
                return el;
            }
            function apply(scale, tx, ty, rotation) {
                var identity = scale === 1 && tx === 0 && ty === 0 && rotation === 0;
                var style = ensureStyle();
                if (identity) {
                    style.textContent = '';
                    if (document.documentElement) {
                        document.documentElement.classList.remove('lw-transformed');
                    }
                    return;
                }
                var transform = 'translate(' + tx + 'px,' + ty + 'px) rotate(' + rotation + 'deg) scale(' + scale + ')';
                style.textContent =
                    'html.lw-transformed{overflow:hidden!important;}' +
                    'html.lw-transformed body{transform:' + transform + ';transform-origin:50% 50%;}';
                if (document.documentElement) {
                    document.documentElement.classList.add('lw-transformed');
                }
            }
            window.__lwUpdateTransform__ = apply;
            if (document.body) {
                apply(\(s), \(tx), \(ty), \(r));
            } else if (document.addEventListener) {
                document.addEventListener('DOMContentLoaded', function () {
                    apply(\(s), \(tx), \(ty), \(r));
                });
            }
        })();
        """
    }

    /// Forces `antialias: true` on every WebGL / WebGL 2 context created by
    /// the page. WPE Spine workshop boilerplates routinely do
    /// `canvas.getContext('webgl', { alpha: false })` without an explicit
    /// `antialias` field — on WebKit this lands as MSAA-off, leaving harsh
    /// polygon-edge aliasing on Spine character meshes. Patching `getContext`
    /// at `documentStart` lets us flip the default without modifying any
    /// wallpaper code. No-op for 2D / bitmaprenderer contexts; idempotent
    /// across page navigations.
    static func webglMSAAForcer() -> String {
        return """
        (function () {
            if (window.__lwWebGLMSAAInstalled__) return;
            window.__lwWebGLMSAAInstalled__ = true;
            try {
                var proto = HTMLCanvasElement && HTMLCanvasElement.prototype;
                if (!proto || !proto.getContext) return;
                var orig = proto.getContext;
                proto.getContext = function (type, attrs) {
                    if (type === 'webgl' || type === 'webgl2' || type === 'experimental-webgl') {
                        var merged = {};
                        if (attrs && typeof attrs === 'object') {
                            for (var k in attrs) {
                                if (Object.prototype.hasOwnProperty.call(attrs, k)) merged[k] = attrs[k];
                            }
                        }
                        merged.antialias = true;
                        return orig.call(this, type, merged);
                    }
                    return orig.apply(this, arguments);
                };
            } catch (e) {}
        })();
        """
    }

    /// Upgrades the WebGL backing store to physical pixels for CSS-naive
    /// canvases. WPE Spine workshop boilerplates do
    /// `canvas.width = window.innerWidth`, which on retina macOS leaves the
    /// backing store at half the physical resolution — WebKit's compositor
    /// then bilinear-upsamples, producing the characteristic Spine blur.
    ///
    /// Mechanism:
    ///   1. Intercept `HTMLCanvasElement.width / height` setters. Always stash
    ///      the requested logical value; only multiply the backing store by
    ///      DPR when the canvas has been claimed for WebGL rendering AND the
    ///      requested value matches CSS-pixel space (≤ the canvas's CSS
    ///      width × 1.05). DPR-aware callers (spine-player, PIXI v8, modern
    ///      Spine 4.2 `SceneRenderer`) set `canvas.width = clientWidth × DPR`
    ///      directly; we recognise that and pass through untouched so we
    ///      don't double-scale them.
    ///   2. Intercept `HTMLCanvasElement.getContext`. On a WebGL request, mark
    ///      the canvas, re-run the size setter so the backing store gets
    ///      upgraded before the context is allocated, then forward.
    ///   3. Intercept `WebGLRenderingContext.viewport / scissor`. When the
    ///      bound framebuffer is the default and the canvas was upgraded,
    ///      multiply the rect by the same scale factor so the rendered
    ///      triangles fill the enlarged backing store.
    ///   4. Track `bindFramebuffer` so user-created FBOs keep author-specified
    ///      viewports.
    ///
    /// 2D canvases (overlays, sprite work buffers) never see the upgrade —
    /// their `ctx.clearRect(0, 0, c.width, c.height)` etc. stays consistent
    /// with the backing store. Same for canvases that only get used for
    /// `toDataURL` / `getImageData`.
    static func canvasBackingStoreUpgrader() -> String {
        return """
        (function () {
            if (window.__lwCanvasUpgraderInstalled__) return;
            window.__lwCanvasUpgraderInstalled__ = true;

            function nativeDPR() {
                var v = window.__liveWallpaperNativeDevicePixelRatio;
                if (typeof v === 'number' && v > 0) return v;
                v = window.devicePixelRatio;
                return (typeof v === 'number' && v > 0) ? v : 1;
            }

            if (nativeDPR() <= 1) return;

            var wDesc, hDesc;
            try {
                wDesc = Object.getOwnPropertyDescriptor(HTMLCanvasElement.prototype, 'width');
                hDesc = Object.getOwnPropertyDescriptor(HTMLCanvasElement.prototype, 'height');
                if (!wDesc || !wDesc.set || !hDesc || !hDesc.set) return;
            } catch (e) { return; }

            try {
                function installSetter(propName, desc, axis) {
                    var ownedKey = (axis === 'w') ? '__lwOwnedStyleW__' : '__lwOwnedStyleH__';
                    function adoptStyle(canvas, value) {
                        // Only touch inline style if it's empty OR we last wrote it ourselves.
                        // Author CSS (e.g. `canvas { width: 100vw }`) and manual
                        // `canvas.style.width = …` stay authoritative.
                        var current = canvas.style[propName];
                        if (current !== '' && current !== canvas[ownedKey]) return;
                        canvas.style[propName] = value;
                        canvas[ownedKey] = value;
                    }
                    function releaseStyle(canvas) {
                        if (canvas.style[propName] === canvas[ownedKey]) {
                            canvas.style[propName] = '';
                        }
                        canvas[ownedKey] = undefined;
                    }
                    Object.defineProperty(HTMLCanvasElement.prototype, propName, {
                        configurable: true,
                        enumerable: desc.enumerable,
                        get: function () {
                            var stash = (axis === 'w') ? this.__lwLogicalW__ : this.__lwLogicalH__;
                            return (typeof stash === 'number') ? stash : desc.get.call(this);
                        },
                        set: function (v) {
                            var n = Number(v) || 0;
                            if (axis === 'w') this.__lwLogicalW__ = n;
                            else              this.__lwLogicalH__ = n;
                            if (n <= 0 || !this.__lwIsWebGL__) {
                                this.__lwScale__ = 1;
                                releaseStyle(this);
                                desc.set.call(this, n);
                                return;
                            }
                            var dpr = nativeDPR();
                            if (dpr <= 1) {
                                this.__lwScale__ = 1;
                                releaseStyle(this);
                                desc.set.call(this, n);
                                return;
                            }
                            // CSS-naive vs DPR-aware detection.
                            // Page set `canvas.width = clientWidth * dpr` → already physical pixels, skip.
                            // Page set `canvas.width = clientWidth` (or innerWidth) → upgrade.
                            var clientSize = (axis === 'w') ? this.clientWidth : this.clientHeight;
                            var innerSize  = (axis === 'w') ? window.innerWidth : window.innerHeight;
                            var ref = Math.max(clientSize || 0, innerSize || 0, 1);
                            if (n > ref * 1.05) {
                                this.__lwScale__ = 1;
                                releaseStyle(this);
                                desc.set.call(this, n);
                                return;
                            }
                            this.__lwScale__ = dpr;
                            adoptStyle(this, n + 'px');
                            desc.set.call(this, Math.round(n * dpr));
                        }
                    });
                }
                installSetter('width',  wDesc, 'w');
                installSetter('height', hDesc, 'h');
            } catch (e) {}

            try {
                var origGetContext = HTMLCanvasElement.prototype.getContext;
                HTMLCanvasElement.prototype.getContext = function (type, attrs) {
                    if (type === 'webgl' || type === 'webgl2' || type === 'experimental-webgl') {
                        if (!this.__lwIsWebGL__) {
                            this.__lwIsWebGL__ = true;
                            var w = (typeof this.__lwLogicalW__ === 'number')
                                ? this.__lwLogicalW__ : wDesc.get.call(this);
                            var h = (typeof this.__lwLogicalH__ === 'number')
                                ? this.__lwLogicalH__ : hDesc.get.call(this);
                            this.width  = w;
                            this.height = h;
                        }
                    }
                    return origGetContext.apply(this, arguments);
                };
            } catch (e) {}

            function hookContextPrototype(proto) {
                if (!proto || proto.__lwGLHookInstalled__) return;
                proto.__lwGLHookInstalled__ = true;
                var origViewport     = proto.viewport;
                var origScissor      = proto.scissor;
                var origBindFB       = proto.bindFramebuffer;
                var FRAMEBUFFER      = 0x8D40;
                var DRAW_FRAMEBUFFER = 0x8CA9;

                proto.bindFramebuffer = function (target, fb) {
                    if (target === FRAMEBUFFER || target === DRAW_FRAMEBUFFER) {
                        this.__lwBoundFB__ = fb;
                    }
                    return origBindFB.call(this, target, fb);
                };

                function scaledRect(ctx, x, y, w, h) {
                    var canvas = ctx.canvas;
                    var bound = ctx.__lwBoundFB__;
                    if (bound != null) return null;
                    var s = canvas && canvas.__lwScale__;
                    if (!s || s === 1) return null;
                    return [
                        Math.round(x * s),
                        Math.round(y * s),
                        Math.round(w * s),
                        Math.round(h * s)
                    ];
                }

                proto.viewport = function (x, y, w, h) {
                    var r = scaledRect(this, x, y, w, h);
                    if (r) return origViewport.call(this, r[0], r[1], r[2], r[3]);
                    return origViewport.call(this, x, y, w, h);
                };

                proto.scissor = function (x, y, w, h) {
                    var r = scaledRect(this, x, y, w, h);
                    if (r) return origScissor.call(this, r[0], r[1], r[2], r[3]);
                    return origScissor.call(this, x, y, w, h);
                };
            }

            try {
                if (typeof WebGLRenderingContext !== 'undefined') {
                    hookContextPrototype(WebGLRenderingContext.prototype);
                }
                if (typeof WebGL2RenderingContext !== 'undefined') {
                    hookContextPrototype(WebGL2RenderingContext.prototype);
                }
            } catch (e) {}
        })();
        """
    }

    /// Records the host display's backing-scale factor on `window` so the
    /// `canvasBackingStoreUpgrader` script can multiply by it regardless of
    /// page-side `devicePixelRatio` manipulation. We deliberately do NOT
    /// override `window.devicePixelRatio` — DPR-aware renderers like
    /// `spine-player` derive their camera viewport size from
    /// `clientWidth × devicePixelRatio`, so lying to them about DPR breaks
    /// the world-space sizing and pushes content out of frame.
    static func physicalPixelState(enabled: Bool, backingScale: CGFloat) -> String {
        let scale = max(Double(backingScale), 1.0)
        let scaleLiteral = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), scale)
        return """
        (function () {
            window.__liveWallpaperNativeDevicePixelRatio = \(scaleLiteral);
            window.__liveWallpaperPhysicalPixelLayout = \(enabled ? "true" : "false");
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
    /// Replays into `loadSource(_:)` for retry / re-entry (sleep wake, error banner).
    private var lastSource: HTMLSource?
    /// Counts consecutive navigation failures since the last successful load.
    /// Capped by `HTMLConfig.maxRetries`; used to drive exponential backoff.
    private var consecutiveFailureCount: Int = 0
    private var pendingRetryTask: Task<Void, Never>?
    /// Repeating reload driver. `nil` when `refreshIntervalSeconds == 0` or
    /// the view is suspended / torn down.
    private var refreshTimerTask: Task<Void, Never>?
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
        #if !LITE_BUILD
        startObservingDeveloperMode()
        #endif
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        #if !LITE_BUILD
        if let token = developerModeObserver {
            NotificationCenter.default.removeObserver(token)
        }
        #endif
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
    /// Subscribes to `.developerModeDidChange` so a Settings toggle is
    /// reflected in this wallpaper's WKWebView without rebuilding the
    /// session. WebKit supports flipping `isInspectable` on a live view,
    /// so the user sees the change immediately (Web Inspector becomes
    /// available or vanishes from the right-click menu).
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
        #if !LITE_BUILD
        return SettingsManager.shared.loadGlobalSettings().developerModeEnabled
        #else
        return false
        #endif
    }

    /// Public entry point so callers (notification handler, future
    /// programmatic toggles) can flip Web Inspector availability on the
    /// active web view without going through a full HTML rebuild. Lite
    /// pins the value to `false` regardless of the requested state.
    func applyDeveloperMode(_ enabled: Bool) {
        if #available(macOS 13.3, *) {
            #if !LITE_BUILD
            webView.isInspectable = enabled
            #else
            webView.isInspectable = false
            #endif
        }
    }

    /// 注入静态基线脚本 + 反映当前配置的状态脚本。
    private func installBaselineUserScripts(for config: HTMLConfig?) {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()

        let cssLiteral = jsStringLiteral(config?.customCSS ?? "")
        let isBrowsing = (config?.allowMouseInteraction ?? false) ? "true" : "false"
        let physicalPixelBootstrap = (config?.physicalPixelLayout ?? false)
            ? HTMLWallpaperRuntimeScript.physicalPixelState(
                enabled: true,
                backingScale: effectiveBackingScaleFactor
            )
            : ""
        let canvasUpgrader = (config?.physicalPixelLayout ?? false)
            ? HTMLWallpaperRuntimeScript.canvasBackingStoreUpgrader()
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

        let msaaForcer = HTMLWallpaperRuntimeScript.webglMSAAForcer()

        let baseline = """
        \(msaaForcer)
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
            // <head> 在 documentStart 时可能尚未就绪 — 用 MutationObserver 做兜底。
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
            || (previous?.allowJavaScript != config.allowJavaScript)
            || (previous?.useEphemeralStorage != config.useEphemeralStorage)
            || (previous?.physicalPixelLayout != config.physicalPixelLayout)

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

        let physicalPixelToggleChanged = previous != nil
            && previous?.physicalPixelLayout != config.physicalPixelLayout
        lastAppliedConfig = config

        if physicalPixelToggleChanged {
            // The canvas-upgrader hooks must attach at `documentStart` before
            // the page calls `getContext('webgl')`. Hot-toggling on a loaded
            // page can't retroactively install them, so reload the page to
            // re-run the user scripts we just re-registered.
            reloadCurrentSource()
        }
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

        if previous?.muteAudio != current.muteAudio || previous?.audioVolume != current.audioVolume {
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

        if previous?.wallpaperEngineProjectProperties != current.wallpaperEngineProjectProperties,
           let schema = wallpaperEnginePropertySchema,
           let script = WallpaperEngineWebPropertyBridge.applyScript(
               schema: schema,
               previousOverrides: previous?.wallpaperEngineProjectProperties ?? [:],
               overrides: current.wallpaperEngineProjectProperties
           ) {
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

    /// Restarts the auto-refresh timer when the interval changes. A non-zero
    /// `seconds` value spins up a repeating MainActor task that calls
    /// `reloadCurrentSource()`; `0` tears the timer down. The task is owned
    /// by `refreshTimerTask` and cancelled on cleanup / suspend.
    private func applyRefreshInterval(_ seconds: Int) {
        refreshTimerTask?.cancel()
        refreshTimerTask = nil
        guard seconds > 0, !isCleaningUp else { return }
        let interval = TimeInterval(seconds)
        refreshTimerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return
                }
                guard let self, !Task.isCancelled, !self.isCleaningUp else { return }
                self.reloadCurrentSource()
            }
        }
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
            let readRoot = Self.readAccessRoot(forFileURL: url)
            currentLocalReadAccessRoot = readRoot
            webView.loadFileURL(url, allowingReadAccessTo: readRoot)
        case .folder(let bookmarkData, let indexFileName):
            guard let folderURL = HTMLWallpaperView.resolveBookmark(bookmarkData) else {
                reportError(.sandboxRevoked)
                return
            }
            activeSecurityScopedURL = folderURL
            currentLocalReadAccessRoot = folderURL
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
            currentLocalReadAccessRoot = nil
            webView.load(URLRequest(url: url))
        case .inline(let html):
            currentLocalReadAccessRoot = nil
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    private func updateWallpaperEnginePropertyBridge(for folderURL: URL?) {
        // Re-parse the manifest only when the active folder actually
        // changes; subsequent override edits reuse the cached schema and
        // hit zero disk I/O on the runtime apply path.
        if folderURL != wallpaperEnginePropertySchemaFolder {
            wallpaperEnginePropertySchemaFolder = folderURL
            wallpaperEnginePropertySchema = folderURL.flatMap {
                WallpaperEngineWebPropertyBridge.parseSchema(forFolder: $0)
            }
        }

        let overrides = lastAppliedConfig?.wallpaperEngineProjectProperties ?? [:]
        let nextScript: String? = {
            guard let schema = wallpaperEnginePropertySchema else { return nil }
            return WallpaperEngineWebPropertyBridge.bootstrapScript(
                schema: schema,
                overrides: overrides
            )
        }()
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
        currentLocalReadAccessRoot = nil
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
    nonisolated static func navigationDecision(
        for url: URL?,
        navigationType: WKNavigationType,
        currentURL: URL?,
        allowMouseInteraction: Bool,
        localReadAccessRoot: URL?
    ) -> NavigationDecision {
        switch navigationType {
        case .other, .reload:
            guard let url else { return .cancel }
            if url.isFileURL {
                return fileURL(url, isContainedIn: localReadAccessRoot) ? .allow : .cancel
            }
            if isAllowedRemoteURL(url) { return .allow }
            if url.scheme?.lowercased() == FolderURLSchemeHandler.scheme { return .allow }
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
        trackerBlockingRequested = false
        pendingRetryTask?.cancel()
        pendingRetryTask = nil
        refreshTimerTask?.cancel()
        refreshTimerTask = nil
        onError = nil
        #if !LITE_BUILD
        if let token = developerModeObserver {
            NotificationCenter.default.removeObserver(token)
            developerModeObserver = nil
        }
        #endif
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
        let decision = HTMLWallpaperView.navigationDecision(
            for: navigationAction.request.url,
            navigationType: navigationAction.navigationType,
            currentURL: webView.url,
            allowMouseInteraction: allowMouseInteraction,
            localReadAccessRoot: currentLocalReadAccessRoot
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
        Logger.info("HTML wallpaper finished loading: \(webView.url?.absoluteString ?? "<no url>")", category: .screenManager)
        resetNavigationFailureState()
        let volume = HTMLWallpaperRuntimeScript.jsNumber(lastAppliedConfig?.audioVolume ?? 1.0)
        let muted = lastAppliedConfig?.muteAudio == true ? "true" : "false"
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
