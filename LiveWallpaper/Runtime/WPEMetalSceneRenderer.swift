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
final class WPEMetalSceneRenderer: NSObject, WPESceneRenderer, MTKViewDelegate {
    /// Default frame rate target when not throttled. `MTKView` clamps this
    /// to the display's refresh rate so 60 means "render every vsync".
    static let defaultPreferredFPS = 60
    /// Frame rate target when an external coordinator wants the renderer
    /// out of the way (e.g. console window in focus, multi-display
    /// exclusive rendering takeover). 1fps keeps the timer alive so we can
    /// bounce back when throttling is released.
    static let throttledPreferredFPS = 1

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

    private(set) var hasPresentedFrame = false
    private(set) var loadDiagnostics: SceneLoadDiagnostic?
    private(set) var renderGraph: WPERenderGraph?
    private(set) var renderPipeline: WPEPreparedRenderPipeline?
    private(set) var lastRuntimeUniforms: WPEMetalRuntimeUniforms?
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
        self.activeEngineAssetsRootURL = didStartEngineAssetsAccess ? engineAssetsRootURL : nil
        self.entryResolver = SceneResourceResolver(cacheRootURL: cacheRootURL)
        self.resourceResolver = WPEMultiRootResourceResolver(
            primaryRootURL: cacheRootURL,
            dependencyMounts: dependencyMounts,
            engineAssetsRootURL: engineAssetsRootURL,
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
        do {
            try await performLoad()
            loadDiagnostics = nil
        } catch {
            loadDiagnostics = diagnostic(for: error)
            logSceneFailureDiagnostics(error: error)
            throw error
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
        onProgress?("Reading scene")
        try Task.checkCancellation()
        let entryURL = try entryResolver.resolveExistingFileURL(relativePath: descriptor.entryFile)
        let document = try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: entryURL)
            return try WPESceneDocumentParser.parse(data: data)
        }.value
        try Task.checkCancellation()

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
        try Task.checkCancellation()

        onProgress?("Preparing render pipeline")
        let pipeline = try await Task.detached(priority: .userInitiated) {
            try WPERenderPipelineBuilder(
                cacheRootURL: cacheRoot,
                engineAssetsRootURL: engineRoot
            ).build(graph: graph)
        }.value
        try Task.checkCancellation()

        renderGraph = graph
        renderPipeline = pipeline
        cameraUniforms = WPEMetalCameraUniforms(
            orthogonalProjection: document.general.orthogonalProjection,
            sceneCamera: document.camera
        )
        sceneRenderSize = cameraUniforms.renderSize

        onProgress?("Loading textures")
        try await loadTextures(for: pipeline)
        try Task.checkCancellation()

        onProgress?("Loading particle systems")
        await loadParticleSystems(from: document)
        try Task.checkCancellation()

        onProgress?("Loading text overlays")
        loadTextOverlays(from: document)
        try Task.checkCancellation()

        onProgress?("Starting audio runtime")
        startSoundRuntime(from: document)
        try Task.checkCancellation()

        onProgress?("Rendering scene")
        outputTexture = try renderCurrentFrame()
        if let outputTexture {
            cachedSnapshot = snapshotter.snapshot(from: outputTexture)
        }
        hasPresentedFrame = true
        didLoad = true
        applyPerformanceProfile(currentProfile)
        mtkView.setNeedsDisplay(mtkView.bounds)
    }

    /// Computes one frame's runtime uniforms (clock, daytime, brightness, pointer) and submits the render pipeline with both runtime and camera uniforms.
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
            for object in textObjects where object.visible && object.alpha > 0 {
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
                            alpha: object.alpha,
                            origin: object.origin,
                            scale: object.scale,
                            visible: object.visible,
                            horizontalAlignment: object.horizontalAlignment,
                            verticalAlignment: object.verticalAlignment,
                            maxWidth: object.maxWidth,
                            parallaxDepth: object.parallaxDepth
                        )
                    } else {
                        liveObject = object
                    }
                } else {
                    liveObject = object
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
        let attachedCount = runtime.start(sounds: document.soundObjects)
        if attachedCount == 0 {
        }
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

    /// Spawn one `WPEParticleSystem` per parsed particle object.
    private func loadParticleSystems(from document: WPESceneDocument) async {
        particleSystems.removeAll(keepingCapacity: true)
        particleTextures.removeAll(keepingCapacity: true)
        for object in document.particleObjects where object.visible {
            guard let particleURL = try? entryResolver.resolveExistingFileURL(relativePath: object.particleRelativePath),
                  let data = try? Data(contentsOf: particleURL),
                  let definition = WPEParticleDefinitionParser.parse(data: data) else {
                continue
            }
            guard let system = WPEParticleSystem(
                definition: definition,
                device: executor.textureSourceDevice
            ) else {
                continue
            }
            particleSystems.append(system)
            if let materialPath = definition.materialRelativePath,
               let materialURL = try? entryResolver.resolveExistingFileURL(relativePath: materialPath),
               let materialData = try? Data(contentsOf: materialURL),
               let materialJSON = try? JSONSerialization.jsonObject(with: materialData) as? [String: Any],
               let passes = materialJSON["passes"] as? [[String: Any]],
               let firstPass = passes.first,
               let textures = firstPass["textures"] as? [Any],
               let firstTexturePath = textures.first as? String,
               let texturePayload = try? await makeTextureResource(
                    relativePath: firstTexturePath,
                    label: "particle texture \(firstTexturePath)"
               ) {
                switch texturePayload {
                case .staticTexture(let texture):
                    particleTextures[ObjectIdentifier(system)] = texture
                case .dynamicSource(let source):
                    if let texture = source.texture(at: 0) {
                        particleTextures[ObjectIdentifier(system)] = texture
                    }
                }
            }
        }
    }

    func reload() async throws {
        didLoad = false
        hasPresentedFrame = false
        outputTexture = nil
        renderGraph = nil
        renderPipeline = nil
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

    func setThrottled(_ throttled: Bool) {
        isThrottled = throttled
        guard currentProfile != .suspended else { return }
        mtkView.preferredFramesPerSecond = throttled
            ? Self.throttledPreferredFPS
            : Self.defaultPreferredFPS
    }

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        currentProfile = profile
        dynamicTextureSources.values.forEach { $0.applyPerformanceProfile(profile) }
        switch profile {
        case .quality:
            let hasDynamic = !dynamicTextureSources.isEmpty
            mtkView.isPaused = !hasDynamic
            mtkView.enableSetNeedsDisplay = !hasDynamic
            mtkView.preferredFramesPerSecond = isThrottled
                ? Self.throttledPreferredFPS
                : Self.defaultPreferredFPS
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
                if dynamicTextureSources.isEmpty {
                    textureToPresent = outputTexture
                } else {
                    let frame = try renderCurrentFrame()
                    outputTexture = frame
                    textureToPresent = frame
                }
                guard let texture = textureToPresent else { return }
                if try executor.present(texture: texture, in: view) {
                    SystemMonitor.shared.tickFrame()
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
        let source = try WPEVideoTextureSource(
            device: executor.textureSourceDevice,
            videoURL: url
        )
        _ = label
        return source
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
        for (path, source) in dynamicTextureSources {
            if let texture = source.texture(at: time) {
                textures[path] = texture
                loadedTextures[path] = texture
            }
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
            case .unsupportedTarget:
                return .materialUnresolved(layer: layerName, reason: "This wallpaper uses an unsupported rendering target.")
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
