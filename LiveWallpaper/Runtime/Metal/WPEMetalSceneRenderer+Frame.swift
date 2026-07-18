#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import MetalKit
import os

extension WPEMetalSceneRenderer {
    // MARK: - Frame instrumentation

    /// Phase-level os_signpost intervals for the per-frame render. Always on;
    /// with no Instruments observer the emit cost is negligible. Read the stages
    /// with the os_signpost template to size Phase 2's off-main move.
    static let frameSignposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "com.taijia.LiveWallpaper",
        category: "WPEFrame"
    )

    /// Wraps a discrete render stage in an os_signpost interval.
    @inline(__always)
    func withFrameSignpost<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let signposter = Self.frameSignposter
        let state = signposter.beginInterval(name, id: signposter.makeSignpostID())
        defer { signposter.endInterval(name, state) }
        return try body()
    }

    // MARK: - Frame rendering

    /// Snapshots the pointer inputs `renderCurrentFrame` needs from the mailbox
    /// (fed by the surface's publisher + view). The frame-rate field is the
    /// renderer's own `effectiveFPS` — the diagnostic reader (audio log) only, and
    /// exactly the value the surface applies to the view. See `WPEFrameInputs`.
    func makeFrameInputs() -> WPEFrameInputs {
        let pointer = mailbox.read()
        return WPEFrameInputs(
            clickCaptureEnabled: pointer.clickCaptureEnabled,
            pointerSample: pointerSampler.sample(),
            pointerFrame: pointer.pointerFrame,
            preferredFramesPerSecond: effectiveFPS
        )
    }

    /// Computes one frame's runtime uniforms (clock, daytime, brightness, pointer) and submits the render pipeline with both runtime and camera uniforms.
    func renderCurrentFrame(inputs: WPEFrameInputs) throws -> MTLTexture {
        let signposter = Self.frameSignposter
        let frameState = signposter.beginInterval(
            "frame",
            id: signposter.makeSignpostID(),
            "scene:\(self.descriptor.workshopID, privacy: .public) renderer:\(self.sceneScriptTraversalDomainID, privacy: .public)"
        )
        defer { signposter.endInterval("frame", frameState) }

        guard let pipeline = renderPipeline else {
            throw WPEMetalRenderExecutorError.noRenderablePasses
        }
        let frameContext = withFrameSignpost("sampleContext") {
            sampleFrameContext(inputs: inputs)
        }
        let uniforms = frameContext.uniforms
        let scriptState = signposter.beginInterval("scriptTick", id: signposter.makeSignpostID())
        let scriptTraversalEpoch = WPESceneScriptTraversalEpoch.next(
            domainID: sceneScriptTraversalDomainID
        )
        let scriptFailureBeforeFrame = sceneScriptLoadState.currentFailureReason
        let publicationBeforeFrame = captureSceneScriptFramePublication()
        beginSceneScriptVideoCommands()
        var didFinishSceneScriptVideoCommands = false
        defer {
            if !didFinishSceneScriptVideoCommands {
                discardSceneScriptVideoCommands()
            }
            WPESceneScriptExecutionGovernor.processShared.completeTraversal(
                scriptTraversalEpoch
            )
            // Static/on-demand renderers may have no next traversal in which to
            // renew or retire a reservation. Do not leave their domain queued.
            if !needsContinuousFrames || currentProfile != .quality {
                WPESceneScriptExecutionGovernor.processShared.cancelReservations(
                    domainID: sceneScriptTraversalDomainID
                )
            }
        }
        var framePipeline = applyingLayerScriptTicks(
            to: pipeline,
            uniforms: uniforms,
            layerScriptPointerFrame: frameContext.layerScriptPointerFrame,
            traversalEpoch: scriptTraversalEpoch
        )
        // Kept around past the pipeline application so the text-overlay pass can
        // re-compose text anchors through the SAME live parent transforms.
        let authoredTransforms = authoredTransformAnimations(at: uniforms.time)
        var liveScriptTransforms = lastStableScriptTransforms
        if let ticked = tickDynamicTransformScripts(
            pointer: frameContext.pointer,
            time: uniforms.time,
            traversalEpoch: scriptTraversalEpoch
        ) {
            if scriptFailureBeforeFrame == nil,
               sceneScriptLoadState.currentFailureReason == nil {
                liveScriptTransforms = ticked
            }
        }
        var liveTransforms = LiveScriptTransforms.resolving(
            authored: authoredTransforms,
            script: liveScriptTransforms
        )
        if !liveTransforms.isEmpty {
            framePipeline = framePipeline.applyingLayerTransforms(
                origins: liveTransforms.origins,
                scales: liveTransforms.scales,
                angles: liveTransforms.angles,
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
        let tickedTextByID = tickTextContentScripts(
            traversalEpoch: scriptTraversalEpoch
        )
        let liveTextByID: [String: String]
        if scriptFailureBeforeFrame == nil,
           let failure = sceneScriptLoadState.currentFailureReason {
            invalidateIntroPhaseAlign()
            restoreSceneScriptPresentation(publicationBeforeFrame.presentation)
            liveScriptTransforms = lastStableScriptTransforms
            liveTransforms = .resolving(
                authored: authoredTransforms,
                script: liveScriptTransforms
            )
            liveTextByID = lastStableScriptTextByID
            framePipeline = applyingSceneScriptPresentation(
                to: pipeline,
                transforms: liveTransforms
            )
            Logger.warning(
                "Scene \(descriptor.workshopID) froze its last stable SceneScript presentation: \(failure)",
                category: .wpeRender
            )
        } else if sceneScriptLoadState.currentFailureReason == nil {
            lastStableScriptTransforms = liveScriptTransforms
            lastStableScriptTextByID = tickedTextByID
            liveTextByID = tickedTextByID
            if !liveCreatedLayers.isEmpty {
                framePipeline = framePipeline.addingCreatedLayers(
                    liveCreatedLayers,
                    templatesByImagePath: createdLayerTemplatesByImagePath
                )
            }
        } else {
            liveScriptTransforms = lastStableScriptTransforms
            liveTransforms = .resolving(
                authored: authoredTransforms,
                script: liveScriptTransforms
            )
            liveTextByID = lastStableScriptTextByID
            framePipeline = applyingSceneScriptPresentation(
                to: pipeline,
                transforms: liveTransforms
            )
        }
        lastFramePipeline = framePipeline
        signposter.endInterval("scriptTick", scriptState)
        // Keep only currently-visible on-demand videos resident (releases hidden
        // ones, rebuilds revealed ones). No-op unless the scene has releasable
        // videos; reads the final per-frame visibility so it covers script-,
        // user-property- and condition-driven switches alike.
        withFrameSignpost("videoReconcile") {
            reconcileVideoResidency(framePipeline)
        }
        withFrameSignpost("particleTick") {
            tickParticleSystems(
                time: uniforms.time,
                followPointerIsLive: frameContext.followPointerIsLive,
                pointer: frameContext.pointer,
                liveTransforms: liveTransforms
            )
        }
        let frame = try encodeSceneFrame(
            pipeline: framePipeline,
            uniforms: uniforms,
            liveTextByID: liveTextByID,
            transforms: liveTransforms,
            parallaxFrame: frameContext.parallaxFrame
        )
        didFinishSceneScriptVideoCommands = true
        return try finishSceneScriptFrame(
            speculativeFrame: frame,
            failureBeforeFrame: scriptFailureBeforeFrame,
            publicationBeforeFrame: publicationBeforeFrame,
            basePipeline: pipeline,
            uniforms: uniforms,
            authoredTransforms: authoredTransforms,
            parallaxFrame: frameContext.parallaxFrame
        )
    }

    func encodeSceneFrame(
        pipeline: WPEPreparedRenderPipeline,
        uniforms: WPEMetalRuntimeUniforms,
        liveTextByID: [String: String],
        transforms: LiveScriptTransforms,
        parallaxFrame: WPECameraParallaxFrame
    ) throws -> MTLTexture {
        let frame = try withFrameSignpost("encode") { () throws -> MTLTexture in
            let currentTextures = try texturesForCurrentFrame(time: uniforms.time, pipeline: pipeline)
            return try executor.render(
                pipeline: pipeline,
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
                particleParallax: parallaxFrame
            )
        }
        try withFrameSignpost("textOverlay") {
            try drawLiveTextOverlays(
                onto: frame,
                uniforms: uniforms,
                liveTextByID: liveTextByID,
                transforms: transforms,
                parallaxFrame: parallaxFrame
            )
        }
        return frame
    }

    func recordSceneFrameForDebug(time: Double, composite: MTLTexture) {
        #if DEBUG
        maybeDumpScenePassesOverTime(time: time, composite: composite)
        #endif
    }

    // MARK: - Per-frame script & particle ticks

    /// Tick layer SceneScripts (e.g. a video intro that plays once then hides):
    /// each drives its layer's visibility/alpha + video playback. Gated so a
    /// scene with no layer scripts pays nothing (no per-frame pipeline rebuild).
    private func applyingLayerScriptTicks(
        to pipeline: WPEPreparedRenderPipeline,
        uniforms: WPEMetalRuntimeUniforms,
        layerScriptPointerFrame: WPEPointerFrame,
        traversalEpoch: WPESceneScriptTraversalEpoch
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
            if let output = tickLayerScript(
                instance,
                runtimeSeconds: uniforms.time,
                pointerFrame: layerScriptPointerFrame,
                traversalEpoch: traversalEpoch
            ) {
                applyLayerScriptOutput(output, ownObjectID: objectID)
            }
        }
        for (objectID, instance) in layerAlphaScriptInstances.sorted(by: { $0.key < $1.key }) {
            if let output = tickLayerScript(
                instance,
                runtimeSeconds: uniforms.time,
                pointerFrame: layerScriptPointerFrame,
                traversalEpoch: traversalEpoch
            ) {
                applyLayerAlphaScriptOutput(output, ownObjectID: objectID)
            }
        }
        for (objectID, instance) in textVisibleScriptInstances.sorted(by: { $0.key < $1.key }) {
            if let output = tickLayerScript(
                instance,
                runtimeSeconds: uniforms.time,
                pointerFrame: layerScriptPointerFrame,
                traversalEpoch: traversalEpoch
            ) {
                applyTextScriptOutput(output, ownObjectID: objectID)
            }
        }
        for (objectID, instance) in textAlphaScriptInstances.sorted(by: { $0.key < $1.key }) {
            if let output = tickLayerScript(
                instance,
                runtimeSeconds: uniforms.time,
                pointerFrame: layerScriptPointerFrame,
                traversalEpoch: traversalEpoch
            ) {
                liveTextAlpha[objectID] = output.own.alpha
            }
        }
        stageIntroPhaseAlign()
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
        time: Double,
        traversalEpoch: WPESceneScriptTraversalEpoch
    ) -> LiveScriptTransforms? {
        guard !dynamicOriginScriptInstances.isEmpty
            || !dynamicScaleScriptInstances.isEmpty
            || !dynamicAnglesScriptInstances.isEmpty else { return nil }
        var transforms = LiveScriptTransforms()
        transforms.origins.reserveCapacity(dynamicOriginScriptInstances.count)
        // Sorted by objectID for the same shared-state-determinism reason as the
        // layer/text script loops above.
        for (objectID, instance) in dynamicOriginScriptInstances.sorted(by: { $0.key < $1.key }) {
            if let origin = tickTransformScript(
                instance,
                pointer: pointer,
                runtimeSeconds: time,
                traversalEpoch: traversalEpoch
            ) {
                transforms.origins[objectID] = origin
            }
        }
        transforms.scales.reserveCapacity(dynamicScaleScriptInstances.count)
        for (objectID, instance) in dynamicScaleScriptInstances.sorted(by: { $0.key < $1.key }) {
            if let scale = tickTransformScript(
                instance,
                pointer: pointer,
                runtimeSeconds: time,
                traversalEpoch: traversalEpoch
            ) {
                transforms.scales[objectID] = scale
            }
        }
        transforms.angles.reserveCapacity(dynamicAnglesScriptInstances.count)
        for (objectID, instance) in dynamicAnglesScriptInstances.sorted(by: { $0.key < $1.key }) {
            if let angle = tickTransformScript(
                instance,
                pointer: pointer,
                runtimeSeconds: time,
                traversalEpoch: traversalEpoch
            ) {
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
        pointer: SIMD2<Double>,
        liveTransforms: LiveScriptTransforms
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
        updateParticleHostOriginOffsets(using: liveTransforms)
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
    private func tickTextContentScripts(
        traversalEpoch: WPESceneScriptTraversalEpoch
    ) -> [String: String] {
        var liveTextByID: [String: String] = [:]
        liveTextByID.reserveCapacity(textScriptInstances.count)
        // Sorted by objectID: hidden compute-scripts write `shared` state that the
        // visible data texts then read (三体 3509243656), so tick order changes the
        // rendered text. Dictionary order was arbitrary — a fixed order makes the
        // oracle trace deterministic and the render reproducible.
        for (id, instance) in textScriptInstances.sorted(by: { $0.key < $1.key }) {
            liveTextByID[id] = tickTextScript(
                instance,
                traversalEpoch: traversalEpoch
            )
        }
        return liveTextByID
    }
}
#endif
