#if !LITE_BUILD
import AppKit
import MetalKit

extension WPEMetalSceneRenderer {
    // MARK: - Load entry point

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

    // MARK: - Failure diagnostics

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

    // MARK: - Scene construction

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
        // First-evaluation seeding, in WPE order: script hosts (pure compute
        // producers, e.g. 3509243656's MAIN n-body sim writing shared.xx*/ktime)
        // update once FIRST, then transform + text consumers seed. Seeding texts
        // inside loadTextOverlays ran consumers before the producer existed —
        // tooltip scripts threw and the `time` script NaN-poisoned itself.
        seedSceneScriptsAfterLoad(from: document)
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

    // MARK: - Deferred audio startup

    /// Boot the sound runtime once the first frame has actually presented (called
    /// from `draw(in:)` after the first successful `present`). The expensive
    /// `prepare(sounds:)` (file loads + buffer decode, ~300-900ms) runs OFF the
    /// main actor so the wallpaper never stalls but produces NO audio. Playback
    /// (`play()`) only starts back on the main actor, AFTER confirming the scene
    /// is still current — so a reload/cleanup during preparation can never let a
    /// stale scene's audio play (it just releases the prepared engine). Mute and
    /// volume are re-applied with the latest values immediately before `play()`,
    /// so a toggle during the off-main window is honored before any sound.
    func beginDeferredAudioStartup() {
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
}
#endif
