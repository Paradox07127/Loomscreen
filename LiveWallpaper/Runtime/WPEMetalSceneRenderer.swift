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
    /// (60 × 122 MB raw) to the streaming source.
    private static let lazyAnimationRawByteThreshold = 200_000_000

    /// When true, emitters are pre-populated to their steady-state spread on
    /// load (`WPEParticleSystem.prewarm`, up to ~900 substeps/system — the
    /// dominant `particles.load` cost). Default OFF: emitters start empty and
    /// fill naturally, trading the populated-on-load look for a faster load.
    /// Flip `WPEParticlePrewarmEnabled` (Developer Tools → "Particle prewarm").
    private static var particlePrewarmEnabled: Bool {
        UserDefaults.standard.bool(forKey: "WPEParticlePrewarmEnabled")
    }

    private let descriptor: SceneDescriptor
    private let cacheRootURL: URL
    private let dependencyMounts: [WPEAssetMount]
    /// Resolved Wallpaper Engine install root (the directory that contains
    /// `assets/`). Captured at init for graph + pipeline builder use; the
    /// security scope is owned here for the lifetime of the renderer.
    private let engineAssetsRootURL: URL?
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
    /// Phase 2D-N: text overlay draws assembled at load time. Each
    /// frame re-rasterizes via the cached WPETextRenderer (cache hits
    /// the common case) and draws atop the scene output.
    private var textRenderer: WPETextRenderer?
    /// GPU MSDF text renderer (Milestone D). Built only when the engine's
    /// `font.frag` resolves; nil → text falls back to the CoreText overlay.
    private var msdfTextRenderer: WPEMSDFTextRenderer?
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
    /// `defaults write Taijia.LiveWallpaper WPEParticleCursorDebug -bool YES`:
    /// logs (~1/s) the sampled cursor + each cursor-reactive particle system's
    /// resolved control-point position and how many particles its attractors
    /// actually pushed last tick — disambiguates "no cursor sampled" from
    /// "cursor sampled but force feels wrong".
    private let cursorDebugLogEnabled = UserDefaults.standard.bool(forKey: "WPEParticleCursorDebug")
    private var cursorDiagCounter = 0
    /// Per-load stage profiler; non-nil only while `WPEMetalLoadTiming` is set.
    /// Fed by `debugStage`, it logs a per-phase load breakdown at first-frame.
    private var loadTiming: WPESceneLoadTiming?
    /// Phase 2D-P: per-text-object SceneScript instances. Keyed by
    /// the text object's id so the renderer can look up the latest
    /// scripted value when rasterizing.
    private var textScriptInstances: [String: WPESceneScriptInstance] = [:]
    /// Layer (image-object) SceneScripts keyed by objectID — visible-scripts that
    /// drive a layer's visibility/alpha and its video texture (e.g. an intro that
    /// plays once then hides). Empty for the common no-layer-script scene.
    private var layerScriptInstances: [String: WPELayerScriptInstance] = [:]
    /// objectID → the `dynamicTextureSources` key of the layer's video source, so
    /// a layer script's `getVideoTexture()` commands reach the right player.
    /// Populated for ALL video-backed layers (a button script drives a different
    /// layer's video via `thisScene.getLayer(name)`), not just scripted ones.
    private var layerVideoSourceKey: [String: String] = [:]
    /// Layer name → objectID, so a script's `thisScene.getLayer(name)` output can
    /// be resolved to the target layer.
    private var layerObjectIDByName: [String: String] = [:]
    /// Live per-layer alpha overrides driven by layer scripts (objectID → alpha).
    private var liveLayerAlpha: [String: Double] = [:]
    private var loadedTextures: [String: MTLTexture] = [:]
    /// Phase 2E: animated and video texture sources keyed by the same path
    /// the executor uses to look up `MTLTexture` for each pass. Populated
    /// during `performLoad()`; refreshed each render via
    /// `texturesForCurrentFrame(time:)` so the executor sees the live frame.
    private var dynamicTextureSources: [String: WPEDynamicTextureSource] = [:]
    private var sceneRenderSize: CGSize = CGSize(width: 1, height: 1)
    private var cameraUniforms: WPEMetalCameraUniforms = .identity
    private var frameClock: WPEMetalFrameClock
    private let pointerSampler: WPEMetalPointerSampler
    private let snapshotter: WPEMetalTextureSnapshotter
    private var cachedSnapshot: NSImage?
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
    /// `WPEMetalCompileTimer.milliseconds` snapshot at load start; the per-load
    /// metal-compile figure is reported as a delta against this (no global reset).
    private var compileMillisecondsAtLoadStart: Double = 0
    /// `WPEMetalTranspileTimer.milliseconds` snapshot at load start; the per-load
    /// transpile figure (GLSL preprocess + MSL transpile, the shader-prep NOT in
    /// the compile timer) is reported as a delta against this.
    private var transpileMillisecondsAtLoadStart: Double = 0

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
    /// shaders see a constant). Driven by the per-screen "Mouse Interaction"
    /// playback toggle; default on preserves the historical behavior.
    private var mouseInteractionEnabled = true
    /// Previous frame's pointer UV, fed as the official `g_PointerPositionLast`.
    private var previousPointer = SIMD2<Double>(0.5, 0.5)
    /// User-selected frame rate ceiling, applied to `mtkView.preferredFramesPerSecond`
    /// whenever the renderer is not suspended. Defaults to the WPE-compatible
    /// 30 FPS until `setFrameRateLimit(_:)` overrides it.
    private var userPreferredFPS: Int = WPEMetalSceneRenderer.defaultPreferredFPS
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
    /// Property-key → render-target bindings for the loaded scene, used by the
    /// incremental settings-apply path. Empty until `load()` completes.
    private(set) var scenePropertyBindings: [String: [WPEScenePropertyBinding]] = [:]
    /// Live per-object visibility, seeded from the document and mutated by
    /// `applyScenePropertyPatch` so a settings toggle takes effect without reload.
    private var liveLayerVisibility: [String: Bool] = [:]
    private var liveTextVisibility: [String: Bool] = [:]

    /// Emits a structured per-frame summary roughly once per second so runtime
    /// logs can show time advancement, dynamic texture swaps, and output size.
    private var lastHeartbeatTime: TimeInterval = -1

    var renderedTexture: MTLTexture? { outputTexture }
    /// CGImage read-back of the most recent rendered frame. Captured at the end
    /// of `performLoad()` **only when scene-debug artifacts are enabled** — the
    /// inspector now shows the project's preview GIF, so production skips the
    /// synchronous GPU read-back. Refreshed by `reload()`, cleared by
    /// `cleanup()`, and otherwise `nil`.
    var previewSnapshot: NSImage? { cachedSnapshot }
    var onProgress: (@MainActor (String) -> Void)?
    var resolutionDiagnostics: WPEResolutionDiagnosticsSnapshot {
        resolutionTracer.snapshot()
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
        let didStartEngineAssetsAccess = engineAssetsRootURL?.startAccessingSecurityScopedResource() ?? false
        // Only feed the engine-assets root to the resolver when its security
        // scope actually opened — otherwise the resolver would attempt reads
        // from an unauthorized root and the "fallback disabled" log below would
        // be a lie.
        let effectiveEngineAssetsRootURL = didStartEngineAssetsAccess ? engineAssetsRootURL : nil
        self.activeEngineAssetsRootURL = effectiveEngineAssetsRootURL
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

        if engineAssetsRootURL != nil && !didStartEngineAssetsAccess {
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
        // Snapshot the global compile accumulator and report a delta (instead of
        // resetting it), so a concurrent scene load on another display can't zero
        // it mid-flight. (Truly concurrent loads still over-count by each other's
        // compiles — a known limit of this opt-in diagnostic.)
        compileMillisecondsAtLoadStart = WPEMetalCompileTimer.milliseconds
        transpileMillisecondsAtLoadStart = WPEMetalTranspileTimer.milliseconds
        loadGeneration &+= 1
        loadTiming = WPESceneLoadTiming.isEnabled
            ? WPESceneLoadTiming(workshopID: descriptor.workshopID)
            : nil
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
        let engineRoot = engineAssetsRootURL
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
        executor.invalidateStaticLayerCache()
        hasAnimatedShaderPasses = Self.pipelineHasAnimatedPasses(pipeline)
        // Seed incremental-apply state. The graph builder already baked each
        // layer's authored `visible` into the pipeline, so these baselines
        // simply mirror it for later diffing in `applyScenePropertyPatch`.
        scenePropertyBindings = document.propertyBindings
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
            sceneCamera: document.camera
        )
        cameraParallaxSettings = document.general.cameraParallax
        sceneSupportsAudioProcessing = document.general.supportsAudioProcessing
        cameraParallaxSmoother.reset()
        sceneRenderSize = cameraUniforms.renderSize
        debugStage("camera", "renderSize=\(Int(sceneRenderSize.width))x\(Int(sceneRenderSize.height))")

        // Pre-warm shader transpile off-thread, overlapping the texture/particle/text
        // load below; awaited at the render.firstFrame gate so the first synchronous
        // render() hits the warmed cache instead of paying the lazy transpile inline.
        // No-op when WPEMetalShaderPrewarmEnabled is off.
        async let shaderWarm: Void = prewarmCustomShaders(for: pipeline)

        debugStage("textures.load", "begin (pipeline-driven)")
        onProgress?("Loading textures")
        try await loadTextures(for: pipeline)
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
        executor.logFBOMemoryReportIfRequested(
            pipeline: pipeline,
            sceneSize: sceneRenderSize,
            sceneID: descriptor.workshopID
        )
        // Finish seeding the shader cache before the first (synchronous) render() so it
        // hits warmed entries. By now this has overlapped the entire texture/particle/text
        // load above; on heavy scenes the ~1.9s transpile is already absorbed.
        await shaderWarm
        debugStage("render.firstFrame", "begin")
        onProgress?("Rendering scene")

        // Render the FIRST frame synchronously: it is read back on the CPU right
        // after load() by the scene-debug snapshot, the corpus harness, and the
        // `renderedTexture` accessor (tests) — an async submission would let those
        // read-backs race the GPU and sample an unfinished frame. It is a one-time
        // cost; the steady-state draw loop switches to async below.
        executor.synchronizeFrameCompletion = true
        let capture = beginGPUCaptureIfRequested()
        outputTexture = try renderCurrentFrame()
        capture?.stop()
        if WPESceneLoadTiming.isEnabled {
            // Split the one-time shader-prep cost: metal-compile is makeLibrary +
            // makeRenderPipelineState; transpile is the GLSL preprocess + MSL transpile
            // (the dominant first-frame CPU, which shader prewarm moves off-thread into
            // the load window when enabled). Both are zero-cost unless WPEMetalLoadTiming.
            let metalCompile = WPEMetalCompileTimer.milliseconds - compileMillisecondsAtLoadStart
            let transpile = WPEMetalTranspileTimer.milliseconds - transpileMillisecondsAtLoadStart
            Logger.notice(
                "[load-timing] scene=\(descriptor.workshopID) metal-compile=\(String(format: "%.1f", metalCompile))ms transpile=\(String(format: "%.1f", transpile))ms",
                category: .performance
            )
        }

        if let outputTexture {
            // Capture per-pass scene-target RT hashes BEFORE finishFrame latches
            // and serializes the trace — otherwise recordPassOutputs runs after the
            // trace is already written and the per-pass output hashes are dropped.
            #if DEBUG
            dumpScenePassesIfRequested()
            #endif
            // The snapshot + visual-stats read-backs exist only to feed the
            // scene-debug artifacts (first-frame PNG + stats). The inspector
            // now shows the project's preview GIF, so skip the synchronous GPU
            // read-back entirely unless artifacts are actually being captured.
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
            let start = DispatchTime.now()
            _ = runtime.prepare(sounds: sounds)   // off-main, decodes files; nothing audible yet
            let ms = Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
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
                        Logger.warning("Deferred scene audio failed to start (engine.start)", category: .wpeRender)
                    }
                }
                if WPESceneLoadTiming.isEnabled {
                    Logger.notice(
                        "[load-timing] scene=\(workshopID) deferred-audio=\(String(format: "%.1f", ms))ms (off main, after first present)",
                        category: .performance
                    )
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
        guard let wantedID, !wantedID.isEmpty, wantedID == descriptor.workshopID else {
            return
        }
        let dumps = executor.scenePassDumps
        Logger.notice(
            "[WPEDumpScenePasses] dumping \(dumps.count) scene-target passes\(suffix.isEmpty ? " (t0)" : " \(suffix)") for \(descriptor.workshopID)",
            category: .wpeRender
        )
        #if !LITE_BUILD && DEBUG
        WPECanonicalTraceRecorder.shared.recordPassOutputs(dumps)
        #endif
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
        for defaults in [UserDefaults(suiteName: "Taijia.LiveWallpaper"), .standard] {
            guard let defaults, defaults.object(forKey: "WPEParallaxGain") != nil else { continue }
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
        // Feed the load profiler first — it's gated independently of scene-debug,
        // so load timing can be gathered without enabling the dump machinery.
        loadTiming?.mark(stage)
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

    /// Computes one frame's runtime uniforms (clock, daytime, brightness, pointer) and submits the render pipeline with both runtime and camera uniforms.
    #if DEBUG
    /// Test-only: render the loaded scene but keep only the first `passLimit`
    /// passes of each layer, so a black-screen bug can be bisected to the exact
    /// pass that blackens the composite. Returns the executor output texture
    /// (no particles/text overlay). Caller must have already `load()`-ed.
    func debugRenderTruncated(passLimit: Int) throws -> MTLTexture {
        guard let pipeline = renderPipeline else {
            throw WPEMetalRenderExecutorError.noRenderablePasses
        }
        // The returned texture is read back on the CPU for bisection, so force the
        // synchronous path regardless of the scene's live submission mode.
        let previousSync = executor.synchronizeFrameCompletion
        executor.synchronizeFrameCompletion = true
        defer { executor.synchronizeFrameCompletion = previousSync }
        let truncated = WPEPreparedRenderPipeline(
            layers: pipeline.layers.map { layer in
                WPEPreparedRenderLayer(
                    graphLayer: layer.graphLayer,
                    puppetModel: layer.puppetModel,
                    passes: Array(layer.passes.prefix(passLimit))
                )
            }
        )
        let uniforms = lastRuntimeUniforms ?? frameClock.runtimeUniforms(
            profile: currentProfile,
            pointerPosition: SIMD2<Double>(0.5, 0.5)
        )
        return try executor.render(
            pipeline: truncated,
            size: sceneRenderSize,
            textures: texturesForCurrentFrame(time: uniforms.time),
            dynamicTextureNames: Set(dynamicTextureSources.keys),
            runtimeUniforms: uniforms,
            cameraUniforms: cameraUniforms,
            sceneID: descriptor.workshopID
        )
    }

    /// Test-only: total pass count of the first layer (the saber image layer).
    var debugFirstLayerPassCount: Int {
        renderPipeline?.layers.first?.passes.count ?? 0
    }

    /// Test-only: render `frames` successive full frames through the real
    /// `renderCurrentFrame` path (so cross-frame `previousFrameHistory` feedback
    /// accumulates exactly like on-device), returning each frame's output texture.
    func debugRenderSuccessiveFrameTextures(_ frames: Int) throws -> [MTLTexture] {
        // This diagnostic holds every frame's texture for after-the-fact pixel
        // comparison; output recycling would alias frame N with frame N+3.
        executor.isOutputPoolingEnabled = false
        // Each frame's texture is held + pixel-diffed on the CPU afterwards, so it
        // must be fully rendered before the next iteration overwrites GPU state.
        let previousSync = executor.synchronizeFrameCompletion
        executor.synchronizeFrameCompletion = true
        defer {
            executor.isOutputPoolingEnabled = true
            executor.synchronizeFrameCompletion = previousSync
        }
        var out: [MTLTexture] = []
        out.reserveCapacity(frames)
        for _ in 0..<frames {
            let tex = try renderCurrentFrame()
            outputTexture = tex
            out.append(tex)
        }
        return out
    }

    static func debugFrameStats(of texture: MTLTexture) -> (Double, Double, Double) {
        guard texture.pixelFormat == .rgba8Unorm || texture.pixelFormat == .rgba8Unorm_srgb else {
            return (-1, -1, -1)
        }
        let bpr = texture.width * 4
        var bytes = [UInt8](repeating: 0, count: bpr * texture.height)
        texture.getBytes(&bytes, bytesPerRow: bpr,
                         from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        var nonBlack = 0, white = 0, sampled = 0
        var lumaSum = 0.0
        let step = max(1, texture.height / 200)
        for y in stride(from: 0, to: texture.height, by: step) {
            for x in stride(from: 0, to: texture.width, by: step) {
                let i = y * bpr + x * 4
                let r = Int(bytes[i]), g = Int(bytes[i + 1]), b = Int(bytes[i + 2])
                lumaSum += Double(r + g + b) / 3.0
                if r > 10 || g > 10 || b > 10 { nonBlack += 1 }
                if r > 240 && g > 240 && b > 240 { white += 1 }
                sampled += 1
            }
        }
        let n = Double(max(sampled, 1))
        return (Double(nonBlack) / n, Double(white) / n, lumaSum / n)
    }
    #endif

    private func renderCurrentFrame() throws -> MTLTexture {
        guard let pipeline = renderPipeline else {
            throw WPEMetalRenderExecutorError.noRenderablePasses
        }
        // Pin to center when mouse interaction is off so cursor-driven parallax
        // and pointer shaders go neutral (and stay there — center maps to a zero
        // parallax target).
        let pointer = mouseInteractionEnabled
            ? pointerSampler.sample(mtkView)
            : SIMD2<Double>(0.5, 0.5)
        var uniforms = frameClock.runtimeUniforms(
            profile: currentProfile,
            pointerPosition: pointer
        )
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
        if SystemAudioCaptureManager.isCapturing {
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
        // capture; click state is neutral unless the Interactive toggle is on.
        uniforms.pointerPositionLast = previousPointer
        uniforms.pointerClick = mtkView.clickCaptureEnabled ? mtkView.pointerFrame : .neutral
        previousPointer = pointer
        lastRuntimeUniforms = uniforms
        // Tick layer SceneScripts (e.g. a video intro that plays once then hides):
        // each drives its layer's visibility/alpha + video playback. Gated so a
        // scene with no layer scripts pays nothing (no per-frame pipeline rebuild).
        var framePipeline = pipeline
        if !layerScriptInstances.isEmpty {
            for (objectID, instance) in layerScriptInstances {
                if let output = instance.tick() {
                    applyLayerScriptOutput(output, ownObjectID: objectID)
                }
            }
            framePipeline = pipeline
                .applyingLayerVisibility(liveLayerVisibility)
                .applyingLayerAlpha(liveLayerAlpha)
        }
        // Particles tick (CPU sim) BEFORE the layer composite so the executor can
        // interleave their draws at each system's scene paint index.
        if !particleSystems.isEmpty {
            // Cursor in the centered render frame (Y-up), or nil when Follow
            // Cursor is off — drives pointer-locked particle control points
            // (emitter-follow + controlpointattract). Center-relative so it
            // matches `WPEParticleSceneTransform`'s coordinate space.
            let particlePointer: SIMD2<Float>? = mouseInteractionEnabled
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
                system.tick(now: uniforms.time)
            }
            if cursorDebugLogEnabled {
                cursorDiagCounter += 1
                if cursorDiagCounter % 60 == 1 {
                    let ptr = particlePointer.map { "(\(Int($0.x)),\(Int($0.y)))" }
                        ?? "nil (mouseInteraction off / off-view)"
                    let lines = particleSystems.enumerated().compactMap { i, system in
                        system.cursorDebugSummary().map { "  [\(i)] \($0)" }
                    }
                    let body = lines.isEmpty
                        ? " — no cursor-reactive systems in this scene"
                        : "\n" + lines.joined(separator: "\n")
                    Logger.notice("[WPEParticleCursorDebug] pointer=\(ptr)\(body)", category: .wpeRender)
                }
            }
        }
        // Split the (synchronous) first load frame into CPU texture prep (lazy
        // .tex decode + dynamic-source refresh) vs GPU render (encode + upload
        // completion + draw + wait), so we can tell which dominates render.firstFrame
        // on heavy scenes. Only the load-time first frame, only when timing is on.
        // `!didLoad` first: it short-circuits the UserDefaults read on every
        // steady-state frame (only the load-time first frame ever gets past it).
        let splitFirstFrame = !didLoad && WPESceneLoadTiming.isEnabled
        let texPrepStart = splitFirstFrame ? DispatchTime.now() : nil
        let currentTextures = texturesForCurrentFrame(time: uniforms.time)
        let gpuRenderStart = splitFirstFrame ? DispatchTime.now() : nil
        let frame = try executor.render(
            pipeline: framePipeline,
            size: sceneRenderSize,
            textures: currentTextures,
            dynamicTextureNames: Set(dynamicTextureSources.keys),
            runtimeUniforms: uniforms,
            cameraUniforms: cameraUniforms,
            sceneID: descriptor.workshopID,
            particleSystems: particleSystems,
            particleTextures: particleTextures,
            particleParallax: parallaxFrame
        )
        if let texPrepStart, let gpuRenderStart {
            let prepMs = Double(gpuRenderStart.uptimeNanoseconds &- texPrepStart.uptimeNanoseconds) / 1_000_000
            let renderMs = Double(DispatchTime.now().uptimeNanoseconds &- gpuRenderStart.uptimeNanoseconds) / 1_000_000
            Logger.notice(
                "[load-timing] scene=\(descriptor.workshopID) firstFrame-split: texture-prep=\(String(format: "%.1f", prepMs))ms gpu-render=\(String(format: "%.1f", renderMs))ms",
                category: .performance
            )
        }
        if let textRenderer, !textObjects.isEmpty {
            // CoreText draws for objects that don't take the MSDF path this frame.
            var draws: [WPETextOverlayDraw] = []
            // Every visible object's CoreText draw, used as the all-or-nothing
            // fallback if the GPU MSDF pass throws.
            var allFallbackDraws: [WPETextOverlayDraw] = []
            var msdfPayloads: [WPEMSDFTextDrawPayload] = []
            draws.reserveCapacity(textObjects.count)
            for object in textObjects where liveTextVisibility[object.id] ?? object.visible {
                let resolvedAlpha = object.resolvedAlpha(at: uniforms.time)
                guard resolvedAlpha > 0 else { continue }
                let liveText = textScriptInstances[object.id]?.tickString() ?? object.text
                let liveObject = object.withLiveText(liveText, alpha: resolvedAlpha)
                guard let entry = textRenderer.rasterize(liveObject) else { continue }
                let halfWidth = Double(sceneRenderSize.width) * 0.5
                let halfHeight = Double(sceneRenderSize.height) * 0.5
                let textParallax = parallaxFrame.pixelOffset(
                    depth: liveObject.parallaxDepth,
                    sceneSize: sceneRenderSize
                )
                let center = SIMD2<Float>(
                    Float(liveObject.origin.x - halfWidth) + textParallax.x,
                    Float(liveObject.origin.y - halfHeight) + textParallax.y
                )
                let scale = SIMD2<Float>(
                    Float(max(liveObject.scale.x, 0.0001)),
                    Float(max(liveObject.scale.y, 0.0001))
                )
                let scaledSize = CGSize(
                    width: entry.size.width * CGFloat(scale.x),
                    height: entry.size.height * CGFloat(scale.y)
                )
                let fallbackDraw = WPETextOverlayDraw(
                    texture: entry.texture,
                    centerInScenePixels: center,
                    sizeInScenePixels: scaledSize,
                    tint: SIMD3<Float>(
                        Float(liveObject.color.x),
                        Float(liveObject.color.y),
                        Float(liveObject.color.z)
                    ),
                    alpha: Float(liveObject.alpha)
                )
                allFallbackDraws.append(fallbackDraw)
                // Prefer the GPU MSDF path; if it can't build a payload for this
                // object, render it via the CoreText overlay this frame.
                if let payload = msdfTextRenderer?.drawPayload(
                    for: liveObject,
                    sceneSize: sceneRenderSize,
                    parallaxOffset: SIMD2<Float>(textParallax.x, textParallax.y)
                ) {
                    msdfPayloads.append(payload)
                } else {
                    draws.append(fallbackDraw)
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
                } catch {
                    msdfSucceeded = false
                }
            }
            // If the MSDF pass failed, fall back to CoreText for everything so no
            // text silently disappears.
            if !msdfSucceeded, !msdfPayloads.isEmpty {
                draws = allFallbackDraws
            }
            if !draws.isEmpty {
                try executor.drawTextOverlays(
                    overlays: draws,
                    sceneSize: sceneRenderSize,
                    output: frame
                )
            }
        }
        #if DEBUG
        maybeDumpScenePassesOverTime(time: uniforms.time, composite: frame)
        #endif
        return frame
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
        // GPU MSDF text is opt-in until glyph generation moves off the main
        // thread: synchronous MSDF rasterization of large/CJK glyphs blocks the
        // first frame. Default OFF → CoreText overlay (the known-good path).
        // Enable for testing with: defaults write <bundle> WPEEnableMSDFText -bool YES
        if UserDefaults.standard.bool(forKey: "WPEEnableMSDFText"),
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
        for object in textObjects {
            guard let script = object.textScript else { continue }
            if let instance = try? WPESceneScriptInstance(
                script: script,
                initialValue: object.text,
                scriptProperties: object.scriptProperties
            ) {
                textScriptInstances[object.id] = instance
            }
        }
    }

    /// Loads the engine's MSDF `font.frag` from the authorized 2.8 install so the
    /// GPU text path can compile it. Returns nil when unavailable → CoreText only.
    private func resolveMSDFFontFragmentSource() -> String? {
        let candidates = ["shaders/font.frag", "shaders/effects/font.frag"]
        for path in candidates {
            guard let data = try? resourceResolver.data(relativePath: path),
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
        return ParticleMaterialDescriptor(
            blendMode: WPEParticleBlendMode(materialString: blendString),
            firstTexturePath: firstTexturePath,
            overbright: Self.overbright(fromConstants: constants)
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
            guard let data = try? resourceResolver.data(relativePath: probe) else {
                continue
            }
            if let sheet = WPEParticleSpriteSheetParser.parse(data: data, atlasPixelSize: atlasPixelSize) {
                return sheet
            }
        }
        return nil
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
        layerVideoSourceKey = [:]
        layerObjectIDByName = [:]
        liveLayerAlpha = [:]
        let scripted = document.imageObjects.filter { $0.visibleScript != nil }
        guard !scripted.isEmpty, let pipeline = renderPipeline else { return }

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

        for object in scripted {
            guard let script = object.visibleScript else { continue }
            do {
                let instance = try WPELayerScriptInstance(
                    script: script,
                    scriptProperties: object.scriptProperties
                )
                layerScriptInstances[object.id] = instance
                applyLayerScriptOutput(instance.initialOutput, ownObjectID: object.id)
                let out = instance.initialOutput
                let others = out.others.map { entry in
                    "\(entry.key)[id=\(layerObjectIDByName[entry.key] ?? "?") vis=\(entry.value.visible) cmds=\(entry.value.videoCommands.count)]"
                }.joined(separator: ",")
                Logger.notice(
                    "[LayerScript] \(object.name) ownVideo=\(layerVideoSourceKey[object.id] ?? "none") initVisible=\(out.own.visible) initCmds=\(out.own.videoCommands) getLayer={\(others)}",
                    category: .wpeRender
                )
            } catch {
                Logger.warning("[LayerScript] init failed for \(object.name): \(error)", category: .wpeRender)
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
    }

    /// Applies one layer's resolved state: visibility + alpha into the live
    /// override maps, and any buffered video commands to that layer's video source.
    private func applyLayerScriptState(_ state: WPELayerScriptState, objectID: String) {
        liveLayerVisibility[objectID] = state.visible
        liveLayerAlpha[objectID] = state.alpha
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
        for object in document.particleObjects where object.visible {
            await expandParticleTree(
                path: object.particleRelativePath,
                parentPath: nil,
                originAccum: SIMD3<Double>(0, 0, 0),
                ancestry: [],
                parentSystem: nil,
                followFromParent: false,
                object: object,
                sortIndex: document.objectPaintOrder[object.id] ?? 0
            )
        }
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
        sortIndex: Int
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
                sortIndex: sortIndex
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
                sortIndex: sortIndex
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
        sortIndex: Int = 0
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
        guard let system = WPEParticleSystem(
            definition: definition,
            device: executor.textureSourceDevice,
            blendMode: blendMode,
            sceneTransform: sceneTransform,
            spriteSheet: spriteSheet
        ) else { return nil }
        system.parallaxDepth = object.parallaxDepth
        system.sortIndex = sortIndex
        system.overbright = material?.overbright ?? 1.0
        if requiresFollowParent {
            system.followParent = followParent
            system.requiresFollowParent = true
        }
        // Prewarm pre-populates the emitter to its STEADY-STATE age/position
        // spread so it loads already-full (matches WPE's populated-on-load
        // look) instead of filling from empty. It is the dominant
        // `particles.load` cost — up to ~900 substeps/system run synchronously
        // on the main actor — so it is gated: default OFF = emitters start at
        // zero and fill naturally (faster load); flip `WPEParticlePrewarmEnabled`
        // (Developer Tools → "Particle prewarm") to restore the populated look.
        if Self.particlePrewarmEnabled {
            // Prewarm long enough that the first-spawned particles have lived a
            // full lifetime (a `+2s` cap left them clustered near the origin).
            let prewarmSeconds = max(0, definition.startDelay)
                + min(max(definition.lifetimeMax, 2.0), 15.0)
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
        deferredAudioStartupTask?.cancel()
        deferredAudioStartupTask = nil
        pendingAudioStartupDocument = nil
        didLoad = false
        hasPresentedFrame = false
        outputTexture = nil
        renderGraph = nil
        renderPipeline = nil
        scenePropertyBindings = [:]
        liveLayerVisibility = [:]
        liveTextVisibility = [:]
        loadDiagnostics = nil
        resolutionTracer.reset()
        releaseDynamicTextureSources()
        particleSystems.removeAll(keepingCapacity: false)
        particleTextures.removeAll(keepingCapacity: false)
        textObjects.removeAll(keepingCapacity: false)
        textRenderer?.releaseAll()
        textRenderer = nil
        msdfTextRenderer = nil
        textScriptInstances.removeAll(keepingCapacity: false)
        layerScriptInstances.removeAll(keepingCapacity: false)
        layerVideoSourceKey.removeAll(keepingCapacity: false)
        layerObjectIDByName.removeAll(keepingCapacity: false)
        liveLayerAlpha.removeAll(keepingCapacity: false)
        soundRuntime?.stop()
        soundRuntime = nil
        sceneRenderSize = CGSize(width: 1, height: 1)
        cameraUniforms = .identity
        lastRuntimeUniforms = nil
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
        if let pipeline = renderPipeline {
            renderPipeline = pipeline.applyingLayerVisibility(liveLayerVisibility)
        }
        mtkView.setNeedsDisplay(mtkView.bounds)
        return true
    }

    func setMouseInteractionEnabled(_ enabled: Bool) {
        mouseInteractionEnabled = enabled
        if !enabled {
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
    /// flips at runtime, so turning Follow Cursor / Interactive on un-pauses a
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
        guard currentProfile != .suspended else { return }
        mtkView.preferredFramesPerSecond = userPreferredFPS
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

    /// True when something on stage actually changes between frames — a
    /// dynamic texture (animated `.tex` / video) or a live particle
    /// system. Static-scene + particle combos must NOT short-circuit
    /// MTKView into the paused/on-demand path or particles freeze after
    /// the first frame (the operator and turbulence updates would never
    /// run again).
    private var needsContinuousFrames: Bool {
        hasAnimatedShaderPasses
            || sceneSupportsAudioProcessing
            || !dynamicTextureSources.isEmpty
            || !particleSystems.isEmpty
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
            mtkView.preferredFramesPerSecond = userPreferredFPS
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
        deferredAudioStartupTask?.cancel()
        deferredAudioStartupTask = nil
        pendingAudioStartupDocument = nil
        mtkView.delegate = nil
        outputTexture = nil
        scenePropertyBindings = [:]
        liveLayerVisibility = [:]
        liveTextVisibility = [:]
        releaseDynamicTextureSources()
        particleSystems.removeAll(keepingCapacity: false)
        particleTextures.removeAll(keepingCapacity: false)
        textObjects.removeAll(keepingCapacity: false)
        textRenderer?.releaseAll()
        textRenderer = nil
        msdfTextRenderer = nil
        textScriptInstances.removeAll(keepingCapacity: false)
        layerScriptInstances.removeAll(keepingCapacity: false)
        layerVideoSourceKey.removeAll(keepingCapacity: false)
        layerObjectIDByName.removeAll(keepingCapacity: false)
        liveLayerAlpha.removeAll(keepingCapacity: false)
        soundRuntime?.stop()
        soundRuntime = nil
        cameraParallaxSettings = .disabled
        sceneSupportsAudioProcessing = false
        cameraParallaxSmoother.reset()
        lastRuntimeUniforms = nil
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

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { [weak self] in
            guard let self, didLoad else { return }
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
                let presented = try executor.present(texture: texture, in: view, fitMode: presentFitMode)
                // Start audio only after the first frame is actually on screen, so
                // the synchronous engine spin-up can never delay the first pixels.
                if presented, pendingAudioStartupDocument != nil {
                    beginDeferredAudioStartup()
                }
            } catch {
                Logger.warning("Experimental Metal scene present failed: \(error.localizedDescription)", category: .screenManager)
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
    private func prewarmCustomShaders(for pipeline: WPEPreparedRenderPipeline) async {
        guard WPEMetalRenderExecutor.isShaderPrewarmEnabled else { return }
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
    }

    private func loadTextures(for pipeline: WPEPreparedRenderPipeline) async throws {
        loadedTextures = [:]
        dynamicTextureSources = [:]

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
                    loadedTextures[jobs[index].path] = texture
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
                loadedTextures[path] = texture
            case .dynamicSource(let source):
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

    private func requiredTextureReferences(for pass: WPEPreparedRenderPass) -> [WPETextureReference] {
        switch normalizedBuiltinShaderName(pass.pass.shader) {
        case "solidcolor", "solidlayer":
            return []

        case "compose":
            let first = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
            let second = pass.textureBindings[1] ?? pass.pass.textures[1] ?? first
            return [first, second].filter(\.isExternalTextureReference)

        case "genericimage4":
            let primary = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
            var refs: [WPETextureReference] = [primary]
            if let mask = pass.textureBindings[1] ?? pass.pass.textures[1] {
                refs.append(mask)
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

    private func normalizedBuiltinShaderName(_ shaderName: String) -> String {
        WPEBuiltinShaderName.normalized(shaderName, genericImageAsCopy: false)
    }

    /// Phase 2E rewrite: returns a `WPELoadedTextureResource` instead of a raw texture so the caller can route MP4 video and multi-frame animations through dedicated dynamic sources.
    private func makeTextureResource(relativePath: String, label: String) async throws -> WPELoadedTextureResource {
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

                        return .staticTexture(try await textureLoader.makeTexture(from: payload, label: label))
                    } catch {
                        lastError = error
                    }
                }
                let image = try resourceResolver.resolveImage(relativePath: candidate)
                return .staticTexture(try await textureLoader.makeTexture(from: image, label: label))
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

    /// Phase 2E: pulls fresh `MTLTexture`s from any dynamic sources before every render call.
    private func texturesForCurrentFrame(time: TimeInterval) -> [String: MTLTexture] {
        let shouldLogHeartbeat = time - lastHeartbeatTime >= 10.0 || lastHeartbeatTime < 0
        var dynamicFrameLog: [String] = []
        for (path, source) in dynamicTextureSources {
            if let texture = source.texture(at: time) {
                loadedTextures[path] = texture
                guard shouldLogHeartbeat else { continue }
                if let animated = source as? WPETexAnimatedTextureSource {
                    dynamicFrameLog.append("\(path)#\(animated.frameIndex(at: time))")
                } else if let lazy = source as? WPETexLazyAnimatedTextureSource {
                    dynamicFrameLog.append("\(path) \(lazy.debugFrameDescription(at: time))")
                } else {
                    dynamicFrameLog.append("\(path)#?")
                }
            }
        }
        // Heartbeat throttled to 10s so it confirms liveness without spamming
        // the log every second. (Was 1s — see Log filtering guidance.)
        if shouldLogHeartbeat {
            lastHeartbeatTime = time
            let scene = "\(Int(sceneRenderSize.width))x\(Int(sceneRenderSize.height))"
            let output = outputTexture.map { "\($0.width)x\($0.height)" } ?? "nil"
            let dyn = dynamicFrameLog.isEmpty ? "none" : dynamicFrameLog.joined(separator: " ")
            debugStage("heartbeat", "t=\(String(format: "%.2f", time))s scene=\(scene) output=\(output) dynamic=\(dyn)")
        }
        return loadedTextures
    }

    private func releaseDynamicTextureSources() {
        dynamicTextureSources.values.forEach { $0.invalidate() }
        dynamicTextureSources.removeAll()
        loadedTextures.removeAll()
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

        if path.hasPrefix("_") {
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
