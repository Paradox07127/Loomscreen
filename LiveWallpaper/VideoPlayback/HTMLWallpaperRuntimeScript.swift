import Foundation

/// JavaScript snippets injected into `HTMLWallpaperView`'s `WKWebView`.
///
/// Each function returns a self-executing IIFE that's safe to inject at
/// `.atDocumentStart` (or `.atDocumentEnd` where noted). The scripts are
/// idempotent — every entry point guards with a `window.__lw*Installed__`
/// sentinel so re-installation after a navigation or hot-config apply
/// doesn't double-wrap getters / setters.
enum HTMLWallpaperRuntimeScript {

    // MARK: - Number formatting

    /// Format a `Double` for JS literal embedding: en_US_POSIX avoids
    /// locale comma separators and exponent notation.
    static func jsNumber(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        return String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    // MARK: - Audio controller

    /// Bootstraps the master audio controller. Four overlapping patches are
    /// needed because each covers media the others miss:
    ///   1. MutationObserver — dynamically-created `<audio>`/`<video>` (the
    ///      common case for game-style wallpapers) would otherwise escape mute.
    ///   2. `HTMLMediaElement.prototype.play` — re-enforces volume in case the
    ///      page set its own between creation and play.
    ///   3. `new Audio()` — standalone objects never appended to the DOM are
    ///      invisible to the MutationObserver.
    ///   4. `BaseAudioContext.destination` getter — routes Web Audio graphs
    ///      through a per-context `GainNode`; the only way to cover game audio
    ///      engines that bypass `<audio>` elements entirely.
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

            window.__lwSuspendAudioContexts__ = function () {
                for (var i = 0; i < __lwAudioContexts__.length; i++) {
                    var ctx = __lwAudioContexts__[i];
                    if (ctx && typeof ctx.suspend === 'function' && ctx.state === 'running') {
                        try { ctx.suspend(); } catch (e) {}
                    }
                }
            };
            window.__lwResumeAudioContexts__ = function () {
                for (var i = 0; i < __lwAudioContexts__.length; i++) {
                    var ctx = __lwAudioContexts__[i];
                    if (ctx && typeof ctx.resume === 'function' && ctx.state === 'suspended') {
                        try { ctx.resume(); } catch (e) {}
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

    // MARK: - Transform controller

    /// Applies a `transform` chain to the body via an injected `<style>`.
    /// Skips the DOM entirely when all values are identity — avoids fighting
    /// layouts in pages that pin their own `body` transform.
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

    // MARK: - GPU canvas MSAA / backing-store upgrader

    /// Forces `antialias: true` on GPU canvas contexts created by the page.
    /// WPE Spine boilerplates request a GPU context without an explicit
    /// `antialias` field — on WebKit this lands as MSAA-off, leaving harsh
    /// polygon-edge aliasing on Spine character meshes. Patching `getContext`
    /// at `documentStart` flips the default without modifying wallpaper code.
    static func gpuCanvasMSAAForcer() -> String {
        return """
        (function () {
            if (window.__lwCanvasMSAAInstalled__) return;
            window.__lwCanvasMSAAInstalled__ = true;
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

    /// Upgrades GPU canvas backing stores to physical pixels for CSS-naive canvases
    /// (e.g. `canvas.width = window.innerWidth`) so retina output is not
    /// bilinear-upsampled by the compositor. Invariants:
    /// - DPR scale applies only to GPU canvases sized in CSS-pixel space;
    ///   DPR-aware callers (spine-player, PIXI v8) pass through untouched.
    /// - `viewport` / `scissor` are scaled only when the default framebuffer
    ///   is bound; user FBOs keep author-specified rects. 2D canvases skipped.
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
                            if (n <= 0 || !this.__lwIsGPUCanvas__) {
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
                        if (!this.__lwIsGPUCanvas__) {
                            this.__lwIsGPUCanvas__ = true;
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

    // MARK: - Lifecycle controller (P0 — JS真正挂起)

    /// Installs `window.__lwSuspend__/__lwResume__/__lwSetRafThrottle__`.
    /// Called alongside native `setAllMediaPlaybackSuspended` so the page-side
    /// render loop, CSS animations, and Web Audio actually stop instead of
    /// burning CPU/GPU while the wallpaper is occluded or thermal-throttled.
    ///
    /// Layered because no single mechanism covers every page:
    /// - Redefined `document.hidden` / `visibilityState` getters + a
    ///   `visibilitychange` event self-throttle Page-Visibility-aware pages
    ///   (Three.js, Pixi.js defaults).
    /// - No-op `requestAnimationFrame` during suspend catches pages that
    ///   ignore `document.hidden`.
    /// - `animation-play-state: paused` via an injected `<html>`-class style.
    ///   Page CSS using its own `!important` still wins; everyday animations
    ///   freeze cleanly.
    ///
    /// `aggressiveSuspend` also releases/restores GPU canvas contexts. Off by
    /// default — many pages don't handle context restore and stay black.
    static func lifecycleController(aggressiveSuspend: Bool) -> String {
        let aggressive = aggressiveSuspend ? "true" : "false"
        return """
        (function () {
            if (window.__lwLifecycleInstalled__) return;
            window.__lwLifecycleInstalled__ = true;
            var aggressive = \(aggressive);
            var rafBackup = null;
            var rafThrottleRatio = 1;
            var rafThrottleCounter = 0;
            var suspended = false;
            var hiddenDescriptorBackup = null;
            var visibilityDescriptorBackup = null;
            var gpuCanvasContexts = [];

            function captureDescriptor(name) {
                try {
                    var proto = Object.getPrototypeOf(document) || Document.prototype;
                    return Object.getOwnPropertyDescriptor(proto, name)
                        || Object.getOwnPropertyDescriptor(Document.prototype, name);
                } catch (e) { return null; }
            }

            function forceHidden(hidden) {
                try {
                    Object.defineProperty(document, 'hidden', {
                        configurable: true,
                        get: function () { return hidden; }
                    });
                    Object.defineProperty(document, 'visibilityState', {
                        configurable: true,
                        get: function () { return hidden ? 'hidden' : 'visible'; }
                    });
                } catch (e) {}
            }

            function restoreVisibility() {
                try {
                    if (hiddenDescriptorBackup) {
                        Object.defineProperty(document, 'hidden', hiddenDescriptorBackup);
                    } else {
                        delete document.hidden;
                    }
                    if (visibilityDescriptorBackup) {
                        Object.defineProperty(document, 'visibilityState', visibilityDescriptorBackup);
                    } else {
                        delete document.visibilityState;
                    }
                } catch (e) {}
            }

            function dispatchVisibility() {
                try {
                    document.dispatchEvent(new Event('visibilitychange'));
                } catch (e) {}
            }

            function installRafOverride() {
                if (rafBackup) return;
                rafBackup = window.requestAnimationFrame;
                window.requestAnimationFrame = function () { return 0; };
            }

            function restoreRaf() {
                if (!rafBackup) return;
                window.requestAnimationFrame = rafBackup;
                rafBackup = null;
            }

            function installRafThrottle(ratio) {
                if (rafBackup) return; // suspended, throttle is meaningless
                rafThrottleRatio = ratio;
                rafThrottleCounter = 0;
                if (ratio <= 1) {
                    if (window.__lwRafThrottleBackup__) {
                        window.requestAnimationFrame = window.__lwRafThrottleBackup__;
                        window.__lwRafThrottleBackup__ = null;
                    }
                    return;
                }
                if (!window.__lwRafThrottleBackup__) {
                    window.__lwRafThrottleBackup__ = window.requestAnimationFrame;
                }
                var original = window.__lwRafThrottleBackup__;
                window.requestAnimationFrame = function (cb) {
                    return original.call(window, function (t) {
                        rafThrottleCounter = (rafThrottleCounter + 1) % rafThrottleRatio;
                        if (rafThrottleCounter === 0) cb(t);
                        else window.requestAnimationFrame(cb);
                    });
                };
            }

            // `animation-play-state` does not inherit, so toggling it on
            // `<html>` doesn't pause descendant animations. Install a CSS
            // rule keyed on a class we add to the root element — that lets
            // a single class flip pause every animated descendant.
            function ensurePauseStyle() {
                var el = document.getElementById('__lw-suspend-style__');
                if (el) return el;
                el = document.createElement('style');
                el.id = '__lw-suspend-style__';
                el.textContent =
                    'html.__lw-suspended__ *, html.__lw-suspended__ *::before, html.__lw-suspended__ *::after {' +
                    '  animation-play-state: paused !important;' +
                    '  -webkit-animation-play-state: paused !important;' +
                    '  transition: none !important;' +
                    '}';
                (document.head || document.documentElement).appendChild(el);
                return el;
            }

            function setCSSPaused(paused) {
                if (!document.documentElement) return;
                ensurePauseStyle();
                document.documentElement.classList.toggle('__lw-suspended__', paused);
            }

            function collectGPUCanvasContexts() {
                gpuCanvasContexts = [];
                try {
                    var canvases = document.querySelectorAll('canvas');
                    for (var i = 0; i < canvases.length; i++) {
                        var ctx = null;
                        try { ctx = canvases[i].getContext('webgl2'); } catch (e) {}
                        if (!ctx) { try { ctx = canvases[i].getContext('webgl'); } catch (e) {} }
                        if (!ctx) { try { ctx = canvases[i].getContext('experimental-webgl'); } catch (e) {} }
                        if (ctx) gpuCanvasContexts.push(ctx);
                    }
                } catch (e) {}
            }

            function releaseGPUCanvasContexts() {
                collectGPUCanvasContexts();
                for (var i = 0; i < gpuCanvasContexts.length; i++) {
                    var ctx = gpuCanvasContexts[i];
                    try {
                        var ext = ctx.getExtension('WEBGL_lose_context');
                        if (ext) ext.loseContext();
                    } catch (e) {}
                }
            }

            function restoreGPUCanvasContexts() {
                for (var i = 0; i < gpuCanvasContexts.length; i++) {
                    var ctx = gpuCanvasContexts[i];
                    try {
                        var ext = ctx.getExtension('WEBGL_lose_context');
                        if (ext) ext.restoreContext();
                    } catch (e) {}
                }
                gpuCanvasContexts = [];
            }

            window.__lwSuspend__ = function () {
                if (suspended) return;
                suspended = true;
                if (!hiddenDescriptorBackup) hiddenDescriptorBackup = captureDescriptor('hidden');
                if (!visibilityDescriptorBackup) visibilityDescriptorBackup = captureDescriptor('visibilityState');
                forceHidden(true);
                dispatchVisibility();
                installRafOverride();
                setCSSPaused(true);
                if (typeof window.__lwSuspendAudioContexts__ === 'function') {
                    window.__lwSuspendAudioContexts__();
                }
                if (aggressive) releaseGPUCanvasContexts();
            };

            window.__lwResume__ = function () {
                if (!suspended) return;
                suspended = false;
                if (aggressive) restoreGPUCanvasContexts();
                if (typeof window.__lwResumeAudioContexts__ === 'function') {
                    window.__lwResumeAudioContexts__();
                }
                setCSSPaused(false);
                restoreRaf();
                restoreVisibility();
                dispatchVisibility();
                // Re-apply the throttle ratio that was in effect before suspend.
                if (rafThrottleRatio > 1) {
                    installRafThrottle(rafThrottleRatio);
                }
            };

            window.__lwSetRafThrottle__ = function (ratio) {
                var r = parseInt(ratio, 10);
                if (!isFinite(r) || r < 1) r = 1;
                if (r > 8) r = 8;
                installRafThrottle(r);
            };
        })();
        """
    }

    // MARK: - CSP injection (P3)

    /// Injects a `<meta http-equiv="Content-Security-Policy">` tag into the
    /// document head before the page's own scripts evaluate. The policy
    /// permits content from any HTTPS origin and inline scripts (most
    /// wallpapers fail catastrophically under strict CSP) while blocking
    /// data exfiltration via WebSockets / WebRTC / fetch to schemes other
    /// than https/data/blob. Opt-in via `HTMLConfig.cspEnforcementEnabled`.
    static func cspInjection() -> String {
        return """
        (function () {
            if (window.__lwCSPInstalled__) return;
            window.__lwCSPInstalled__ = true;
            var policy = "default-src 'self' https: data: blob: livewallpaper:; " +
                         "script-src 'self' 'unsafe-inline' 'unsafe-eval' https: blob:; " +
                         "style-src 'self' 'unsafe-inline' https:; " +
                         "img-src 'self' https: data: blob:; " +
                         "media-src 'self' https: data: blob: livewallpaper:; " +
                         "font-src 'self' https: data:; " +
                         "connect-src 'self' https: wss: data: blob:; " +
                         "frame-src 'self' https:; " +
                         "object-src 'none'; " +
                         "base-uri 'self';";
            function install() {
                if (!document.head && !document.documentElement) return false;
                if (document.querySelector('meta[http-equiv="Content-Security-Policy"][data-lw-csp]')) return true;
                var meta = document.createElement('meta');
                meta.setAttribute('http-equiv', 'Content-Security-Policy');
                meta.setAttribute('data-lw-csp', '1');
                meta.setAttribute('content', policy);
                var target = document.head || document.documentElement;
                if (target.firstChild) target.insertBefore(meta, target.firstChild);
                else target.appendChild(meta);
                return true;
            }
            if (install()) return;
            try {
                var mo = new MutationObserver(function () {
                    if (install()) mo.disconnect();
                });
                mo.observe(document.documentElement || document, { childList: true });
            } catch (e) {}
        })();
        """
    }

    // MARK: - WPE general property notification

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
