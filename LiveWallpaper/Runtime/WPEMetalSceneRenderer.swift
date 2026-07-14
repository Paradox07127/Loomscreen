#if !LITE_BUILD
import AppKit
import MetalKit

/// Wraps a texture-load failure with the requested asset path AND the WPE
/// object/layer name that referenced it so the H1 diagnostic mapper can
/// blame the exact file and surface the failing layer instead of falling
/// back to the scene entry point.
private struct WPEMetalTextureLoadContextError: Error {
    let layerName: String
    let path: String
    let underlying: any Error
}

@MainActor
final class WPEMetalSceneRenderer: NSObject, WallpaperPerformanceConfigurable, WallpaperFrameRateConfigurable, WallpaperAudioConfigurable, MTKViewDelegate {
    /// Default frame rate target when no user override has been applied.
    /// 30 FPS matches Wallpaper Engine's stock default
    /// (Almamu's reference open-source impl ships `maximumFPS = 30`; the
    /// official Windows app's "Balanced" preset also defaults to 30) —
    /// most published WPE shaders are tuned around a 30 FPS clock, so
    /// running at 60 made their `g_Time`-driven motion look ≈2× too fast.
    /// `MTKView` clamps this to the display's refresh rate.
    static let defaultPreferredFPS = 30
    /// Perspective scenes render at the drawable resolution (capped 4K) instead
    /// of the fixed 1080 fallback, so HUD text is crisp. Default ON; disable with
    /// `defaults write Taijia.LiveWallpaper WPEMetalPerspectiveNativeResolution -bool NO`.
    static let perspectiveNativeResolutionEnabled: Bool =
        (UserDefaults.standard.object(forKey: "WPEMetalPerspectiveNativeResolution") as? Bool) ?? true
    /// Floor for the adaptive "background" throttle — never drop a still-visible
    /// wallpaper below this even when occluded/on battery (15 FPS measured at
    /// ~83 mW vs ~330 mW at 60, a ~75% GPU-power cut, while staying watchable).
    static let adaptiveThrottleFloorFPS = 15
    /// Native vsync cap used when the user picks `.unlimited` — MTKView's
    /// throttle clamps to the display refresh anyway, but we surface a
    /// concrete value here so a `setPreferredFramesPerSecond(0)` doesn't get
    /// interpreted as "as fast as possible" (which on some macOS versions
    /// free-runs well past vsync). Derived from the fastest attached display
    /// so ProMotion panels actually reach 120 instead of a literal 60;
    /// MTKView still clamps per-display, so over-asking on slower screens
    /// is harmless.
    static var unlimitedPreferredFPS: Int {
        let fastest = NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 0
        return fastest > 0 ? fastest : 60
    }
    /// Above this raw-bytes footprint, eager-upload a multi-frame `.tex`
    /// would burn far more VRAM than the runtime needs at any one moment
    /// — route through `WPETexLazyAnimatedTextureSource` instead. Threshold
    /// chosen to keep small (≤2-3 frame) workshop sprite-sheets on the
    /// fast eager path while sending workshop 3725117707-class assets
    /// (60 × 122 MB raw) to the streaming source. Tiered by physical RAM
    /// (halved on 8 GB machines — see `WPEMemoryTier`).
    private static let lazyAnimationRawByteThreshold = WPEMemoryTier.current.lazyAnimationRawByteThreshold

    static let textureCacheBudgetMiBDefaultsKey = "WPEMetalTextureCacheBudgetMiB"
    /// VRAM budget for reloadable static source textures. Unset ⇒ the machine's
    /// memory-tier default (8/16 GB Macs bounded, ≥24 GB unbounded — see
    /// `WPEMemoryTier`); explicit 0 or negative ⇒ unbounded (manual opt-out);
    /// positive ⇒ that many MiB. Over-budget inactive (hidden-layer) textures
    /// are LRU-evicted and reloaded on demand. Snapshot per scene load, so
    /// `defaults write Taijia.LiveWallpaper WPEMetalTextureCacheBudgetMiB -int 256`
    /// applies on the next (re)load.
    static var textureCacheBudgetBytes: Int? {
        resolvedTextureCacheBudgetBytes(
            manualValue: UserDefaults.standard.object(forKey: textureCacheBudgetMiBDefaultsKey),
            tier: .current
        )
    }

    static func resolvedTextureCacheBudgetBytes(manualValue: Any?, tier: WPEMemoryTier) -> Int? {
        guard let manualValue else { return tier.defaultTextureCacheBudgetBytes }
        let mib = (manualValue as? NSNumber)?.intValue ?? 0
        guard mib > 0 else { return nil }
        return mib * 1_048_576
    }

    /// When true, emitters with no authored start offset are also pre-populated
    /// to their steady-state spread on load. Emitters with `starttime > 0`
    /// always prewarm because WPE authors use that field as an initial simulation
    /// offset for already-populated first frames.
    private static var particlePrewarmEnabled: Bool {
        UserDefaults.standard.bool(forKey: "WPEParticlePrewarmEnabled")
    }

    nonisolated static func particlePrewarmSeconds(
        for definition: WPEParticleDefinition,
        manualPrewarmEnabled: Bool
    ) -> Double? {
        guard definition.rate > 0 || definition.instantaneousCount > 0 else { return nil }
        let authoredStart = max(0, definition.startDelay)
        guard authoredStart > 0 || manualPrewarmEnabled else { return nil }
        let activeSeconds = min(max(definition.lifetimeMax, 2.0), 15.0)
        let seconds = authoredStart + activeSeconds
        return seconds > 0 ? seconds : nil
    }

    /// Slave a revealed loop video's playhead to lead its intro overlay by the
    /// measured phase offset (seamless intro→loop). Default on; `-bool NO` disables.
    private static var introPhaseAlignEnabled: Bool {
        UserDefaults.standard.object(forKey: "WPEMetalIntroPhaseAlignEnabled") as? Bool ?? true
    }

    /// ADR-003 step 1 kill-switch: async latest-snapshot script ticks (the frame
    /// path never waits on a script engine queue). Frozen at first use; default
    /// ON. `defaults write <bundle> WPEScriptAsyncTickEnabled -bool NO` restores
    /// the legacy bounded-blocking ticks on the next launch.
    private static let scriptAsyncTickEnabled: Bool = resolvedScriptAsyncTickEnabled(
        manualValue: UserDefaults.standard.object(forKey: "WPEScriptAsyncTickEnabled")
    )

    nonisolated static func resolvedScriptAsyncTickEnabled(manualValue: Any?) -> Bool {
        manualValue as? Bool ?? true
    }

    private let descriptor: SceneDescriptor
    private let cacheRootURL: URL
    private let dependencyMounts: [WPEAssetMount]
    /// Resolved Wallpaper Engine install root (the directory that contains
    /// `assets/`). Captured at init for graph + pipeline builder use; the
    /// security scope is owned here for the lifetime of the renderer.
    private let engineAssetsRootURL: URL?
    /// `engineAssetsRootURL` gated by access: nil when an external (non-container)
    /// root's security scope failed to open, else the usable root. Graph/pipeline
    /// builders must use THIS, not the raw root, so a scope-denied manual link
    /// never feeds the resolver.
    private let effectiveEngineAssetsRootURL: URL?
    /// `(unsafe)` because `deinit` is non-isolated and needs to clear the
    /// reference + drop the scope. All other writes happen on `@MainActor`
    /// (`cleanup()`), so observed mutation is single-threaded.
    nonisolated(unsafe) private var activeEngineAssetsRootURL: URL?
    private let entryResolver: SceneResourceResolver
    private let resourceResolver: WPEMultiRootResourceResolver
    /// Non-nil for package-/source-backed scenes — threaded into the graph and
    /// pipeline builders so they resolve from the same in-place source. `nil`
    /// keeps the legacy directory-backed (cache root URL) construction.
    private let sceneAssetProvider: (any WPESceneAssetProvider)?
    /// Root holding `project.json` for the property schema. For package-/source-
    /// backed scenes this is the source folder (zero-cache — nothing extracted);
    /// `nil` falls back to `cacheRootURL` (legacy extracted cache).
    private let projectManifestRootURL: URL?
    private let resolutionTracer: WPEResolutionTracer
    private let mtkView: WPEInteractiveMTKView
    private let executor: WPEMetalRenderExecutor
    private let textureLoader: WPEMetalTextureLoader
    private var outputTexture: MTLTexture?
    /// How the final scene texture is fitted onto the screen drawable. Defaults
    /// to `.cover` (crop-to-fill), matching the persisted `fitMode` default, so
    /// non-16:9 displays don't distort the scene. Pushed in from the session.
    private var presentFitMode: WPEPresentFitMode = .cover
    /// Phase 2D-L: alive particle systems and the per-system sprite
    /// texture. Built on load from the scene's `particleObjects`; ticked
    /// + drawn each frame.
    private var particleSystems: [WPEParticleSystem] = []
    private var particleTextures: [ObjectIdentifier: MTLTexture] = [:]
    /// Refraction normal map (`g_Texture1`) for REFRACT particle systems, keyed
    /// like `particleTextures`. Absent ⇒ the system renders as a flat sprite.
    private var particleNormalTextures: [ObjectIdentifier: MTLTexture] = [:]
    /// Phase 2D-N: text overlay draws assembled at load time. Each
    /// frame re-rasterizes via the cached WPETextRenderer (cache hits
    /// the common case) and draws atop the scene output.
    private var textRenderer: WPETextRenderer?
    /// GPU MSDF text renderer (Milestone D). Built only when the engine's
    /// `font.frag` resolves; nil → text falls back to the CoreText overlay.
    private var msdfTextRenderer: WPEMSDFTextRenderer?
    /// Suppresses repeat `drawMSDFText` failure logs within a failure streak
    /// (mirrors `didLogFrameFailure`) — a persistently-failing MSDF combo
    /// falls back to CoreText every frame and must not flood the log.
    private var didLogMSDFTextDrawFailure = false
    private var textObjects: [WPESceneTextObject] = []
    /// Phase 2D-O: audio runtime publishing live FFT bins into the
    /// runtime uniform that audio-reactive shaders sample. Optional —
    /// scenes without sound objects skip this entirely.
    private var soundRuntime: WPESoundRuntime?
    /// `WPEAudioDebugLog -bool YES` → throttled per-second log of what the
    /// renderer actually sees on the shared audio broker, to diagnose
    /// audio-reactive scenes that don't move.
    private let audioDebugLogEnabled = UserDefaults.standard.bool(forKey: "WPEAudioDebugLog")
    private var audioDiagCounter = 0
    /// Phase 2D-P: per-text-object SceneScript instances. Keyed by
    /// the text object's id so the renderer can look up the latest
    /// scripted value when rasterizing.
    private var textScriptInstances: [String: WPESceneScriptInstance] = [:]
    /// Layer (image-object) SceneScripts keyed by objectID — visible-scripts that
    /// drive a layer's visibility/alpha and its video texture (e.g. an intro that
    /// plays once then hides). Empty for the common no-layer-script scene.
    private var layerScriptInstances: [String: WPELayerScriptInstance] = [:] {
        didSet { cachedInstalledScriptLayerIDs = nil }
    }
    /// TEXT objects' own visible/alpha SceneScripts (3509243656's login-intro
    /// texts fade themselves out) — same machinery as image layer scripts, but
    /// outputs land in `liveTextVisibility`/`liveTextAlpha` for the text loop.
    private var textVisibleScriptInstances: [String: WPELayerScriptInstance] = [:]
    private var textAlphaScriptInstances: [String: WPELayerScriptInstance] = [:]
    private var liveTextAlpha: [String: Double] = [:]
    /// Current hover state per scripted layer (cursorEnter/Leave transitions).
    private var layerHoverStates: [String: Bool] = [:]
    private var sceneScriptSharedState: WPESharedScriptState?
    /// Image-object alpha field scripts keyed by objectID. These return an alpha
    /// scalar from `update(value)` and intentionally do not affect visibility.
    private var layerAlphaScriptInstances: [String: WPELayerScriptInstance] = [:] {
        didSet { cachedInstalledScriptLayerIDs = nil }
    }
    /// Image-object origin SceneScripts keyed by objectID. These are dynamic
    /// transform scripts, e.g. cursor-follow flowers that assign
    /// `origin = input.cursorWorldPosition` every frame.
    private var dynamicOriginScriptInstances: [String: WPEDynamicTransformScriptInstance] = [:] {
        didSet { cachedInstalledScriptLayerIDs = nil }
    }
    /// Image-object scale SceneScripts keyed by objectID. Used by scenes that
    /// drive body sizes or link lengths from shared simulation state.
    private var dynamicScaleScriptInstances: [String: WPEDynamicTransformScriptInstance] = [:] {
        didSet { cachedInstalledScriptLayerIDs = nil }
    }
    /// Image-object angles SceneScripts keyed by objectID. Used by camera/control
    /// rigs such as drag-to-rotate scene roots.
    private var dynamicAnglesScriptInstances: [String: WPEDynamicTransformScriptInstance] = [:] {
        didSet { cachedInstalledScriptLayerIDs = nil }
    }
    /// Memoized load-scoped part of `staticCacheExcludedLayerIDs` (the five
    /// installed-script key sets above). Cleared via `didSet` on EVERY mutation
    /// of those dictionaries, so no install/teardown path can leave it stale.
    private var cachedInstalledScriptLayerIDs: Set<String>?
    /// Non-rendered transform hosts keyed by objectID. These are WPE `solid`
    /// groups that move/render no pixels themselves but compose into child layers.
    private var transformHostLocalTransformsByID: [String: WPERenderObjectTransform] = [:]
    /// objectID → the `dynamicTextureSources` key of the layer's video source, so
    /// a layer script's `getVideoTexture()` commands reach the right player.
    /// Populated for ALL video-backed layers (a button script drives a different
    /// layer's video via `thisScene.getLayer(name)`), not just scripted ones.
    private var layerVideoSourceKey: [String: String] = [:]
    /// Layer name → objectID, so a script's `thisScene.getLayer(name)` output can
    /// be resolved to the target layer.
    private var layerObjectIDByName: [String: String] = [:]
    /// objectID → texture key for scene-output-only video layers (never a hidden
    /// composite source), kept resident only while visible. Each
    /// `WPEVideoTextureSource` holds its whole MP4 + decode buffers (~300 MB per 4K
    /// source), so a multi-video scene that shows one at a time otherwise pays for
    /// all of them. `reconcileVideoResidency` flips residency per frame.
    private var onDemandVideoKeyByID: [String: String] = [:]
    /// Texture keys whose rebuild is in flight, so a layer staying visible across
    /// frames doesn't spawn a duplicate Task while the first resolves.
    private var onDemandVideoLoading: Set<String> = []
    /// Live per-layer alpha overrides driven by layer scripts (objectID → alpha).
    private var liveLayerAlpha: [String: Double] = [:]
    /// Runtime-created image layers keyed by renderer-unique objectID. Produced
    /// by layer SceneScript `thisScene.createLayer(...)` handles.
    private var liveCreatedLayers: [String: WPECreatedLayerScriptState] = [:]
    /// Prepared one-pass templates keyed by model path. Hidden template layers
    /// are retained by the graph builder only when a script references them.
    private var createdLayerTemplatesByImagePath: [String: WPEPreparedRenderLayer] = [:]
    /// Intro→loop phase alignment: an intro overlay (`introPhaseSource`) and the
    /// free-running loop it reveals (`loopPhaseSource`) are often the same
    /// animation a few seconds out of phase, with nothing in the scripts wiring the
    /// handoff. We measure the offset once (`intro@t ≈ loop@(t+offset)`) and slave
    /// the loop's playhead to lead the intro by it, so the crossfade is seamless.
    private var introPhaseSource: WPEVideoTextureSource?
    private var loopPhaseSource: WPEVideoTextureSource?
    private var introLoopOffset: TimeInterval?
    /// Bumped per reload so a slow async measurement from a prior scene is ignored.
    private var introPhaseToken = 0
    private var loadedTextures: [String: MTLTexture] = [:]
    /// Reloadable static-texture bookkeeping for the optional VRAM budget
    /// (`textureCacheBudgetBytes`). Inactive over-budget entries are evicted and
    /// reloaded on demand; dynamic/video sources are never tracked here.
    private struct StaticTextureCacheRecord: Sendable {
        let layerName: String
        let candidates: [String]
        var bytes: Int
    }
    private var staticTextureCacheRecords: [String: StaticTextureCacheRecord] = [:]
    private var textureCacheLRU = WPEMetalTextureCacheLRU(budgetBytes: 0)
    private var textureCacheBudgetBytesInUse: Int?
    /// Per-load snapshot of `Self.textureCacheBudgetBytes` — the frame path must
    /// never read UserDefaults (per-frame defaults reads showed up hot in the C2
    /// flag-freeze pass).
    private var textureCacheBudgetBytesResolved: Int?
    private var staticTexturePlaceholderPaths: Set<String> = []
    private var pendingStaticTextureReloads: Set<String> = []
    private var staticTextureReloadThrottles: [String: WPEStaticTextureReloadThrottle] = [:]
    /// Memoizes `activeStaticTexturePaths` (the budget's only per-frame walk).
    /// Keyed by a per-layer visibility/shape signature: script or property flips
    /// recompute, static frames reuse. A hash collision only mis-protects for
    /// one frame and self-heals via the placeholder+reload path.
    private var cachedActiveStaticPaths: Set<String> = []
    private var cachedActiveStaticSignature: Int?
    private var staticTextureRecordsEpoch = 0
    /// Phase 2E: animated and video texture sources keyed by the same path
    /// the executor uses to look up `MTLTexture` for each pass. Populated
    /// during `performLoad()`; refreshed each render via
    /// `texturesForCurrentFrame(time:pipeline:)` so the executor sees the live frame.
    private var dynamicTextureSources: [String: WPEDynamicTextureSource] = [:] {
        didSet { cachedDynamicTextureNames = nil }
    }
    /// Memoized `Set(dynamicTextureSources.keys)` for the per-frame render call.
    /// All mutations are cold (load, lazy video rebuild, residency release,
    /// teardown) and each clears this via `didSet`; the frame path only reads.
    private var cachedDynamicTextureNames: Set<String>?
    private var dynamicTextureNames: Set<String> {
        if let cached = cachedDynamicTextureNames { return cached }
        let names = Set(dynamicTextureSources.keys)
        cachedDynamicTextureNames = names
        return names
    }
    private var sceneRenderSize: CGSize = CGSize(width: 1, height: 1)
    private var cameraUniforms: WPEMetalCameraUniforms = .identity
    private var frameClock: WPEMetalFrameClock
    /// Frozen frame globals when the render oracle is enabled (read once at load);
    /// `nil` in production, so the real clock/pointer drive every frame unchanged.
    private let oracleFrameOverride = WPEOracleMode.loadFrameOverride()
    private let pointerSampler: WPEMetalPointerSampler
    private let snapshotter: WPEMetalTextureSnapshotter
    private var cachedSnapshot: NSImage?
    private var pendingLivePosterCaptures: [UUID: CheckedContinuation<NSImage?, Never>] = [:]
    private final class LivePosterCaptureBatch: @unchecked Sendable {
        weak var renderer: WPEMetalSceneRenderer?
        let captures: [UUID: CheckedContinuation<NSImage?, Never>]
        let generation: Int
        let snapshotter: WPEMetalTextureSnapshotter

        @MainActor
        init(
            renderer: WPEMetalSceneRenderer,
            captures: [UUID: CheckedContinuation<NSImage?, Never>]
        ) {
            self.renderer = renderer
            self.captures = captures
            self.generation = renderer.loadGeneration
            self.snapshotter = renderer.snapshotter
        }

        func captureAfterPresent(
            from texture: MTLTexture,
            completed: Bool,
            releaseSource: @escaping @Sendable () -> Void
        ) {
            let source = WPEMetalTextureSnapshotter.SnapshotSource(texture: texture)
            let snapshotter = snapshotter
            if !completed {
                Logger.info("[live-poster] present command buffer not completed — poster skipped", category: .wpeRender)
            }
            Task { [self, snapshotter] in
                let image = completed ? await snapshotter.snapshotAsync(from: source) : nil
                releaseSource()
                await MainActor.run {
                    let result = renderer?.loadGeneration == generation ? image : nil
                    finish(image: result)
                }
            }
        }

        func finish(image: NSImage?) {
            for continuation in captures.values {
                continuation.resume(returning: image)
            }
        }
    }
    private var didLoad = false
    /// Bumped on every load and on teardown (`reload`/`cleanup`) so a deferred
    /// task — e.g. the off-critical-path audio startup — can detect that the
    /// renderer has since reloaded or torn down and bail on a stale scene.
    private var loadGeneration = 0
    /// Set at the end of `performLoad` for scenes with sound; consumed by the
    /// first successful `present` in `draw(in:)`, so audio startup begins only
    /// after the first frame is actually on screen.
    private var pendingAudioStartupDocument: WPESceneDocument?
    /// The in-flight off-main audio-startup task, tracked so `reload`/`cleanup`
    /// can cancel it.
    private var deferredAudioStartupTask: Task<Void, Never>?

    #if DEBUG
    /// Test-only: audio startup is deferred (waiting on the first present), not yet started.
    var debugAudioStartupPending: Bool { pendingAudioStartupDocument != nil }
    /// Test-only: the sound runtime has been published (audio actually started).
    var debugSoundRuntimeActive: Bool { soundRuntime != nil }
    #endif
    /// Scene-level camera parallax: the parsed settings plus the per-frame
    /// exponential smoother that drives every layer's depth shift. Neutral when
    /// the scene disables parallax.
    private var cameraParallaxSettings: WPESceneCameraParallaxSettings = .disabled
    private var cameraParallaxSmoother = WPECameraParallaxSmoother()
    /// Per-machine magnitude multiplier for camera parallax. Defaults to
    /// `WPECameraParallaxFrame.defaultGain`. Read once at load — set it with
    /// `defaults write Taijia.LiveWallpaper WPEParallaxGain <number>` and reload
    /// the wallpaper to apply.
    private let cameraParallaxGain = WPEMetalSceneRenderer.resolvedParallaxGain()
    private var currentProfile: WallpaperPerformanceProfile = .quality
    /// When false, the per-frame pointer is pinned to the screen center so the
    /// scene stops reacting to the cursor (camera parallax freezes, pointer
    /// shaders see a constant). Driven by the per-screen "Follow Cursor"
    /// playback toggle; default on preserves the historical behavior.
    private var mouseInteractionEnabled = true
    /// Previous frame's pointer UV, fed as the official `g_PointerPositionLast`.
    private var previousPointer = SIMD2<Double>(0.5, 0.5)
    /// Tracks the live/inactive edge so pointer-spawned particles can be removed
    /// as soon as the cursor leaves this renderer's screen.
    private var previousPointerWasLive = false
    /// Previous captured pointer/button frame used to emit SceneScript cursor
    /// down/up edges exactly once per transition.
    private var previousLayerScriptPointerFrame = WPEPointerFrame.neutral
    /// User-selected frame rate ceiling, applied to `mtkView.preferredFramesPerSecond`
    /// whenever the renderer is not suspended. Defaults to the WPE-compatible
    /// 30 FPS until `setFrameRateLimit(_:)` overrides it.
    private var userPreferredFPS: Int = WPEMetalSceneRenderer.defaultPreferredFPS
    /// System-driven background throttle (adaptive frame rate). Layered on top
    /// of `userPreferredFPS` via `effectiveFPS` so it never clobbers the user's
    /// saved ceiling — clearing it restores the exact prior rate.
    private var adaptiveThrottleActive = false
    /// Inspector mute state cached here so callers that arrive before the
    /// deferred audio startup can still record intent; `beginDeferredAudioStartup`
    /// reads these to seed `WPESoundRuntime` at the right level (and re-applies
    /// them once the off-main start finishes, in case they changed meanwhile).
    private var pendingAudioMuted: Bool = false
    private var pendingAudioVolume: Double = 1.0

    private(set) var hasPresentedFrame = false
    private(set) var loadDiagnostics: SceneLoadDiagnostic?
    private(set) var renderGraph: WPERenderGraph?
    private(set) var renderPipeline: WPEPreparedRenderPipeline?
    /// True when the pipeline has effect / custom-shader passes (scroll,
    /// waterwaves, pulse, audio bars, …). These animate every frame via
    /// `g_Time` / `g_AudioSpectrum*`, so the view must run continuously even
    /// when there are no dynamic textures or particles — otherwise the scene
    /// renders one frame and freezes. Computed once per load.
    private var hasAnimatedShaderPasses = false
    /// WPE `general.supportsaudioprocessing`. An audio-reactive scene must stay
    /// on the continuous-frame path so `g_AudioSpectrum*` re-samples every frame
    /// — `pipelineHasAnimatedPasses` only catches audio shaders under
    /// `effects/`/`workshop/`, so a custom-path audio shader would otherwise
    /// freeze on the static/on-demand path.
    private var sceneSupportsAudioProcessing = false
    private(set) var lastRuntimeUniforms: WPEMetalRuntimeUniforms?
    private(set) var lastFramePipeline: WPEPreparedRenderPipeline?
    /// Property-key → render-target bindings for the loaded scene, used by the
    /// incremental settings-apply path. Empty until `load()` completes.
    private(set) var scenePropertyBindings: [String: [WPEScenePropertyBinding]] = [:]
    /// Live per-object visibility, seeded from the document and mutated by
    /// `applyScenePropertyPatch` so a settings toggle takes effect without reload.
    private var liveLayerVisibility: [String: Bool] = [:]
    private var liveTextVisibility: [String: Bool] = [:]
    /// Object hierarchy + own baked visibility (groups included), used to fold a
    /// layer script's `visible` against its ancestors' CURRENT visibility so a
    /// script can't show a layer under a hidden ancestor. See `WPESceneDocument`.
    private var objectParentByID: [String: String] = [:]
    private var ownVisibilityByID: [String: Bool] = [:]

    var renderedTexture: MTLTexture? { outputTexture }

    /// Test hook: reads a value from the scene's shared script store after a
    /// render, so a test can assert a HIDDEN text object's compute script ran
    /// (populated `shared`) rather than being skipped by the visibility filter.
    func sharedScriptValueForTesting(_ key: String) -> Any? {
        sceneScriptSharedState?.get(key)
    }
    /// Read-back of the first frame, captured at the end of `performLoad()`
    /// **only when scene-debug artifacts are enabled**. Production leaves it
    /// `nil`; the inspector requests a poster from the next normally-presented
    /// frame via `captureLivePosterFromNextFrame()`.
    var previewSnapshot: NSImage? { cachedSnapshot }

    /// Reuses the next frame the renderer was already going to present as the
    /// inspector poster. This deliberately avoids forcing a fresh synchronous
    /// `renderCurrentFrame()` on the main actor. Dynamic scenes resolve on their
    /// next natural frame; static scenes re-present the retained output texture.
    func captureLivePosterFromNextFrame() async -> NSImage? {
        guard didLoad, hasPresentedFrame, renderPipeline != nil, currentProfile == .quality else {
            Logger.info(
                "[live-poster] skipped: didLoad=\(didLoad) presented=\(hasPresentedFrame) pipeline=\(renderPipeline != nil) profile=\(String(describing: currentProfile))",
                category: .wpeRender
            )
            return nil
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pendingLivePosterCaptures[id] = continuation
                requestLivePosterCaptureFrame()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishLivePosterCapture(id: id, image: nil)
            }
        }
    }

    private func requestLivePosterCaptureFrame() {
        if needsContinuousFrames {
            mtkView.setNeedsDisplay(mtkView.bounds)
        } else if outputTexture != nil {
            mtkView.draw()
        } else {
            mtkView.setNeedsDisplay(mtkView.bounds)
        }
    }

    private func takePendingLivePosterCaptures() -> LivePosterCaptureBatch? {
        guard !pendingLivePosterCaptures.isEmpty else { return nil }
        let captures = pendingLivePosterCaptures
        pendingLivePosterCaptures.removeAll(keepingCapacity: true)
        return LivePosterCaptureBatch(renderer: self, captures: captures)
    }

    nonisolated private static func capturePendingLivePostersAfterPresent(
        _ batch: LivePosterCaptureBatch,
        from texture: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        releaseSource: @escaping @Sendable () -> Void
    ) {
        batch.captureAfterPresent(
            from: texture,
            completed: commandBuffer.status == .completed,
            releaseSource: releaseSource
        )
    }

    private static func livePosterPresentCompletion(
        for batch: LivePosterCaptureBatch?
    ) -> (@Sendable (MTLTexture, MTLCommandBuffer, @escaping @Sendable () -> Void) -> Void)? {
        guard let batch else { return nil }
        return { source, commandBuffer, releaseSource in
            Self.capturePendingLivePostersAfterPresent(
                batch,
                from: source,
                commandBuffer: commandBuffer,
                releaseSource: releaseSource
            )
        }
    }

    private func finishLivePosterCapture(id: UUID, image: NSImage?) {
        guard let continuation = pendingLivePosterCaptures.removeValue(forKey: id) else { return }
        continuation.resume(returning: image)
    }

    private func finishAllPendingLivePosterCaptures(image: NSImage?) {
        guard !pendingLivePosterCaptures.isEmpty else { return }
        let captures = pendingLivePosterCaptures
        pendingLivePosterCaptures.removeAll(keepingCapacity: false)
        LivePosterCaptureBatch(renderer: self, captures: captures).finish(image: image)
    }

    private static func finishLivePosterCaptures(
        _ batch: LivePosterCaptureBatch?,
        image: NSImage?
    ) {
        batch?.finish(image: image)
    }

    var onProgress: (@MainActor (String) -> Void)?
    var resolutionDiagnostics: WPEResolutionDiagnosticsSnapshot {
        resolutionTracer.snapshot()
    }
    /// GPU command-buffer errors observed since load — surfaced in the scene
    /// diagnostic log because they fire post-return on a GPU thread and never
    /// reach `loadDiagnostics`.
    var gpuErrorSummary: (count: Int, last: String?) {
        executor.gpuErrorSink.summary
    }

    /// Custom-shader compile failures (the only Release-visible signal — the dump
    /// is hard-off there). A failed pass is silently skipped.
    var shaderErrorSummary: (count: Int, entries: [(shader: String, reason: String)]) {
        executor.shaderErrorSink.summary
    }

    init(
        descriptor: SceneDescriptor,
        cacheRootURL: URL,
        assetProvider: (any WPESceneAssetProvider)? = nil,
        projectManifestRootURL: URL? = nil,
        dependencyMounts: [WPEAssetMount],
        engineAssetsRootURL: URL? = nil,
        frame: CGRect,
        device: MTLDevice,
        frameClock: WPEMetalFrameClock = WPEMetalFrameClock(),
        pointerSampler: WPEMetalPointerSampler = .live,
        snapshotter: WPEMetalTextureSnapshotter = .shared
    ) throws {
        self.descriptor = descriptor
        self.cacheRootURL = cacheRootURL
        self.dependencyMounts = dependencyMounts
        self.engineAssetsRootURL = engineAssetsRootURL
        let executor = try WPEMetalRenderExecutor(device: device)
        let resolutionTracer = WPEResolutionTracer()
        // A managed (in-app-downloaded) install lives inside our sandbox
        // container — it's always readable and has no security scope to open, so
        // don't gate it on `startAccessingSecurityScopedResource()` (which
        // returns false for container-internal paths).
        let needsScope = engineAssetsRootURL.map { !WPEEngineAssetsLibrary.isContainerInternal($0) } ?? false
        let didStartEngineAssetsAccess = needsScope
            ? (engineAssetsRootURL?.startAccessingSecurityScopedResource() ?? false)
            : false
        // Feed the engine-assets root to the resolver when it needs no scope
        // (container-internal) or its security scope actually opened — otherwise
        // the resolver would attempt reads from an unauthorized root.
        let effectiveEngineAssetsRootURL: URL? = engineAssetsRootURL.flatMap {
            (!needsScope || didStartEngineAssetsAccess) ? $0 : nil
        }
        // Only the scoped case has access to stop on teardown.
        self.activeEngineAssetsRootURL = didStartEngineAssetsAccess ? engineAssetsRootURL : nil
        self.effectiveEngineAssetsRootURL = effectiveEngineAssetsRootURL
        self.sceneAssetProvider = assetProvider
        self.projectManifestRootURL = projectManifestRootURL
        if let assetProvider {
            self.entryResolver = SceneResourceResolver(provider: assetProvider, cacheRootURL: cacheRootURL)
            self.resourceResolver = WPEMultiRootResourceResolver(
                primaryProvider: assetProvider,
                dependencyMounts: dependencyMounts,
                engineAssetsRootURL: effectiveEngineAssetsRootURL,
                tracer: resolutionTracer
            )
        } else {
            self.entryResolver = SceneResourceResolver(cacheRootURL: cacheRootURL)
            self.resourceResolver = WPEMultiRootResourceResolver(
                primaryRootURL: cacheRootURL,
                dependencyMounts: dependencyMounts,
                engineAssetsRootURL: effectiveEngineAssetsRootURL,
                tracer: resolutionTracer
            )
        }
        self.resolutionTracer = resolutionTracer
        self.executor = executor
        self.textureLoader = WPEMetalTextureLoader(device: device)
        self.mtkView = WPEInteractiveMTKView(frame: frame, device: device)
        self.frameClock = frameClock
        self.pointerSampler = pointerSampler
        self.snapshotter = snapshotter
        super.init()

        if needsScope && !didStartEngineAssetsAccess {
            Logger.warning(
                "Wallpaper Engine assets security scope could not be started — engine fallback disabled for this session",
                category: .fileAccess
            )
        }

        mtkView.delegate = self
        mtkView.colorPixelFormat = WPEMetalRenderExecutor.outputPixelFormat
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        mtkView.preferredFramesPerSecond = Self.defaultPreferredFPS
        mtkView.autoresizingMask = [.width, .height]
        mtkView.enableSetNeedsDisplay = false
        mtkView.isPaused = true
    }

    var nsView: NSView { mtkView }

    func load() async throws {
        guard !didLoad else { return }
        let descriptorSummary = "\(descriptor.workshopID) tier=\(descriptor.capabilityTier.rawValue) entry=\(descriptor.entryFile)"
        WPESceneDebugArtifacts.shared.beginSession(
            workshopID: descriptor.workshopID,
            descriptor: descriptorSummary
        )
        #if !LITE_BUILD && DEBUG
        WPECanonicalTraceRecorder.shared.beginScene(
            workshopID: descriptor.workshopID,
            projectJsonPath: projectManifestRootURL?.appendingPathComponent(descriptor.entryFile).path,
            descriptor: descriptorSummary
        )
        #endif
        loadGeneration &+= 1
        debugStage("load.begin", descriptorSummary)
        do {
            try await performLoad()
            loadDiagnostics = nil
            WPESceneDebugArtifacts.shared.recordResolutionSummary(resolutionTracer.snapshot())
            WPESceneDebugArtifacts.shared.appendLog(
                "load() succeeded; presented first frame",
                level: .notice
            )
            if let snapshot = cachedSnapshot {
                WPESceneDebugArtifacts.shared.recordFirstFrame(image: snapshot)
            }
            WPESceneDebugArtifacts.shared.endSession()
        } catch {
            loadDiagnostics = diagnostic(for: error)
            logSceneFailureDiagnostics(error: error)
            WPESceneDebugArtifacts.shared.recordResolutionSummary(resolutionTracer.snapshot())
            WPESceneDebugArtifacts.shared.appendLog(
                "load() failed: \(error)",
                level: .error
            )
            if let snapshot = cachedSnapshot {
                WPESceneDebugArtifacts.shared.recordFirstFrame(image: snapshot)
            }
            WPESceneDebugArtifacts.shared.endSession()
            if let reason = Self.metalUnsupportedReason(for: error) {
                throw SceneRenderingError.metalRendererUnsupported(reason: reason)
            }
            throw error
        }
    }

    /// Classifies a `performLoad()` failure that is specific to the Metal
    /// renderer. Returning a non-nil reason promotes the error to
    /// `SceneRenderingError.metalRendererUnsupported`, which surfaces to the
    /// user as the scene's load error.
    private static func metalUnsupportedReason(for error: Error) -> String? {
        switch error {
        case let context as WPEMetalTextureLoadContextError:
            return metalUnsupportedReason(for: context.underlying)
        case let executorError as WPEMetalRenderExecutorError:
            switch executorError {
            case .shaderTranslatorUnavailable(let name, let reason):
                return "shader '\(name)': \(reason)"
            case .unsupportedShader(let name):
                return "shader '\(name)' unsupported by Metal renderer"
            case .unsupportedTarget:
                return "unsupported Metal render target"
            case .pipelineStateBuildFailed(let name, let detail):
                return "Metal pipeline '\(name)' rejected (likely stage_in mismatch): \(detail)"
            case .renderTargetDimensionsExceedDeviceLimit(let targetName, let width, let height, let limit):
                return "render target '\(targetName)' is \(width)x\(height), exceeding this device's \(limit)x\(limit) Metal texture limit"
            case .missingTexture(let reference):
                switch reference {
                case .previous:
                    return "previous-frame effect not implemented on Metal"
                case .fbo(let name):
                    return "named FBO '\(name)' unresolved on Metal pass — likely cross-pass alias miss"
                case .image, .asset:
                    return nil
                }
            case .commandQueueUnavailable, .libraryUnavailable, .pipelineUnavailable, .commandBufferFailed, .noRenderablePasses:
                return nil
            }
        default:
            return nil
        }
    }

    /// Dumps the resolved/missed resource tally to the persistent log so maintainers can `tail ~/Library/Logs/LiveWallpaper/runtime.log` and diagnose without having the DEBUG inspector window open.
    private func logSceneFailureDiagnostics(error: Error) {
        let snapshot = resolutionTracer.snapshot()
        let workshopID = descriptor.workshopID
        Logger.error(
            "Scene \(workshopID) failed: \(error)",
            category: .screenManager
        )
        let counts = snapshot.resolvedByOrigin
        let dependencyCount = counts.reduce(0) { partial, entry in
            if case .dependency = entry.key { return partial + entry.value }
            return partial
        }
        Logger.notice(
            "Scene \(workshopID) resolution summary — events:\(snapshot.events.count) resolved:\(snapshot.resolvedCount) scene:\(counts[.scene, default: 0]) builtin:\(counts[.builtin, default: 0]) engineAssets:\(counts[.engineAssets, default: 0]) dependency:\(dependencyCount)",
            category: .screenManager
        )
        let missed = snapshot.missedRefs
        if !missed.isEmpty {
            let summary = missed.prefix(40)
                .map { "\($0.ref) → \($0.finalOutcome.debugLabel)" }
                .joined(separator: " | ")
            let suffix = missed.count > 40 ? " | +\(missed.count - 40) more" : ""
            Logger.notice(
                "Scene \(workshopID) misses (top 40 of \(missed.count)): \(summary)\(suffix)",
                category: .screenManager
            )
        }
    }

    private func performLoad() async throws {
        let id = descriptor.workshopID

        debugStage("read.entry", "resolving \(descriptor.entryFile)")
        onProgress?("Reading scene")
        try Task.checkCancellation()
        let entryReader = entryResolver
        let sceneDescriptor = descriptor
        // project.json lives at the source folder for in-place scenes, the cache
        // dir for legacy ones — the property schema reads from here.
        let sceneCacheRoot = projectManifestRootURL ?? cacheRootURL
        let document = try await Task.detached(priority: .userInitiated) {
            let data = try entryReader.data(relativePath: sceneDescriptor.entryFile)
            let userValues = WallpaperEngineProjectPropertySchema.effectiveSceneValues(
                descriptor: sceneDescriptor,
                cacheRootURL: sceneCacheRoot
            )
            return try WPESceneDocumentParser.parse(data: data, userValues: userValues)
        }.value
        debugStage("read.entry.done", "imageObjects=\(document.imageObjects.count) particles=\(document.particleObjects.count) text=\(document.textObjects.count) sound=\(document.soundObjects.count)")
        try Task.checkCancellation()

        debugStage("graph.build", "begin")
        onProgress?("Building render graph")
        let cacheRoot = cacheRootURL
        let mounts = dependencyMounts
        let engineRoot = effectiveEngineAssetsRootURL
        let provider = sceneAssetProvider
        let graph = try await Task.detached(priority: .userInitiated) {
            let builder = provider.map {
                WPERenderGraphBuilder(primaryProvider: $0, dependencyMounts: mounts, engineAssetsRootURL: engineRoot)
            } ?? WPERenderGraphBuilder(cacheRootURL: cacheRoot, dependencyMounts: mounts, engineAssetsRootURL: engineRoot)
            return try builder.build(document: document)
        }.value
        debugStage("graph.build.done", "layers=\(graph.layers.count)")
        try Task.checkCancellation()

        debugStage("pipeline.build", "begin")
        onProgress?("Preparing render pipeline")
        let pipeline = try await Task.detached(priority: .userInitiated) {
            let builder = provider.map {
                WPERenderPipelineBuilder(primaryProvider: $0, dependencyMounts: mounts, engineAssetsRootURL: engineRoot)
            } ?? WPERenderPipelineBuilder(cacheRootURL: cacheRoot, dependencyMounts: mounts, engineAssetsRootURL: engineRoot)
            return try builder.build(graph: graph)
        }.value
        let passCount = pipeline.layers.reduce(0) { $0 + $1.passes.count }
        debugStage("pipeline.build.done", "passes=\(passCount)")
        for layer in pipeline.layers {
            for preparedPass in layer.passes {
                let p = preparedPass.pass
                let target: String = {
                    switch p.target {
                    case .scene: return "scene"
                    case .layerComposite(let n): return "comp:\(n)"
                    case .fbo(let n): return "fbo:\(n)"
                    }
                }()
                let source: String = {
                    switch p.source {
                    case .image(let v): return "img:\(v)"
                    case .asset(let v): return "asset:\(v)"
                    case .fbo(let v): return "fbo:\(v)"
                    case .previous: return "previous"
                    }
                }()
                let combos = p.combos.isEmpty
                    ? "-"
                    : p.combos.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
                debugStage(
                    "pipeline.pass",
                    "layer=\(layer.graphLayer.objectName) id=\(p.id) shader=\(p.shader) src=\(source) tgt=\(target) blend=\(p.blending) combos=\(combos)"
                )
            }
        }
        WPESceneDebugArtifacts.shared.recordPassList(pipeline)
        try Task.checkCancellation()

        renderGraph = graph
        renderPipeline = pipeline
        createdLayerTemplatesByImagePath = Self.createdLayerTemplatesByImagePath(pipeline)
        executor.invalidateStaticLayerCache()
        textureCacheBudgetBytesResolved = Self.textureCacheBudgetBytes
        hasAnimatedShaderPasses = Self.pipelineHasAnimatedPasses(pipeline)
        // Seed incremental-apply state. The graph builder already baked each
        // layer's authored `visible` into the pipeline, so these baselines
        // simply mirror it for later diffing in `applyScenePropertyPatch`.
        scenePropertyBindings = document.propertyBindings
        objectParentByID = document.objectParentByID
        ownVisibilityByID = document.ownVisibilityByID
        liveLayerVisibility = Dictionary(
            document.imageObjects.map { ($0.id, $0.visible) },
            uniquingKeysWith: { first, _ in first }
        )
        liveTextVisibility = Dictionary(
            document.textObjects.map { ($0.id, $0.visible) },
            uniquingKeysWith: { first, _ in first }
        )
        cameraUniforms = WPEMetalCameraUniforms(
            orthogonalProjection: document.general.orthogonalProjection,
            sceneCamera: document.camera,
            usesPerspectiveProjection: document.general.usesPerspectiveProjection,
            lightAmbientColor: document.general.lightAmbientColor,
            lightSkylightColor: document.general.lightSkylightColor,
            sceneHDR: document.general.hdr,
            bloom: document.general.bloom
        )
        // Perspective scenes (orthogonalprojection:null) have no authored pixel
        // canvas — the fixed 1920×1080 fallback renders every panel/label at half
        // the density of a 4K display, then present upscales it to a blur. WPE
        // renders perspective natively, so its 8px HUD text is crisp where ours
        // mushed. Render perspective at the drawable resolution (capped 4K, never
        // below the authored size) so text pixels are 1:1 with the display.
        // Geometry is fov-based (resolution-independent) — only pixel density and
        // FBO cost change. Kill switch: WPEMetalPerspectiveNativeResolution -bool NO.
        if document.general.usesPerspectiveProjection,
           Self.perspectiveNativeResolutionEnabled {
            let drawable = mtkView.drawableSize
            let base = cameraUniforms.renderSize
            let cap = CGSize(width: 3840, height: 2160)
            var targetW = min(max(drawable.width, base.width), cap.width)
            var targetH = min(max(drawable.height, base.height), cap.height)
            // Clamp to the memory tier's pixel budget (HDR float16 counts double)
            // so native-res + HDR bloom don't stack into an OOM on 8/16 GB Macs.
            let budget = WPEMemoryTier.current.perspectiveRenderPixelBudget(hdr: document.general.hdr)
            let pixels = Double(targetW * targetH)
            if pixels > budget {
                let shrink = (budget / pixels).squareRoot()
                targetW = max(base.width, (targetW * CGFloat(shrink)).rounded())
                targetH = max(base.height, (targetH * CGFloat(shrink)).rounded())
            }
            if targetW > base.width + 1 || targetH > base.height + 1 {
                cameraUniforms = WPEMetalCameraUniforms(
                    orthogonalProjection: WPESceneOrthogonalProjection(
                        width: targetW, height: targetH, auto: false
                    ),
                    sceneCamera: document.camera,
                    usesPerspectiveProjection: true,
                    lightAmbientColor: document.general.lightAmbientColor,
                    lightSkylightColor: document.general.lightSkylightColor,
                    sceneHDR: document.general.hdr,
                    bloom: document.general.bloom
                )
            }
        }
        cameraParallaxSettings = document.general.cameraParallax
        sceneSupportsAudioProcessing = document.general.supportsAudioProcessing
        cameraParallaxSmoother.reset()
        sceneRenderSize = cameraUniforms.renderSize
        debugStage("camera", "renderSize=\(Int(sceneRenderSize.width))x\(Int(sceneRenderSize.height))")
        sceneScriptSharedState = WPESharedScriptState()
        loadDynamicOriginScripts(from: document)

        // Pre-warm shader transpile off-thread, overlapping the texture/particle/text
        // load below; awaited at the render.firstFrame gate so the first synchronous
        // render() hits the warmed cache instead of paying the lazy transpile inline.
        async let shaderWarm: Void = prewarmCustomShaders(for: pipeline, textObjects: document.textObjects)

        debugStage("textures.load", "begin (pipeline-driven)")
        onProgress?("Loading textures")
        try await loadTextures(for: pipeline)
        indexOnDemandVideoLayers(pipeline: pipeline)
        debugStage("textures.load.done", "loaded=\(loadedTextures.count) dynamic=\(dynamicTextureSources.count)")
        dumpLoadedTexturesIfRequested()
        try Task.checkCancellation()

        debugStage("particles.load", "begin")
        onProgress?("Loading particle systems")
        await loadParticleSystems(from: document)
        debugStage(
            "particles.load.done",
            "systems=\(particleSystems.count)"
        )
        try Task.checkCancellation()

        debugStage("text.load", "begin")
        onProgress?("Loading text overlays")
        loadTextOverlays(from: document)
        debugStage("text.load.done", "objects=\(textObjects.count)")
        try Task.checkCancellation()

        // Layer visible-scripts (video intros etc.). After textures so the video
        // sources exist; runs each script's init() to seed visibility/alpha and
        // suppress auto-play on script-owned video sources.
        loadLayerScripts(from: document)
        try Task.checkCancellation()

        // Audio startup is deferred to after the first frame (see below): the
        // synchronous `runtime.start(sounds:)` is a 300-900ms hit that does not
        // gate any pixels, so keeping it on the load path only inflates perceived
        // load time.
        // Finish seeding the shader cache before the first (synchronous) render() so it
        // hits warmed entries. By now this has overlapped the entire texture/particle/text
        // load above; on heavy scenes the ~1.9s transpile is already absorbed.
        await shaderWarm
        debugStage("render.firstFrame", "begin")
        onProgress?("Rendering scene")

        // Render the FIRST frame synchronously: it is read back on the CPU right
        // after load() by the scene-debug snapshot and the `renderedTexture`
        // accessor (tests) — an async submission would let those read-backs race
        // the GPU and sample an unfinished frame. It is a one-time cost; the
        // steady-state draw loop switches to async below.
        executor.synchronizeFrameCompletion = true
        let capture = beginGPUCaptureIfRequested()
        outputTexture = try renderCurrentFrame()
        capture?.stop()

        if let outputTexture {
            // Capture per-pass scene-target RT hashes BEFORE finishFrame latches
            // and serializes the trace — otherwise recordPassOutputs runs after the
            // trace is already written and the per-pass output hashes are dropped.
            #if DEBUG
            dumpScenePassesIfRequested()
            #endif
            // The snapshot + visual-stats read-backs here exist only to feed the
            // scene-debug artifacts (first-frame PNG + stats). The inspector
            // reuses a *current* live frame on demand (captureLivePoster), so
            // production skips this synchronous load-path read-back — it would
            // slow first-frame present, and frame 0 often predates a scene's
            // intro / warmed particles / decoded video anyway.
            if WPESceneDebugArtifacts.shared.isEnabled {
                cachedSnapshot = snapshotter.snapshot(from: outputTexture)
                let stats = WPEMetalTextureVisualStats.analyze(texture: outputTexture)
                if let stats {
                    WPESceneDebugArtifacts.shared.recordFirstFrameStats(stats)
                }
                #if !LITE_BUILD && DEBUG
                WPECanonicalTraceRecorder.shared.finishFrame(
                    outputTexture: outputTexture,
                    runtimeUniforms: lastRuntimeUniforms,
                    firstFrameStats: stats,
                    resolutionDiagnostics: resolutionTracer.snapshot()
                )
                #endif
            }
            dumpOutputTextureIfRequested(outputTexture)
        }
        hasPresentedFrame = true
        didLoad = true
        // Steady-state draw loop: async in production (no per-frame CPU stall on
        // the GPU); stay synchronous only when a per-frame read-back is active
        // (scene-debug / GPU capture / pass dumps) or pinned via WPEMetalSerializeFrames.
        executor.synchronizeFrameCompletion = shouldSynchronizeFrames()
        applyPerformanceProfile(currentProfile)
        mtkView.setNeedsDisplay(mtkView.bounds)
        debugStage("render.firstFrame.done", "size=\(outputTexture?.width ?? 0)x\(outputTexture?.height ?? 0) snapshot=\(cachedSnapshot == nil ? "none" : "saved")")
        // Defer audio startup to the first actual present (handled in draw(in:))
        // so it never blocks the first visible frame. Empty-sound scenes clear
        // any prior runtime now.
        if document.soundObjects.isEmpty {
            soundRuntime = nil
            pendingAudioStartupDocument = nil
        } else {
            pendingAudioStartupDocument = document
        }
        _ = id
    }

    /// Boot the sound runtime once the first frame has actually presented (called
    /// from `draw(in:)` after the first successful `present`). The expensive
    /// `prepare(sounds:)` (file loads + buffer decode, ~300-900ms) runs OFF the
    /// main actor so the wallpaper never stalls but produces NO audio. Playback
    /// (`play()`) only starts back on the main actor, AFTER confirming the scene
    /// is still current — so a reload/cleanup during preparation can never let a
    /// stale scene's audio play (it just releases the prepared engine). Mute and
    /// volume are re-applied with the latest values immediately before `play()`,
    /// so a toggle during the off-main window is honored before any sound.
    private func beginDeferredAudioStartup() {
        guard let document = pendingAudioStartupDocument else { return }
        pendingAudioStartupDocument = nil
        let sounds = document.soundObjects
        guard !sounds.isEmpty else {
            soundRuntime = nil
            return
        }
        let runtime = WPESoundRuntime(resolver: resourceResolver)
        runtime.setMuted(pendingAudioMuted)
        runtime.setMasterVolume(pendingAudioVolume)
        let generation = loadGeneration
        let workshopID = descriptor.workshopID
        deferredAudioStartupTask?.cancel()
        deferredAudioStartupTask = Task.detached(priority: .userInitiated) { [weak self] in
            _ = runtime.prepare(sounds: sounds)   // off-main, decodes files; nothing audible yet
            await MainActor.run {
                guard let self, !Task.isCancelled, self.loadGeneration == generation else {
                    // Scene reloaded / torn down while we were preparing. play()
                    // never ran, so no stale audio leaked; release the engine.
                    runtime.stop()
                    return
                }
                // Apply the latest mute/volume (may have changed during prepare),
                // publish the runtime, THEN start playback only if the scene is
                // still meant to run. A performance policy may have suspended us
                // during the off-main prepare window — in that case the runtime
                // stays prepared-but-silent and the next `.quality`/`resume()`
                // starts it (otherwise audio would leak on a suspended wallpaper).
                runtime.setMuted(self.pendingAudioMuted)
                runtime.setMasterVolume(self.pendingAudioVolume)
                self.soundRuntime = runtime
                if self.currentProfile == .quality {
                    if !runtime.play() {
                        Logger.warning("Scene \(workshopID) deferred audio failed to start (engine.start)", category: .wpeRender)
                    }
                }
            }
        }
    }

    #if DEBUG
    /// Whether the current scene is in the GPU-capture set. `WPEMetalCaptureScene`
    /// holds a string array (the Developer Tools "GPU capture" list); a single
    /// `defaults write ... WPEMetalCaptureScene <id>` string — optionally comma/
    /// space separated — is still honored for back-compat with the CLI workflow.
    private func gpuCaptureRequestedForCurrentScene() -> Bool {
        let d = UserDefaults.standard
        let raw: [String]
        if let arr = d.stringArray(forKey: "WPEMetalCaptureScene") {
            raw = arr
        } else if let s = d.string(forKey: "WPEMetalCaptureScene") {
            raw = s.split(whereSeparator: { ",; ".contains($0) }).map(String.init)
        } else {
            raw = []
        }
        let wanted = Set(raw.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        return wanted.contains(descriptor.workshopID)
    }
    #endif

    /// Iterate every entry in `loadedTextures` and dump each to a PNG so we
    /// can verify whether the source-image upload actually carried bytes to
    /// the GPU. Same gate as the GPU trace + outputTexture dump.
    private func dumpLoadedTexturesIfRequested() {
        #if DEBUG
        guard gpuCaptureRequestedForCurrentScene() else { return }
        for (path, texture) in loadedTextures {
            let safeName = path
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "\\", with: "_")
            dumpTextureToPNG(texture, basename: "tex-\(safeName)")
        }
        #endif
    }

    #if DEBUG
    /// Dump one PNG per scene-target pass (collected by the executor when
    /// `WPEDumpScenePasses` matches this scene) so we can see exactly which pass
    /// introduces an artifact. PNGs land in App Support/LiveWallpaper/gpu-traces/
    /// as `wpe-<id>-scenepass-NN-<passid>-WxH.png`, ordered by draw sequence.
    private func dumpScenePassesIfRequested(suffix: String = "") {
        let wantedID = UserDefaults.standard.string(forKey: "WPEDumpScenePasses")
        let pngRequested = (wantedID?.isEmpty == false) && wantedID == descriptor.workshopID
        // Oracle mode attaches per-pass output hashes to the canonical trace even
        // without the workshopID-scoped PNG flag, and skips the (expensive) PNG
        // encode. `recordPassOutputs` matches by pass id, so passing the full dump
        // list is idempotent.
        guard pngRequested || WPEOracleMode.perPassHashesEnabled else { return }
        let dumps = executor.scenePassDumps
        WPECanonicalTraceRecorder.shared.recordPassOutputs(dumps)
        guard pngRequested else { return }
        Logger.notice(
            "[WPEDumpScenePasses] dumping \(dumps.count) scene-target passes\(suffix.isEmpty ? " (t0)" : " \(suffix)") for \(descriptor.workshopID)",
            category: .wpeRender
        )
        for (index, entry) in dumps.enumerated() {
            let safeLabel = entry.label
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: ".", with: "_")
            let ordinal = index < 10 ? "0\(index)" : "\(index)"
            dumpTextureToPNG(entry.texture, basename: "scenepass\(suffix)-\(ordinal)-\(safeLabel)")
        }
    }

    /// One-shot per-pass + composite dump once scene time crosses a threshold
    /// (default 6s, override via env `WPEDumpScenePassesAtTime`). Lets us see
    /// time-animated artifacts (e.g. a face distorted by an animated effect over
    /// time) that the first-frame dump at t≈0 misses. Same `WPEDumpScenePasses`
    /// gate. `composite` is the post-particle/text frame the user actually sees.
    private var didDumpScenePassesOverTime = false
    private func maybeDumpScenePassesOverTime(time: Double, composite: MTLTexture) {
        guard !didDumpScenePassesOverTime else { return }
        let wantedID = UserDefaults.standard.string(forKey: "WPEDumpScenePasses")
        guard let wantedID, !wantedID.isEmpty, wantedID == descriptor.workshopID else { return }
        let threshold = ProcessInfo.processInfo.environment["WPEDumpScenePassesAtTime"].flatMap(Double.init) ?? 6.0
        guard time >= threshold else { return }
        didDumpScenePassesOverTime = true
        let tag = "t\(Int(time.rounded()))s"
        dumpScenePassesIfRequested(suffix: "-\(tag)")
        dumpTextureToPNG(composite, basename: "composite-\(tag)")
    }

    private func dumpTextureToPNG(_ rawTexture: MTLTexture, basename: String) {
        let texture: MTLTexture
        if rawTexture.pixelFormat == .rgba8Unorm || rawTexture.pixelFormat == .rgba8Unorm_srgb {
            texture = rawTexture
        } else if let decoded = executor.debugDecodeToRGBA(rawTexture) {
            // BC/DXT/RG88/R8 etc. — decode by sampling into rgba8 so we can view it.
            texture = decoded
        } else {
            Logger.info(
                "[gpu-dump] texture dump: unsupported pixel format \(rawTexture.pixelFormat.rawValue) for \(basename)",
                category: .wpeRender
            )
            return
        }
        let bytesPerPixel = 4
        let bytesPerRow = texture.width * bytesPerPixel
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        texture.getBytes(
            &bytes,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height),
            mipmapLevel: 0
        )

        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else {
            Logger.info("[gpu-dump] texture dump: CGDataProvider failed for \(basename)", category: .wpeRender)
            return
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let cgImage = CGImage(
            width: texture.width,
            height: texture.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            Logger.info("[gpu-dump] texture dump: CGImage failed for \(basename)", category: .wpeRender)
            return
        }

        let nsImage = NSImage(cgImage: cgImage, size: CGSize(width: texture.width, height: texture.height))
        do {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let dir = support
                .appendingPathComponent("LiveWallpaper", isDirectory: true)
                .appendingPathComponent("gpu-traces", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(
                "wpe-\(descriptor.workshopID)-\(basename)-\(texture.width)x\(texture.height).png"
            )
            guard let tiff = nsImage.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                Logger.info("[gpu-dump] texture dump: PNG encode failed for \(basename)", category: .wpeRender)
                return
            }
            try png.write(to: url)
            Logger.notice("[gpu-dump] texture dump → \(url.path)", category: .wpeRender)
        } catch {
            Logger.info(
                "[gpu-dump] texture dump failed for \(basename): \(error.localizedDescription)",
                category: .wpeRender
            )
        }
    }
    #endif

    /// Writes the raw post-render `outputTexture` (the scene render output
    /// *before* present blit) to disk as a PNG via a GPU blit into a
    /// `.storageModeShared` `MTLBuffer` — the robust readback path for
    /// large textures where `texture.getBytes(...)` can silently return
    /// stale bytes on some driver/storage combos. Gated on the same
    /// `WPEMetalCaptureScene` UserDefault as the GPU trace capture.
    private func dumpOutputTextureIfRequested(_ texture: MTLTexture) {
        #if DEBUG
        guard gpuCaptureRequestedForCurrentScene() else { return }
        let device = texture.device
        guard texture.pixelFormat == .rgba8Unorm || texture.pixelFormat == .rgba8Unorm_srgb else {
            Logger.info(
                "[WPEMetalCaptureScene] outputTexture dump: unsupported pixel format \(texture.pixelFormat.rawValue)",
                category: .wpeRender
            )
            return
        }
        let bytesPerPixel = 4
        let bytesPerRow = texture.width * bytesPerPixel
        let totalBytes = bytesPerRow * texture.height
        guard let buffer = device.makeBuffer(length: totalBytes, options: .storageModeShared) else {
            Logger.info("[WPEMetalCaptureScene] outputTexture dump: makeBuffer failed", category: .wpeRender)
            return
        }
        guard let queue = device.makeCommandQueue(),
              let cb = queue.makeCommandBuffer(),
              let blit = cb.makeBlitCommandEncoder() else {
            Logger.info("[WPEMetalCaptureScene] outputTexture dump: cannot create blit encoder", category: .wpeRender)
            return
        }
        blit.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: buffer,
            destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: totalBytes
        )
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        guard cb.status == .completed else {
            Logger.info(
                "[WPEMetalCaptureScene] outputTexture dump: blit failed (status=\(cb.status.rawValue))",
                category: .wpeRender
            )
            return
        }

        let provider = CGDataProvider(dataInfo: nil, data: buffer.contents(), size: totalBytes) { _, _, _ in }
        guard let provider else {
            Logger.info("[WPEMetalCaptureScene] outputTexture dump: CGDataProvider failed", category: .wpeRender)
            return
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let cg = CGImage(
            width: texture.width,
            height: texture.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            Logger.info("[WPEMetalCaptureScene] outputTexture dump: CGImage failed", category: .wpeRender)
            return
        }
        let nsImage = NSImage(cgImage: cg, size: CGSize(width: texture.width, height: texture.height))
        let fm = FileManager.default
        do {
            let support = try fm.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let dir = support
                .appendingPathComponent("LiveWallpaper", isDirectory: true)
                .appendingPathComponent("gpu-traces", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(
                "wpe-\(descriptor.workshopID)-output-\(texture.width)x\(texture.height).png"
            )
            guard let tiff = nsImage.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                Logger.info("[WPEMetalCaptureScene] outputTexture dump: PNG encode failed", category: .wpeRender)
                return
            }
            try png.write(to: url)
            // Also probe the buffer contents directly so we have a numeric
            // sanity check independent of CG / PNG encoding: how many of the
            // first 64 KB of bytes are non-zero.
            let probe = buffer.contents().assumingMemoryBound(to: UInt8.self)
            let probeLength = min(64 * 1024, totalBytes)
            var nonZero = 0
            for i in 0..<probeLength where probe[i] != 0 { nonZero += 1 }
            Logger.notice(
                "[WPEMetalCaptureScene] outputTexture dump → \(url.path) (first \(probeLength) bytes: \(nonZero) non-zero)",
                category: .wpeRender
            )
        } catch {
            Logger.info(
                "[WPEMetalCaptureScene] outputTexture dump failed: \(error.localizedDescription)",
                category: .wpeRender
            )
        }
        #endif
    }

    /// Camera-parallax magnitude multiplier. Reads `WPEParallaxGain` from the
    /// app's `Taijia.LiveWallpaper` suite first, then the process `.standard`
    /// domain (which IS that suite in the renderer process), falling back to the
    /// built-in default when the key is absent. A present value is normalized by
    /// `WPECameraParallaxFrame.clampedGain` (0 honored = parallax off, negatives
    /// clamp to 0, capped at `maxGain`). Tune to match Wallpaper Engine with:
    ///   defaults write Taijia.LiveWallpaper WPEParallaxGain 0.8
    private static func resolvedParallaxGain() -> Double {
        for defaults in [UserDefaults.appSuite, .standard] {
            guard defaults.object(forKey: "WPEParallaxGain") != nil else { continue }
            return WPECameraParallaxFrame.clampedGain(defaults.double(forKey: "WPEParallaxGain"))
        }
        return WPECameraParallaxFrame.defaultGain
    }

    /// DEBUG-only `MTLCaptureManager` wrap around `renderCurrentFrame()`. When
    /// `UserDefaults.standard.string(forKey: "WPEMetalCaptureScene")` matches
    /// the active scene's workshopID, the render's `MTLCommandBuffer` is
    /// captured to a `.gputrace` file under `/tmp` so a maintainer can open
    /// it in Xcode and inspect every render-pass attachment, bound texture,
    /// uniform buffer, and translated MSL source for that scene.
    ///
    /// Triggered via:
    ///   defaults write Taijia.LiveWallpaper WPEMetalCaptureScene 3669681034
    /// (then reload the wallpaper). Clear with:
    ///   defaults delete Taijia.LiveWallpaper WPEMetalCaptureScene
    private func beginGPUCaptureIfRequested() -> GPUCaptureHandle? {
        #if DEBUG
        guard gpuCaptureRequestedForCurrentScene() else { return nil }
        let manager = MTLCaptureManager.shared()
        guard manager.supportsDestination(.gpuTraceDocument) else {
            Logger.info(
                "[WPEMetalCaptureScene] device does not support gpuTraceDocument capture; ensure MetalCaptureEnabled is YES in Info.plist and Xcode is attached.",
                category: .wpeRender
            )
            return nil
        }
        let descriptorObj = MTLCaptureDescriptor()
        descriptorObj.captureObject = executor.textureSourceDevice
        descriptorObj.destination = .gpuTraceDocument
        let traceURL: URL
        do {
            traceURL = try Self.makeCaptureURL(workshopID: descriptor.workshopID)
        } catch {
            Logger.info(
                "[WPEMetalCaptureScene] could not create capture directory: \(error.localizedDescription)",
                category: .wpeRender
            )
            return nil
        }
        descriptorObj.outputURL = traceURL
        do {
            try manager.startCapture(with: descriptorObj)
            Logger.notice(
                "[WPEMetalCaptureScene] capture started for \(descriptor.workshopID) → \(traceURL.path)",
                category: .wpeRender
            )
            WPESceneDebugArtifacts.shared.appendLog(
                "[capture.start] gputrace → \(traceURL.path)",
                level: .notice
            )
            return GPUCaptureHandle(manager: manager, outputURL: traceURL)
        } catch {
            Logger.info(
                "[WPEMetalCaptureScene] capture start failed: \(error.localizedDescription)",
                category: .wpeRender
            )
            return nil
        }
        #else
        return nil
        #endif
    }

    #if DEBUG
    private static func makeCaptureURL(workshopID: String) throws -> URL {
        let fm = FileManager.default
        let support = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = support
            .appendingPathComponent("LiveWallpaper", isDirectory: true)
            .appendingPathComponent("gpu-traces", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let suffix = UUID().uuidString.prefix(8)
        return dir.appendingPathComponent("wpe-\(workshopID)-\(suffix).gputrace")
    }

    private struct GPUCaptureHandle {
        let manager: MTLCaptureManager
        let outputURL: URL

        func stop() {
            guard manager.isCapturing else { return }
            manager.stopCapture()
            Logger.notice(
                "[WPEMetalCaptureScene] capture written → \(outputURL.path)",
                category: .wpeRender
            )
            WPESceneDebugArtifacts.shared.appendLog(
                "[capture.stop] gputrace ready at \(outputURL.path)",
                level: .notice
            )
        }
    }
    #else
    private struct GPUCaptureHandle {
        func stop() {}
    }
    #endif

    /// One-shot debug breadcrumb shared by every load-path stage. Emits to
    /// the `wpeRender` os.Logger category AND mirrors into the per-scene
    /// `scene.log` so the file artifact stays self-contained without the
    /// reader having to cross-reference Console.app.
    /// Per-load stage breadcrumb. Gated on the scene-debug switch (Developer
    /// Tools → "Scene debug artifacts"), which is off by default — so a normal
    /// run emits none of these and, because `detail` is `@autoclosure`, never
    /// even builds the (per-stage, per-pass) interpolated strings. Flip the
    /// switch on to get the full console + scene.log stage trace back.
    private func debugStage(_ stage: String, _ detail: @autoclosure () -> String) {
        guard WPESceneDebugArtifacts.shared.isEnabled else { return }
        let detail = detail()
        Logger.debug(
            "[WPE-DEBUG][scene:\(descriptor.workshopID)][stage:\(stage)] \(detail)",
            category: .wpeRender
        )
        WPESceneDebugArtifacts.shared.appendLog("[\(stage)] \(detail)")
    }

    /// Whether the executor should submit frames synchronously (block on GPU
    /// completion) for this scene. True only when a CPU read-back of the rendered
    /// frame will happen — scene-debug artifacts (first-frame snapshot / stats),
    /// GPU capture, per-pass dumps — or the operator pins it via
    /// `WPEMetalSerializeFrames`. Production has none of these, so frames submit
    /// asynchronously and the CPU never stalls on the GPU per frame.
    private func shouldSynchronizeFrames() -> Bool {
        if UserDefaults.standard.bool(forKey: "WPEMetalSerializeFrames") { return true }
        if WPESceneDebugArtifacts.shared.isEnabled { return true }
        #if DEBUG
        if gpuCaptureRequestedForCurrentScene() { return true }
        if !(UserDefaults.standard.string(forKey: "WPEDumpScenePasses") ?? "").isEmpty { return true }
        #endif
        return false
    }

    // MARK: Script tick dispatch (ADR-003 step 1)

    private func tickLayerScript(
        _ instance: WPELayerScriptInstance,
        runtimeSeconds: Double,
        pointerFrame: WPEPointerFrame
    ) -> WPELayerScriptOutput? {
        Self.scriptAsyncTickEnabled
            ? instance.liveTick(runtimeSeconds: runtimeSeconds, pointerFrame: pointerFrame)
            : instance.tick(runtimeSeconds: runtimeSeconds, pointerFrame: pointerFrame)
    }

    private func tickTransformScript(
        _ instance: WPEDynamicTransformScriptInstance,
        pointer: SIMD2<Double>,
        runtimeSeconds: Double
    ) -> SIMD3<Double>? {
        Self.scriptAsyncTickEnabled
            ? instance.liveTick(pointerPosition: pointer, runtimeSeconds: runtimeSeconds)
            : instance.tick(pointerPosition: pointer, runtimeSeconds: runtimeSeconds)
    }

    private func tickTextScript(_ instance: WPESceneScriptInstance) -> String {
        Self.scriptAsyncTickEnabled ? instance.liveTickString() : instance.tickString()
    }

    /// Cursor events fire inside the frame path, so async mode enqueues them
    /// fire-and-forget (the output drains through the next frame's tick) and
    /// returns nil; legacy mode returns the output for immediate application.
    private func dispatchScriptCursorEvent(
        _ instance: WPELayerScriptInstance,
        event: WPELayerScriptCursorEvent,
        pointerFrame: WPEPointerFrame,
        runtimeSeconds: Double
    ) -> WPELayerScriptOutput? {
        guard Self.scriptAsyncTickEnabled else {
            return instance.dispatchCursorEvent(
                event,
                pointerFrame: pointerFrame,
                runtimeSeconds: runtimeSeconds
            )
        }
        instance.liveDispatchCursorEvent(
            event,
            pointerFrame: pointerFrame,
            runtimeSeconds: runtimeSeconds
        )
        return nil
    }

    /// Load/settings property pushes stay bounded-synchronous in both modes; the
    /// superseding variant additionally folds the result through the async slot.
    private func applyScriptUserProperties(
        _ instance: WPELayerScriptInstance,
        _ properties: [String: WPESceneScriptPropertyValue],
        runtimeSeconds: Double? = nil
    ) -> WPELayerScriptOutput? {
        Self.scriptAsyncTickEnabled
            ? instance.applyUserPropertiesSuperseding(properties, runtimeSeconds: runtimeSeconds)
            : instance.applyUserProperties(properties, runtimeSeconds: runtimeSeconds)
    }

    /// Computes one frame's runtime uniforms (clock, daytime, brightness, pointer) and submits the render pipeline with both runtime and camera uniforms.
    private func renderCurrentFrame() throws -> MTLTexture {
        guard let pipeline = renderPipeline else {
            throw WPEMetalRenderExecutorError.noRenderablePasses
        }
        let frameContext = sampleFrameContext()
        let uniforms = frameContext.uniforms
        var framePipeline = applyingLayerScriptTicks(
            to: pipeline,
            uniforms: uniforms,
            layerScriptPointerFrame: frameContext.layerScriptPointerFrame
        )
        // Kept around past the pipeline application so the text-overlay pass can
        // re-compose text anchors through the SAME live parent transforms.
        var liveTransforms = LiveScriptTransforms()
        if let ticked = tickDynamicTransformScripts(
            pointer: frameContext.pointer,
            time: uniforms.time
        ) {
            liveTransforms = ticked
            framePipeline = framePipeline.applyingLayerTransforms(
                origins: ticked.origins,
                scales: ticked.scales,
                angles: ticked.angles,
                parentByID: objectParentByID,
                hostTransforms: transformHostLocalTransformsByID
            )
        }
        // Hover hit-testing AFTER live transforms: the pads follow the moving
        // bodies (per-star cursorEnter → shared.cretN → label fade-in), so the
        // rects must come from this frame's transformed geometry.
        dispatchLayerHoverEvents(
            pointer: frameContext.followPointerIsLive ? frameContext.pointer : nil,
            pipeline: framePipeline,
            pointerFrame: frameContext.layerScriptPointerFrame,
            runtimeSeconds: uniforms.time
        )
        if !liveCreatedLayers.isEmpty {
            framePipeline = framePipeline.addingCreatedLayers(
                liveCreatedLayers,
                templatesByImagePath: createdLayerTemplatesByImagePath
            )
        }
        lastFramePipeline = framePipeline
        // Keep only currently-visible on-demand videos resident (releases hidden
        // ones, rebuilds revealed ones). No-op unless the scene has releasable
        // videos; reads the final per-frame visibility so it covers script-,
        // user-property- and condition-driven switches alike.
        reconcileVideoResidency(framePipeline)
        tickParticleSystems(
            time: uniforms.time,
            followPointerIsLive: frameContext.followPointerIsLive,
            pointer: frameContext.pointer
        )
        let currentTextures = try texturesForCurrentFrame(time: uniforms.time, pipeline: framePipeline)
        let frame = try executor.render(
            pipeline: framePipeline,
            size: sceneRenderSize,
            textures: currentTextures,
            dynamicTextureNames: dynamicTextureNames,
            dynamicLayerIDs: staticCacheExcludedLayerIDs,
            runtimeUniforms: uniforms,
            cameraUniforms: cameraUniforms,
            sceneID: descriptor.workshopID,
            particleSystems: particleSystems,
            particleTextures: particleTextures,
            particleNormalTextures: particleNormalTextures,
            particleParallax: frameContext.parallaxFrame
        )
        let liveTextByID = tickTextContentScripts()
        try drawLiveTextOverlays(
            onto: frame,
            uniforms: uniforms,
            liveTextByID: liveTextByID,
            transforms: liveTransforms,
            parallaxFrame: frameContext.parallaxFrame
        )
        #if DEBUG
        maybeDumpScenePassesOverTime(time: uniforms.time, composite: frame)
        #endif
        return frame
    }

    /// Per-frame inputs shared by the script/particle/encode stages, computed
    /// once at the top of `renderCurrentFrame`.
    private struct FrameContext {
        let uniforms: WPEMetalRuntimeUniforms
        let pointer: SIMD2<Double>
        let followPointerIsLive: Bool
        let layerScriptPointerFrame: WPEPointerFrame
        let parallaxFrame: WPECameraParallaxFrame
    }

    /// Samples the pointer, advances the frame clock/parallax smoothing, folds in
    /// live audio spectra, and derives the pointer frame layer scripts see.
    private func sampleFrameContext() -> FrameContext {
        // Pin follow-cursor effects to center when disabled, or when the
        // global cursor belongs to another display. Click capture stays
        // independent because Interaction can be enabled without Follow Cursor.
        let pointerSample = (mouseInteractionEnabled || mtkView.clickCaptureEnabled)
            ? pointerSampler.sample(mtkView)
            : .inactive
        let pointerIsInsideView = pointerSample.isInsideView
        let followPointerIsLive = mouseInteractionEnabled && pointerIsInsideView
        let clickPointerIsLive = mtkView.clickCaptureEnabled && pointerIsInsideView
        // The oracle pins the pointer (self = center, fidelity = the replayed
        // Windows cursor) so it never enters the trace as ambient state.
        let pointer = oracleFrameOverride?.pointer ?? (followPointerIsLive
            ? pointerSample.position
            : SIMD2<Double>(0.5, 0.5))
        if !followPointerIsLive && previousPointerWasLive {
            for system in particleSystems where system.tracksPointer {
                system.clearLiveParticles()
            }
        }
        previousPointerWasLive = followPointerIsLive
        var uniforms = frameClock.runtimeUniforms(
            profile: currentProfile,
            pointerPosition: pointer
        )
        // Freeze wall-clock time and time-of-day to fixed values so two oracle runs
        // of unchanged code produce byte-identical traces. Applied before parallax
        // and the audio rebuild below, both of which read `uniforms.time`, so they
        // inherit the frozen clock.
        if let override = oracleFrameOverride {
            uniforms = WPEMetalRuntimeUniforms(
                time: override.time,
                daytime: override.daytime,
                brightness: uniforms.brightness,
                pointerPosition: uniforms.pointerPosition
            )
        }
        // Compute once per frame (advances smoothing state); assigned below
        // after the audio path may have rebuilt `uniforms`.
        let parallaxFrame = cameraParallaxSmoother.frame(
            settings: cameraParallaxSettings,
            pointerPosition: pointer,
            time: uniforms.time,
            gain: cameraParallaxGain
        )
        // Audio-reactive uniforms follow the shared system-audio capture (the
        // loopback of whatever is playing), not the scene's own sounds — those
        // are already in the system mix the tap captures. `soundRuntime` stays
        // a pure player. When capture is off the broker is silent (flat bars).
        if SystemAudioCaptureManager.isCapturing, oracleFrameOverride == nil {
            let audio = SystemAudioCaptureManager.broker.snapshot()
            if audioDebugLogEnabled {
                audioDiagCounter += 1
                // Periodic (~every 60 frames) snapshot of what the renderer sees
                // on the shared audio broker — diagnoses audio-reactive scenes
                // whose bars don't move.
                if audioDiagCounter % 60 == 1 {
                    let peakL = audio.left.max() ?? 0
                    let peakR = audio.right.max() ?? 0
                    Logger.notice(
                        "[AudioCapture] renderer: capturing=true peakL=\(String(format: "%.3f", peakL)) peakR=\(String(format: "%.3f", peakR)) fps=\(mtkView.preferredFramesPerSecond) → feeding g_AudioSpectrum*",
                        category: .audioCapture
                    )
                }
            }
            uniforms = WPEMetalRuntimeUniforms(
                time: uniforms.time,
                daytime: uniforms.daytime,
                brightness: uniforms.brightness,
                pointerPosition: uniforms.pointerPosition,
                audioSpectrumLeft: audio.left.map(Double.init),
                audioSpectrumRight: audio.right.map(Double.init)
            )
        }
        uniforms.cameraParallax = parallaxFrame
        // Re-apply pointer fields here: the audio path above may have rebuilt
        // `uniforms` via the stereo initializer, which would otherwise reset
        // them. `g_PointerPositionLast` tracks motion regardless of click
        // capture; click state is neutral unless the Interaction toggle is on.
        let layerScriptPointerFrame = clickPointerIsLive
            ? mtkView.pointerFrame
            : WPEPointerFrame(
                position: pointer,
                clickPosition: pointer,
                isDown: false,
                isRightDown: false
            )
        uniforms.pointerPositionLast = previousPointer
        uniforms.pointerClick = clickPointerIsLive ? layerScriptPointerFrame : .neutral
        previousPointer = pointer
        lastRuntimeUniforms = uniforms
        return FrameContext(
            uniforms: uniforms,
            pointer: pointer,
            followPointerIsLive: followPointerIsLive,
            layerScriptPointerFrame: layerScriptPointerFrame,
            parallaxFrame: parallaxFrame
        )
    }

    /// Tick layer SceneScripts (e.g. a video intro that plays once then hides):
    /// each drives its layer's visibility/alpha + video playback. Gated so a
    /// scene with no layer scripts pays nothing (no per-frame pipeline rebuild).
    private func applyingLayerScriptTicks(
        to pipeline: WPEPreparedRenderPipeline,
        uniforms: WPEMetalRuntimeUniforms,
        layerScriptPointerFrame: WPEPointerFrame
    ) -> WPEPreparedRenderPipeline {
        guard !layerScriptInstances.isEmpty || !layerAlphaScriptInstances.isEmpty
            || !textVisibleScriptInstances.isEmpty || !textAlphaScriptInstances.isEmpty else {
            return pipeline
        }
        dispatchLayerCursorEvents(
            from: previousLayerScriptPointerFrame,
            to: layerScriptPointerFrame,
            runtimeSeconds: uniforms.time
        )
        previousLayerScriptPointerFrame = layerScriptPointerFrame
        // Sorted by objectID: these scripts cross-talk through shared state, so a
        // stable tick order keeps the frame deterministic (oracle) and behaviour
        // reproducible (dictionary order was arbitrary).
        for (objectID, instance) in layerScriptInstances.sorted(by: { $0.key < $1.key }) {
            if let output = tickLayerScript(instance, runtimeSeconds: uniforms.time, pointerFrame: layerScriptPointerFrame) {
                applyLayerScriptOutput(output, ownObjectID: objectID)
            }
        }
        for (objectID, instance) in layerAlphaScriptInstances.sorted(by: { $0.key < $1.key }) {
            if let output = tickLayerScript(instance, runtimeSeconds: uniforms.time, pointerFrame: layerScriptPointerFrame) {
                applyLayerAlphaScriptOutput(output, ownObjectID: objectID)
            }
        }
        for (objectID, instance) in textVisibleScriptInstances.sorted(by: { $0.key < $1.key }) {
            if let output = tickLayerScript(instance, runtimeSeconds: uniforms.time, pointerFrame: layerScriptPointerFrame) {
                applyTextScriptOutput(output, ownObjectID: objectID)
            }
        }
        for (objectID, instance) in textAlphaScriptInstances.sorted(by: { $0.key < $1.key }) {
            if let output = tickLayerScript(instance, runtimeSeconds: uniforms.time, pointerFrame: layerScriptPointerFrame) {
                liveTextAlpha[objectID] = output.own.alpha
            }
        }
        updateIntroPhaseAlign()
        return pipeline
            .applyingLayerVisibility(liveLayerVisibility)
            .applyingLayerAlpha(liveLayerAlpha)
    }

    private struct LiveScriptTransforms {
        var origins: [String: SIMD3<Double>] = [:]
        var scales: [String: SIMD3<Double>] = [:]
        var angles: [String: SIMD3<Double>] = [:]
    }

    /// Ticks the dynamic origin/scale/angles scripts; nil when the scene has none
    /// (the pipeline keeps its parse-time transforms).
    private func tickDynamicTransformScripts(
        pointer: SIMD2<Double>,
        time: Double
    ) -> LiveScriptTransforms? {
        guard !dynamicOriginScriptInstances.isEmpty
            || !dynamicScaleScriptInstances.isEmpty
            || !dynamicAnglesScriptInstances.isEmpty else { return nil }
        var transforms = LiveScriptTransforms()
        transforms.origins.reserveCapacity(dynamicOriginScriptInstances.count)
        // Sorted by objectID for the same shared-state-determinism reason as the
        // layer/text script loops above.
        for (objectID, instance) in dynamicOriginScriptInstances.sorted(by: { $0.key < $1.key }) {
            if let origin = tickTransformScript(instance, pointer: pointer, runtimeSeconds: time) {
                transforms.origins[objectID] = origin
            }
        }
        transforms.scales.reserveCapacity(dynamicScaleScriptInstances.count)
        for (objectID, instance) in dynamicScaleScriptInstances.sorted(by: { $0.key < $1.key }) {
            if let scale = tickTransformScript(instance, pointer: pointer, runtimeSeconds: time) {
                transforms.scales[objectID] = scale
            }
        }
        transforms.angles.reserveCapacity(dynamicAnglesScriptInstances.count)
        for (objectID, instance) in dynamicAnglesScriptInstances.sorted(by: { $0.key < $1.key }) {
            if let angle = tickTransformScript(instance, pointer: pointer, runtimeSeconds: time) {
                // WPE's script API exposes `angles` in degrees; scene.json and the
                // rotation math are radians (corpus-verified: all 353 nonzero static
                // angles ≤ 2π). Convert only at this boundary — the instance's
                // lastValue stays in script-space degrees so `value.y += k`
                // accumulation matches WPE (3509243656 universe spin was 57.3× fast).
                transforms.angles[objectID] = angle * (.pi / 180)
            }
        }
        return transforms
    }

    /// Particles tick (CPU sim) BEFORE the layer composite so the executor can
    /// interleave their draws at each system's scene paint index.
    private func tickParticleSystems(
        time: Double,
        followPointerIsLive: Bool,
        pointer: SIMD2<Double>
    ) {
        guard !particleSystems.isEmpty else { return }
        // Cursor in the centered render frame (Y-up), or nil when Follow
        // Cursor is off/outside this renderer — drives pointer-locked
        // particle control points (emitter-follow + controlpointattract).
        // Center-relative so it matches `WPEParticleSceneTransform`'s
        // coordinate space.
        let particlePointer: SIMD2<Float>? = followPointerIsLive
            ? SIMD2<Float>(
                Float((pointer.x - 0.5) * sceneRenderSize.width),
                Float((0.5 - pointer.y) * sceneRenderSize.height)
            )
            : nil
        // Parents precede their children in `particleSystems` (DFS
        // registration order), so a parent's `primaryLiveParticlePosition`
        // is already this-frame-fresh when its event-follow child ticks.
        for system in particleSystems {
            system.pointerCentered = particlePointer
            if let parent = system.followParent {
                if let followPosition = parent.primaryLiveParticlePosition {
                    system.injectedControlPoints[system.followControlPointID] = followPosition
                } else {
                    system.injectedControlPoints.removeValue(forKey: system.followControlPointID)
                }
            } else if system.requiresFollowParent {
                // Parent missing (failed to register or weak ref gone): keep
                // the follow gate so the orphan stays disabled instead of
                // spawning at a wrong static origin.
                system.injectedControlPoints.removeValue(forKey: system.followControlPointID)
            }
            system.tick(now: time)
        }
    }

    /// WPE runs a text object's script regardless of its visibility. Several
    /// scenes (e.g. 三体 3509243656) use a HIDDEN text object purely as a
    /// COMPUTE script that writes shared state — civilisation stats, ranking,
    /// temperature — which the VISIBLE data texts then read via `value =
    /// shared.txtN`. Ticking only visible objects left that shared state unset,
    /// so every derived readout rendered blank. Tick every script here (for its
    /// side effects on `shared`), independent of whether it will be drawn.
    private func tickTextContentScripts() -> [String: String] {
        var liveTextByID: [String: String] = [:]
        liveTextByID.reserveCapacity(textScriptInstances.count)
        // Sorted by objectID: hidden compute-scripts write `shared` state that the
        // visible data texts then read (三体 3509243656), so tick order changes the
        // rendered text. Dictionary order was arbitrary — a fixed order makes the
        // oracle trace deterministic and the render reproducible.
        for (id, instance) in textScriptInstances.sorted(by: { $0.key < $1.key }) {
            liveTextByID[id] = tickTextScript(instance)
        }
        return liveTextByID
    }

    /// Rasterizes and composites the frame's text overlays (MSDF-first, CoreText
    /// fallback) atop the rendered scene.
    private func drawLiveTextOverlays(
        onto frame: MTLTexture,
        uniforms: WPEMetalRuntimeUniforms,
        liveTextByID: [String: String],
        transforms: LiveScriptTransforms,
        parallaxFrame: WPECameraParallaxFrame
    ) throws {
        guard let textRenderer, !textObjects.isEmpty else { return }
        // CoreText draws for objects that don't take the MSDF path this frame.
        var draws: [WPETextOverlayDraw] = []
        var msdfPayloads: [WPEMSDFTextDrawPayload] = []
        // Objects that DID take the MSDF path this frame, kept so their
        // CoreText fallback can be rasterized LAZILY only if the MSDF pass
        // throws (an all-or-nothing recovery). On the happy path they never
        // pay a redundant CoreText rasterize.
        var deferredMSDFObjects: [(object: WPESceneTextObject, geometry: WPETextOverlayGeometry)] = []
        draws.reserveCapacity(textObjects.count)
        // Own live visibility AND the live ancestor chain: a script hiding a
        // parent GROUP (489 加载信息) must take its text children along —
        // parse-time folding only covered the static state.
        for object in textObjects
        where (liveTextVisibility[object.id] ?? object.visible) && ancestorChainVisible(object.id) {
            let resolvedAlpha = liveTextAlpha[object.id] ?? object.resolvedAlpha(at: uniforms.time)
            guard resolvedAlpha > 0 else { continue }
            let liveText = liveTextByID[object.id] ?? object.text
            let liveObject = object.withLiveText(liveText, alpha: resolvedAlpha)
            guard let placement = textOverlayPlacement(
                for: liveObject,
                transforms: transforms,
                parallaxFrame: parallaxFrame
            ) else { continue }
            // Prefer the GPU MSDF path. Only rasterize CoreText when MSDF
            // can't build a payload this frame (glyphs still warming, or an
            // unsupported object) — the eager per-frame CoreText rasterize
            // for every object (even MSDF-happy ones) was pure redundant work.
            if let payload = msdfTextRenderer?.drawPayload(
                for: liveObject,
                sceneSize: sceneRenderSize,
                parallaxOffset: cameraUniforms.usesPerspectiveProjection
                    ? .zero
                    : placement.textParallax,
                originOverride: placement.msdfOriginOverride,
                sizeScale: Double(placement.geometry.perspectiveSizeScale),
                rotation: placement.zRotation
            ) {
                msdfPayloads.append(payload)
                deferredMSDFObjects.append((liveObject, placement.geometry))
            } else if let draw = coreTextOverlayDraw(
                for: liveObject, geometry: placement.geometry, textRenderer: textRenderer
            ) {
                draws.append(draw)
            }
        }
        var msdfSucceeded = false
        if !msdfPayloads.isEmpty {
            do {
                try executor.drawMSDFText(
                    payloads: msdfPayloads,
                    sceneSize: sceneRenderSize,
                    output: frame
                )
                msdfSucceeded = true
                didLogMSDFTextDrawFailure = false
            } catch {
                msdfSucceeded = false
                // This used to fail silently — every affected frame fell back to
                // CoreText with zero signal that MSDF was even attempted. Log the
                // first failure of a streak (mirrors didLogFrameFailure) so a
                // persistently-broken combo/pipeline is diagnosable instead of
                // looking like MSDF was simply never enabled.
                if !didLogMSDFTextDrawFailure {
                    Logger.warning(
                        "Scene \(descriptor.workshopID) MSDF text draw failed (\(msdfPayloads.count) payload(s)), falling back to CoreText: \(error)",
                        category: .wpeRender
                    )
                    didLogMSDFTextDrawFailure = true
                }
                debugStage("text.msdf.drawFailed", "count=\(msdfPayloads.count) error=\(error)")
            }
        }
        // If the MSDF pass threw, rasterize CoreText for the MSDF objects NOW
        // (lazily) so no text silently disappears — the safety net is
        // preserved, just no longer paid for on every happy-path frame.
        if !msdfSucceeded, !msdfPayloads.isEmpty {
            for entry in deferredMSDFObjects {
                if let draw = coreTextOverlayDraw(
                    for: entry.object, geometry: entry.geometry, textRenderer: textRenderer
                ) {
                    draws.append(draw)
                }
            }
        }
        if !draws.isEmpty {
            try executor.drawTextOverlays(
                overlays: draws,
                sceneSize: sceneRenderSize,
                output: frame
            )
        }
    }

    /// A text object's composed screen placement for this frame: the overlay
    /// geometry both text paths share, plus the MSDF-space origin override and
    /// parallax. nil when a perspective projection rejects the world point.
    private struct WPETextOverlayPlacement {
        let geometry: WPETextOverlayGeometry
        let msdfOriginOverride: SIMD2<Double>?
        let textParallax: SIMD2<Float>
        let zRotation: Double
    }

    private func textOverlayPlacement(
        for liveObject: WPESceneTextObject,
        transforms: LiveScriptTransforms,
        parallaxFrame: WPECameraParallaxFrame
    ) -> WPETextOverlayPlacement? {
        // A text anchored under script-driven transform hosts (menu
        // panels following the view) must re-compose its LOCAL origin
        // through the live parent chain — the parse-time world origin
        // freezes it at the load-time panel position.
        let livePlacement = liveTextWorldPlacement(
            liveObject,
            scriptOrigins: transforms.origins,
            scriptScales: transforms.scales,
            scriptAngles: transforms.angles
        )
        let liveOrigin = livePlacement.origin
        let liveRotation = Float(livePlacement.zRotation)
        let textParallax = parallaxFrame.pixelOffset(
            depth: liveObject.parallaxDepth,
            sceneSize: sceneRenderSize
        )
        let scale = SIMD2<Float>(
            Float(max(liveObject.scale.x, 0.0001)),
            Float(max(liveObject.scale.y, 0.0001))
        )
        // Perspective scenes (orthogonalprojection:null) author text
        // origins in world units, so they must project through the same
        // camera as image quads (WPEMetalRenderExecutor.perspectiveObjectQuadUniforms).
        // Treating them as pixels pushed every x≈0 label ~960px off-screen.
        // Ortho scenes keep the pixel-space placement clocks/date overlays rely on.
        let center: SIMD2<Float>
        let perspectiveSizeScale: Float
        if cameraUniforms.usesPerspectiveProjection {
            guard let projection = cameraUniforms.projectedCenterInScenePixels(
                worldPoint: liveOrigin,
                sceneSize: sceneRenderSize
            ) else { return nil }
            center = projection.center + SIMD2<Float>(textParallax.x, textParallax.y)
            perspectiveSizeScale = projection.depthScale
        } else {
            let halfWidth = Double(sceneRenderSize.width) * 0.5
            let halfHeight = Double(sceneRenderSize.height) * 0.5
            center = SIMD2<Float>(
                Float(liveOrigin.x - halfWidth) + textParallax.x,
                Float(liveOrigin.y - halfHeight) + textParallax.y
            )
            perspectiveSizeScale = 1
        }
        let geometry = WPETextOverlayGeometry(
            center: center, scale: scale, perspectiveSizeScale: perspectiveSizeScale,
            rotation: liveRotation
        )
        // In perspective the projected `center` (scene-centered, +Y up)
        // already carries parallax; convert it into the MSDF path's
        // absolute top-left pixel space so both text paths land at the
        // same screen point. The ortho live-recomposed origin is author
        // space (+Y up) like `object.origin`, so it needs the SAME
        // top-left flip + parallax fold the MSDF transform applies to
        // non-overridden origins — passing it raw y-mirrored every text
        // object the moment MSDF took over from CoreText (3470764447's
        // clock stack teleported up and reversed its line order).
        let msdfOriginOverride: SIMD2<Double>? = cameraUniforms.usesPerspectiveProjection
            ? SIMD2<Double>(
                Double(center.x) + Double(sceneRenderSize.width) * 0.5,
                Double(sceneRenderSize.height) * 0.5 - Double(center.y)
            )
            : (liveOrigin == liveObject.origin
                ? nil
                : SIMD2<Double>(
                    liveOrigin.x + Double(textParallax.x),
                    Double(sceneRenderSize.height) - (liveOrigin.y + Double(textParallax.y))
                ))
        return WPETextOverlayPlacement(
            geometry: geometry,
            msdfOriginOverride: msdfOriginOverride,
            textParallax: SIMD2<Float>(textParallax.x, textParallax.y),
            zRotation: livePlacement.zRotation
        )
    }

    /// The already-computed placement of a text object this frame, shared by the
    /// MSDF and CoreText paths so the CoreText fallback can be built lazily
    /// (only when MSDF isn't available) without recomputing projection/parallax.
    private struct WPETextOverlayGeometry {
        let center: SIMD2<Float>
        let scale: SIMD2<Float>
        let perspectiveSizeScale: Float
        /// Composed live-chain z rotation (radians, author-space CCW); 0 for
        /// static chains. Applied by both text paths so they stay in lockstep.
        let rotation: Float
    }

    /// Rasterize a text object via CoreText and build its overlay draw. Called
    /// only when the MSDF path can't cover the object this frame (glyphs warming)
    /// or, on the throw-recovery path, for the MSDF objects — never eagerly for
    /// MSDF-happy objects. Returns nil when there's nothing to rasterize.
    private func coreTextOverlayDraw(
        for liveObject: WPESceneTextObject,
        geometry: WPETextOverlayGeometry,
        textRenderer: WPETextRenderer
    ) -> WPETextOverlayDraw? {
        guard let entry = textRenderer.rasterize(liveObject) else { return nil }
        let scaledSize = CGSize(
            width: entry.size.width * CGFloat(geometry.scale.x) * CGFloat(geometry.perspectiveSizeScale),
            height: entry.size.height * CGFloat(geometry.scale.y) * CGFloat(geometry.perspectiveSizeScale)
        )
        // Object `brightness` folds into the tint exactly like an image layer's
        // `rgb × brightness` (may exceed 1 — the fragment premultiplies in float,
        // so >1 brightens antialiased edges before the UNORM store clamps).
        let brightness = Float(max(liveObject.brightness, 0))
        return WPETextOverlayDraw(
            texture: entry.texture,
            centerInScenePixels: geometry.center,
            sizeInScenePixels: scaledSize,
            tint: SIMD3<Float>(
                Float(liveObject.color.x) * brightness,
                Float(liveObject.color.y) * brightness,
                Float(liveObject.color.z) * brightness
            ),
            alpha: Float(liveObject.alpha),
            rotation: geometry.rotation
        )
    }

    /// Phase 2D-O: spin up the audio runtime and start playback if the scene declared sound objects.
    /// Phase 2D-N: build the WPETextRenderer + cache the parsed text object list.
    private func loadTextOverlays(from document: WPESceneDocument) {
        textObjects = document.textObjects
        guard !textObjects.isEmpty else {
            textRenderer = nil
            msdfTextRenderer = nil
            textScriptInstances.removeAll(keepingCapacity: false)
            return
        }
        textRenderer = WPETextRenderer(
            device: executor.textureSourceDevice,
            resolver: resourceResolver
        )
        // GPU MSDF text is ON by default: glyph generation runs off the main
        // thread (77059619) and the clean-room `font.frag` ships in
        // wpe-builtins.bundle, so the shader resolves for every install. The
        // flag stays as a kill-switch for this visual-fidelity feature —
        // disable with: defaults write <bundle> WPEEnableMSDFText -bool NO
        // A resolver miss (or any draw failure) still falls back to the
        // CoreText overlay; multi-line text always renders via CoreText.
        if UserDefaults.standard.object(forKey: "WPEEnableMSDFText") as? Bool ?? true,
           let fontFragmentSource = resolveMSDFFontFragmentSource() {
            msdfTextRenderer = WPEMSDFTextRenderer(
                device: executor.textureSourceDevice,
                resolver: resourceResolver,
                fontFragmentSource: fontFragmentSource
            )
        } else {
            msdfTextRenderer = nil
        }
        textScriptInstances.removeAll(keepingCapacity: false)
        let sharedState = sceneScriptSharedState ?? WPESharedScriptState()
        sceneScriptSharedState = sharedState
        for object in textObjects {
            guard let script = object.textScript else { continue }
            do {
                let instance = try WPESceneScriptInstance(
                    script: script,
                    initialValue: object.text,
                    scriptProperties: object.scriptProperties,
                    shared: sharedState
                )
                // Off-frame seed: the first frame renders the scripted value
                // instead of popping the authored placeholder for one frame.
                if Self.scriptAsyncTickEnabled { instance.seedAsyncTick() }
                textScriptInstances[object.id] = instance
            } catch {
                Logger.warning("Scene \(descriptor.workshopID) [TextScript] init failed for \(object.name): \(error)", category: .wpeRender)
            }
        }
    }

    /// Loads the MSDF `font.frag` for the GPU text path. Resolves through the
    /// standard cascade — a scene's own override first, then the clean-room copy
    /// in `wpe-builtins.bundle` (present for every install), then an optional
    /// engine-assets root. Returns nil when unavailable → CoreText only.
    private func resolveMSDFFontFragmentSource() -> String? {
        let candidates = ["shaders/font.frag", "shaders/effects/font.frag"]
        for path in candidates {
            guard let data = try? resourceResolver.data(relativePath: path, optional: true),
                  let source = String(data: data, encoding: .utf8) else {
                continue
            }
            return source
        }
        return nil
    }

    /// Material descriptor extracted from `passes[0]`. Only the fields the
    /// particle path needs — full material parsing lives in the generic
    /// pipeline builder.
    private struct ParticleMaterialDescriptor {
        let blendMode: WPEParticleBlendMode
        let firstTexturePath: String?
        /// `constantshadervalues.ui_editor_properties_overbright` — HDR colour
        /// multiplier on the shader output (1 = unchanged). Drives additive
        /// glow intensity.
        let overbright: Float
        /// `genericparticle` `REFRACT` combo — screen-space refraction (lens
        /// water droplets / heat haze): the particle multiplies its colour by the
        /// scene framebuffer sampled at a normal-map-offset UV, so it shows the
        /// distorted background instead of a flat sprite. Needs `normalTexturePath`.
        let isRefract: Bool
        /// Second pass texture (`g_Texture1`), the refraction normal map.
        let normalTexturePath: String?
        /// `g_RefractAmount` (screen-UV offset scale). WPE default 0.05.
        let refractAmount: Float
    }

    private func parseParticleMaterial(at relativePath: String) -> ParticleMaterialDescriptor? {
        guard let materialData = try? entryResolver.data(relativePath: relativePath),
              let materialJSON = try? JSONSerialization.jsonObject(with: materialData) as? [String: Any],
              let passes = materialJSON["passes"] as? [[String: Any]],
              let firstPass = passes.first else {
            return nil
        }
        let blendString = firstPass["blending"] as? String
        let textures = firstPass["textures"] as? [Any]
        let firstTexturePath = textures?.first as? String
        let constants = firstPass["constantshadervalues"] as? [String: Any]
        let combos = firstPass["combos"] as? [String: Any]
        let isRefract: Bool = {
            guard let raw = combos?["REFRACT"] else { return false }
            if let n = raw as? NSNumber { return n.intValue != 0 }
            return false
        }()
        let refractAmount: Float = {
            guard let n = constants?["ui_editor_properties_refract_amount"] as? NSNumber,
                  !(constants?["ui_editor_properties_refract_amount"] is Bool) else { return 0.05 }
            return Float(truncating: n)
        }()
        return ParticleMaterialDescriptor(
            blendMode: WPEParticleBlendMode(materialString: blendString),
            firstTexturePath: firstTexturePath,
            overbright: Self.overbright(fromConstants: constants),
            isRefract: isRefract,
            normalTexturePath: (textures?.count ?? 0) >= 2 ? textures?[1] as? String : nil,
            refractAmount: refractAmount
        )
    }

    /// Parses `ui_editor_properties_overbright` from a pass's
    /// `constantshadervalues`. A JSON boolean bridges to an `NSNumber` whose
    /// `Float` value is 0/1, so guard it out (a stray `false` would otherwise
    /// black the particle out); clamp to ≥ 0. Absent/malformed → 1.0 (no change).
    nonisolated static func overbright(fromConstants constants: [String: Any]?) -> Float {
        let raw = constants?["ui_editor_properties_overbright"]
        if raw is Bool { return 1.0 }
        guard let number = raw as? NSNumber else { return 1.0 }
        return max(0, Float(truncating: number))
    }

    /// Effective particle colour multiplier: material overbright × the host
    /// object's generic `brightness` (WPE modulates any renderable object with
    /// it; particles fold it into the same overbright uniform, shader unchanged).
    /// Clamped ≥ 0 — a negative authored brightness must not invert colours.
    nonisolated static func particleOverbright(
        material: Float?,
        objectBrightness: Double
    ) -> Float {
        max(0, (material ?? 1.0) * Float(objectBrightness))
    }

    /// Best-effort `.tex-json` sidecar lookup. The atlas slicing
    /// metadata WPE ships next to each `.tex` (cols/rows derived from
    /// the sequence frame size, plus the pixel format) lives in
    /// `<path>.tex-json` — we try the same set of probe paths the main
    /// texture resolver tried (with `.tex` stripped, `materials/`
    /// prefix optional), then read + parse the JSON.
    ///
    /// Returns `nil` when the sidecar is absent or malformed; the
    /// caller then treats the texture as a single-frame static sprite.
    private func parseParticleSpriteSheet(
        texturePath: String,
        atlasPixelSize: (width: Int, height: Int)
    ) -> WPEParticleSpriteSheet? {
        let probes = textureCandidates(for: texturePath).map { candidate -> String in
            // Each candidate already covers ".tex", ".png", etc. — turn
            // them into ".tex-json" siblings.
            let stripped = (candidate as NSString).deletingPathExtension
            return "\(stripped).tex-json"
        }
        var seen = Set<String>()
        for probe in probes where seen.insert(probe).inserted {
            guard let data = try? resourceResolver.data(relativePath: probe, optional: true) else {
                continue
            }
            if let sheet = WPEParticleSpriteSheetParser.parse(data: data, atlasPixelSize: atlasPixelSize) {
                return sheet
            }
        }
        return nil
    }

    /// Largest exact square-cell grid over the LOGICAL image (cell = gcd of the
    /// logical sides), emitted as explicit frame rects normalized over the padded
    /// atlas. Square/equal-sided images yield one cell (`nil` — stays a static
    /// sprite), so this only ever slices genuinely rectangular sheets. Bounds
    /// (cell ≥ 16px, ≤ 512 frames) reject degenerate grids from odd image sizes.
    static func squareCellGridSpriteSheet(
        logicalWidth: Int,
        logicalHeight: Int,
        atlasWidth: Int,
        atlasHeight: Int,
        isAlphaMask: Bool
    ) -> WPEParticleSpriteSheet? {
        guard logicalWidth > 0, logicalHeight > 0, atlasWidth > 0, atlasHeight > 0 else { return nil }
        func gcd(_ a: Int, _ b: Int) -> Int {
            var (a, b) = (a, b)
            while b != 0 { (a, b) = (b, a % b) }
            return a
        }
        let cell = gcd(logicalWidth, logicalHeight)
        let cols = logicalWidth / cell
        let rows = logicalHeight / cell
        let frames = cols * rows
        guard cell >= 16, frames > 1, frames <= 512 else { return nil }
        var rects: [SIMD4<Float>] = []
        rects.reserveCapacity(frames)
        let w = Float(atlasWidth)
        let h = Float(atlasHeight)
        for row in 0..<rows {
            for col in 0..<cols {
                rects.append(SIMD4<Float>(
                    Float(col * cell) / w,
                    Float(row * cell) / h,
                    Float((col + 1) * cell) / w,
                    Float((row + 1) * cell) / h
                ))
            }
        }
        return WPEParticleSpriteSheet(
            cols: cols,
            rows: rows,
            frameCount: frames,
            baseFrameRate: 0,
            isAlphaMask: isAlphaMask,
            frameRects: rects
        )
    }

    private func makeParticleSceneTransform(for object: WPESceneParticleObject) -> WPEParticleSceneTransform {
        WPEParticleSceneTransform(
            sceneSize: SIMD2<Float>(Float(sceneRenderSize.width), Float(sceneRenderSize.height)),
            objectOrigin: SIMD3<Float>(Float(object.origin.x), Float(object.origin.y), Float(object.origin.z)),
            objectScale: SIMD3<Float>(Float(object.scale.x), Float(object.scale.y), Float(object.scale.z)),
            objectAngleZ: Float(object.angles.z)
        )
    }

    /// Builds a `WPELayerScriptInstance` per image object whose `visible` field
    /// is a SceneScript, maps each to its video source, and applies the script's
    /// `init()` state (visibility/alpha + video stop/seek). Runs after textures so
    /// the video sources exist. No-op for scenes without layer scripts.
    private func loadLayerScripts(from document: WPESceneDocument) {
        layerScriptInstances = [:]
        layerAlphaScriptInstances = [:]
        textVisibleScriptInstances = [:]
        textAlphaScriptInstances = [:]
        liveTextAlpha = [:]
        layerHoverStates = [:]
        layerVideoSourceKey = [:]
        layerObjectIDByName = [:]
        liveLayerAlpha = [:]
        introPhaseSource = nil
        loopPhaseSource = nil
        introLoopOffset = nil
        introPhaseToken += 1
        let visibleScripted = document.imageObjects.filter { $0.visibleScript != nil }
        let alphaScripted = document.imageObjects.filter { $0.alphaScript != nil }
        let textVisibleScripted = document.textObjects.filter { $0.visibleScript != nil }
        let textAlphaScripted = document.textObjects.filter { $0.alphaScript != nil }
        let scriptHosts = document.scriptHostObjects
        debugStage(
            "layerScripts.load",
            "hosts=\(scriptHosts.count) visible=\(visibleScripted.count) alpha=\(alphaScripted.count) "
                + "textVisible=\(textVisibleScripted.count) textAlpha=\(textAlphaScripted.count) "
                + "hostNames=\(scriptHosts.prefix(8).map(\.name).joined(separator: ","))"
        )
        guard (!visibleScripted.isEmpty || !alphaScripted.isEmpty || !scriptHosts.isEmpty
                || !textVisibleScripted.isEmpty || !textAlphaScripted.isEmpty),
              let pipeline = renderPipeline else { return }

        // Map EVERY layer's name→id and (when video-backed) id→video-source-key,
        // so a script's `thisScene.getLayer(name)` can drive another layer's video
        // (e.g. the button that controls 千咲入场动画).
        for layer in pipeline.layers {
            let id = layer.graphLayer.objectID
            layerObjectIDByName[layer.graphLayer.objectName] = id
            if let key = videoTexturePaths(for: layer).first(where: { dynamicTextureSources[$0] is WPEVideoTextureSource }) {
                layerVideoSourceKey[id] = key
            }
        }

        // WPE delivers the user-property bag to each script after init(); time-of-day
        // scripts gate their day/night switch on it (e.g. `timevarying`), so without
        // this the switch never runs.
        let userProperties = currentLayerScriptUserProperties()
        debugStage("layerScripts.userProperties", "count=\(userProperties.count)")
        // One `shared` store for the whole scene so WPE's cross-script `shared`
        // global coordinates across the scripts' isolated contexts.
        let sharedState = sceneScriptSharedState ?? WPESharedScriptState()
        sceneScriptSharedState = sharedState
        let scriptCanvasSize = SIMD2<Double>(
            max(Double(sceneRenderSize.width), 1),
            max(Double(sceneRenderSize.height), 1)
        )
        for object in scriptHosts {
            do {
                let instance = try WPELayerScriptInstance(
                    script: object.visibleScript,
                    scriptProperties: object.scriptProperties,
                    shared: sharedState,
                    canvasSize: scriptCanvasSize
                )
                layerScriptInstances[object.id] = instance
                applyLayerScriptOutput(instance.initialOutput, ownObjectID: object.id)
                if let output = applyScriptUserProperties(instance, userProperties) {
                    applyLayerScriptOutput(output, ownObjectID: object.id)
                }
            } catch {
                Logger.warning("Scene \(descriptor.workshopID) [ScriptHost] init failed for \(object.name): \(error)", category: .wpeRender)
            }
        }
        for object in visibleScripted {
            guard let script = object.visibleScript else { continue }
            do {
                let instance = try WPELayerScriptInstance(
                    script: script,
                    scriptProperties: object.scriptProperties,
                    shared: sharedState,
                    canvasSize: scriptCanvasSize
                )
                layerScriptInstances[object.id] = instance
                applyLayerScriptOutput(instance.initialOutput, ownObjectID: object.id)
                if let output = applyScriptUserProperties(instance, userProperties) {
                    applyLayerScriptOutput(output, ownObjectID: object.id)
                }
            } catch {
                Logger.warning("Scene \(descriptor.workshopID) [LayerScript] init failed for \(object.name): \(error)", category: .wpeRender)
            }
        }
        for object in alphaScripted {
            guard let script = object.alphaScript else { continue }
            do {
                let instance = try WPELayerScriptInstance(
                    script: script,
                    scriptProperties: object.alphaScriptProperties,
                    shared: sharedState,
                    canvasSize: scriptCanvasSize,
                    outputMode: .returnedAlpha(initialValue: object.alpha)
                )
                layerAlphaScriptInstances[object.id] = instance
                applyLayerAlphaScriptOutput(instance.initialOutput, ownObjectID: object.id)
                if let output = applyScriptUserProperties(instance, userProperties) {
                    applyLayerAlphaScriptOutput(output, ownObjectID: object.id)
                }
            } catch {
                Logger.warning("Scene \(descriptor.workshopID) [AlphaScript] init failed for \(object.name): \(error)", category: .wpeRender)
            }
        }
        for object in textVisibleScripted {
            guard let script = object.visibleScript else { continue }
            do {
                let instance = try WPELayerScriptInstance(
                    script: script,
                    scriptProperties: object.visibleScriptProperties,
                    shared: sharedState,
                    canvasSize: scriptCanvasSize
                )
                textVisibleScriptInstances[object.id] = instance
                applyTextScriptOutput(instance.initialOutput, ownObjectID: object.id)
                if let output = applyScriptUserProperties(instance, userProperties) {
                    applyTextScriptOutput(output, ownObjectID: object.id)
                }
            } catch {
                Logger.warning("Scene \(descriptor.workshopID) [TextVisibleScript] init failed for \(object.name): \(error)", category: .wpeRender)
            }
        }
        for object in textAlphaScripted {
            guard let script = object.alphaScript else { continue }
            do {
                let instance = try WPELayerScriptInstance(
                    script: script,
                    scriptProperties: object.alphaScriptProperties,
                    shared: sharedState,
                    canvasSize: scriptCanvasSize,
                    outputMode: .returnedAlpha(initialValue: object.alpha)
                )
                textAlphaScriptInstances[object.id] = instance
                liveTextAlpha[object.id] = instance.initialOutput.own.alpha
                if let output = applyScriptUserProperties(instance, userProperties) {
                    liveTextAlpha[object.id] = output.own.alpha
                }
            } catch {
                Logger.warning("Scene \(descriptor.workshopID) [TextAlphaScript] init failed for \(object.name): \(error)", category: .wpeRender)
            }
        }
        setUpIntroPhaseAlign(scripted: visibleScripted)
    }

    /// A text object's own `visible` script output → live text visibility (and
    /// alpha when the script assigned it). `others` still routes to image
    /// layers via the shared name map, matching image layer-script semantics.
    private func applyTextScriptOutput(_ output: WPELayerScriptOutput, ownObjectID: String) {
        if output.own.visibleAssigned {
            liveTextVisibility[ownObjectID] = output.own.visible
        }
        if output.own.alphaAssigned {
            liveTextAlpha[ownObjectID] = output.own.alpha
        }
        for (name, state) in output.others {
            guard let targetID = layerObjectIDByName[name] else { continue }
            applyLayerScriptState(state, objectID: targetID)
        }
    }

    /// Builds dynamic origin script instances for image layers whose `origin`
    /// SceneScript depends on live input. Static origin scripts were resolved by
    /// `WPESceneDocumentParser`, so they do not reach this path.
    private func loadDynamicOriginScripts(from document: WPESceneDocument) {
        dynamicOriginScriptInstances = [:]
        dynamicScaleScriptInstances = [:]
        dynamicAnglesScriptInstances = [:]
        transformHostLocalTransformsByID = Dictionary(
            document.transformHostObjects.map { object in
                (
                    object.id,
                    WPERenderObjectTransform(
                        origin: object.localOrigin,
                        scale: object.localScale,
                        angles: object.localAngles
                    )
                )
            },
            uniquingKeysWith: { first, _ in first }
        )
        let originScripts = document.imageObjects.compactMap { object -> (String, WPESceneTransformScript)? in
            object.originScript.map { (object.id, $0) }
        } + document.transformHostObjects.compactMap { object -> (String, WPESceneTransformScript)? in
            object.originScript.map { (object.id, $0) }
        } + document.textObjects.compactMap { object -> (String, WPESceneTransformScript)? in
            // TEXT objects with a dynamic origin (3509243656's tooltip labels
            // that track their star via `shared.xxN`). Ticked into the same
            // live-origins map the overlay loop reads.
            object.originScript.map { (object.id, $0) }
        }
        let scaleScripts = document.imageObjects.compactMap { object -> (String, WPESceneTransformScript)? in
            object.scaleScript.map { (object.id, $0) }
        } + document.transformHostObjects.compactMap { object -> (String, WPESceneTransformScript)? in
            object.scaleScript.map { (object.id, $0) }
        }
        // Angles seeds come from scene.json in radians; the script sees degrees
        // (same boundary as the deg→rad conversion in the per-frame tick).
        let anglesScripts = (document.imageObjects.compactMap { object -> (String, WPESceneTransformScript)? in
            object.anglesScript.map { (object.id, $0) }
        } + document.transformHostObjects.compactMap { object -> (String, WPESceneTransformScript)? in
            object.anglesScript.map { (object.id, $0) }
        }).map { (id, script) in
            (id, WPESceneTransformScript(
                script: script.script,
                scriptProperties: script.scriptProperties,
                seed: script.seed * (180 / .pi)
            ))
        }
        debugStage(
            "transformScripts.load",
            "origin=\(originScripts.count) scale=\(scaleScripts.count) angles=\(anglesScripts.count) hosts=\(document.transformHostObjects.count)"
        )
        guard !originScripts.isEmpty || !scaleScripts.isEmpty || !anglesScripts.isEmpty else { return }
        let canvasSize = SIMD2<Double>(
            max(Double(sceneRenderSize.width), 1),
            max(Double(sceneRenderSize.height), 1)
        )
        let sharedState = sceneScriptSharedState ?? WPESharedScriptState()
        sceneScriptSharedState = sharedState
        func install(
            _ scripts: [(String, WPESceneTransformScript)],
            into instances: inout [String: WPEDynamicTransformScriptInstance],
            label: String
        ) {
            for (objectID, script) in scripts {
                do {
                    let instance = try WPEDynamicTransformScriptInstance(
                        script: script.script,
                        scriptProperties: script.scriptProperties,
                        seed: script.seed,
                        canvasSize: canvasSize,
                        shared: sharedState
                    )
                    // Off-frame seed with the neutral pointer (the frame path's
                    // follow-cursor-off default), so the first frame uses the
                    // scripted transform instead of popping from the baked value.
                    if Self.scriptAsyncTickEnabled {
                        instance.seedAsyncTick(pointerPosition: SIMD2<Double>(0.5, 0.5))
                    }
                    instances[objectID] = instance
                } catch {
                    Logger.warning("Scene \(descriptor.workshopID) [\(label)] init failed for \(objectID): \(error)", category: .wpeRender)
                }
            }
        }
        install(originScripts, into: &dynamicOriginScriptInstances, label: "OriginScript")
        install(scaleScripts, into: &dynamicScaleScriptInstances, label: "ScaleScript")
        install(anglesScripts, into: &dynamicAnglesScriptInstances, label: "AnglesScript")
    }

    /// Index video layers whose every pass targets `.scene` (so they're never a
    /// hidden composite/FBO source another layer samples) — only these are safe to
    /// release when hidden, since the executor skips a hidden scene pass entirely.
    private func indexOnDemandVideoLayers(pipeline: WPEPreparedRenderPipeline) {
        onDemandVideoKeyByID = [:]
        onDemandVideoLoading = []
        for layer in pipeline.layers {
            guard let key = videoTexturePaths(for: layer)
                .first(where: { dynamicTextureSources[$0] is WPEVideoTextureSource }) else { continue }
            let sceneOnly = layer.passes.allSatisfy { pass in
                if case .scene = pass.pass.target { return true }
                return false
            }
            if sceneOnly {
                onDemandVideoKeyByID[layer.graphLayer.objectID] = key
            }
        }
    }

    private static func createdLayerTemplatesByImagePath(
        _ pipeline: WPEPreparedRenderPipeline
    ) -> [String: WPEPreparedRenderLayer] {
        var templates: [String: WPEPreparedRenderLayer] = [:]
        for layer in pipeline.layers {
            let path = layer.graphLayer.imagePath
            guard !path.isEmpty,
                  templates[path] == nil,
                  layer.puppetModel == nil,
                  layer.passes.count == 1 else {
                continue
            }
            templates[path] = layer
        }
        return templates
    }

    /// Per-frame: an on-demand video source is resident iff some layer using it is
    /// visible this frame; otherwise it's released (freeing its resident MP4 +
    /// buffers) and rebuilt on the next reveal. Aggregated by texture key, so two
    /// layers sharing one video keep it while either is visible. No-op for the
    /// common single-always-visible-video scene.
    private func reconcileVideoResidency(_ framePipeline: WPEPreparedRenderPipeline) {
        guard !onDemandVideoKeyByID.isEmpty else { return }
        var visibleByID: [String: Bool] = [:]
        visibleByID.reserveCapacity(framePipeline.layers.count)
        for layer in framePipeline.layers {
            visibleByID[layer.graphLayer.objectID] = layer.graphLayer.visible
        }
        var keyVisible: [String: Bool] = [:]
        for (objectID, key) in onDemandVideoKeyByID {
            if visibleByID[objectID] == true { keyVisible[key] = true }
            else if keyVisible[key] == nil { keyVisible[key] = false }
        }
        for (key, visible) in keyVisible {
            if visible {
                lazyLoadVideo(key: key)
            } else if let source = dynamicTextureSources[key] as? WPEVideoTextureSource {
                // Phase-aligned intro/loop sources hold object references elsewhere;
                // releasing one would leave those refs dangling (no rebuild hook).
                guard source !== introPhaseSource, source !== loopPhaseSource else { continue }
                source.invalidate()
                dynamicTextureSources.removeValue(forKey: key)
                // 1×1 placeholder, not a removal: a stray sampler reference resolves
                // instead of erroring (the hidden layer's scene pass is skipped).
                loadedTextures[key] = (try? makeDynamicPlaceholderTexture(label: "\(key) released")) ?? loadedTextures[key]
            }
        }
    }

    private func lazyLoadVideo(key: String) {
        guard dynamicTextureSources[key] == nil,
              !onDemandVideoLoading.contains(key) else { return }
        onDemandVideoLoading.insert(key)
        let generation = loadGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.onDemandVideoLoading.remove(key) }
            guard self.loadGeneration == generation else { return }
            do {
                try await self.loadDynamicTextureOnActor(path: key, layerName: key)
            } catch {
                Logger.warning("Scene \(self.descriptor.workshopID) [OnDemandVideo] rebuild failed for \(key): \(error)", category: .wpeRender)
                return
            }
            // Force-play the freshly-rebuilt (paused) source under the current
            // profile; a layer script re-issues its own play() next tick.
            guard self.loadGeneration == generation,
                  let source = self.dynamicTextureSources[key] as? WPEVideoTextureSource else { return }
            source.applyPerformanceProfile(self.currentProfile)
            self.mtkView.setNeedsDisplay(self.mtkView.bounds)
        }
    }

    /// Effective scene user-property values (project.json defaults ⊕ the
    /// descriptor's persisted overrides) bridged to the script value type, so a
    /// layer script's `applyUserProperties` sees the SAME bag WPE delivers. Keyed
    /// by the project.json property name the script reads (`timevarying`, etc.).
    private func currentLayerScriptUserProperties() -> [String: WPESceneScriptPropertyValue] {
        let manifestRoot = projectManifestRootURL ?? cacheRootURL
        let values = WallpaperEngineProjectPropertySchema.effectiveSceneValues(
            descriptor: descriptor,
            cacheRootURL: manifestRoot
        )
        return Self.bridgeUserProperties(values)
    }

    private static func bridgeUserProperties(
        _ values: [String: WallpaperEngineProjectPropertyValue]
    ) -> [String: WPESceneScriptPropertyValue] {
        values.reduce(into: [:]) { result, pair in
            switch pair.value {
            case .bool(let value): result[pair.key] = .bool(value)
            case .number(let value): result[pair.key] = .number(value)
            case .string(let value): result[pair.key] = .string(value)
            }
        }
    }

    /// Identify the intro overlay video and the free-running loop video it reveals,
    /// then measure their phase offset off-thread (used by `updateIntroPhaseAlign`).
    /// Intro = a scripted layer that owns a video. Loop = a video no script drives:
    /// by now every scripted layer's init commands have run, so the intro overlay
    /// and any button-driven video are already `scriptControlled`, leaving the
    /// free-running loop as the one that isn't.
    private func setUpIntroPhaseAlign(scripted: [WPESceneImageObject]) {
        guard Self.introPhaseAlignEnabled else { return }
        guard let introKey = scripted.compactMap({ layerVideoSourceKey[$0.id] }).first,
              let intro = dynamicTextureSources[introKey] as? WPEVideoTextureSource,
              let introURL = intro.analysisURL else { return }
        let loop = layerVideoSourceKey.values
            .compactMap { self.dynamicTextureSources[$0] as? WPEVideoTextureSource }
            .first { !$0.isScriptControlled }
        guard let loop, let loopURL = loop.analysisURL else { return }
        introPhaseSource = intro
        loopPhaseSource = loop
        let token = introPhaseToken
        Task { [weak self] in
            let offset = await WPEVideoPhaseOffset.measure(introURL: introURL, loopURL: loopURL)
            guard let self, self.introPhaseToken == token else { return }
            self.introLoopOffset = offset
        }
    }

    /// Keep the revealed loop's playhead leading the intro by the measured offset
    /// while the intro plays, so the crossfade lands on matching frames. Cheap:
    /// re-seeks only when phase drifts (after the first correction it stays put).
    private func updateIntroPhaseAlign() {
        guard let offset = introLoopOffset,
              let intro = introPhaseSource,
              let loop = loopPhaseSource,
              intro.isActivelyPlaying else { return }
        let duration = loop.loopDurationSeconds
        guard duration > 0.1 else { return }
        let target = ((intro.currentPlayheadSeconds + offset)
            .truncatingRemainder(dividingBy: duration) + duration)
            .truncatingRemainder(dividingBy: duration)
        let delta = abs(loop.currentPlayheadSeconds - target)
        let circularDrift = min(delta, duration - delta)
        if circularDrift > 0.3 { loop.alignPlayhead(to: target) }
    }

    /// Per-layer hover transitions (`cursorEnter`/`cursorLeave`): hit-tests the
    /// pointer against each scripted layer's screen rect (axis-aligned; ortho =
    /// origin-centered size×scale, perspective = projected center + depth-scaled
    /// size) and dispatches only on state change. `pointer` nil (follow-cursor
    /// off / outside the view) counts as leaving everything. WPE fires these
    /// without click capture — hover only needs the cursor position.
    private func dispatchLayerHoverEvents(
        pointer: SIMD2<Double>?,
        pipeline: WPEPreparedRenderPipeline,
        pointerFrame: WPEPointerFrame,
        runtimeSeconds: Double
    ) {
        guard !layerScriptInstances.isEmpty || !layerAlphaScriptInstances.isEmpty else { return }
        var geometryByID: [String: WPERenderLayerGeometry] = [:]
        for layer in pipeline.layers {
            let objectID = layer.graphLayer.objectID
            if layerScriptInstances[objectID] != nil || layerAlphaScriptInstances[objectID] != nil {
                geometryByID[objectID] = layer.graphLayer.geometry
            }
        }
        let width = Double(max(sceneRenderSize.width, 1))
        let height = Double(max(sceneRenderSize.height, 1))
        let pointerPixels = pointer.map { SIMD2<Double>($0.x * width, $0.y * height) }

        func dispatch(
            _ instances: [String: WPELayerScriptInstance],
            apply: (WPELayerScriptOutput, String) -> Void
        ) {
            for (objectID, instance) in instances {
                let inside: Bool
                if let pointerPixels, let geometry = geometryByID[objectID] {
                    inside = pointerHits(pointerPixels, geometry: geometry)
                } else {
                    inside = false
                }
                let previous = layerHoverStates[objectID] ?? false
                guard inside != previous else { continue }
                layerHoverStates[objectID] = inside
                if let output = dispatchScriptCursorEvent(
                    instance,
                    event: inside ? .enter : .leave,
                    pointerFrame: pointerFrame,
                    runtimeSeconds: runtimeSeconds
                ) {
                    apply(output, objectID)
                }
            }
        }
        dispatch(layerScriptInstances) { applyLayerScriptOutput($0, ownObjectID: $1) }
        dispatch(layerAlphaScriptInstances) { applyLayerAlphaScriptOutput($0, ownObjectID: $1) }

        if hoverCursorDebugEnabled, let pointerPixels {
            hoverDebugCounter += 1
            if hoverDebugCounter % 30 == 1 {
                for (objectID, geometry) in geometryByID.sorted(by: { $0.key < $1.key }) {
                    let rect = hoverHitRect(geometry: geometry)
                    Logger.notice(
                        "[hover] obj=\(objectID) pointer=(\(Int(pointerPixels.x)),\(Int(pointerPixels.y))) "
                            + "rect=\(rect.map { "c(\(Int($0.center.x)),\(Int($0.center.y)))±(\(Int($0.half.x)),\(Int($0.half.y)))" } ?? "nil") "
                            + "inside=\(rect.map { abs(pointerPixels.x - $0.center.x) <= $0.half.x && abs(pointerPixels.y - $0.center.y) <= $0.half.y } ?? false)",
                        category: .wpeRender
                    )
                }
            }
        }
    }

    private var hoverDebugCounter = 0
    private var hoverCursorDebugEnabled: Bool {
        UserDefaults.standard.bool(forKey: "WPEHoverCursorDebug")
    }

    /// Pointer (top-left scene pixels) vs a layer's axis-aligned screen rect.
    private func pointerHits(_ pointerPixels: SIMD2<Double>, geometry: WPERenderLayerGeometry) -> Bool {
        guard let rect = hoverHitRect(geometry: geometry) else { return false }
        return abs(pointerPixels.x - rect.center.x) <= rect.half.x
            && abs(pointerPixels.y - rect.center.y) <= rect.half.y
    }

    /// A scripted layer's hover rect in scene pixels. A MINIMUM half-extent
    /// (scaled to render size) keeps a distant/perspective-shrunk hover pad
    /// reachable — the n-body sim pushes some bodies far enough that their pad
    /// would otherwise project to a few pixels the cursor can't land on
    /// (3509243656's outer stars had no tooltip until this floor).
    private func hoverHitRect(
        geometry: WPERenderLayerGeometry
    ) -> (center: SIMD2<Double>, half: SIMD2<Double>)? {
        guard let size = geometry.size, size.width > 0, size.height > 0 else { return nil }
        let width = Double(max(sceneRenderSize.width, 1))
        let height = Double(max(sceneRenderSize.height, 1))
        let minHalf = max(height, 1) * 0.02
        let center: SIMD2<Double>
        var half: SIMD2<Double>
        if cameraUniforms.usesPerspectiveProjection {
            guard let projection = cameraUniforms.projectedCenterInScenePixels(
                worldPoint: geometry.origin,
                sceneSize: sceneRenderSize
            ) else { return nil }
            center = SIMD2<Double>(
                width * 0.5 + Double(projection.center.x),
                height * 0.5 - Double(projection.center.y)
            )
            let depthScale = Double(projection.depthScale)
            half = SIMD2<Double>(
                Double(size.width) * abs(geometry.scale.x) * depthScale * 0.5,
                Double(size.height) * abs(geometry.scale.y) * depthScale * 0.5
            )
        } else {
            center = SIMD2<Double>(geometry.origin.x, geometry.origin.y)
            half = SIMD2<Double>(
                Double(size.width) * abs(geometry.scale.x) * 0.5,
                Double(size.height) * abs(geometry.scale.y) * 0.5
            )
        }
        half.x = max(half.x, minHalf)
        half.y = max(half.y, minHalf)
        return (center, half)
    }

    private func dispatchLayerCursorEvents(
        from previous: WPEPointerFrame,
        to current: WPEPointerFrame,
        runtimeSeconds: Double
    ) {
        var events: [WPELayerScriptCursorEvent] = []
        if !previous.isDown, current.isDown { events.append(.down) }
        if previous.isDown, !current.isDown { events.append(.up) }
        if !previous.isRightDown, current.isRightDown { events.append(.rightDown) }
        if previous.isRightDown, !current.isRightDown { events.append(.rightUp) }
        guard !events.isEmpty else { return }

        for event in events {
            for (objectID, instance) in layerScriptInstances {
                if let output = dispatchScriptCursorEvent(
                    instance,
                    event: event,
                    pointerFrame: current,
                    runtimeSeconds: runtimeSeconds
                ) {
                    applyLayerScriptOutput(output, ownObjectID: objectID)
                }
            }
            for (objectID, instance) in layerAlphaScriptInstances {
                if let output = dispatchScriptCursorEvent(
                    instance,
                    event: event,
                    pointerFrame: current,
                    runtimeSeconds: runtimeSeconds
                ) {
                    applyLayerAlphaScriptOutput(output, ownObjectID: objectID)
                }
            }
        }
    }

    /// Applies a layer script's full output: its own layer plus any layers it
    /// drove via `thisScene.getLayer(name)` (resolved name→objectID).
    private func applyLayerScriptOutput(_ output: WPELayerScriptOutput, ownObjectID: String) {
        applyLayerScriptState(output.own, objectID: ownObjectID)
        for (name, state) in output.others {
            guard let targetID = layerObjectIDByName[name] else { continue }
            applyLayerScriptState(state, objectID: targetID)
        }
        for created in output.created {
            guard !created.imagePath.isEmpty else { continue }
            var state = created
            state.key = "\(ownObjectID).\(created.key)"
            liveCreatedLayers[state.key] = state
        }
    }

    private func applyLayerAlphaScriptOutput(_ output: WPELayerScriptOutput, ownObjectID: String) {
        liveLayerAlpha[ownObjectID] = output.own.alpha
    }

    /// Layer IDs the static-layer cache must never admit. Origin/scale/angles
    /// scripts and live-created layers move geometry the classifier can't see.
    /// Layer/alpha scripts are excluded because `applyingLayerAlpha` bakes the
    /// script value into `geometry.alpha` and clears `alphaAnimation` BEFORE
    /// classification — a script-alpha layer would otherwise classify as static
    /// and freeze at its first-cached alpha. `scriptAlphaOverriddenIDs` (the live
    /// alpha override map's keys) additionally catches cross-layer writes: a layer
    /// script may set any other named layer's alpha via its `others` output, which
    /// is unknowable statically; passed per frame, so the target layer stops
    /// classifying as static the moment it is first written. Pure + static for
    /// unit testing.
    nonisolated static func staticCacheExcludedLayerIDs(
        originScriptIDs: some Sequence<String>,
        scaleScriptIDs: some Sequence<String>,
        anglesScriptIDs: some Sequence<String>,
        liveCreatedLayerIDs: some Sequence<String>,
        layerScriptIDs: some Sequence<String>,
        alphaScriptIDs: some Sequence<String>,
        scriptAlphaOverriddenIDs: some Sequence<String>
    ) -> Set<String> {
        var ids = Set(originScriptIDs)
        ids.formUnion(scaleScriptIDs)
        ids.formUnion(anglesScriptIDs)
        ids.formUnion(liveCreatedLayerIDs)
        ids.formUnion(layerScriptIDs)
        ids.formUnion(alphaScriptIDs)
        ids.formUnion(scriptAlphaOverriddenIDs)
        return ids
    }

    private var staticCacheExcludedLayerIDs: Set<String> {
        var ids = installedScriptLayerIDs
        guard !liveCreatedLayers.isEmpty || !liveLayerAlpha.isEmpty else { return ids }
        ids.formUnion(liveCreatedLayers.keys)
        ids.formUnion(liveLayerAlpha.keys)
        return ids
    }

    /// The exclusion set's load-scoped part, memoized. `liveCreatedLayers` and
    /// `liveLayerAlpha` deliberately stay OUT of the cache — scripts grow them
    /// mid-frame, so their keys are unioned live above every frame.
    private var installedScriptLayerIDs: Set<String> {
        if let cached = cachedInstalledScriptLayerIDs { return cached }
        let ids = Self.staticCacheExcludedLayerIDs(
            originScriptIDs: dynamicOriginScriptInstances.keys,
            scaleScriptIDs: dynamicScaleScriptInstances.keys,
            anglesScriptIDs: dynamicAnglesScriptInstances.keys,
            liveCreatedLayerIDs: EmptyCollection<String>(),
            layerScriptIDs: layerScriptInstances.keys,
            alphaScriptIDs: layerAlphaScriptInstances.keys,
            scriptAlphaOverriddenIDs: EmptyCollection<String>()
        )
        cachedInstalledScriptLayerIDs = ids
        return ids
    }

    /// True unless some ancestor is currently hidden. Each ancestor's CURRENT
    /// visibility is its live override (image/script/text) if tracked, else its
    /// baked `visible` (groups) — so both static group toggles and live image
    /// toggles are honored. Pure + static for unit testing.
    nonisolated static func ancestorChainVisible(
        _ objectID: String,
        parentByID: [String: String],
        liveLayerVisibility: [String: Bool],
        liveTextVisibility: [String: Bool],
        ownVisibilityByID: [String: Bool]
    ) -> Bool {
        var seen: Set<String> = []
        var current = parentByID[objectID]
        while let id = current, seen.insert(id).inserted {
            let visible = liveLayerVisibility[id]
                ?? liveTextVisibility[id]
                ?? ownVisibilityByID[id]
                ?? true
            if !visible { return false }
            current = parentByID[id]
        }
        return true
    }

    private func ancestorChainVisible(_ objectID: String) -> Bool {
        Self.ancestorChainVisible(
            objectID,
            parentByID: objectParentByID,
            liveLayerVisibility: liveLayerVisibility,
            liveTextVisibility: liveTextVisibility,
            ownVisibilityByID: ownVisibilityByID
        )
    }

    /// Applies one layer's resolved state: visibility + alpha into the live
    /// override maps, and any buffered video commands to that layer's video source.
    private func applyLayerScriptState(_ state: WPELayerScriptState, objectID: String) {
        // A hidden ancestor always wins — the script runtime's `getParent()` is an
        // always-visible stub, so a dock script gating on `parent.visible` can't
        // otherwise hide itself (green App Launcher Dock on 3660962877). Walk the
        // chain live so a runtime ancestor toggle is respected, not snapshotted.
        if state.visibleAssigned {
            liveLayerVisibility[objectID] = state.visible && ancestorChainVisible(objectID)
        }
        if state.alphaAssigned {
            liveLayerAlpha[objectID] = state.alpha
        }
        guard !state.videoCommands.isEmpty,
              let key = layerVideoSourceKey[objectID],
              let video = dynamicTextureSources[key] as? WPEVideoTextureSource else { return }
        for command in state.videoCommands {
            switch command {
            case .play: video.scriptPlay()
            case .pause: video.scriptPause()
            case .stop: video.scriptStop()
            case .seek(let seconds): video.scriptSetCurrentTime(seconds)
            }
        }
    }

    /// External texture paths a layer references, in pass order — mirrors the
    /// `loadTextures` walk so a layer script can find its video source key.
    private func videoTexturePaths(for layer: WPEPreparedRenderLayer) -> [String] {
        var paths: [String] = []
        if layer.passes.isEmpty {
            if let path = externalTexturePath(for: .image(layer.graphLayer.imagePath)) {
                paths.append(path)
            }
            return paths
        }
        for pass in layer.passes {
            for reference in requiredTextureReferences(for: pass) {
                if let path = externalTexturePath(for: reference) {
                    paths.append(path)
                }
            }
        }
        return paths
    }

    /// Spawn one `WPEParticleSystem` per parsed particle object.
    ///
    /// A particle system is only registered if its sprite texture loads
    /// successfully. Missing textures would otherwise leave Metal's
    /// fragment-texture(0) slot stale across systems and produce the
    /// "black background + red grid" overlay seen in workshop 3725117707
    /// before the fix.
    private func loadParticleSystems(from document: WPESceneDocument) async {
        particleSystems.removeAll(keepingCapacity: true)
        particleTextures.removeAll(keepingCapacity: true)
        particleNormalTextures.removeAll(keepingCapacity: true)
        let imageObjectsByID = Dictionary(
            document.imageObjects.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for object in document.particleObjects where object.visible {
            let groupEffect = await resolveParticleGroupEffect(
                for: object,
                objectParentByID: document.objectParentByID,
                imageObjectsByID: imageObjectsByID
            )
            await expandParticleTree(
                path: object.particleRelativePath,
                parentPath: nil,
                originAccum: SIMD3<Double>(0, 0, 0),
                ancestry: [],
                parentSystem: nil,
                followFromParent: false,
                object: object,
                sortIndex: document.objectPaintOrder[object.id] ?? 0,
                groupEffect: groupEffect
            )
        }
    }

    /// A particle whose parent chain runs through a `composelayer` group inherits
    /// that group's tint + opacity-mask effects: WPE renders the system into the
    /// group's isolated buffer, then the group recolours and spatially confines it
    /// (3462491575's matrix rain → cyan-tinted, masked to an upper-centre blob).
    /// The particle pipeline draws straight to scene, so bake those two effects
    /// onto the system instead. Returns the loaded mask texture + tint, or nil.
    private func resolveParticleGroupEffect(
        for object: WPESceneParticleObject,
        objectParentByID: [String: String],
        imageObjectsByID: [String: WPESceneImageObject]
    ) async -> (mask: MTLTexture?, tint: SIMD3<Float>)? {
        var tint = SIMD3<Float>(1, 1, 1)
        var maskPath: String?
        var current = objectParentByID[object.id]
        var seen: Set<String> = []
        while let id = current, seen.insert(id).inserted {
            if let ancestor = imageObjectsByID[id],
               ancestor.imageRelativePath.lowercased().contains("composelayer") {
                for effect in ancestor.effects where effect.visible {
                    let file = effect.fileRelativePath.lowercased()
                    let pass = effect.passOverrides.first
                    if file.contains("/tint/"),
                       let color = pass?.constants["color"]?.vectorValue, color.count >= 3 {
                        tint = SIMD3<Float>(Float(color[0]), Float(color[1]), Float(color[2]))
                    }
                    if file.contains("/opacity/"),
                       let mask = pass?.textures[1] {
                        maskPath = mask
                    }
                }
            }
            current = objectParentByID[id]
        }
        guard maskPath != nil || tint != SIMD3<Float>(1, 1, 1) else { return nil }
        var maskTexture: MTLTexture?
        if let maskPath,
           let payload = try? await makeTextureResource(
               relativePath: maskPath, label: "particle group mask \(maskPath)"),
           case .staticTexture(let t) = payload {
            maskTexture = t
        }
        return (maskTexture, tint)
    }

    /// Recursively expand a nested particle `children` tree into drawable
    /// systems. Unlike a global `visited` set, dedup is per-ancestry-chain so
    /// same-path siblings with different `origin` offsets (the matrix-rain
    /// columns) each instantiate; only a path repeating within its own chain
    /// is skipped to break cycles. A spawner with `renderer: []` is expanded
    /// but not registered as drawable.
    private func expandParticleTree(
        path: String,
        parentPath: String?,
        originAccum: SIMD3<Double>,
        ancestry: [String],
        parentSystem: WPEParticleSystem?,
        followFromParent: Bool,
        object: WPESceneParticleObject,
        sortIndex: Int,
        groupEffect: (mask: MTLTexture?, tint: SIMD3<Float>)? = nil
    ) async {
        // Reload/cleanup cancels the owning load task cooperatively; bail
        // before doing any work (or recursing) on behalf of a dead load.
        guard !Task.isCancelled else { return }
        guard ancestry.count < 16 else {
            debugStage("particle", "skip \(object.name) — particle child depth limit reached at: \(path)")
            return
        }
        let particlePath = resolvedParticleChildPath(path, parentPath: parentPath)
        guard !ancestry.contains(particlePath) else {
            debugStage("particle", "skip \(object.name) — particle child cycle detected: \(particlePath)")
            return
        }
        guard let parsedDefinition = loadParticleDefinition(at: particlePath) else {
            debugStage("particle", "skip \(object.name) — particle definition load failed: \(particlePath)")
            return
        }
        let definition = parsedDefinition
            .offsettingOrigin(by: originAccum)
            .applying(instanceOverride: object.instanceOverride)
        let registered: WPEParticleSystem?
        if definition.rendersSprite {
            registered = await registerParticleSystem(
                definition: definition,
                object: object,
                particlePath: particlePath,
                followParent: followFromParent ? parentSystem : nil,
                requiresFollowParent: followFromParent,
                sortIndex: sortIndex,
                isNestedChild: !ancestry.isEmpty,
                groupEffect: groupEffect
            )
        } else {
            registered = nil
            debugStage("particle", "expand-only \(object.name) — renderer disabled: \(particlePath)")
        }
        // A renderer:[] spawner (didn't register) forwards its OWN parent so its
        // children can still event-follow up the chain. A rendering parent that
        // FAILED to register forwards nil — its event-follow children must stay
        // gated rather than silently following the grandparent.
        let childParentSystem = definition.rendersSprite ? registered : parentSystem
        let childAncestry = ancestry + [particlePath]
        for child in parsedDefinition.childReferences {
            await expandParticleTree(
                path: child.relativePath,
                parentPath: particlePath,
                originAccum: originAccum + child.originOffset,
                ancestry: childAncestry,
                parentSystem: childParentSystem,
                followFromParent: child.isEventFollow,
                object: object,
                sortIndex: sortIndex,
                groupEffect: groupEffect
            )
        }
    }

    private func resolvedParticleChildPath(_ childPath: String, parentPath: String?) -> String {
        guard !childPath.contains("/"), let parentPath else {
            return childPath
        }
        let directory = (parentPath as NSString).deletingLastPathComponent
        return directory.isEmpty ? childPath : "\(directory)/\(childPath)"
    }

    private func loadParticleDefinition(at particlePath: String) -> WPEParticleDefinition? {
        guard let data = try? entryResolver.data(relativePath: particlePath) else {
            return nil
        }
        return WPEParticleDefinitionParser.parse(data: data)
    }

    @discardableResult
    private func registerParticleSystem(
        definition: WPEParticleDefinition,
        object: WPESceneParticleObject,
        particlePath: String,
        followParent: WPEParticleSystem? = nil,
        requiresFollowParent: Bool = false,
        sortIndex: Int = 0,
        isNestedChild: Bool = false,
        groupEffect: (mask: MTLTexture?, tint: SIMD3<Float>)? = nil
    ) async -> WPEParticleSystem? {
        let material = definition.materialRelativePath
            .flatMap(parseParticleMaterial(at:))
        let blendMode = material?.blendMode ?? .translucent
        let sceneTransform = makeParticleSceneTransform(for: object)
        guard let texturePath = material?.firstTexturePath else {
            debugStage("particle", "skip \(object.name) — material missing texture binding: \(particlePath)")
            return nil
        }
        guard let texturePayload = try? await makeTextureResource(
            relativePath: texturePath,
            label: "particle texture \(texturePath)"
        ) else {
            debugStage("particle", "skip \(object.name) — texture load failed: \(texturePath)")
            return nil
        }
        // A reload may have reset `particleSystems` while this load was
        // suspended above — registering now would append a dead load's
        // subtree into the NEW load's scene (duplicated particle systems).
        guard !Task.isCancelled else { return nil }
        let texture: MTLTexture?
        let animatedTextureSource: WPETexAnimatedTextureSource?
        switch texturePayload {
        case .staticTexture(let t):
            texture = t
            animatedTextureSource = nil
        case .dynamicSource(let source):
            texture = source.texture(at: 0)
            animatedTextureSource = source as? WPETexAnimatedTextureSource
        }
        guard let resolved = texture else {
            debugStage("particle", "skip \(object.name) — dynamic source yielded no texture")
            return nil
        }
        var spriteSheet = parseParticleSpriteSheet(
            texturePath: texturePath,
            atlasPixelSize: (width: resolved.width, height: resolved.height)
        )
        // No `.tex-json` sidecar (or a single-frame one) but the `.tex` carries
        // a TEXS animation track: slice the atlas by the decoded per-frame
        // sub-rects. This is the Matrix-glyph case — frames live in the TEXS
        // chunk, not a sidecar, so the uniform-grid path would draw the whole
        // atlas as one quad.
        if spriteSheet == nil || (spriteSheet?.frameCount ?? 1) <= 1,
           let animatedTextureSource {
            let frameRects = animatedTextureSource.spriteSheetFrameRectsNormalized()
            if !frameRects.isEmpty {
                spriteSheet = WPEParticleSpriteSheet(
                    cols: 1,
                    rows: 1,
                    frameCount: frameRects.count,
                    baseFrameRate: animatedTextureSource.spriteSheetFrameRate,
                    isAlphaMask: resolved.pixelFormat == .r8Unorm,
                    frameRects: frameRects
                )
            }
        }
        // A repacked scene can strip the TEXS frame table from a sequence atlas
        // (3462491575's matrix glyph sheet: single-frame 512×512 .tex, logical
        // 450×400, no sidecar). WPE still slices the LOGICAL image into its
        // largest exact square-cell grid (gcd 50 → 9×8 = 72 frames, matching the
        // authored "spritesheet 72"), so derive the same grid — but only for
        // particles that explicitly opted into sequence animation; a defaulted
        // `animationmode` must not slice single-image sprites.
        if spriteSheet == nil, definition.declaresSequenceAnimation {
            let resolution = WPEMetalTextureMetadataRegistry.shared.resolution(for: resolved)
            spriteSheet = Self.squareCellGridSpriteSheet(
                logicalWidth: resolution.imageWidth,
                logicalHeight: resolution.imageHeight,
                atlasWidth: resolved.width,
                atlasHeight: resolved.height,
                isAlphaMask: resolved.pixelFormat == .r8Unorm
            )
        }
        // Defensive: an R8 particle texture whose `.tex-json` sidecar is
        // missing/invalid would otherwise fall through to the non-mask path
        // and sample `.r8Unorm` alpha as 1 → an opaque quad (the RG88
        // "red square" failure mode, in single channel). R8 is always a
        // single-channel alpha mask, so flag it as such.
        if spriteSheet == nil, resolved.pixelFormat == .r8Unorm {
            spriteSheet = WPEParticleSpriteSheet(
                cols: 1, rows: 1, frameCount: 1, baseFrameRate: 0, isAlphaMask: true
            )
        }
        // Under the render oracle, seed spawn jitter deterministically so the scene
        // renders byte-identically run-to-run. `nil` in production ⇒ system CSPRNG.
        let oracleSeed: UInt64? = WPEOracleMode.isEnabled
            ? WPEParticleSystem.deterministicSeed(
                workshopID: descriptor.workshopID, objectID: object.id, sortIndex: sortIndex)
            : nil
        guard let system = WPEParticleSystem(
            definition: definition,
            device: executor.textureSourceDevice,
            blendMode: blendMode,
            sceneTransform: sceneTransform,
            spriteSheet: spriteSheet,
            seed: oracleSeed
        ) else { return nil }
        system.parallaxDepth = object.parallaxDepth
        system.sortIndex = sortIndex
        system.overbright = Self.particleOverbright(
            material: material?.overbright,
            objectBrightness: object.brightness
        )
        system.isNestedChildSystem = isNestedChild
        if let groupEffect {
            system.groupOpacityMask = groupEffect.mask
            system.groupTint = groupEffect.tint
        }
        // REFRACT (lens water droplets / heat haze): needs the normal map too.
        // If it fails to load, fall back to the flat-sprite path rather than a
        // refraction that samples nothing.
        if material?.isRefract == true, let normalPath = material?.normalTexturePath,
           let normalPayload = try? await makeTextureResource(
               relativePath: normalPath, label: "particle normal \(normalPath)",
               colorSpace: .linear),   // a normal map is DATA — sRGB gamma corrupts its vectors
           case .staticTexture(let normalTexture) = normalPayload {
            system.isRefract = true
            system.refractAmount = material?.refractAmount ?? 0.05
            particleNormalTextures[ObjectIdentifier(system)] = normalTexture
        }
        if requiresFollowParent {
            system.followParent = followParent
            system.requiresFollowParent = true
        }
        // WPE `starttime` is used by workshop authors as an initial simulation
        // offset: star fields with `starttime: 200` should load already full,
        // not wait 200 wall-clock seconds. The manual developer flag only adds
        // the same steady-state prewarm to emitters whose authored starttime is 0.
        if let prewarmSeconds = Self.particlePrewarmSeconds(
            for: definition,
            manualPrewarmEnabled: Self.particlePrewarmEnabled
        ) {
            system.prewarm(simulatedSeconds: prewarmSeconds)
        }
        particleSystems.append(system)
        particleTextures[ObjectIdentifier(system)] = resolved
        if WPESceneDebugArtifacts.shared.isEnabled {
            // Dump the parsed motion-driving params so an emitter-placement /
            // fall-speed divergence vs WPE can be traced to either our PARSING
            // (these values wrong) or our SIMULATION (values right, motion wrong).
            let idx = particleSystems.count - 1
            let d = definition
            var s = "particle[\(idx)] name=\(object.name)\n"
            s += "material=\(d.materialRelativePath ?? "-") blend=\(blendMode.rawValue) animationMode=\(d.animationMode)\n"
            s += "maxCount=\(d.maxCount) rate=\(d.rate) startDelay=\(d.startDelay)\n"
            s += "lifetime=[\(d.lifetimeMin),\(d.lifetimeMax)] size=[\(d.sizeMin),\(d.sizeMax)]\n"
            s += "originOffset=\(d.originOffset) dispersal=[\(d.dispersalMin),\(d.dispersalMax)] directionMask=\(d.directionMask)\n"
            s += "velocityMin=\(d.velocityMin) velocityMax=\(d.velocityMax)\n"
            s += "gravity=\(d.gravity) drag=\(d.drag)\n"
            s += "rotation=[\(d.rotationMin),\(d.rotationMax)] angularVel=[\(d.angularVelocityMin),\(d.angularVelocityMax)] angularForceZ=\(d.angularForceZ)\n"
            s += "turbulence: speed=[\(d.turbulenceSpeedMin),\(d.turbulenceSpeedMax)] scale=\(d.turbulenceScale) mask=\(d.turbulenceMask)\n"
            s += "sceneTransform: renderOrigin=\(sceneTransform.renderOrigin) objectScale=\(sceneTransform.objectScale) objectAngleZ=\(sceneTransform.objectAngleZ)\n"
            WPESceneDebugArtifacts.shared.recordNote(name: "particle-def-\(idx).txt", contents: s)
        }
        let textureLabel = resolved.label ?? "<unlabeled>"
        let sheetDescription: String
        if let sheet = spriteSheet {
            sheetDescription = "sheet=\(sheet.cols)x\(sheet.rows)×\(sheet.frameCount) mask=\(sheet.isAlphaMask)"
        } else {
            sheetDescription = "sheet=none"
        }
        debugStage(
            "particle.binding",
            "\(object.name) particle=\(particlePath) count=\(definition.maxCount) rate=\(definition.rate) blend=\(blendMode.rawValue) texturePath=\(texturePath) texture=\(textureLabel) \(sheetDescription)"
        )
        return system
    }

    func reload() async throws {
        loadGeneration &+= 1
        finishAllPendingLivePosterCaptures(image: nil)
        deferredAudioStartupTask?.cancel()
        deferredAudioStartupTask = nil
        pendingAudioStartupDocument = nil
        didLoad = false
        hasPresentedFrame = false
        outputTexture = nil
        renderGraph = nil
        renderPipeline = nil
        lastFramePipeline = nil
        scenePropertyBindings = [:]
        liveLayerVisibility = [:]
        liveCreatedLayers = [:]
        createdLayerTemplatesByImagePath = [:]
        previousPointer = SIMD2<Double>(0.5, 0.5)
        previousPointerWasLive = false
        previousLayerScriptPointerFrame = .neutral
        objectParentByID = [:]
        ownVisibilityByID = [:]
        liveTextVisibility = [:]
        loadDiagnostics = nil
        resolutionTracer.reset()
        releaseDynamicTextureSources()
        particleSystems.removeAll(keepingCapacity: false)
        particleTextures.removeAll(keepingCapacity: false)
        particleNormalTextures.removeAll(keepingCapacity: false)
        textObjects.removeAll(keepingCapacity: false)
        textRenderer?.releaseAll()
        textRenderer = nil
        msdfTextRenderer = nil
        textScriptInstances.removeAll(keepingCapacity: false)
        layerScriptInstances.removeAll(keepingCapacity: false)
        sceneScriptSharedState = nil
        layerAlphaScriptInstances.removeAll(keepingCapacity: false)
        dynamicOriginScriptInstances.removeAll(keepingCapacity: false)
        dynamicScaleScriptInstances.removeAll(keepingCapacity: false)
        dynamicAnglesScriptInstances.removeAll(keepingCapacity: false)
        transformHostLocalTransformsByID.removeAll(keepingCapacity: false)
        layerVideoSourceKey.removeAll(keepingCapacity: false)
        layerObjectIDByName.removeAll(keepingCapacity: false)
        onDemandVideoKeyByID.removeAll(keepingCapacity: false)
        onDemandVideoLoading.removeAll(keepingCapacity: false)
        liveLayerAlpha.removeAll(keepingCapacity: false)
        liveCreatedLayers.removeAll(keepingCapacity: false)
        createdLayerTemplatesByImagePath.removeAll(keepingCapacity: false)
        introPhaseSource = nil
        loopPhaseSource = nil
        introLoopOffset = nil
        soundRuntime?.stop()
        soundRuntime = nil
        sceneRenderSize = CGSize(width: 1, height: 1)
        cameraUniforms = .identity
        lastRuntimeUniforms = nil
        lastFramePipeline = nil
        cachedSnapshot = nil
        executor.releaseTransientResources()
        try await load()
    }

    /// Applies a project-property change in place when every changed binding is
    /// incremental; returns `false` (so the caller falls back to a full reload)
    /// otherwise. Today only image/text visibility is incremental.
    func applyScenePropertyPatch(_ patch: WPEScenePropertyPatch) -> Bool {
        guard !patch.requiresReload else { return false }
        guard !patch.changedKeys.isEmpty else { return true }
        // A scene with no live pipeline can't be patched — only allow the no-op
        // (no incremental bindings) case through; anything substantive reloads.
        guard renderPipeline != nil || patch.incrementalBindings.isEmpty else { return false }

        var nextLayerVisibility = liveLayerVisibility
        var nextTextVisibility = liveTextVisibility

        // Resolves a visibility binding's live boolean. Condition-form (style
        // selector) bindings evaluate `newValue matches condition`; simple
        // bindings read the boolean directly. Returns nil (→ safe full reload)
        // when the changed value can't drive this target.
        func resolvedVisible(for binding: WPEScenePropertyBinding) -> Bool? {
            if let condition = binding.condition {
                guard let value = patch.newValues[binding.propertyKey] else { return nil }
                return WallpaperEngineProjectPropertySchema.sceneConditionMatches(
                    value: value,
                    condition: condition
                )
            }
            return patch.newValues[binding.propertyKey]?.boolValue
        }

        for binding in patch.incrementalBindings {
            switch (binding.target, binding.kind) {
            case (.imageObject(let id), .visible):
                guard let value = resolvedVisible(for: binding) else { return false }
                nextLayerVisibility[id] = value
            case (.textObject(let id), .visible):
                guard let value = resolvedVisible(for: binding) else { return false }
                nextTextVisibility[id] = value
            default:
                // An incremental binding we don't yet know how to apply: bail to
                // the safe full-reload path rather than silently dropping it.
                return false
            }
        }

        liveLayerVisibility = nextLayerVisibility
        liveTextVisibility = nextTextVisibility

        // Feed changed values to any layer/text script's `applyUserProperties` so a
        // runtime toggle (e.g. `timevarying`) reacts without a full reload. Text
        // visible/alpha scripts route the same way as they do at init and per frame.
        if !layerScriptInstances.isEmpty || !layerAlphaScriptInstances.isEmpty
            || !textVisibleScriptInstances.isEmpty || !textAlphaScriptInstances.isEmpty {
            let changed = Self.bridgeUserProperties(
                patch.newValues.filter { patch.changedKeys.contains($0.key) }
            )
            if !changed.isEmpty {
                for (objectID, instance) in layerScriptInstances {
                    if let output = applyScriptUserProperties(
                        instance,
                        changed,
                        runtimeSeconds: lastRuntimeUniforms?.time
                    ) {
                        applyLayerScriptOutput(output, ownObjectID: objectID)
                    }
                }
                for (objectID, instance) in layerAlphaScriptInstances {
                    if let output = applyScriptUserProperties(
                        instance,
                        changed,
                        runtimeSeconds: lastRuntimeUniforms?.time
                    ) {
                        applyLayerAlphaScriptOutput(output, ownObjectID: objectID)
                    }
                }
                for (objectID, instance) in textVisibleScriptInstances {
                    if let output = applyScriptUserProperties(
                        instance,
                        changed,
                        runtimeSeconds: lastRuntimeUniforms?.time
                    ) {
                        applyTextScriptOutput(output, ownObjectID: objectID)
                    }
                }
                for (objectID, instance) in textAlphaScriptInstances {
                    if let output = applyScriptUserProperties(
                        instance,
                        changed,
                        runtimeSeconds: lastRuntimeUniforms?.time
                    ) {
                        liveTextAlpha[objectID] = output.own.alpha
                    }
                }
            }
        }

        if let pipeline = renderPipeline {
            renderPipeline = pipeline
                .applyingLayerVisibility(liveLayerVisibility)
                .applyingLayerAlpha(liveLayerAlpha)
            // A static scene is paused with setNeedsDisplay disabled, so the flag
            // below is inert and even a forced draw() re-presents the cached
            // outputTexture. Render the patched pipeline once here so the toggle
            // shows immediately instead of waiting for an unrelated live trigger.
            if !needsContinuousFrames, let frame = try? renderCurrentFrame() {
                outputTexture = frame
                mtkView.draw()
                return true
            }
        }
        mtkView.setNeedsDisplay(mtkView.bounds)
        return true
    }

    func setMouseInteractionEnabled(_ enabled: Bool) {
        mouseInteractionEnabled = enabled
        if !enabled {
            previousPointerWasLive = false
            previousPointer = SIMD2<Double>(0.5, 0.5)
            previousLayerScriptPointerFrame = .neutral
            // Follow Cursor off: the pointer-spawned particle emitters stop (their
            // spawn is gated on a live pointer), so also clear whatever they already
            // emitted — otherwise those particles linger at the cursor's last spot
            // (and reappear on reload) instead of being prohibited outright.
            for system in particleSystems where system.tracksPointer {
                system.clearLiveParticles()
            }
            // Re-present so the cleared state shows at once even if the scene is paused.
            mtkView.setNeedsDisplay(mtkView.bounds)
        }
        refreshLiveness()
    }

    /// Updates how the scene is fitted to the screen. For a static (non-continuous)
    /// scene, re-present once so the new fit shows immediately rather than waiting
    /// for the next content change.
    func setPresentFitMode(_ mode: WPEPresentFitMode) {
        guard mode != presentFitMode else { return }
        presentFitMode = mode
        if !needsContinuousFrames, outputTexture != nil {
            mtkView.draw()
        }
    }

    func setClickCaptureEnabled(_ enabled: Bool) {
        mtkView.clickCaptureEnabled = enabled
        refreshLiveness()
    }

    /// Re-evaluates the paused/continuous state after a mouse-interaction toggle
    /// flips at runtime, so turning Follow Cursor / Interaction on un-pauses a
    /// previously-static scene (and turning them off lets it re-pause).
    private func refreshLiveness() {
        guard currentProfile == .quality else { return }
        mtkView.isPaused = !needsContinuousFrames
        mtkView.enableSetNeedsDisplay = !needsContinuousFrames
    }

    /// Applies the user-selected frame rate ceiling. `.unlimited` falls
    /// back to vsync (`unlimitedPreferredFPS`) so MTKView doesn't free-run.
    /// Suspended state is not overridden here — the ceiling takes effect on
    /// the next non-suspended transition.
    func setFrameRateLimit(_ limit: FrameRateLimit) {
        let resolved: Int
        switch limit {
        case .unlimited:
            resolved = Self.unlimitedPreferredFPS
        default:
            resolved = max(1, limit.rawValue)
        }
        guard resolved != userPreferredFPS else { return }
        userPreferredFPS = resolved
        applyEffectiveFrameRate()
    }

    /// The user ceiling, optionally halved (floored at `adaptiveThrottleFloorFPS`,
    /// never above the ceiling) while the adaptive background throttle is active.
    private var effectiveFPS: Int {
        guard adaptiveThrottleActive else { return userPreferredFPS }
        return min(userPreferredFPS, max(Self.adaptiveThrottleFloorFPS, userPreferredFPS / 2))
    }

    /// Suspended scenes don't drive frames, so the ceiling re-applies on the
    /// next `.quality` transition (mirrors `setFrameRateLimit`'s old guard).
    private func applyEffectiveFrameRate() {
        guard currentProfile != .suspended else { return }
        mtkView.preferredFramesPerSecond = effectiveFPS
    }

    func setAdaptiveFrameRateThrottle(_ active: Bool) {
        guard active != adaptiveThrottleActive else { return }
        adaptiveThrottleActive = active
        applyEffectiveFrameRate()
    }

    /// Forwards the inspector's mute toggle into the scene's audio
    /// runtime. Cached so calls that arrive before the deferred audio
    /// startup (which fires after the first present) still take effect once
    /// the runtime exists.
    func setAudioMuted(_ muted: Bool) {
        pendingAudioMuted = muted
        soundRuntime?.setMuted(muted)
    }

    /// Forwards the inspector's audio slider into the scene's audio
    /// runtime as a master gain multiplied into each scene-declared
    /// `sound.volume`. Cached so pre-load calls survive across the
    /// deferred audio-startup boundary.
    func setAudioVolume(_ volume: Double) {
        pendingAudioVolume = volume
        soundRuntime?.setMasterVolume(volume)
    }

    /// True when something on stage actually changes between frames — a dynamic
    /// texture (animated `.tex` / video), a live particle system, or a
    /// SceneScript-driven transform. Static-scene + dynamic-content combos must
    /// NOT short-circuit MTKView into the paused/on-demand path or they freeze
    /// after the first frame.
    private var needsContinuousFrames: Bool {
        hasAnimatedShaderPasses
            || sceneSupportsAudioProcessing
            || !dynamicTextureSources.isEmpty
            // On-demand videos may all be released (hidden) yet still need a live
            // loop so a reveal triggers their rebuild via reconcileVideoResidency.
            || !onDemandVideoKeyByID.isEmpty
            || !particleSystems.isEmpty
            || !dynamicOriginScriptInstances.isEmpty
            || !dynamicScaleScriptInstances.isEmpty
            || !dynamicAnglesScriptInstances.isEmpty
            || !layerScriptInstances.isEmpty
            || !layerAlphaScriptInstances.isEmpty
            // Text scripts tick per frame too (content writes `shared` state;
            // visibility/alpha drive fades) — a scene whose only live driver is a
            // text script must keep the loop running or it freezes at frame 0.
            || !textScriptInstances.isEmpty
            || !textVisibleScriptInstances.isEmpty
            || !textAlphaScriptInstances.isEmpty
            || pointerDrivenContent
    }

    /// The cursor moves between frames, so anything that consumes it needs a
    /// live frame to re-sample — otherwise a static scene renders once at load
    /// and never reacts to the mouse again (the "no interaction" bug). Camera
    /// parallax (gated by the Follow Cursor toggle) and click capture both
    /// qualify; pointer-only shaders are already "animated" (effects/workshop)
    /// and covered by `hasAnimatedShaderPasses`.
    private var pointerDrivenContent: Bool {
        (mouseInteractionEnabled
            && cameraParallaxSettings.enabled
            && cameraParallaxSettings.amount > 0
            && cameraParallaxSettings.mouseInfluence > 0)
            || mtkView.clickCaptureEnabled
    }

    /// A pass animates per-frame when its shader samples `g_Time` /
    /// `g_AudioSpectrum*` — i.e. WPE local effects (`effects/…`) and workshop
    /// custom shaders (`workshop/…`). The static base shaders (`solidcolor`,
    /// `genericimage2/4`, `compose`, `copy`) do not, so a scene built only on
    /// those is genuinely static and may stay on the paused/on-demand path.
    private static func pipelineHasAnimatedPasses(_ pipeline: WPEPreparedRenderPipeline) -> Bool {
        pipeline.layers.contains { layer in
            layer.passes.contains { prepared in
                let shader = prepared.pass.shader.lowercased()
                return shader.contains("effects/") || shader.contains("workshop/")
            }
        }
    }

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        currentProfile = profile
        dynamicTextureSources.values.forEach { $0.applyPerformanceProfile(profile) }
        switch profile {
        case .quality:
            mtkView.isPaused = !needsContinuousFrames
            mtkView.enableSetNeedsDisplay = !needsContinuousFrames
            mtkView.preferredFramesPerSecond = effectiveFPS
            // Restart scene audio that a prior `.suspended` paused. No-op when
            // audio never started (deferred startup) or is already running.
            soundRuntime?.resume()
        case .suspended:
            mtkView.isPaused = true
            mtkView.enableSetNeedsDisplay = true
            mtkView.releaseDrawables()
            // Pause the audio engine + FFT tap so a suspended wallpaper costs no
            // audio CPU; the decoded PCM stays resident for an instant resume.
            soundRuntime?.pause()
            executor.releaseTransientResources()
        }
    }

    func cleanup() {
        loadGeneration &+= 1
        finishAllPendingLivePosterCaptures(image: nil)
        deferredAudioStartupTask?.cancel()
        deferredAudioStartupTask = nil
        pendingAudioStartupDocument = nil
        mtkView.delegate = nil
        outputTexture = nil
        lastFramePipeline = nil
        scenePropertyBindings = [:]
        liveLayerVisibility = [:]
        liveCreatedLayers = [:]
        createdLayerTemplatesByImagePath = [:]
        previousPointer = SIMD2<Double>(0.5, 0.5)
        previousPointerWasLive = false
        previousLayerScriptPointerFrame = .neutral
        objectParentByID = [:]
        ownVisibilityByID = [:]
        liveTextVisibility = [:]
        releaseDynamicTextureSources()
        particleSystems.removeAll(keepingCapacity: false)
        particleTextures.removeAll(keepingCapacity: false)
        particleNormalTextures.removeAll(keepingCapacity: false)
        textObjects.removeAll(keepingCapacity: false)
        textRenderer?.releaseAll()
        textRenderer = nil
        msdfTextRenderer = nil
        textScriptInstances.removeAll(keepingCapacity: false)
        layerScriptInstances.removeAll(keepingCapacity: false)
        sceneScriptSharedState = nil
        layerAlphaScriptInstances.removeAll(keepingCapacity: false)
        dynamicOriginScriptInstances.removeAll(keepingCapacity: false)
        dynamicScaleScriptInstances.removeAll(keepingCapacity: false)
        dynamicAnglesScriptInstances.removeAll(keepingCapacity: false)
        transformHostLocalTransformsByID.removeAll(keepingCapacity: false)
        layerVideoSourceKey.removeAll(keepingCapacity: false)
        layerObjectIDByName.removeAll(keepingCapacity: false)
        onDemandVideoKeyByID.removeAll(keepingCapacity: false)
        onDemandVideoLoading.removeAll(keepingCapacity: false)
        liveLayerAlpha.removeAll(keepingCapacity: false)
        liveCreatedLayers.removeAll(keepingCapacity: false)
        createdLayerTemplatesByImagePath.removeAll(keepingCapacity: false)
        introPhaseSource = nil
        loopPhaseSource = nil
        introLoopOffset = nil
        soundRuntime?.stop()
        soundRuntime = nil
        cameraParallaxSettings = .disabled
        sceneSupportsAudioProcessing = false
        cameraParallaxSmoother.reset()
        lastRuntimeUniforms = nil
        lastFramePipeline = nil
        cachedSnapshot = nil
        resolutionTracer.reset()
        executor.releaseTransientResources()
        stopEngineAssetsAccessIfNeeded()
    }

    deinit {
        stopEngineAssetsAccessIfNeeded()
    }

    nonisolated private func stopEngineAssetsAccessIfNeeded() {
        guard let url = activeEngineAssetsRootURL else { return }
        url.stopAccessingSecurityScopedResource()
        activeEngineAssetsRootURL = nil
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    /// Suppresses repeat `draw(in:)` failure logs within a failure streak so a
    /// broken pipeline warns once, not once per frame.
    private var didLogFrameFailure = false

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { [weak self] in
            self?.drawOnMainActor(in: view)
        }
    }

    private func drawOnMainActor(in view: MTKView) {
        guard didLoad else { return }
        do {
            let textureToPresent: MTLTexture?
            if needsContinuousFrames {
                let frame = try renderCurrentFrame()
                outputTexture = frame
                textureToPresent = frame
            } else {
                textureToPresent = outputTexture
            }
            guard let texture = textureToPresent else { return }
            let livePosterCaptures = takePendingLivePosterCaptures()
            let presentCompletion = Self.livePosterPresentCompletion(for: livePosterCaptures)
            var presented = false
            do {
                presented = try executor.present(
                    texture: texture,
                    in: view,
                    fitMode: presentFitMode,
                    presentCompletion: presentCompletion
                )
                if !presented {
                    Self.finishLivePosterCaptures(livePosterCaptures, image: nil)
                }
            } catch {
                Self.finishLivePosterCaptures(livePosterCaptures, image: nil)
                throw error
            }
            didLogFrameFailure = false
            // Start audio only after the first frame is actually on screen, so
            // the synchronous engine spin-up can never delay the first pixels.
            if presented, pendingAudioStartupDocument != nil {
                beginDeferredAudioStartup()
            }
        } catch is WPEMetalFrameInFlightBudgetExhausted {
            // GPU still busy on a prior frame — skip this vsync rather than
            // block the @MainActor (keeps other displays at full rate). The
            // previously presented frame stays on screen; not a failure.
            return
        } catch {
            // Per-frame path: log only the first failure of a streak (resets on
            // recovery) so a persistently-broken pipeline can't flood the log.
            if !didLogFrameFailure {
                Logger.warning("Scene \(descriptor.workshopID) frame render/present failed: \(error.localizedDescription)", category: .screenManager)
                didLogFrameFailure = true
            }
        }
    }

    /// Phase 2E: differentiates between a one-shot static texture and a
    /// dynamic source (animated TEX or video) so the renderer can either
    /// stuff the result into `loadedTextures` or hold the source for
    /// per-frame refresh via `texturesForCurrentFrame(time:)`.
    private enum WPELoadedTextureResource {
        case staticTexture(MTLTexture)
        case dynamicSource(WPEDynamicTextureSource)
    }

    /// One unique external texture to load, captured before fan-out so the
    /// off-actor lane never races on a shared dedup map.
    private struct WPETextureLoadJob: Sendable {
        let path: String
        let layerName: String
        let candidates: [String]
    }

    /// Outcome of the off-actor resolve+upload lane. `staticTexture` carries a
    /// fully-built Metal texture (a thread-safe object) back to the main actor;
    /// `needsOnActor` flags a dynamic/video/animated/heavy-streaming source
    /// whose construction is `@MainActor`-isolated and is handled serially.
    /// `@unchecked Sendable` is the idiomatic escape hatch for ferrying an
    /// `MTLTexture` (documented thread-safe) across the actor hop.
    private enum WPEParallelTextureResult: @unchecked Sendable {
        case staticTexture(MTLTexture)
        case needsOnActor
    }

    /// Off-thread shader-transpile pre-warm. Builds the deterministic, runtime-independent
    /// compile request for every custom-shader pass on the main actor (deduped by cache key),
    /// then translates + makeLibrary's them in parallel OFF the main actor and seeds
    /// `executor.translatedShaderCache` — so the first synchronous `render()` gets cache hits
    /// instead of paying the ~1.9s lazy GLSL→MSL transpile inline. Launched as an `async let`
    /// during the load window (overlapping texture/particle/text load) and awaited at the
    /// render.firstFrame gate. Flag-gated; per-pass failures are swallowed (the real first
    /// render re-hits and records them as today). Respects `loadGeneration` so a superseded
    /// load never seeds. Captures only `Sendable` values (the compiler protocol is `Sendable`,
    /// requests are `Sendable`) — never the non-`Sendable` executor.
    private func prewarmCustomShaders(
        for pipeline: WPEPreparedRenderPipeline,
        textObjects: [WPESceneTextObject]
    ) async {
        // Always pre-compile before the first-frame encode: compiling a pipeline
        // state inline during an open render encoder corrupts the pass (3660962877
        // black bg + green quad).
        let generation = loadGeneration
        debugStage("shader.prewarm", "begin")

        // Build + dedup requests on the main actor (the preprocess is cheap; only the
        // translate+makeLibrary that follows is the heavy CPU). recordFailure:false keeps
        // the warm silent — the real first-frame render stays the sole failure recorder.
        var requestsByKey: [String: WPEShaderCompileRequest] = [:]
        for layer in pipeline.layers {
            for pass in layer.passes where pass.shader?.isBuiltin == false {
                guard let request = try? WPEMetalRenderExecutor.makeCompileRequest(for: pass, recordFailure: false) else { continue }
                requestsByKey[request.translationCacheKey] = request
            }
        }
        // GPU MSDF text loads via a separate path (loadTextOverlays) whose font.frag
        // is otherwise transpiled lazily on the first synchronous drawMSDFText. Warm
        // it here on the same off-thread task group. Gate must match loadTextOverlays.
        if !textObjects.isEmpty,
           UserDefaults.standard.object(forKey: "WPEEnableMSDFText") as? Bool ?? true,
           let fontFragmentSource = resolveMSDFFontFragmentSource() {
            for request in WPEMSDFTextRenderer.prewarmShaderRequests(
                for: textObjects,
                fontFragmentSource: fontFragmentSource,
                resolver: resourceResolver
            ) {
                requestsByKey[request.translationCacheKey] = request
            }
        }
        let requests = Array(requestsByKey.values)
        guard !requests.isEmpty, loadGeneration == generation else {
            debugStage("shader.prewarm.done", "passes=0")
            return
        }

        let compiler = executor.shaderCompiler
        let width = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))

        let warmed: [(key: String, result: WPEShaderCompileResult)]
        do {
            warmed = try await withThrowingTaskGroup(
                of: (key: String, result: WPEShaderCompileResult)?.self
            ) { group in
                var next = 0
                func spawn() -> Bool {
                    guard next < requests.count else { return false }
                    let request = requests[next]
                    next += 1
                    group.addTask(priority: .userInitiated) {
                        try Task.checkCancellation()
                        // Swallow an unsupported shader: leave it uncached so the real
                        // first-frame render re-hits compileCustomShader and records it.
                        guard let result = try? compiler.compile(request, recordFailure: false) else {
                            return nil
                        }
                        return (key: request.translationCacheKey, result: result)
                    }
                    return true
                }
                for _ in 0..<width where spawn() {}
                var collected: [(key: String, result: WPEShaderCompileResult)] = []
                while let entry = try await group.next() {
                    if loadGeneration != generation {
                        group.cancelAll()
                        break
                    }
                    if let entry { collected.append(entry) }
                    _ = spawn()
                }
                return collected
            }
        } catch {
            // A superseded load cancelled the group mid-drain; drop the partial results.
            debugStage("shader.prewarm.cancelled", "\(error)")
            return
        }

        guard loadGeneration == generation else { return }
        executor.seedTranslatedShaderCache(warmed)
        debugStage("shader.prewarm.done", "warmed=\(warmed.count)/\(requests.count)")

        // Second parallel phase: pre-build the pipeline STATES too. makeRenderPipelineState
        // is the dominant residual first-frame cost (transpile/makeLibrary above are already
        // warmed) and was still compiled lazily & serially on the render thread. Enumerate
        // each pass's (shader, blend) against the scene's dominant color format and the two
        // common vertex functions (fullscreen + object-quad); dedup by pipeline identity.
        // Over-/under-prediction only changes the cache-hit rate, never correctness.
        var resultByKey: [String: WPEShaderCompileResult] = [:]
        for entry in warmed { resultByKey[entry.key] = entry.result }
        let sceneColorFormat: MTLPixelFormat = cameraUniforms.sceneHDR
            ? .rgba16Float
            : WPEMetalRenderExecutor.outputPixelFormat
        let vertexCandidates: [String?] = [nil, "wpe_object_quad_vertex"]
        let prewarmDevice = executor.textureSourceDevice
        var pipelinePrewarms: [WPEMetalRenderExecutor.WPETranslatedPipelinePrewarm] = []
        var seenPipelineKeys = Set<String>()
        for layer in pipeline.layers {
            for pass in layer.passes where pass.shader?.isBuiltin == false {
                guard let request = try? WPEMetalRenderExecutor.makeCompileRequest(for: pass, recordFailure: false),
                      let result = resultByKey[request.translationCacheKey] else { continue }
                let blend = pass.pass.blending
                for vertexName in vertexCandidates {
                    let dedup = "\(ObjectIdentifier(result.library))|\(vertexName ?? result.vertexFunctionName)|\(result.fragmentFunctionName)|\(blend.lowercased())|\(sceneColorFormat.rawValue)"
                    guard seenPipelineKeys.insert(dedup).inserted else { continue }
                    pipelinePrewarms.append(.init(
                        device: prewarmDevice,
                        result: result,
                        vertexName: vertexName,
                        blendMode: blend,
                        colorPixelFormat: sceneColorFormat,
                        depthPixelFormat: .invalid
                    ))
                }
            }
        }
        guard loadGeneration == generation, !pipelinePrewarms.isEmpty else {
            debugStage("pipeline.prewarm.done", "combos=0")
            return
        }
        // Compile the pipeline states in parallel OFF the render thread (mirrors the
        // translation task group above — captures only the `@unchecked Sendable` prewarm
        // requests, never the executor), then seed synchronously before the first frame.
        let pipeWidth = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 1))
        let built: [WPEMetalRenderExecutor.WPEPrewarmedPipeline] = await withTaskGroup(
            of: WPEMetalRenderExecutor.WPEPrewarmedPipeline?.self
        ) { group in
            var next = 0
            func spawn() -> Bool {
                guard next < pipelinePrewarms.count else { return false }
                let prewarm = pipelinePrewarms[next]
                next += 1
                group.addTask(priority: .userInitiated) {
                    WPEMetalRenderExecutor.buildTranslatedPipeline(prewarm)
                }
                return true
            }
            for _ in 0..<pipeWidth where spawn() {}
            var collected: [WPEMetalRenderExecutor.WPEPrewarmedPipeline] = []
            while let entry = await group.next() {
                if loadGeneration != generation {
                    group.cancelAll()
                    break
                }
                if let entry { collected.append(entry) }
                _ = spawn()
            }
            return collected
        }
        guard loadGeneration == generation else { return }
        executor.seedTranslatedPipelines(built)
        debugStage("pipeline.prewarm.done", "combos=\(pipelinePrewarms.count) built=\(built.count)")
    }

    private func loadTextures(for pipeline: WPEPreparedRenderPipeline) async throws {
        loadedTextures = [:]
        dynamicTextureSources = [:]
        resetTextureCacheBudgetState()

        // Collect the unique external textures in pipeline order. Deduping up
        // front (instead of the old per-iteration map check) means concurrent
        // resolves never touch the same path, so the @MainActor texture maps
        // are written exactly once each, on this actor.
        var jobs: [WPETextureLoadJob] = []
        var seen = Set<String>()
        for layer in pipeline.layers {
            let layerName = layer.graphLayer.objectName
            if layer.passes.isEmpty {
                if let path = externalTexturePath(for: .image(layer.graphLayer.imagePath)),
                   seen.insert(path).inserted {
                    jobs.append(WPETextureLoadJob(path: path, layerName: layerName, candidates: textureCandidates(for: path)))
                }
                continue
            }
            for preparedPass in layer.passes {
                for reference in requiredTextureReferences(for: preparedPass) {
                    if let path = externalTexturePath(for: reference),
                       seen.insert(path).inserted {
                        jobs.append(WPETextureLoadJob(path: path, layerName: layerName, candidates: textureCandidates(for: path)))
                    }
                }
            }
        }
        guard !jobs.isEmpty else { return }

        // Snapshot the load generation so a reload/cleanup that resets the maps
        // mid-flight can't get a stale texture written into the new load.
        let generation = loadGeneration
        let resolver = resourceResolver
        let loader = textureLoader
        let threshold = Self.lazyAnimationRawByteThreshold
        // Width bounded like the upload lane: parallelizes the per-texture
        // inflate (the on-main serial cost today) without over-subscribing the
        // upload queue, which keeps its own 1-2 slot admission bound.
        let width = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))

        try await withThrowingTaskGroup(of: (Int, WPEParallelTextureResult).self) { group in
            var nextIndex = 0
            func spawnNext() -> Bool {
                guard nextIndex < jobs.count else { return false }
                let index = nextIndex
                nextIndex += 1
                let job = jobs[index]
                group.addTask(priority: .userInitiated) {
                    do {
                        let result = try await Self.resolveStaticTextureOrDefer(
                            relativePath: job.path,
                            label: "WPE texture \(job.path)",
                            candidates: job.candidates,
                            resolver: resolver,
                            loader: loader,
                            streamingThreshold: threshold
                        )
                        return (index, result)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        throw WPEMetalTextureLoadContextError(layerName: job.layerName, path: job.path, underlying: error)
                    }
                }
                return true
            }

            for _ in 0..<width where spawnNext() {}

            while let (index, result) = try await group.next() {
                try Task.checkCancellation()
                guard loadGeneration == generation else {
                    group.cancelAll()
                    return
                }
                switch result {
                case .staticTexture(let texture):
                    recordLoadedStaticTexture(
                        path: jobs[index].path,
                        layerName: jobs[index].layerName,
                        candidates: jobs[index].candidates,
                        texture: texture
                    )
                case .needsOnActor:
                    // Rare: video / multi-frame animation / heavy-streaming
                    // `.tex`. Their source construction is @MainActor-only, so
                    // route through the untouched serial resolver rather than
                    // duplicating that logic in the parallel lane.
                    try await loadDynamicTextureOnActor(path: jobs[index].path, layerName: jobs[index].layerName)
                }
                _ = spawnNext()
            }
        }
    }

    /// Off-actor: resolve + upload a *static* texture, or report that the
    /// reference needs @MainActor construction. Mirrors the candidate-walk in
    /// `makeTextureResource`; only the static-image / static-payload branches
    /// build here (the upload still flows through the bounded upload queue).
    private nonisolated static func resolveStaticTextureOrDefer(
        relativePath: String,
        label: String,
        candidates: [String],
        resolver: WPEMultiRootResourceResolver,
        loader: WPEMetalTextureLoader,
        streamingThreshold: Int
    ) async throws -> WPEParallelTextureResult {
        var lastError: Error?
        for candidate in candidates {
            do {
                if shouldTryTexturePayload(candidate) {
                    do {
                        if detectHeavyStreaming(candidate, resolver: resolver, threshold: streamingThreshold) {
                            return .needsOnActor
                        }
                        let payload = try resolver.resolveTexturePayload(relativePath: candidate)
                        if payload.videoPayload != nil || payload.animationTrack != nil {
                            return .needsOnActor
                        }
                        return .staticTexture(try await loader.makeTexture(from: payload, label: label))
                    } catch {
                        lastError = error
                    }
                }
                let image = try resolver.resolveImage(relativePath: candidate)
                return .staticTexture(try await loader.makeTexture(from: image, label: label))
            } catch {
                lastError = error
            }
        }
        throw lastError ?? WPEMetalRenderExecutorError.missingTexture(.image(relativePath))
    }

    /// `nonisolated` heavy-`.tex` probe matching `resolveStreamingPayloadIfHeavy`'s
    /// decision (same threshold + probe candidates), minus the opt-in debug
    /// marks. When this returns true the on-actor path re-resolves and builds
    /// the lazy streaming source.
    private nonisolated static func detectHeavyStreaming(
        _ candidate: String,
        resolver: WPEMultiRootResourceResolver,
        threshold: Int
    ) -> Bool {
        let ext = (candidate as NSString).pathExtension.lowercased()
        let probeCandidates: [String]
        if ext == "tex" {
            probeCandidates = [candidate]
        } else if ext.isEmpty {
            let stripped = (candidate as NSString).deletingPathExtension
            probeCandidates = [candidate, "materials/\(stripped).tex"]
        } else {
            return false
        }
        for probe in probeCandidates {
            guard let payload = try? resolver.resolveStreamingTexturePayload(relativePath: probe) else {
                continue
            }
            if payload.totalUncompressedImageBytes > threshold {
                return true
            }
        }
        return false
    }

    /// On-actor build for the dynamic/video/animated/heavy-streaming minority,
    /// reusing the serial `makeTextureResource`. Paths are pre-deduped by the
    /// caller, so no map guard is needed here.
    private func loadDynamicTextureOnActor(path: String, layerName: String) async throws {
        do {
            let resource = try await makeTextureResource(relativePath: path, label: "WPE texture \(path)")
            try Task.checkCancellation()
            switch resource {
            case .staticTexture(let texture):
                recordLoadedStaticTexture(
                    path: path,
                    layerName: layerName,
                    candidates: textureCandidates(for: path),
                    texture: texture
                )
            case .dynamicSource(let source):
                forgetStaticTextureCacheRecord(path)
                dynamicTextureSources[path] = source
                if let texture = source.texture(at: lastRuntimeUniforms?.time ?? 0) {
                    loadedTextures[path] = texture
                } else {
                    loadedTextures[path] = try makeDynamicPlaceholderTexture(label: "\(path) placeholder")
                }
            }
        } catch is CancellationError {
            // Keep cancellation transparent — wrapping it in the load-context
            // error would defeat the session's `catch is CancellationError`.
            throw CancellationError()
        } catch {
            throw WPEMetalTextureLoadContextError(layerName: layerName, path: path, underlying: error)
        }
    }

    private func externalTexturePath(for reference: WPETextureReference) -> String? {
        switch reference {
        case .image(let path), .asset(let path):
            return path
        case .fbo, .previous:
            return nil
        }
    }

    /// Live world placement for a text object. When its ancestors are transform
    /// hosts (null groups) carrying script-driven transforms this frame, the
    /// text's LOCAL origin is re-composed through the live chain — otherwise
    /// (no live overrides, non-host parent, or no local data) the parse-time
    /// world origin stands. Mirrors `applyingLayerTransforms` composition so
    /// panel text tracks its panel background exactly.
    ///
    /// `zRotation` is the chain's composed z angle (radians, author-space CCW):
    /// WPE rotates text with its host (3470764447's 总组件角度 = -15° tilts the
    /// whole clock stack). When the live chain composes, it is the chain's
    /// composed angle; otherwise the parse-time WORLD angle stands — text
    /// objects rotate like image layers, so a static `angles` in scene.json
    /// (2986828130's Clock/Date 30° tilt) must not collapse to 0.
    private func liveTextWorldPlacement(
        _ object: WPESceneTextObject,
        scriptOrigins: [String: SIMD3<Double>],
        scriptScales: [String: SIMD3<Double>],
        scriptAngles: [String: SIMD3<Double>]
    ) -> (origin: SIMD3<Double>, zRotation: Double) {
        // The text's OWN dynamic origin (a tooltip label tracking its star via
        // `shared.xxN`) is the live LOCAL origin — it takes precedence over the
        // parse-time local origin and is then composed through any live parent
        // chain (its 521-parent is identity, so it lands at the world position).
        let ownLiveOrigin = scriptOrigins[object.id]
        guard let parentID = object.parentObjectID,
              let localOrigin = ownLiveOrigin ?? object.localOrigin,
              !(scriptOrigins.isEmpty && scriptScales.isEmpty && scriptAngles.isEmpty) else {
            return (ownLiveOrigin ?? object.origin, object.angles.z)
        }
        var chain: [WPERenderObjectTransform] = []
        var cursor: String? = parentID
        var visited: Set<String> = []
        var chainIsLive = ownLiveOrigin != nil
        while let id = cursor, !visited.contains(id), visited.count < 100 {
            visited.insert(id)
            guard let hostLocal = transformHostLocalTransformsByID[id] else {
                // Non-host ancestor (image layer): its motion isn't composable
                // here — keep the parse-time origin rather than half-compose.
                return (ownLiveOrigin ?? object.origin, object.angles.z)
            }
            if scriptOrigins[id] != nil || scriptScales[id] != nil || scriptAngles[id] != nil {
                chainIsLive = true
            }
            chain.append(hostLocal.applying(
                origin: scriptOrigins[id],
                scale: scriptScales[id],
                angles: scriptAngles[id]
            ))
            cursor = objectParentByID[id]
        }
        guard chainIsLive, !chain.isEmpty else {
            return (ownLiveOrigin ?? object.origin, object.angles.z)
        }
        var world = WPERenderObjectTransform(
            origin: localOrigin,
            scale: SIMD3<Double>(1, 1, 1),
            angles: SIMD3<Double>(0, 0, 0)
        )
        for parent in chain {
            world = parent.combining(child: world)
        }
        return (world.origin, world.angles.z)
    }

    private func requiredTextureReferences(for pass: WPEPreparedRenderPass) -> [WPETextureReference] {
        switch WPEBuiltinShaderKind(normalizing: pass.pass.shader) {
        case .solidColor?, .solidLayer?:
            return []

        case .compose?:
            let first = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
            let second = pass.textureBindings[1] ?? pass.pass.textures[1] ?? first
            return [first, second].filter(\.isExternalTextureReference)

        case .genericImage4?:
            let primary = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
            var refs: [WPETextureReference] = [primary]
            if let mask = pass.textureBindings[1] ?? pass.pass.textures[1] {
                refs.append(mask)
            }
            // generic4 MODEL materials carry the PBR component map (emissive
            // mask) in slot 2 — the scene-model fragment samples it.
            if let componentMap = pass.textureBindings[2] ?? pass.pass.textures[2] {
                refs.append(componentMap)
            }
            return refs.filter(\.isExternalTextureReference)

        default:
            let reference = pass.pass.binds[0]
                ?? pass.textureBindings[0]
                ?? pass.pass.textures[0]
                ?? pass.pass.source
            var refs: [WPETextureReference] = [reference]
            for slot in 1..<4 {
                if let extra = pass.pass.binds[slot] ?? pass.textureBindings[slot] ?? pass.pass.textures[slot] {
                    refs.append(extra)
                }
            }
            return refs.filter(\.isExternalTextureReference)
        }
    }


    /// Phase 2E rewrite: returns a `WPELoadedTextureResource` instead of a raw texture so the caller can route MP4 video and multi-frame animations through dedicated dynamic sources.
    private func makeTextureResource(
        relativePath: String,
        label: String,
        colorSpace: WPEMetalColorSpace = .sRGB
    ) async throws -> WPELoadedTextureResource {
        var lastError: Error?
        for candidate in textureCandidates(for: relativePath) {
            do {
                if shouldTryTexturePayload(candidate) {
                    do {
                        if let streaming = try resolveStreamingPayloadIfHeavy(candidate) {
                            let source = try textureLoader.makeLazyAnimatedTextureSource(
                                from: streaming,
                                label: label
                            )
                            Logger.info(
                                "WPE Metal lazy .tex animation '\(candidate)' raw=\(streaming.totalUncompressedImageBytes)B frames=\(streaming.frames.count)",
                                category: .screenManager
                            )
                            return .dynamicSource(source)
                        }

                        let payload = try resourceResolver.resolveTexturePayload(relativePath: candidate)

                        if payload.videoPayload != nil {
                            let source = try await makeVideoTextureSource(from: payload, label: label)
                            return .dynamicSource(source)
                        }
                        if payload.animationTrack != nil {
                            let source = try await textureLoader.makeAnimatedTextureSource(
                                from: payload,
                                label: label
                            )
                            return .dynamicSource(source)
                        }

                        return .staticTexture(try await textureLoader.makeTexture(from: payload, label: label, colorSpace: colorSpace))
                    } catch {
                        lastError = error
                    }
                }
                let image = try resourceResolver.resolveImage(relativePath: candidate)
                return .staticTexture(try await textureLoader.makeTexture(from: image, label: label, colorSpace: colorSpace))
            } catch {
                lastError = error
            }
        }
        throw lastError ?? WPEMetalRenderExecutorError.missingTexture(.image(relativePath))
    }

    /// Returns a streaming payload only when the source is a `.tex` whose
    /// total raw image footprint clears the lazy threshold. Anything
    /// smaller falls through to the eager path so single-frame textures
    /// and tiny sprite-sheets don't pay the per-frame decompression cost.
    /// Accepts both `.tex`-suffixed candidates and bare names (probes
    /// `<bare>` and `materials/<bare>.tex` in the same order the eager
    /// path uses).
    private func resolveStreamingPayloadIfHeavy(_ candidate: String) throws -> WPETexStreamingPayload? {
        let probeCandidates: [String]
        let ext = (candidate as NSString).pathExtension.lowercased()
        if ext == "tex" {
            probeCandidates = [candidate]
        } else if ext.isEmpty {
            let stripped = (candidate as NSString).deletingPathExtension
            probeCandidates = [candidate, "materials/\(stripped).tex"]
        } else {
            return nil
        }

        for probe in probeCandidates {
            let payload: WPETexStreamingPayload
            do {
                payload = try resourceResolver.resolveStreamingTexturePayload(relativePath: probe)
            } catch let SceneResourceResolver.ResolveError.texture(decodeError) {
                switch decodeError {
                case .unsupportedAnimation, .unsupportedFormat:
                    debugStage(
                        "tex.lazy.skip",
                        "probe=\(probe) reason=\(decodeError)"
                    )
                    continue
                default:
                    debugStage(
                        "tex.lazy.skip",
                        "probe=\(probe) decodeError=\(decodeError)"
                    )
                    continue
                }
            } catch SceneResourceResolver.ResolveError.fileMissing,
                    SceneResourceResolver.ResolveError.unsupportedTexture {
                continue
            } catch {
                debugStage(
                    "tex.lazy.skip",
                    "probe=\(probe) error=\(error)"
                )
                continue
            }
            if payload.totalUncompressedImageBytes <= Self.lazyAnimationRawByteThreshold {
                debugStage(
                    "tex.lazy.skip",
                    "probe=\(probe) raw=\(payload.totalUncompressedImageBytes)B below threshold"
                )
                continue
            }
            debugStage(
                "tex.lazy.hit",
                "probe=\(probe) raw=\(payload.totalUncompressedImageBytes)B images=\(payload.compressedImages.count) frames=\(payload.frames.count)"
            )
            return payload
        }
        return nil
    }

    /// Phase 2E: stages MP4 bytes into the per-process video cache and constructs a `WPEVideoTextureSource` bound to the executor's MTLDevice.
    private func makeVideoTextureSource(
        from payload: WPETexTexturePayload,
        label: String
    ) async throws -> WPEVideoTextureSource {
        guard let videoPayload = payload.videoPayload else {
            throw WPEMetalTextureLoaderError.malformedPayload("missing video payload")
        }
        // Stage into the per-scene disk cache keyed by workshop ID + content
        // hash, so repeated extractions dedup and launch GC can reclaim videos
        // for scenes that are no longer installed.
        let url = try await WPEVideoTextureDiskCache.shared.store(
            videoPayload.bytes,
            workshopID: descriptor.workshopID
        )
        do {
            let source = try WPEVideoTextureSource(
                device: executor.textureSourceDevice,
                videoURL: url,
                // Release the lease (keep the file for reuse) rather than
                // deleting — the cache owns its lifetime now.
                onInvalidate: { staleURL in
                    Task.detached(priority: .utility) {
                        await WPEVideoTextureDiskCache.shared.release(staleURL)
                    }
                }
            )
            _ = label
            return source
        } catch {
            await WPEVideoTextureDiskCache.shared.release(url)
            throw error
        }
    }

    /// Phase 2E: returns a 1×1 transparent texture used as a temporary stand-in for dynamic sources whose first frame has not yet decoded.
    private func makeDynamicPlaceholderTexture(label: String) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: WPEMetalRenderExecutor.outputPixelFormat,
            width: 1,
            height: 1,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = executor.textureSourceDevice.makeTexture(descriptor: descriptor) else {
            throw WPEMetalTextureLoaderError.textureAllocationFailed
        }
        texture.label = label
        WPEMetalTextureMetadataRegistry.shared.register(texture: texture)
        var pixel: UInt32 = 0
        texture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0,
            withBytes: &pixel,
            bytesPerRow: 4
        )
        return texture
    }

    private func recordLoadedStaticTexture(
        path: String,
        layerName: String,
        candidates: [String],
        texture: MTLTexture
    ) {
        loadedTextures[path] = texture
        staticTexturePlaceholderPaths.remove(path)
        staticTextureReloadThrottles.removeValue(forKey: path)
        let bytes = Self.textureResidentBytes(for: texture)
        staticTextureCacheRecords[path] = StaticTextureCacheRecord(
            layerName: layerName,
            candidates: candidates,
            bytes: bytes
        )
        staticTextureRecordsEpoch += 1
        if textureCacheBudgetBytesInUse != nil {
            textureCacheLRU.admit(path, bytes: bytes)
        }
    }

    private func forgetStaticTextureCacheRecord(_ path: String) {
        staticTextureCacheRecords.removeValue(forKey: path)
        staticTexturePlaceholderPaths.remove(path)
        pendingStaticTextureReloads.remove(path)
        staticTextureReloadThrottles.removeValue(forKey: path)
        staticTextureRecordsEpoch += 1
        textureCacheLRU.remove(path)
    }

    private func resetTextureCacheBudgetState() {
        staticTextureCacheRecords.removeAll(keepingCapacity: false)
        staticTexturePlaceholderPaths.removeAll(keepingCapacity: false)
        pendingStaticTextureReloads.removeAll(keepingCapacity: false)
        staticTextureReloadThrottles.removeAll(keepingCapacity: false)
        cachedActiveStaticPaths.removeAll(keepingCapacity: false)
        cachedActiveStaticSignature = nil
        staticTextureRecordsEpoch += 1
        textureCacheLRU.removeAll()
        textureCacheBudgetBytesInUse = nil
    }

    private func activateTextureCacheBudget(_ budgetBytes: Int) {
        guard textureCacheBudgetBytesInUse != budgetBytes else { return }
        textureCacheLRU = WPEMetalTextureCacheLRU(budgetBytes: budgetBytes)
        textureCacheBudgetBytesInUse = budgetBytes
        for (path, record) in staticTextureCacheRecords
        where loadedTextures[path] != nil && !staticTexturePlaceholderPaths.contains(path) {
            textureCacheLRU.admit(path, bytes: record.bytes)
        }
    }

    private func deactivateTextureCacheBudget() {
        guard textureCacheBudgetBytesInUse != nil else { return }
        textureCacheBudgetBytesInUse = nil
        textureCacheLRU.removeAll()
        // Budget turned off mid-session: reload anything previously evicted so the
        // eager-resident invariant holds again.
        for path in staticTextureCacheRecords.keys where loadedTextures[path] == nil {
            scheduleStaticTextureReload(for: path)
        }
    }

    /// External texture paths the upcoming frame actually samples, restricted to
    /// reloadable static ones (the only eviction candidates). Memoized on a
    /// cheap O(layers) signature — the full layers × passes × refs walk only
    /// reruns when visibility/shape or the record set actually changed.
    private func activeStaticTexturePaths(for pipeline: WPEPreparedRenderPipeline) -> Set<String> {
        var hasher = Hasher()
        hasher.combine(loadGeneration)
        hasher.combine(staticTextureRecordsEpoch)
        hasher.combine(pipeline.layers.count)
        for layer in pipeline.layers {
            hasher.combine(layer.graphLayer.objectID)
            hasher.combine(layer.graphLayer.visible)
            hasher.combine(layer.passes.count)
        }
        let signature = hasher.finalize()
        if signature == cachedActiveStaticSignature {
            return cachedActiveStaticPaths
        }
        let paths = activeExternalTexturePaths(for: pipeline).filter { staticTextureCacheRecords[$0] != nil }
        cachedActiveStaticPaths = paths
        cachedActiveStaticSignature = signature
        return paths
    }

    private func activeExternalTexturePaths(for pipeline: WPEPreparedRenderPipeline) -> Set<String> {
        var paths = Set<String>()
        for layer in pipeline.layers {
            // A plain image layer with no passes is still drawn (encodeCopy) when
            // visible, so its image texture is sampled and must stay protected.
            if layer.passes.isEmpty {
                if layer.graphLayer.visible,
                   let path = externalTexturePath(for: .image(layer.graphLayer.imagePath)) {
                    paths.insert(path)
                }
                continue
            }
            for pass in layer.passes {
                // Hidden layers still encode composite/FBO passes (dependents may
                // sample them); only their scene draw is skipped — mirror that here.
                if !layer.graphLayer.visible {
                    switch pass.pass.target {
                    case .scene:
                        continue
                    case .layerComposite, .fbo:
                        break
                    }
                }
                for reference in requiredTextureReferences(for: pass) {
                    if let path = externalTexturePath(for: reference) {
                        paths.insert(path)
                    }
                }
            }
        }
        return paths
    }

    /// Guarantee every active static path has at least a placeholder this frame
    /// (so an evicted texture never renders as a missing/black draw) and queue a
    /// reload for any that are missing or placeholder-only.
    private func ensureActiveStaticTexturesResident(_ activePaths: Set<String>) throws {
        for path in activePaths {
            if loadedTextures[path] == nil {
                loadedTextures[path] = try makeDynamicPlaceholderTexture(label: "\(path) static placeholder")
                staticTexturePlaceholderPaths.insert(path)
            }
            if staticTexturePlaceholderPaths.contains(path) {
                scheduleStaticTextureReload(for: path)
            }
        }
    }

    private func touchStaticTextureCache(paths: Set<String>) {
        for path in paths {
            textureCacheLRU.touch(path)
        }
    }

    private func evictInactiveStaticTextures(protecting protected: Set<String>) {
        let evicted = textureCacheLRU.evictOverBudget(protecting: protected)
        for path in evicted {
            loadedTextures.removeValue(forKey: path)
            staticTexturePlaceholderPaths.remove(path)
            Logger.info("[WPE.texture-cache] evicted static texture path=\(path)", category: .wpeRender)
        }
    }

    /// Reload an evicted static texture off the main thread, then republish on the
    /// main actor under a `loadGeneration` guard so a reload from a prior scene is
    /// ignored. Triggers a redraw so the placeholder is replaced once resident.
    /// Failed attempts back off per path (`WPEStaticTextureReloadThrottle`).
    private func scheduleStaticTextureReload(for path: String) {
        guard let record = staticTextureCacheRecords[path],
              staticTextureReloadThrottles[path, default: .init()]
                  .allowsAttempt(at: ProcessInfo.processInfo.systemUptime),
              pendingStaticTextureReloads.insert(path).inserted else { return }
        let generation = loadGeneration
        let resolver = resourceResolver
        let loader = textureLoader
        let threshold = Self.lazyAnimationRawByteThreshold
        Task(priority: .utility) { @MainActor [weak self] in
            let result = try? await Self.resolveStaticTextureOrDefer(
                relativePath: path,
                label: "WPE texture \(path)",
                candidates: record.candidates,
                resolver: resolver,
                loader: loader,
                streamingThreshold: threshold
            )
            guard let self, self.loadGeneration == generation else { return }
            self.pendingStaticTextureReloads.remove(path)
            switch result {
            case .staticTexture(let texture):
                self.recordLoadedStaticTexture(
                    path: path,
                    layerName: record.layerName,
                    candidates: record.candidates,
                    texture: texture
                )
            case .needsOnActor:
                do {
                    try await self.loadDynamicTextureOnActor(path: path, layerName: record.layerName)
                } catch {
                    self.noteStaticTextureReloadFailure(path)
                    return
                }
            case .none:
                self.noteStaticTextureReloadFailure(path)
                return
            }
            self.mtkView.setNeedsDisplay(self.mtkView.bounds)
        }
    }

    private func noteStaticTextureReloadFailure(_ path: String) {
        var throttle = staticTextureReloadThrottles[path, default: .init()]
        throttle.recordFailure(at: ProcessInfo.processInfo.systemUptime)
        staticTextureReloadThrottles[path] = throttle
        if throttle.isExhausted {
            Logger.warning("[WPE.texture-cache] reload giving up after \(throttle.failureCount) failures path=\(path)", category: .wpeRender)
        } else {
            Logger.warning("[WPE.texture-cache] reload failed (attempt \(throttle.failureCount)) path=\(path)", category: .wpeRender)
        }
    }

    static func textureResidentBytes(for texture: MTLTexture) -> Int {
        // BC formats are block-compressed in VRAM (the texture loader uploads them
        // compressed); per-pixel math would 4-6x over-count the budget.
        let baseBytes: Int
        switch texture.pixelFormat {
        case .bc1_rgba, .bc1_rgba_srgb:
            baseBytes = compressedTextureBytes(width: texture.width, height: texture.height, bytesPerBlock: 8)
        case .bc2_rgba, .bc2_rgba_srgb, .bc3_rgba, .bc3_rgba_srgb,
             .bc7_rgbaUnorm, .bc7_rgbaUnorm_srgb:
            baseBytes = compressedTextureBytes(width: texture.width, height: texture.height, bytesPerBlock: 16)
        default:
            baseBytes = texture.width * texture.height * textureCacheBytesPerPixel(for: texture.pixelFormat)
        }
        // No loader path generates mips today; the 4/3 mip-chain bound keeps the
        // estimate honest if one ever does.
        return texture.mipmapLevelCount > 1 ? baseBytes * 4 / 3 : baseBytes
    }

    private static func compressedTextureBytes(width: Int, height: Int, bytesPerBlock: Int) -> Int {
        max((width + 3) / 4, 1) * max((height + 3) / 4, 1) * bytesPerBlock
    }

    private static func textureCacheBytesPerPixel(for pixelFormat: MTLPixelFormat) -> Int {
        switch pixelFormat {
        case .rgba16Float: return 8
        case .rg8Unorm: return 2
        case .r8Unorm: return 1
        default: return 4
        }
    }

    /// Phase 2E: pulls fresh `MTLTexture`s from dynamic sources and enforces the
    /// optional static-texture VRAM budget before every render call.
    private func texturesForCurrentFrame(time: TimeInterval, pipeline: WPEPreparedRenderPipeline) throws -> [String: MTLTexture] {
        for (path, source) in dynamicTextureSources {
            if let texture = source.texture(at: time) {
                loadedTextures[path] = texture
            }
        }

        // Zero overhead on the unbounded (budget off, nothing evicted) path:
        // only walk active paths when the budget is/was active or a placeholder
        // still awaits reload.
        if textureCacheBudgetBytesResolved != nil
            || textureCacheBudgetBytesInUse != nil
            || !staticTexturePlaceholderPaths.isEmpty {
            let activeStaticPaths = activeStaticTexturePaths(for: pipeline)
            try ensureActiveStaticTexturesResident(activeStaticPaths)
            if let budgetBytes = textureCacheBudgetBytesResolved {
                activateTextureCacheBudget(budgetBytes)
                touchStaticTextureCache(paths: activeStaticPaths)
                evictInactiveStaticTextures(protecting: activeStaticPaths)
            } else {
                deactivateTextureCacheBudget()
            }
        }
        return loadedTextures
    }

    private func releaseDynamicTextureSources() {
        dynamicTextureSources.values.forEach { $0.invalidate() }
        dynamicTextureSources.removeAll()
        loadedTextures.removeAll()
        resetTextureCacheBudgetState()
    }

    private func shouldTryTexturePayload(_ path: String) -> Bool {
        Self.shouldTryTexturePayload(path)
    }

    /// `nonisolated` twin so the off-actor parallel-resolve lane can make the
    /// same `.tex`-vs-raster decision the on-actor path uses.
    private nonisolated static func shouldTryTexturePayload(_ path: String) -> Bool {
        let extensionName = (path as NSString).pathExtension.lowercased()
        return !knownRawImageExtensions.contains(extensionName)
    }

    /// Raster image extensions that `WPETextureLoader` can load via ImageIO
    /// without going through the `.tex` container. Path lookups ending in one
    /// of these are taken at face value; anything else (including names that
    /// merely *look* like they end in an extension because they contain a dot)
    /// goes through the materials/-prefix fallback below.
    nonisolated static let knownRawImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "tga", "dds", "bmp", "gif", "webp"
    ]

    /// Visible to `@testable` test suites that probe the candidate generator without spinning up a full renderer fixture.
    func textureCandidates(for path: String) -> [String] {
        let extensionName = (path as NSString).pathExtension.lowercased()
        if extensionName == "tex" || extensionName == "json" {
            return [path]
        }
        if !extensionName.isEmpty, Self.knownRawImageExtensions.contains(extensionName) {
            // WPE converts source images to `<name>.<ext>.tex` (e.g. a particle
            // sprite `workshop/…/雪花.jpg` is stored as
            // `materials/workshop/…/雪花.jpg.tex`). Try the literal image, then
            // the converted `.tex`, including under the `materials/` root —
            // otherwise extension-bearing refs never find their `.tex`.
            var candidates = [path, "\(path).tex"]
            let anchored = ["materials/", "models/", "shaders/", "fonts/",
                            "scripts/", "particles/", "sounds/", "scenes/", "../", "_"]
            if !anchored.contains(where: path.hasPrefix) {
                candidates.append("materials/\(path)")
                candidates.append("materials/\(path).tex")
            }
            return candidates
        }

        if let dependency = dependencyReference(path) {
            let child = dependency.childPath
            if child.contains("/") {
                return [
                    path,
                    "\(path).tex",
                    "\(path).png",
                    "\(path).jpg",
                    "\(path).jpeg"
                ]
            }
            let prefix = "../\(dependency.workshopID)"
            return [
                "\(prefix)/materials/\(child).tex",
                "\(prefix)/materials/\(child).png",
                "\(prefix)/materials/\(child).jpg",
                "\(prefix)/materials/\(child).jpeg",
                path
            ]
        }

        if path.hasPrefix("_"), !path.hasPrefix("__") {
            return [path]
        }

        if path.contains("/") {
            let anchoredPrefixes = ["materials/", "models/", "shaders/", "fonts/", "scripts/", "particles/", "sounds/", "scenes/"]
            if anchoredPrefixes.contains(where: path.hasPrefix) {
                return [
                    path,
                    "\(path).tex",
                    "\(path).png",
                    "\(path).jpg",
                    "\(path).jpeg"
                ]
            }
            return [
                "materials/\(path).tex",
                "materials/\(path).png",
                "materials/\(path).jpg",
                "materials/\(path).jpeg",
                path,
                "\(path).tex",
                "\(path).png",
                "\(path).jpg",
                "\(path).jpeg"
            ]
        }

        return [
            "materials/\(path).tex",
            "materials/\(path).png",
            "materials/\(path).jpg",
            "materials/\(path).jpeg",
            path
        ]
    }

    private func dependencyReference(_ relativePath: String) -> (workshopID: String, childPath: String)? {
        guard relativePath.hasPrefix("../") else { return nil }
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] == ".." else { return nil }
        return (String(parts[1]), parts.dropFirst(2).joined(separator: "/"))
    }

    /// Maps any error raised during `performLoad()` onto the shared `SceneLoadDiagnostic` taxonomy so the UI gets one consistent failure-reporting path.
    private func diagnostic(for error: Error) -> SceneLoadDiagnostic {
        diagnostic(for: error, fallbackPath: nil, layerName: "scene")
    }

    private func diagnostic(
        for error: Error,
        fallbackPath: String?,
        layerName: String
    ) -> SceneLoadDiagnostic {
        switch error {
        case let context as WPEMetalTextureLoadContextError:
            return diagnostic(
                for: context.underlying,
                fallbackPath: context.path,
                layerName: context.layerName
            )
        case let executorError as WPEMetalRenderExecutorError:
            switch executorError {
            case .unsupportedShader(let name):
                return .materialUnresolved(layer: layerName, reason: "Shader \"\(name)\" is not supported by the Metal renderer yet.")
            case .shaderTranslatorUnavailable(let name, let reason):
                return .materialUnresolved(
                    layer: layerName,
                    reason: "Shader \"\(name)\" needs the WPE GLSL translator: \(reason)"
                )
            case .pipelineStateBuildFailed(let name, let detail):
                return .materialUnresolved(
                    layer: layerName,
                    reason: "Metal pipeline for \"\(name)\" failed to build: \(detail)"
                )
            case .unsupportedTarget:
                return .materialUnresolved(layer: layerName, reason: "This wallpaper uses an unsupported rendering target.")
            case .renderTargetDimensionsExceedDeviceLimit(let targetName, let width, let height, let limit):
                return .materialUnresolved(
                    layer: layerName,
                    reason: "Render target \"\(targetName)\" is \(width)x\(height), exceeding this device's \(limit)x\(limit) Metal texture limit."
                )
            case .missingTexture(let reference):
                switch reference {
                case .image(let path), .asset(let path), .fbo(let path):
                    return .fileMissing(layer: layerName, path: path)
                case .previous:
                    return .materialUnresolved(layer: layerName, reason: "Previous-frame effects (motion blur, feedback) are not yet supported.")
                }
            case .noRenderablePasses:
                return .materialUnresolved(layer: layerName, reason: "Scene contains no renderable passes.")
            case .commandQueueUnavailable, .libraryUnavailable, .pipelineUnavailable, .commandBufferFailed:
                return .other(layer: layerName, message: executorError.errorDescription ?? "Metal renderer failed.")
            }
        case let loaderError as WPEMetalTextureLoaderError:
            switch loaderError {
            case .unsupportedFormat, .unsupportedCompressedFormat, .malformedPayload, .textureAllocationFailed:
                return .other(layer: layerName, message: loaderError.errorDescription ?? "Texture upload failed.")
            }
        case let resolveError as SceneResourceResolver.ResolveError:
            switch resolveError {
            case .fileMissing:
                return .fileMissing(layer: layerName, path: fallbackPath ?? descriptor.entryFile)
            case .pathEscape:
                return .crossPackageReference(layer: layerName, path: fallbackPath ?? descriptor.entryFile)
            case .materialUnresolved(let reason):
                return .materialUnresolved(layer: layerName, reason: reason)
            case .texture(let texError):
                return .texture(layer: layerName, error: texError)
            case .unsupportedTexture:
                return .legacyUnsupportedTexture(layer: layerName)
            case .decodeFailed:
                return .other(
                    layer: layerName,
                    message: String(
                        localized: "A texture or image file is corrupted and cannot be decoded.",
                        defaultValue: "A texture or image file is corrupted and cannot be decoded.",
                        comment: "Wallpaper Engine fallback diagnostic when a texture decode fails because the file is corrupt."
                    )
                )
            }
        default:
            return .other(layer: layerName, message: error.localizedDescription)
        }
    }
}

/// Phase 2C: filters out FBO/previous references at the texture-discovery
/// layer so the renderer never tries to load an in-graph FBO from disk.
/// Those references resolve at executor time via the frame state.
private extension WPETextureReference {
    var isExternalTextureReference: Bool {
        switch self {
        case .image, .asset:
            return true
        case .fbo, .previous:
            return false
        }
    }
}
#endif
