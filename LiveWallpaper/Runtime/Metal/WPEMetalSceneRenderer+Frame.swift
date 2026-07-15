#if !LITE_BUILD
import AppKit
import MetalKit

extension WPEMetalSceneRenderer {
    // MARK: - Script tick dispatch (ADR-003 step 1)

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
    func dispatchScriptCursorEvent(
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
    func applyScriptUserProperties(
        _ instance: WPELayerScriptInstance,
        _ properties: [String: WPESceneScriptPropertyValue],
        runtimeSeconds: Double? = nil
    ) -> WPELayerScriptOutput? {
        Self.scriptAsyncTickEnabled
            ? instance.applyUserPropertiesSuperseding(properties, runtimeSeconds: runtimeSeconds)
            : instance.applyUserProperties(properties, runtimeSeconds: runtimeSeconds)
    }

    // MARK: - Frame rendering

    /// Computes one frame's runtime uniforms (clock, daytime, brightness, pointer) and submits the render pipeline with both runtime and camera uniforms.
    func renderCurrentFrame() throws -> MTLTexture {
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

    // MARK: - Per-frame script & particle ticks

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
        dispatchPointerButtonEdges(
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

    struct LiveScriptTransforms {
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
            || !dynamicAnglesScriptInstances.isEmpty
            || !dynamicOriginAnimations.isEmpty else { return nil }
        var transforms = LiveScriptTransforms()
        transforms.origins.reserveCapacity(
            dynamicOriginScriptInstances.count + dynamicOriginAnimations.count
        )
        // Keyframed origins first so an origin SCRIPT on the same object still
        // wins (scripts are the live authority; the track is the authored path).
        for (objectID, animation) in dynamicOriginAnimations.sorted(by: { $0.key < $1.key }) {
            guard let v = animation.vector(at: time), v.count >= 3 else { continue }
            transforms.origins[objectID] = SIMD3<Double>(v[0], v[1], v[2])
        }
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
}
#endif
