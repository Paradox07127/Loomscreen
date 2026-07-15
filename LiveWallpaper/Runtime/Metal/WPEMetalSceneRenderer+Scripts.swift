#if !LITE_BUILD
import AppKit
import MetalKit

extension WPEMetalSceneRenderer {
    // MARK: - Script loading & seeding

    /// Builds a `WPELayerScriptInstance` per image object whose `visible` field
    /// is a SceneScript, maps each to its video source, and applies the script's
    /// `init()` state (visibility/alpha + video stop/seek). Runs after textures so
    /// the video sources exist. No-op for scenes without layer scripts.
    func loadLayerScripts(from document: WPESceneDocument) {
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
    func applyTextScriptOutput(_ output: WPELayerScriptOutput, ownObjectID: String) {
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

    /// One deterministic "frame 0" evaluation pass over the scene's scripts, run
    /// once at the end of load — PRODUCERS FIRST. WPE ticks every script serially
    /// in scene-object order each frame, so a `shared`-consuming script never
    /// evaluates before the producers that precede it. Our per-load seeding used
    /// to run inside each loader (texts before the layer scripts even existed);
    /// a consumer's first evaluation then read an empty `shared` — worst case
    /// permanently corrupting its own module state (3509243656's `time` script
    /// accumulates `undefined` arithmetic into NaN, and its self-reset keys off
    /// `shared.xntime === undefined`, which that same broken tick already set to
    /// NaN — "frozen at NaN Years" forever). Order here: script hosts (pure
    /// compute producers, e.g. MAIN's n-body sim writing shared.xx*/ktime) run
    /// one update() each, then transform + text-content consumers seed.
    /// Async mode only: legacy sync ticks already run layer scripts before text
    /// scripts inside every frame, so their first frame is producer-first.
    func seedSceneScriptsAfterLoad(from document: WPESceneDocument) {
        guard Self.scriptAsyncTickEnabled else { return }
        // 1. Script hosts: one bounded synchronous update() each, in scene
        //    order, applied exactly like a frame tick.
        for host in document.scriptHostObjects {
            guard let instance = layerScriptInstances[host.id] else { continue }
            if let output = instance.tick(runtimeSeconds: 0, pointerFrame: .neutral) {
                applyLayerScriptOutput(output, ownObjectID: host.id)
            }
        }
        // 2. Transform scripts, neutral pointer (the frame path's
        //    follow-cursor-off default) — first frame shows the scripted
        //    transform instead of popping from the baked value.
        let neutralPointer = SIMD2<Double>(0.5, 0.5)
        for instances in [
            dynamicOriginScriptInstances,
            dynamicScaleScriptInstances,
            dynamicAnglesScriptInstances
        ] {
            for (_, instance) in instances.sorted(by: { $0.key < $1.key }) {
                instance.seedAsyncTick(pointerPosition: neutralPointer)
            }
        }
        // 3. Text-content scripts, in scene-object order (hidden compute texts
        //    write shared.txtN that later data texts read — 三体's 日志).
        for object in textObjects {
            textScriptInstances[object.id]?.seedAsyncTick()
        }
    }

    /// Builds dynamic origin script instances for image layers whose `origin`
    /// SceneScript depends on live input. Static origin scripts were resolved by
    /// `WPESceneDocumentParser`, so they do not reach this path.
    func loadDynamicOriginScripts(from document: WPESceneDocument) {
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
        // Keyframed origins ride the same live-transform map as the scripts, so a
        // moving transform host composes onto its children exactly the same way.
        dynamicOriginAnimations = Dictionary(
            document.transformHostObjects.compactMap { object -> (String, WPESceneAnimatedValue)? in
                object.originAnimation.map { (object.id, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        debugStage(
            "transformScripts.load",
            "origin=\(originScripts.count) scale=\(scaleScripts.count) angles=\(anglesScripts.count) originAnim=\(dynamicOriginAnimations.count) hosts=\(document.transformHostObjects.count)"
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
                    // Seeded in seedSceneScriptsAfterLoad() — after the script
                    // hosts have produced their first `shared` state (a tooltip
                    // origin script reading `shared.xxN` must not run first).
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

    // MARK: - On-demand video layers

    /// Index video layers whose every pass targets `.scene` (so they're never a
    /// hidden composite/FBO source another layer samples) — only these are safe to
    /// release when hidden, since the executor skips a hidden scene pass entirely.
    func indexOnDemandVideoLayers(pipeline: WPEPreparedRenderPipeline) {
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

    static func createdLayerTemplatesByImagePath(
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
    func reconcileVideoResidency(_ framePipeline: WPEPreparedRenderPipeline) {
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

    // MARK: - User properties

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

    static func bridgeUserProperties(
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

    // MARK: - Intro phase align

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
    func updateIntroPhaseAlign() {
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

    // MARK: - Pointer events

    /// Per-layer hover transitions (`cursorEnter`/`cursorLeave`): hit-tests the
    /// pointer against each scripted layer's screen rect (axis-aligned; ortho =
    /// origin-centered size×scale, perspective = projected center + depth-scaled
    /// size) and dispatches only on state change. `pointer` nil (follow-cursor
    /// off / outside the view) counts as leaving everything. WPE fires these
    /// without click capture — hover only needs the cursor position.
    func dispatchLayerHoverEvents(
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

    /// Detects button edges between two pointer frames and fans each one out to
    /// every layer/alpha script instance.
    func dispatchPointerButtonEdges(
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

    // MARK: - Script output application

    /// Applies a layer script's full output: its own layer plus any layers it
    /// drove via `thisScene.getLayer(name)` (resolved name→objectID).
    func applyLayerScriptOutput(_ output: WPELayerScriptOutput, ownObjectID: String) {
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

    func applyLayerAlphaScriptOutput(_ output: WPELayerScriptOutput, ownObjectID: String) {
        liveLayerAlpha[ownObjectID] = output.own.alpha
    }

    // MARK: - Static-cache exclusion & ancestor visibility

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

    var staticCacheExcludedLayerIDs: Set<String> {
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

    func ancestorChainVisible(_ objectID: String) -> Bool {
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
}
#endif
