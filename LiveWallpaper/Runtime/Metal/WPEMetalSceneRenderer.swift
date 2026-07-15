#if !LITE_BUILD
import AppKit
import MetalKit

/// Wraps a texture-load failure with the requested asset path AND the WPE
/// object/layer name that referenced it so the H1 diagnostic mapper can
/// blame the exact file and surface the failing layer instead of falling
/// back to the scene entry point.
struct WPEMetalTextureLoadContextError: Error {
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
    static let lazyAnimationRawByteThreshold = WPEMemoryTier.current.lazyAnimationRawByteThreshold

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
    static var particlePrewarmEnabled: Bool {
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
    static var introPhaseAlignEnabled: Bool {
        UserDefaults.standard.object(forKey: "WPEMetalIntroPhaseAlignEnabled") as? Bool ?? true
    }

    /// ADR-003 step 1 kill-switch: async latest-snapshot script ticks (the frame
    /// path never waits on a script engine queue). Frozen at first use; default
    /// ON. `defaults write <bundle> WPEScriptAsyncTickEnabled -bool NO` restores
    /// the legacy bounded-blocking ticks on the next launch.
    static let scriptAsyncTickEnabled: Bool = resolvedScriptAsyncTickEnabled(
        manualValue: UserDefaults.standard.object(forKey: "WPEScriptAsyncTickEnabled")
    )

    nonisolated static func resolvedScriptAsyncTickEnabled(manualValue: Any?) -> Bool {
        manualValue as? Bool ?? true
    }

    let descriptor: SceneDescriptor
    let cacheRootURL: URL
    let dependencyMounts: [WPEAssetMount]
    /// Resolved Wallpaper Engine install root (the directory that contains
    /// `assets/`). Captured at init for graph + pipeline builder use; the
    /// security scope is owned here for the lifetime of the renderer.
    private let engineAssetsRootURL: URL?
    /// `engineAssetsRootURL` gated by access: nil when an external (non-container)
    /// root's security scope failed to open, else the usable root. Graph/pipeline
    /// builders must use THIS, not the raw root, so a scope-denied manual link
    /// never feeds the resolver.
    let effectiveEngineAssetsRootURL: URL?
    /// `(unsafe)` because `deinit` is non-isolated and needs to clear the
    /// reference + drop the scope. All other writes happen on `@MainActor`
    /// (`cleanup()`), so observed mutation is single-threaded.
    nonisolated(unsafe) var activeEngineAssetsRootURL: URL?
    let entryResolver: SceneResourceResolver
    let resourceResolver: WPEMultiRootResourceResolver
    /// Non-nil for package-/source-backed scenes — threaded into the graph and
    /// pipeline builders so they resolve from the same in-place source. `nil`
    /// keeps the legacy directory-backed (cache root URL) construction.
    let sceneAssetProvider: (any WPESceneAssetProvider)?
    /// Root holding `project.json` for the property schema. For package-/source-
    /// backed scenes this is the source folder (zero-cache — nothing extracted);
    /// `nil` falls back to `cacheRootURL` (legacy extracted cache).
    let projectManifestRootURL: URL?
    let resolutionTracer: WPEResolutionTracer
    let mtkView: WPEInteractiveMTKView
    let executor: WPEMetalRenderExecutor
    let textureLoader: WPEMetalTextureLoader
    var outputTexture: MTLTexture?
    /// How the final scene texture is fitted onto the screen drawable. Defaults
    /// to `.cover` (crop-to-fill), matching the persisted `fitMode` default, so
    /// non-16:9 displays don't distort the scene. Pushed in from the session.
    var presentFitMode: WPEPresentFitMode = .cover
    /// Phase 2D-L: alive particle systems and the per-system sprite
    /// texture. Built on load from the scene's `particleObjects`; ticked
    /// + drawn each frame.
    var particleSystems: [WPEParticleSystem] = []
    var particleTextures: [ObjectIdentifier: MTLTexture] = [:]
    /// Refraction normal map (`g_Texture1`) for REFRACT particle systems, keyed
    /// like `particleTextures`. Absent ⇒ the system renders as a flat sprite.
    var particleNormalTextures: [ObjectIdentifier: MTLTexture] = [:]
    /// Phase 2D-N: text overlay draws assembled at load time. Each
    /// frame re-rasterizes via the cached WPETextRenderer (cache hits
    /// the common case) and draws atop the scene output.
    var textRenderer: WPETextRenderer?
    /// GPU MSDF text renderer (Milestone D). Built only when the engine's
    /// `font.frag` resolves; nil → text falls back to the CoreText overlay.
    var msdfTextRenderer: WPEMSDFTextRenderer?
    /// Suppresses repeat `drawMSDFText` failure logs within a failure streak
    /// (mirrors `didLogFrameFailure`) — a persistently-failing MSDF combo
    /// falls back to CoreText every frame and must not flood the log.
    var didLogMSDFTextDrawFailure = false
    var textObjects: [WPESceneTextObject] = []
    /// Phase 2D-O: audio runtime publishing live FFT bins into the
    /// runtime uniform that audio-reactive shaders sample. Optional —
    /// scenes without sound objects skip this entirely.
    var soundRuntime: WPESoundRuntime?
    /// `WPEAudioDebugLog -bool YES` → throttled per-second log of what the
    /// renderer actually sees on the shared audio broker, to diagnose
    /// audio-reactive scenes that don't move.
    let audioDebugLogEnabled = UserDefaults.standard.bool(forKey: "WPEAudioDebugLog")
    var audioDiagCounter = 0
    /// Phase 2D-P: per-text-object SceneScript instances. Keyed by
    /// the text object's id so the renderer can look up the latest
    /// scripted value when rasterizing.
    var textScriptInstances: [String: WPESceneScriptInstance] = [:]
    /// Layer (image-object) SceneScripts keyed by objectID — visible-scripts that
    /// drive a layer's visibility/alpha and its video texture (e.g. an intro that
    /// plays once then hides). Empty for the common no-layer-script scene.
    var layerScriptInstances: [String: WPELayerScriptInstance] = [:] {
        didSet { cachedInstalledScriptLayerIDs = nil }
    }
    /// TEXT objects' own visible/alpha SceneScripts (3509243656's login-intro
    /// texts fade themselves out) — same machinery as image layer scripts, but
    /// outputs land in `liveTextVisibility`/`liveTextAlpha` for the text loop.
    var textVisibleScriptInstances: [String: WPELayerScriptInstance] = [:]
    var textAlphaScriptInstances: [String: WPELayerScriptInstance] = [:]
    var liveTextAlpha: [String: Double] = [:]
    /// Current hover state per scripted layer (cursorEnter/Leave transitions).
    var layerHoverStates: [String: Bool] = [:]
    var sceneScriptSharedState: WPESharedScriptState?
    /// Image-object alpha field scripts keyed by objectID. These return an alpha
    /// scalar from `update(value)` and intentionally do not affect visibility.
    var layerAlphaScriptInstances: [String: WPELayerScriptInstance] = [:] {
        didSet { cachedInstalledScriptLayerIDs = nil }
    }
    /// Image-object origin SceneScripts keyed by objectID. These are dynamic
    /// transform scripts, e.g. cursor-follow flowers that assign
    /// `origin = input.cursorWorldPosition` every frame.
    var dynamicOriginScriptInstances: [String: WPEDynamicTransformScriptInstance] = [:] {
        didSet { cachedInstalledScriptLayerIDs = nil }
    }
    /// Keyframed object `origin` tracks, keyed by objectID. Same live-transform
    /// map as the origin SCRIPTS above, so the existing parent→child composition
    /// carries a moving group onto its children (3448877775's meteor emitter is a
    /// bare transform host whose sweep is what gates its shooting stars).
    var dynamicOriginAnimations: [String: WPESceneAnimatedValue] = [:]
    /// Image-object scale SceneScripts keyed by objectID. Used by scenes that
    /// drive body sizes or link lengths from shared simulation state.
    var dynamicScaleScriptInstances: [String: WPEDynamicTransformScriptInstance] = [:] {
        didSet { cachedInstalledScriptLayerIDs = nil }
    }
    /// Image-object angles SceneScripts keyed by objectID. Used by camera/control
    /// rigs such as drag-to-rotate scene roots.
    var dynamicAnglesScriptInstances: [String: WPEDynamicTransformScriptInstance] = [:] {
        didSet { cachedInstalledScriptLayerIDs = nil }
    }
    /// Memoized load-scoped part of `staticCacheExcludedLayerIDs` (the five
    /// installed-script key sets above). Cleared via `didSet` on EVERY mutation
    /// of those dictionaries, so no install/teardown path can leave it stale.
    var cachedInstalledScriptLayerIDs: Set<String>?
    /// Non-rendered transform hosts keyed by objectID. These are WPE `solid`
    /// groups that move/render no pixels themselves but compose into child layers.
    var transformHostLocalTransformsByID: [String: WPERenderObjectTransform] = [:]
    /// objectID → the `dynamicTextureSources` key of the layer's video source, so
    /// a layer script's `getVideoTexture()` commands reach the right player.
    /// Populated for ALL video-backed layers (a button script drives a different
    /// layer's video via `thisScene.getLayer(name)`), not just scripted ones.
    var layerVideoSourceKey: [String: String] = [:]
    /// Layer name → objectID, so a script's `thisScene.getLayer(name)` output can
    /// be resolved to the target layer.
    var layerObjectIDByName: [String: String] = [:]
    /// objectID → texture key for scene-output-only video layers (never a hidden
    /// composite source), kept resident only while visible. Each
    /// `WPEVideoTextureSource` holds its whole MP4 + decode buffers (~300 MB per 4K
    /// source), so a multi-video scene that shows one at a time otherwise pays for
    /// all of them. `reconcileVideoResidency` flips residency per frame.
    var onDemandVideoKeyByID: [String: String] = [:]
    /// Texture keys whose rebuild is in flight, so a layer staying visible across
    /// frames doesn't spawn a duplicate Task while the first resolves.
    var onDemandVideoLoading: Set<String> = []
    /// Live per-layer alpha overrides driven by layer scripts (objectID → alpha).
    var liveLayerAlpha: [String: Double] = [:]
    /// Runtime-created image layers keyed by renderer-unique objectID. Produced
    /// by layer SceneScript `thisScene.createLayer(...)` handles.
    var liveCreatedLayers: [String: WPECreatedLayerScriptState] = [:]
    /// Prepared one-pass templates keyed by model path. Hidden template layers
    /// are retained by the graph builder only when a script references them.
    var createdLayerTemplatesByImagePath: [String: WPEPreparedRenderLayer] = [:]
    /// Intro→loop phase alignment: an intro overlay (`introPhaseSource`) and the
    /// free-running loop it reveals (`loopPhaseSource`) are often the same
    /// animation a few seconds out of phase, with nothing in the scripts wiring the
    /// handoff. We measure the offset once (`intro@t ≈ loop@(t+offset)`) and slave
    /// the loop's playhead to lead the intro by it, so the crossfade is seamless.
    var introPhaseSource: WPEVideoTextureSource?
    var loopPhaseSource: WPEVideoTextureSource?
    var introLoopOffset: TimeInterval?
    /// Bumped per reload so a slow async measurement from a prior scene is ignored.
    var introPhaseToken = 0
    var loadedTextures: [String: MTLTexture] = [:]
    /// Reloadable static-texture bookkeeping for the optional VRAM budget
    /// (`textureCacheBudgetBytes`). Inactive over-budget entries are evicted and
    /// reloaded on demand; dynamic/video sources are never tracked here.
    struct StaticTextureCacheRecord: Sendable {
        let layerName: String
        let candidates: [String]
        var bytes: Int
    }
    var staticTextureCacheRecords: [String: StaticTextureCacheRecord] = [:]
    var textureCacheLRU = WPEMetalTextureCacheLRU(budgetBytes: 0)
    var textureCacheBudgetBytesInUse: Int?
    /// Per-load snapshot of `Self.textureCacheBudgetBytes` — the frame path must
    /// never read UserDefaults (per-frame defaults reads showed up hot in the C2
    /// flag-freeze pass).
    var textureCacheBudgetBytesResolved: Int?
    var staticTexturePlaceholderPaths: Set<String> = []
    var pendingStaticTextureReloads: Set<String> = []
    var staticTextureReloadThrottles: [String: WPEStaticTextureReloadThrottle] = [:]
    /// Memoizes `activeStaticTexturePaths` (the budget's only per-frame walk).
    /// Keyed by a per-layer visibility/shape signature: script or property flips
    /// recompute, static frames reuse. A hash collision only mis-protects for
    /// one frame and self-heals via the placeholder+reload path.
    var cachedActiveStaticPaths: Set<String> = []
    var cachedActiveStaticSignature: Int?
    var staticTextureRecordsEpoch = 0
    /// Phase 2E: animated and video texture sources keyed by the same path
    /// the executor uses to look up `MTLTexture` for each pass. Populated
    /// during `performLoad()`; refreshed each render via
    /// `texturesForCurrentFrame(time:pipeline:)` so the executor sees the live frame.
    var dynamicTextureSources: [String: WPEDynamicTextureSource] = [:] {
        didSet { cachedDynamicTextureNames = nil }
    }
    /// Memoized `Set(dynamicTextureSources.keys)` for the per-frame render call.
    /// All mutations are cold (load, lazy video rebuild, residency release,
    /// teardown) and each clears this via `didSet`; the frame path only reads.
    private var cachedDynamicTextureNames: Set<String>?
    var dynamicTextureNames: Set<String> {
        if let cached = cachedDynamicTextureNames { return cached }
        let names = Set(dynamicTextureSources.keys)
        cachedDynamicTextureNames = names
        return names
    }
    var sceneRenderSize: CGSize = CGSize(width: 1, height: 1)
    var cameraUniforms: WPEMetalCameraUniforms = .identity
    var frameClock: WPEMetalFrameClock
    /// Frozen frame globals when the render oracle is enabled (read once at load);
    /// `nil` in production, so the real clock/pointer drive every frame unchanged.
    let oracleFrameOverride = WPEOracleMode.loadFrameOverride()
    let pointerSampler: WPEMetalPointerSampler
    let snapshotter: WPEMetalTextureSnapshotter
    var cachedSnapshot: NSImage?
    var pendingLivePosterCaptures: [UUID: CheckedContinuation<NSImage?, Never>] = [:]
    var didLoad = false
    /// Bumped on every load and on teardown (`reload`/`cleanup`) so a deferred
    /// task — e.g. the off-critical-path audio startup — can detect that the
    /// renderer has since reloaded or torn down and bail on a stale scene.
    var loadGeneration = 0
    /// Set at the end of `performLoad` for scenes with sound; consumed by the
    /// first successful `present` in `draw(in:)`, so audio startup begins only
    /// after the first frame is actually on screen.
    var pendingAudioStartupDocument: WPESceneDocument?
    /// The in-flight off-main audio-startup task, tracked so `reload`/`cleanup`
    /// can cancel it.
    var deferredAudioStartupTask: Task<Void, Never>?

    #if DEBUG
    /// Test-only: audio startup is deferred (waiting on the first present), not yet started.
    var debugAudioStartupPending: Bool { pendingAudioStartupDocument != nil }
    /// Test-only: the sound runtime has been published (audio actually started).
    var debugSoundRuntimeActive: Bool { soundRuntime != nil }
    #endif
    /// Scene-level camera parallax: the parsed settings plus the per-frame
    /// exponential smoother that drives every layer's depth shift. Neutral when
    /// the scene disables parallax.
    var cameraParallaxSettings: WPESceneCameraParallaxSettings = .disabled
    var cameraParallaxSmoother = WPECameraParallaxSmoother()
    /// Per-machine magnitude multiplier for camera parallax. Defaults to
    /// `WPECameraParallaxFrame.defaultGain`. Read once at load — set it with
    /// `defaults write Taijia.LiveWallpaper WPEParallaxGain <number>` and reload
    /// the wallpaper to apply.
    let cameraParallaxGain = WPEMetalSceneRenderer.resolvedParallaxGain()
    var currentProfile: WallpaperPerformanceProfile = .quality
    /// When false, the per-frame pointer is pinned to the screen center so the
    /// scene stops reacting to the cursor (camera parallax freezes, pointer
    /// shaders see a constant). Driven by the per-screen "Follow Cursor"
    /// playback toggle; default on preserves the historical behavior.
    var mouseInteractionEnabled = true
    /// Previous frame's pointer UV, fed as the official `g_PointerPositionLast`.
    var previousPointer = SIMD2<Double>(0.5, 0.5)
    /// Tracks the live/inactive edge so pointer-spawned particles can be removed
    /// as soon as the cursor leaves this renderer's screen.
    var previousPointerWasLive = false
    /// Previous captured pointer/button frame used to emit SceneScript cursor
    /// down/up edges exactly once per transition.
    var previousLayerScriptPointerFrame = WPEPointerFrame.neutral
    /// User-selected frame rate ceiling, applied to `mtkView.preferredFramesPerSecond`
    /// whenever the renderer is not suspended. Defaults to the WPE-compatible
    /// 30 FPS until `setFrameRateLimit(_:)` overrides it.
    var userPreferredFPS: Int = WPEMetalSceneRenderer.defaultPreferredFPS
    /// System-driven background throttle (adaptive frame rate). Layered on top
    /// of `userPreferredFPS` via `effectiveFPS` so it never clobbers the user's
    /// saved ceiling — clearing it restores the exact prior rate.
    var adaptiveThrottleActive = false
    /// Inspector mute state cached here so callers that arrive before the
    /// deferred audio startup can still record intent; `beginDeferredAudioStartup`
    /// reads these to seed `WPESoundRuntime` at the right level (and re-applies
    /// them once the off-main start finishes, in case they changed meanwhile).
    var pendingAudioMuted: Bool = false
    var pendingAudioVolume: Double = 1.0

    var hasPresentedFrame = false
    var loadDiagnostics: SceneLoadDiagnostic?
    var renderGraph: WPERenderGraph?
    var renderPipeline: WPEPreparedRenderPipeline?
    /// True when the pipeline has effect / custom-shader passes (scroll,
    /// waterwaves, pulse, audio bars, …). These animate every frame via
    /// `g_Time` / `g_AudioSpectrum*`, so the view must run continuously even
    /// when there are no dynamic textures or particles — otherwise the scene
    /// renders one frame and freezes. Computed once per load.
    var hasAnimatedShaderPasses = false
    /// WPE `general.supportsaudioprocessing`. An audio-reactive scene must stay
    /// on the continuous-frame path so `g_AudioSpectrum*` re-samples every frame
    /// — `pipelineHasAnimatedPasses` only catches audio shaders under
    /// `effects/`/`workshop/`, so a custom-path audio shader would otherwise
    /// freeze on the static/on-demand path.
    var sceneSupportsAudioProcessing = false
    var lastRuntimeUniforms: WPEMetalRuntimeUniforms?
    var lastFramePipeline: WPEPreparedRenderPipeline?
    /// Property-key → render-target bindings for the loaded scene, used by the
    /// incremental settings-apply path. Empty until `load()` completes.
    var scenePropertyBindings: [String: [WPEScenePropertyBinding]] = [:]
    /// Live per-object visibility, seeded from the document and mutated by
    /// `applyScenePropertyPatch` so a settings toggle takes effect without reload.
    var liveLayerVisibility: [String: Bool] = [:]
    var liveTextVisibility: [String: Bool] = [:]
    /// Object hierarchy + own baked visibility (groups included), used to fold a
    /// layer script's `visible` against its ancestors' CURRENT visibility so a
    /// script can't show a layer under a hidden ancestor. See `WPESceneDocument`.
    var objectParentByID: [String: String] = [:]
    var ownVisibilityByID: [String: Bool] = [:]

    var renderedTexture: MTLTexture? { outputTexture }

    /// Test hook: reads a value from the scene's shared script store after a
    /// render, so a test can assert a HIDDEN text object's compute script ran
    /// (populated `shared`) rather than being skipped by the visibility filter.
    func sharedScriptValueForTesting(_ key: String) -> Any? {
        sceneScriptSharedState?.get(key)
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


    #if DEBUG
    var didDumpScenePassesOverTime = false
    #endif

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






    var hoverDebugCounter = 0



    deinit {
        stopEngineAssetsAccessIfNeeded()
    }


    /// Suppresses repeat `draw(in:)` failure logs within a failure streak so a
    /// broken pipeline warns once, not once per frame.
    var didLogFrameFailure = false

}

#endif
