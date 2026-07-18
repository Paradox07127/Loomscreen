#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import LiveWallpaperProWPE
import MetalKit
import os

/// Wraps a texture-load failure with the requested asset path AND the WPE
/// object/layer name that referenced it so the H1 diagnostic mapper can
/// blame the exact file and surface the failing layer instead of falling
/// back to the scene entry point.
struct WPEMetalTextureLoadContextError: Error {
    let layerName: String
    let path: String
    let underlying: any Error
}

// Runtime-config protocol conformances (performance / frame-rate / audio) were
// lifted onto `WPERendererConfigAdapter` (SceneWallpaperSession.swift) so the
// session, not the renderer, is what consumers depend on. The methods below stay
// public on the renderer for the adapter to forward into.
//
// M2c1b-3c: the renderer is no longer `@MainActor`. It lives inside a single
// `WPEDisplayRenderActor`'s isolation — the frame path and setters via the
// actor's `withRenderer` sync entry, the async surfaces (load/reload/…) via
// methods that take `isolated WPEDisplayRenderActor`. It is non-`Sendable`, so
// the compiler keeps it in that one domain; the actor's backing thread (main by
// default, a dedicated render thread when the off-main flag is set) is the only
// variable. Sync tails that must spawn work (deferred audio, on-demand video,
// static-texture reload) re-enter through the weakly-held `displayActor`.
final class WPEMetalSceneRenderer: NSObject {
    /// The actor this renderer is isolated to (set by `WPEDisplayRenderActor
    /// .adopt`). Weak: the actor owns the renderer strongly, this points back so
    /// sync task-spawning tails can capture the actor (Sendable) and re-enter the
    /// isolation instead of capturing `self`. Nil only before adoption / after
    /// teardown, in which case those tails no-op.
    weak var displayActor: WPEDisplayRenderActor?

    #if DEBUG
    /// Test-only strong reference to the surface built by the `frame:device:`
    /// convenience init, so tests can reach the MTKView via `nsView`. Never set by
    /// the production designated init (which takes only Sendable seams), so the
    /// production renderer's region stays free of the surface.
    var debugSurface: WPERenderSurface?
    #endif

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
    /// Non-blocking control seam to the surface (M2c1b). Every renderer call site
    /// that drove the view goes through this `Sendable` handle. Because it is a
    /// `Sendable` existential, the surface (and the delivery shim + render actor it
    /// transitively references) sit in a **separate** isolation region from the
    /// renderer — that is what keeps the renderer `sending`-adoptable into the
    /// actor. The renderer therefore holds no strong `WPERenderSurface` and no
    /// shim; the surface owns the shim and the session owns the surface.
    let surfaceControl: any WPESurfaceControl
    /// Render-path pointer source, fed by the surface's publisher + view. Same
    /// instance the surface owns.
    let mailbox: WPEPointerMailbox
    /// The view's `CAMetalLayer`, the present/drawable source, held via a Sendable
    /// wrapper so the renderer's region does not reach the main-thread surface.
    let metalLayer: WPEPresentLayer
    /// Drawable pixel size pushed from the surface (`updateSurfaceGeometry`).
    /// Read by the perspective native-resolution path in `performLoad`.
    var surfaceDrawableSize: CGSize
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
    let sceneScriptLoadState = WPESceneScriptLoadState()
    /// Last complete cross-family presentation. If a runtime resource ceiling
    /// latches between script families, transforms/text stay on this snapshot
    /// instead of falling back to their baked values while layer state freezes.
    var lastStableScriptTransforms = LiveScriptTransforms()
    var lastStableScriptTextByID: [String: String] = [:]
    var sceneScriptVideoCommandBuffer = WPESceneScriptVideoCommandBuffer()
    /// Staged with the SceneScript video transaction. The eventual AVPlayer
    /// seek is allowed only after every script family and frame encode succeed.
    var sceneScriptIntroPhaseAlignPending = false
    /// Stable renderer identity used only by the process-wide SceneScript
    /// admission governor. It is safe to derive without touching actor state,
    /// including from the nonisolated deinitializer fail-safe.
    nonisolated var sceneScriptTraversalDomainID: UInt64 {
        UInt64(UInt(bitPattern: ObjectIdentifier(self)))
    }
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
    /// Owns admission, generation tickets and retained task handles for
    /// on-demand static-texture residency reloads.
    let staticTextureReloadTaskOwner = WPEStaticTextureReloadTaskOwner()
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
    /// User-selected frame rate ceiling, applied to the surface's
    /// `preferredFramesPerSecond` whenever the renderer is not suspended.
    /// Defaults to the WPE-compatible
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

    var onProgress: (@Sendable (String) -> Void)?
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
        surfaceControl: any WPESurfaceControl,
        mailbox: WPEPointerMailbox,
        presentLayer: WPEPresentLayer,
        drawableSize: CGSize,
        device: MTLDevice,
        frameClock: WPEMetalFrameClock = WPEMetalFrameClock(),
        pointerSampler: WPEMetalPointerSampler? = nil,
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
        // The renderer receives only the surface's `Sendable` seams (control
        // handle, mailbox, present-layer wrapper, drawable size) — never the whole
        // `WPERenderSurface`. Taking a non-Sendable surface here would merge the
        // renderer's isolation region with the main-thread surface's and block the
        // `sending` adoption into the render actor. The builder wires the delivery
        // shim onto the surface itself.
        self.surfaceControl = surfaceControl
        self.mailbox = mailbox
        self.metalLayer = presentLayer
        self.surfaceDrawableSize = drawableSize
        self.frameClock = frameClock
        self.pointerSampler = pointerSampler ?? .mailbox(mailbox)
        self.snapshotter = snapshotter
        super.init()

        if needsScope && !didStartEngineAssetsAccess {
            Logger.warning(
                "Wallpaper Engine assets security scope could not be started — engine fallback disabled for this session",
                category: .fileAccess
            )
        }

    }

    /// Legacy/test convenience: builds the main-thread surface here (so it must be
    /// `@MainActor`), extracts its `Sendable` seams, and forwards to the injecting
    /// designated init. Keeps existing `frame:device:` call sites compiling. The
    /// production path goes through the session builder, which also wires the shim.
    @MainActor
    convenience init(
        descriptor: SceneDescriptor,
        cacheRootURL: URL,
        assetProvider: (any WPESceneAssetProvider)? = nil,
        projectManifestRootURL: URL? = nil,
        dependencyMounts: [WPEAssetMount],
        engineAssetsRootURL: URL? = nil,
        frame: CGRect,
        device: MTLDevice,
        frameClock: WPEMetalFrameClock = WPEMetalFrameClock(),
        pointerSampler: WPEMetalPointerSampler? = nil,
        snapshotter: WPEMetalTextureSnapshotter = .shared
    ) throws {
        let surface = WPERenderSurface(frame: frame, device: device)
        try self.init(
            descriptor: descriptor,
            cacheRootURL: cacheRootURL,
            assetProvider: assetProvider,
            projectManifestRootURL: projectManifestRootURL,
            dependencyMounts: dependencyMounts,
            engineAssetsRootURL: engineAssetsRootURL,
            surfaceControl: surface,
            mailbox: surface.mailbox,
            presentLayer: WPEPresentLayer(layer: surface.metalLayer),
            drawableSize: surface.metalLayer.drawableSize,
            device: device,
            frameClock: frameClock,
            pointerSampler: pointerSampler,
            snapshotter: snapshotter
        )
        #if DEBUG
        self.debugSurface = surface
        #endif
    }

    /// Surface geometry push (main-thread MTKView drawable size). No live
    /// consumer beyond `performLoad`'s perspective native-resolution sizing today.
    func updateSurfaceGeometry(drawableSize: CGSize) {
        surfaceDrawableSize = drawableSize
    }


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
        WPESceneScriptExecutionGovernor.processShared.forgetDomain(domainID: sceneScriptTraversalDomainID)
        sceneScriptLoadState.retireCurrent()
        stopEngineAssetsAccessIfNeeded()
    }

    /// Suppresses repeat `draw(in:)` failure logs within a failure streak so a
    /// broken pipeline warns once, not once per frame.
    var didLogFrameFailure = false

}

#endif
