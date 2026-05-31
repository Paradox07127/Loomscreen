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
final class WPEMetalSceneRenderer: NSObject, WPESceneRenderer, WPEScenePropertyRuntime, WallpaperFrameRateConfigurable, WallpaperAudioConfigurable, MTKViewDelegate {
    /// Default frame rate target when not throttled and no user override
    /// has been applied. 30 FPS matches Wallpaper Engine's stock default
    /// (Almamu's reference open-source impl ships `maximumFPS = 30`; the
    /// official Windows app's "Balanced" preset also defaults to 30) —
    /// most published WPE shaders are tuned around a 30 FPS clock, so
    /// running at 60 made their `g_Time`-driven motion look ≈2× too fast.
    /// `MTKView` clamps this to the display's refresh rate.
    static let defaultPreferredFPS = 30
    /// Native vsync cap used when the user picks `.unlimited` — MTKView's
    /// throttle clamps to the display refresh anyway, but we surface 60
    /// here so a `setPreferredFramesPerSecond(0)` doesn't get interpreted
    /// as "as fast as possible" (which on some macOS versions free-runs
    /// well past vsync).
    static let unlimitedPreferredFPS = 60
    /// Frame rate target when an external coordinator wants the renderer
    /// out of the way (e.g. console window in focus, multi-display
    /// exclusive rendering takeover). 1fps keeps the timer alive so we can
    /// bounce back when throttling is released.
    static let throttledPreferredFPS = 1
    /// Above this raw-bytes footprint, eager-upload a multi-frame `.tex`
    /// would burn far more VRAM than the runtime needs at any one moment
    /// — route through `WPETexLazyAnimatedTextureSource` instead. Threshold
    /// chosen to keep small (≤2-3 frame) workshop sprite-sheets on the
    /// fast eager path while sending workshop 3725117707-class assets
    /// (60 × 122 MB raw) to the streaming source.
    private static let lazyAnimationRawByteThreshold = 200_000_000

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
    private let resolutionTracer: WPEResolutionTracer
    private let mtkView: MTKView
    private let executor: WPEMetalRenderExecutor
    private let textureLoader: WPEMetalTextureLoader
    private var outputTexture: MTLTexture?
    /// Phase 2D-L: alive particle systems and the per-system sprite
    /// texture. Built on load from the scene's `particleObjects`; ticked
    /// + drawn each frame.
    private var particleSystems: [WPEParticleSystem] = []
    private var particleTextures: [ObjectIdentifier: MTLTexture] = [:]
    /// Phase 2D-N: text overlay draws assembled at load time. Each
    /// frame re-rasterizes via the cached WPETextRenderer (cache hits
    /// the common case) and draws atop the scene output.
    private var textRenderer: WPETextRenderer?
    private var textObjects: [WPESceneTextObject] = []
    /// Phase 2D-O: audio runtime publishing live FFT bins into the
    /// runtime uniform that audio-reactive shaders sample. Optional —
    /// scenes without sound objects skip this entirely.
    private var soundRuntime: WPESoundRuntime?
    /// Phase 2D-P: per-text-object SceneScript instances. Keyed by
    /// the text object's id so the renderer can look up the latest
    /// scripted value when rasterizing.
    private var textScriptInstances: [String: WPESceneScriptInstance] = [:]
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
    private var isThrottled = false
    private var currentProfile: WallpaperPerformanceProfile = .quality
    /// User-selected frame rate ceiling, applied to `mtkView.preferredFramesPerSecond`
    /// whenever the renderer is not throttled / suspended. Defaults to the
    /// WPE-compatible 30 FPS until `setFrameRateLimit(_:)` overrides it.
    private var userPreferredFPS: Int = WPEMetalSceneRenderer.defaultPreferredFPS
    /// Inspector mute state cached here so callers that arrive before
    /// `startSoundRuntime` can still record intent; `startSoundRuntime`
    /// reads these to seed `WPESoundRuntime` at the right level.
    private var pendingAudioMuted: Bool = false
    private var pendingAudioVolume: Double = 1.0

    private(set) var hasPresentedFrame = false
    private(set) var loadDiagnostics: SceneLoadDiagnostic?
    private(set) var renderGraph: WPERenderGraph?
    private(set) var renderPipeline: WPEPreparedRenderPipeline?
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
    /// CGImage readback of the most recent rendered frame; populated at the
    /// end of `performLoad()` so `WPESceneDetailView` can show a thumbnail
    /// instead of falling into `.previewUnavailable`. Refreshed by `reload()`
    /// and cleared by `cleanup()`.
    var previewSnapshot: NSImage? { cachedSnapshot }
    var onProgress: (@MainActor (String) -> Void)?
    var resolutionDiagnostics: WPEResolutionDiagnosticsSnapshot {
        resolutionTracer.snapshot()
    }

    init(
        descriptor: SceneDescriptor,
        cacheRootURL: URL,
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
        self.entryResolver = SceneResourceResolver(cacheRootURL: cacheRootURL)
        self.resourceResolver = WPEMultiRootResourceResolver(
            primaryRootURL: cacheRootURL,
            dependencyMounts: dependencyMounts,
            engineAssetsRootURL: effectiveEngineAssetsRootURL,
            tracer: resolutionTracer
        )
        self.resolutionTracer = resolutionTracer
        self.executor = executor
        self.textureLoader = WPEMetalTextureLoader(device: device)
        self.mtkView = MTKView(frame: frame, device: device)
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
        WPESceneDebugArtifacts.shared.appendLog(
            "load() began for \(descriptorSummary)",
            level: .info
        )
        Logger.debug(
            "[WPE-DEBUG][scene:\(descriptor.workshopID)][stage:load.begin] \(descriptorSummary)",
            category: .wpeRender
        )
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
            // Keep session open if the scene swaps to WebGL; the WebGL
            // session will overwrite scene-info but its dumps land in a
            // sibling folder so the Metal artifacts stay intact.
            WPESceneDebugArtifacts.shared.endSession()
            if let reason = Self.metalFallbackReason(for: error) {
                throw SceneRenderingError.metalRendererUnsupported(reason: reason)
            }
            throw error
        }
    }

    /// Classifies a `performLoad()` failure as Metal-specific versus generic
    /// (where both backends would hit the same problem). Returning a non-nil
    /// reason promotes the error to `SceneRenderingError.metalRendererUnsupported`;
    /// only automatic sessions use that as a WebGL fallback trigger.
    private static func metalFallbackReason(for error: Error) -> String? {
        switch error {
        case let context as WPEMetalTextureLoadContextError:
            return metalFallbackReason(for: context.underlying)
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
        Logger.warning(
            "Scene \(workshopID) resolution summary — events:\(snapshot.events.count) resolved:\(snapshot.resolvedCount) scene:\(counts[.scene, default: 0]) builtin:\(counts[.builtin, default: 0]) engineAssets:\(counts[.engineAssets, default: 0]) dependency:\(dependencyCount)",
            category: .screenManager
        )
        let missed = snapshot.missedRefs
        if !missed.isEmpty {
            let summary = missed.prefix(40)
                .map { "\($0.ref) → \($0.finalOutcome.debugLabel)" }
                .joined(separator: " | ")
            let suffix = missed.count > 40 ? " | +\(missed.count - 40) more" : ""
            Logger.warning(
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
        let entryURL = try entryResolver.resolveExistingFileURL(relativePath: descriptor.entryFile)
        let sceneDescriptor = descriptor
        let sceneCacheRoot = cacheRootURL
        let document = try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: entryURL)
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
        let graph = try await Task.detached(priority: .userInitiated) {
            try WPERenderGraphBuilder(
                cacheRootURL: cacheRoot,
                dependencyMounts: mounts,
                engineAssetsRootURL: engineRoot
            ).build(document: document)
        }.value
        debugStage("graph.build.done", "layers=\(graph.layers.count)")
        try Task.checkCancellation()

        debugStage("pipeline.build", "begin")
        onProgress?("Preparing render pipeline")
        let pipeline = try await Task.detached(priority: .userInitiated) {
            try WPERenderPipelineBuilder(
                cacheRootURL: cacheRoot,
                dependencyMounts: mounts,
                engineAssetsRootURL: engineRoot
            ).build(graph: graph)
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
        sceneRenderSize = cameraUniforms.renderSize
        debugStage("camera", "renderSize=\(Int(sceneRenderSize.width))x\(Int(sceneRenderSize.height))")

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

        debugStage("audio.start", "begin")
        onProgress?("Starting audio runtime")
        startSoundRuntime(from: document)
        debugStage("audio.start.done", "runtime=\(soundRuntime == nil ? "absent" : "active")")
        try Task.checkCancellation()

        debugStage("render.firstFrame", "begin")
        onProgress?("Rendering scene")

        let capture = beginGPUCaptureIfRequested()
        outputTexture = try renderCurrentFrame()
        capture?.stop()

        if let outputTexture {
            cachedSnapshot = snapshotter.snapshot(from: outputTexture)
            if let stats = WPEMetalTextureVisualStats.analyze(texture: outputTexture) {
                WPESceneDebugArtifacts.shared.recordFirstFrameStats(stats)
            }
            dumpOutputTextureIfRequested(outputTexture)
        }
        hasPresentedFrame = true
        didLoad = true
        applyPerformanceProfile(currentProfile)
        mtkView.setNeedsDisplay(mtkView.bounds)
        debugStage("render.firstFrame.done", "size=\(outputTexture?.width ?? 0)x\(outputTexture?.height ?? 0) snapshot=\(cachedSnapshot == nil ? "none" : "saved")")
        _ = id
    }

    /// Iterate every entry in `loadedTextures` and dump each to a PNG so we
    /// can verify whether the source-image upload actually carried bytes to
    /// the GPU. Same gate as the GPU trace + outputTexture dump.
    private func dumpLoadedTexturesIfRequested() {
        #if DEBUG
        let wantedID = UserDefaults.standard.string(forKey: "WPEMetalCaptureScene")
        guard let wantedID, !wantedID.isEmpty, wantedID == descriptor.workshopID else {
            return
        }
        for (path, texture) in loadedTextures {
            let safeName = path
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "\\", with: "_")
            dumpTextureToPNG(texture, basename: "tex-\(safeName)")
        }
        #endif
    }

    #if DEBUG
    private func dumpTextureToPNG(_ texture: MTLTexture, basename: String) {
        guard texture.pixelFormat == .rgba8Unorm || texture.pixelFormat == .rgba8Unorm_srgb else {
            Logger.warning(
                "[WPEMetalCaptureScene] texture dump: unsupported pixel format \(texture.pixelFormat.rawValue) for \(basename)",
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
            Logger.warning("[WPEMetalCaptureScene] texture dump: CGDataProvider failed for \(basename)", category: .wpeRender)
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
            Logger.warning("[WPEMetalCaptureScene] texture dump: CGImage failed for \(basename)", category: .wpeRender)
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
                Logger.warning("[WPEMetalCaptureScene] texture dump: PNG encode failed for \(basename)", category: .wpeRender)
                return
            }
            try png.write(to: url)
            Logger.notice("[WPEMetalCaptureScene] texture dump → \(url.path)", category: .wpeRender)
        } catch {
            Logger.warning(
                "[WPEMetalCaptureScene] texture dump failed for \(basename): \(error.localizedDescription)",
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
        let wantedID = UserDefaults.standard.string(forKey: "WPEMetalCaptureScene")
        guard let wantedID, !wantedID.isEmpty, wantedID == descriptor.workshopID else {
            return
        }
        let device = texture.device
        guard texture.pixelFormat == .rgba8Unorm || texture.pixelFormat == .rgba8Unorm_srgb else {
            Logger.warning(
                "[WPEMetalCaptureScene] outputTexture dump: unsupported pixel format \(texture.pixelFormat.rawValue)",
                category: .wpeRender
            )
            return
        }
        let bytesPerPixel = 4
        let bytesPerRow = texture.width * bytesPerPixel
        let totalBytes = bytesPerRow * texture.height
        guard let buffer = device.makeBuffer(length: totalBytes, options: .storageModeShared) else {
            Logger.warning("[WPEMetalCaptureScene] outputTexture dump: makeBuffer failed", category: .wpeRender)
            return
        }
        guard let queue = device.makeCommandQueue(),
              let cb = queue.makeCommandBuffer(),
              let blit = cb.makeBlitCommandEncoder() else {
            Logger.warning("[WPEMetalCaptureScene] outputTexture dump: cannot create blit encoder", category: .wpeRender)
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
            Logger.warning(
                "[WPEMetalCaptureScene] outputTexture dump: blit failed (status=\(cb.status.rawValue))",
                category: .wpeRender
            )
            return
        }

        let provider = CGDataProvider(dataInfo: nil, data: buffer.contents(), size: totalBytes) { _, _, _ in }
        guard let provider else {
            Logger.warning("[WPEMetalCaptureScene] outputTexture dump: CGDataProvider failed", category: .wpeRender)
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
            Logger.warning("[WPEMetalCaptureScene] outputTexture dump: CGImage failed", category: .wpeRender)
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
                Logger.warning("[WPEMetalCaptureScene] outputTexture dump: PNG encode failed", category: .wpeRender)
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
            Logger.warning(
                "[WPEMetalCaptureScene] outputTexture dump failed: \(error.localizedDescription)",
                category: .wpeRender
            )
        }
        #endif
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
        let wantedID = UserDefaults.standard.string(forKey: "WPEMetalCaptureScene")
        guard let wantedID, !wantedID.isEmpty, wantedID == descriptor.workshopID else {
            return nil
        }
        let manager = MTLCaptureManager.shared()
        guard manager.supportsDestination(.gpuTraceDocument) else {
            Logger.warning(
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
            Logger.warning(
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
            Logger.warning(
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
    private func debugStage(_ stage: String, _ detail: String) {
        let id = descriptor.workshopID
        Logger.debug(
            "[WPE-DEBUG][scene:\(id)][stage:\(stage)] \(detail)",
            category: .wpeRender
        )
        WPESceneDebugArtifacts.shared.appendLog("[\(stage)] \(detail)")
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
            runtimeUniforms: uniforms,
            cameraUniforms: cameraUniforms
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
        var uniforms = frameClock.runtimeUniforms(
            profile: currentProfile,
            pointerPosition: pointerSampler.sample(mtkView)
        )
        if let soundRuntime {
            uniforms = WPEMetalRuntimeUniforms(
                time: uniforms.time,
                daytime: uniforms.daytime,
                brightness: uniforms.brightness,
                pointerPosition: uniforms.pointerPosition,
                audioSpectrum: soundRuntime.currentSpectrum
            )
        }
        lastRuntimeUniforms = uniforms
        let currentTextures = texturesForCurrentFrame(time: uniforms.time)
        let frame = try executor.render(
            pipeline: pipeline,
            size: sceneRenderSize,
            textures: currentTextures,
            runtimeUniforms: uniforms,
            cameraUniforms: cameraUniforms
        )
        if !particleSystems.isEmpty {
            for system in particleSystems {
                system.tick(now: uniforms.time)
            }
            try executor.drawParticles(
                systems: particleSystems,
                texturesByMaterial: particleTextures,
                sceneSize: sceneRenderSize,
                output: frame
            )
        }
        if let textRenderer, !textObjects.isEmpty {
            var draws: [WPETextOverlayDraw] = []
            draws.reserveCapacity(textObjects.count)
            for object in textObjects where liveTextVisibility[object.id] ?? object.visible {
                let resolvedAlpha = object.resolvedAlpha(at: uniforms.time)
                guard resolvedAlpha > 0 else { continue }
                let liveObject: WPESceneTextObject
                if let instance = textScriptInstances[object.id] {
                    let updated = instance.tickString()
                    if updated != object.text {
                        liveObject = WPESceneTextObject(
                            id: object.id,
                            name: object.name,
                            text: updated,
                            textScript: object.textScript,
                            fontRelativePath: object.fontRelativePath,
                            pointSize: object.pointSize,
                            color: object.color,
                            alpha: resolvedAlpha,
                            alphaAnimation: object.alphaAnimation,
                            origin: object.origin,
                            scale: object.scale,
                            visible: object.visible,
                            horizontalAlignment: object.horizontalAlignment,
                            verticalAlignment: object.verticalAlignment,
                            maxWidth: object.maxWidth,
                            parallaxDepth: object.parallaxDepth
                        )
                    } else {
                        liveObject = WPESceneTextObject(
                            id: object.id,
                            name: object.name,
                            text: object.text,
                            textScript: object.textScript,
                            fontRelativePath: object.fontRelativePath,
                            pointSize: object.pointSize,
                            color: object.color,
                            alpha: resolvedAlpha,
                            alphaAnimation: object.alphaAnimation,
                            origin: object.origin,
                            scale: object.scale,
                            visible: object.visible,
                            horizontalAlignment: object.horizontalAlignment,
                            verticalAlignment: object.verticalAlignment,
                            maxWidth: object.maxWidth,
                            parallaxDepth: object.parallaxDepth
                        )
                    }
                } else {
                    liveObject = WPESceneTextObject(
                        id: object.id,
                        name: object.name,
                        text: object.text,
                        textScript: object.textScript,
                        fontRelativePath: object.fontRelativePath,
                        pointSize: object.pointSize,
                        color: object.color,
                        alpha: resolvedAlpha,
                        alphaAnimation: object.alphaAnimation,
                        origin: object.origin,
                        scale: object.scale,
                        visible: object.visible,
                        horizontalAlignment: object.horizontalAlignment,
                        verticalAlignment: object.verticalAlignment,
                        maxWidth: object.maxWidth,
                        parallaxDepth: object.parallaxDepth
                    )
                }
                guard let entry = textRenderer.rasterize(liveObject) else { continue }
                let halfWidth = Double(sceneRenderSize.width) * 0.5
                let halfHeight = Double(sceneRenderSize.height) * 0.5
                let center = SIMD2<Float>(
                    Float(liveObject.origin.x - halfWidth),
                    Float(liveObject.origin.y - halfHeight)
                )
                let scale = SIMD2<Float>(
                    Float(max(liveObject.scale.x, 0.0001)),
                    Float(max(liveObject.scale.y, 0.0001))
                )
                let scaledSize = CGSize(
                    width: entry.size.width * CGFloat(scale.x),
                    height: entry.size.height * CGFloat(scale.y)
                )
                draws.append(WPETextOverlayDraw(
                    texture: entry.texture,
                    centerInScenePixels: center,
                    sizeInScenePixels: scaledSize,
                    tint: SIMD3<Float>(
                        Float(liveObject.color.x),
                        Float(liveObject.color.y),
                        Float(liveObject.color.z)
                    ),
                    alpha: Float(liveObject.alpha)
                ))
            }
            if !draws.isEmpty {
                try executor.drawTextOverlays(
                    overlays: draws,
                    sceneSize: sceneRenderSize,
                    output: frame
                )
            }
        }
        return frame
    }

    /// Phase 2D-O: spin up the audio runtime and start playback if the scene declared sound objects.
    private func startSoundRuntime(from document: WPESceneDocument) {
        guard !document.soundObjects.isEmpty else {
            soundRuntime = nil
            return
        }
        let runtime = WPESoundRuntime(resolver: resourceResolver)
        // Seed the runtime with whatever pending inspector state arrived
        // before load completed — otherwise muting a scene before it
        // finishes loading would silently revert to the scene-declared
        // sound.volume the moment audio starts.
        runtime.setMuted(pendingAudioMuted)
        runtime.setMasterVolume(pendingAudioVolume)
        _ = runtime.start(sounds: document.soundObjects)
        soundRuntime = runtime
    }

    /// Phase 2D-N: build the WPETextRenderer + cache the parsed text object list.
    private func loadTextOverlays(from document: WPESceneDocument) {
        textObjects = document.textObjects
        guard !textObjects.isEmpty else {
            textRenderer = nil
            textScriptInstances.removeAll(keepingCapacity: false)
            return
        }
        textRenderer = WPETextRenderer(
            device: executor.textureSourceDevice,
            resolver: resourceResolver
        )
        textScriptInstances.removeAll(keepingCapacity: false)
        for object in textObjects {
            guard let script = object.textScript else { continue }
            if let instance = try? WPESceneScriptInstance(script: script, initialValue: object.text) {
                textScriptInstances[object.id] = instance
            }
        }
    }

    /// Material descriptor extracted from `passes[0]`. Only the fields the
    /// particle path needs — full material parsing lives in the generic
    /// pipeline builder.
    private struct ParticleMaterialDescriptor {
        let blendMode: WPEParticleBlendMode
        let firstTexturePath: String?
    }

    private func parseParticleMaterial(at relativePath: String) -> ParticleMaterialDescriptor? {
        guard let materialURL = try? entryResolver.resolveExistingFileURL(relativePath: relativePath),
              let materialData = try? Data(contentsOf: materialURL),
              let materialJSON = try? JSONSerialization.jsonObject(with: materialData) as? [String: Any],
              let passes = materialJSON["passes"] as? [[String: Any]],
              let firstPass = passes.first else {
            return nil
        }
        let blendString = firstPass["blending"] as? String
        let textures = firstPass["textures"] as? [Any]
        let firstTexturePath = textures?.first as? String
        return ParticleMaterialDescriptor(
            blendMode: WPEParticleBlendMode(materialString: blendString),
            firstTexturePath: firstTexturePath
        )
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
            guard let url = try? resourceResolver.resolveExistingFileURL(relativePath: probe),
                  let data = try? Data(contentsOf: url) else {
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
            var visited = Set<String>()
            var pending: [(path: String, parent: String?)] = [(object.particleRelativePath, nil)]
            while let next = pending.popLast() {
                let particlePath = resolvedParticleChildPath(next.path, parentPath: next.parent)
                guard visited.insert(particlePath).inserted else { continue }
                guard let parsedDefinition = loadParticleDefinition(at: particlePath) else {
                    debugStage("particle", "skip \(object.name) — particle definition load failed: \(particlePath)")
                    continue
                }
                let definition = parsedDefinition.applying(instanceOverride: object.instanceOverride)
                await registerParticleSystem(
                    definition: definition,
                    object: object,
                    particlePath: particlePath
                )
                for childPath in parsedDefinition.childRelativePaths.reversed() {
                    pending.append((childPath, particlePath))
                }
            }
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
        guard let particleURL = try? entryResolver.resolveExistingFileURL(relativePath: particlePath),
              let data = try? Data(contentsOf: particleURL) else {
            return nil
        }
        return WPEParticleDefinitionParser.parse(data: data)
    }

    private func registerParticleSystem(
        definition: WPEParticleDefinition,
        object: WPESceneParticleObject,
        particlePath: String
    ) async {
        let material = definition.materialRelativePath
            .flatMap(parseParticleMaterial(at:))
        let blendMode = material?.blendMode ?? .translucent
        let sceneTransform = makeParticleSceneTransform(for: object)
        guard let texturePath = material?.firstTexturePath else {
            debugStage("particle", "skip \(object.name) — material missing texture binding: \(particlePath)")
            return
        }
        guard let texturePayload = try? await makeTextureResource(
            relativePath: texturePath,
            label: "particle texture \(texturePath)"
        ) else {
            debugStage("particle", "skip \(object.name) — texture load failed: \(texturePath)")
            return
        }
        let texture: MTLTexture?
        switch texturePayload {
        case .staticTexture(let t):
            texture = t
        case .dynamicSource(let source):
            texture = source.texture(at: 0)
        }
        guard let resolved = texture else {
            debugStage("particle", "skip \(object.name) — dynamic source yielded no texture")
            return
        }
        let spriteSheet = parseParticleSpriteSheet(
            texturePath: texturePath,
            atlasPixelSize: (width: resolved.width, height: resolved.height)
        )
        guard let system = WPEParticleSystem(
            definition: definition,
            device: executor.textureSourceDevice,
            blendMode: blendMode,
            sceneTransform: sceneTransform,
            spriteSheet: spriteSheet
        ) else { return }
        // Spread `startDelay + 2s` worth of spawn/integration across
        // the first frame so the user doesn't see a one-particle-
        // per-frame cold start — matches WPE's behaviour where the
        // scene loads with a populated emitter.
        let prewarmSeconds = max(0, definition.startDelay) + 2.0
        system.prewarm(simulatedSeconds: prewarmSeconds)
        particleSystems.append(system)
        particleTextures[ObjectIdentifier(system)] = resolved
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
    }

    func reload() async throws {
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
        textScriptInstances.removeAll(keepingCapacity: false)
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

        for binding in patch.incrementalBindings {
            switch (binding.target, binding.kind) {
            case (.imageObject(let id), .visible):
                guard let value = patch.newValues[binding.propertyKey]?.boolValue else { return false }
                nextLayerVisibility[id] = value
            case (.textObject(let id), .visible):
                guard let value = patch.newValues[binding.propertyKey]?.boolValue else { return false }
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

    /// Resolves the effective `preferredFramesPerSecond` honouring the
    /// renderer-wide throttle (per-screen visibility) and the user's
    /// frame-rate ceiling. Performance profile is intentionally not a knob
    /// here — graduated FPS reduction conflicts with the user's per-screen
    /// cap, so the runtime only switches between full quality and suspended.
    private var effectivePreferredFramesPerSecond: Int {
        isThrottled ? Self.throttledPreferredFPS : userPreferredFPS
    }

    func setThrottled(_ throttled: Bool) {
        isThrottled = throttled
        guard currentProfile != .suspended else { return }
        mtkView.preferredFramesPerSecond = effectivePreferredFramesPerSecond
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
        mtkView.preferredFramesPerSecond = effectivePreferredFramesPerSecond
    }

    /// Forwards the inspector's mute toggle into the scene's audio
    /// runtime. Cached so calls that arrive before `startSoundRuntime`
    /// (which only fires from `performLoad`) still take effect once the
    /// runtime exists.
    func setAudioMuted(_ muted: Bool) {
        pendingAudioMuted = muted
        soundRuntime?.setMuted(muted)
    }

    /// Forwards the inspector's audio slider into the scene's audio
    /// runtime as a master gain multiplied into each scene-declared
    /// `sound.volume`. Cached so pre-load calls survive across the
    /// `startSoundRuntime` boundary.
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
        !dynamicTextureSources.isEmpty || !particleSystems.isEmpty
    }

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        currentProfile = profile
        dynamicTextureSources.values.forEach { $0.applyPerformanceProfile(profile) }
        switch profile {
        case .quality:
            mtkView.isPaused = !needsContinuousFrames
            mtkView.enableSetNeedsDisplay = !needsContinuousFrames
            mtkView.preferredFramesPerSecond = effectivePreferredFramesPerSecond
        case .suspended:
            mtkView.isPaused = true
            mtkView.enableSetNeedsDisplay = true
            mtkView.releaseDrawables()
            executor.releaseTransientResources()
        }
    }

    func cleanup() {
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
        textScriptInstances.removeAll(keepingCapacity: false)
        soundRuntime?.stop()
        soundRuntime = nil
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
                _ = try executor.present(texture: texture, in: view)
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

    private func loadTextures(for pipeline: WPEPreparedRenderPipeline) async throws {
        loadedTextures = [:]
        dynamicTextureSources = [:]

        for layer in pipeline.layers {
            try Task.checkCancellation()
            if layer.passes.isEmpty {
                try await loadTexture(
                    reference: .image(layer.graphLayer.imagePath),
                    layerName: layer.graphLayer.objectName
                )
                continue
            }
            for preparedPass in layer.passes {
                for reference in requiredTextureReferences(for: preparedPass) {
                    try Task.checkCancellation()
                    try await loadTexture(
                        reference: reference,
                        layerName: layer.graphLayer.objectName
                    )
                }
            }
        }
    }

    private func loadTexture(
        reference: WPETextureReference,
        layerName: String
    ) async throws {
        guard let path = externalTexturePath(for: reference),
              loadedTextures[path] == nil,
              dynamicTextureSources[path] == nil else {
            return
        }
        do {
            let resource = try await makeTextureResource(relativePath: path, label: "WPE texture \(path)")
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
        let url = try await WPEVideoTextureSource.persistVideoData(
            videoPayload.bytes,
            cacheDirectory: Self.videoCacheDirectory()
        )
        do {
            let source = try WPEVideoTextureSource(
                device: executor.textureSourceDevice,
                videoURL: url
            )
            _ = label
            return source
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private static func videoCacheDirectory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("wpe-tex-video", isDirectory: true)
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
        var textures = loadedTextures
        var dynamicFrameLog: [String] = []
        for (path, source) in dynamicTextureSources {
            if let texture = source.texture(at: time) {
                textures[path] = texture
                loadedTextures[path] = texture
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
        if time - lastHeartbeatTime >= 10.0 || lastHeartbeatTime < 0 {
            lastHeartbeatTime = time
            let scene = "\(Int(sceneRenderSize.width))x\(Int(sceneRenderSize.height))"
            let output = outputTexture.map { "\($0.width)x\($0.height)" } ?? "nil"
            let dyn = dynamicFrameLog.isEmpty ? "none" : dynamicFrameLog.joined(separator: " ")
            debugStage("heartbeat", "t=\(String(format: "%.2f", time))s scene=\(scene) output=\(output) dynamic=\(dyn)")
        }
        return textures
    }

    private func releaseDynamicTextureSources() {
        dynamicTextureSources.values.forEach { $0.invalidate() }
        dynamicTextureSources.removeAll()
        loadedTextures.removeAll()
    }

    private func shouldTryTexturePayload(_ path: String) -> Bool {
        let extensionName = (path as NSString).pathExtension.lowercased()
        return !Self.knownRawImageExtensions.contains(extensionName)
    }

    /// Raster image extensions that `WPETextureLoader` can load via ImageIO
    /// without going through the `.tex` container. Path lookups ending in one
    /// of these are taken at face value; anything else (including names that
    /// merely *look* like they end in an extension because they contain a dot)
    /// goes through the materials/-prefix fallback below.
    static let knownRawImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "tga", "dds", "bmp", "gif", "webp"
    ]

    /// Visible to `@testable` test suites that probe the candidate generator without spinning up a full renderer fixture.
    func textureCandidates(for path: String) -> [String] {
        let extensionName = (path as NSString).pathExtension.lowercased()
        if !extensionName.isEmpty,
           Self.knownRawImageExtensions.contains(extensionName) || extensionName == "tex" || extensionName == "json" {
            return [path]
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
