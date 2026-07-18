#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import LiveWallpaperProWPE
import MetalKit

extension WPEMetalSceneRenderer {

    // MARK: - Reload & scene property patching

    func reload(on actor: isolated WPEDisplayRenderActor) async throws {
        WPESceneScriptExecutionGovernor.processShared.forgetDomain(domainID: sceneScriptTraversalDomainID)
        sceneScriptLoadState.retireCurrent()
        didLoad = false
        let staticTextureReloadDrain = await staticTextureReloadTaskOwner.quiesce()
        loadGeneration &+= 1
        await staticTextureReloadDrain.wait()
        finishAllPendingLivePosterCaptures(image: nil)
        deferredAudioStartupTask?.cancel()
        deferredAudioStartupTask = nil
        pendingAudioStartupDocument = nil
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
        clearSceneScriptRuntimeState()
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
        transformHostLocalTransformsByID.removeAll(keepingCapacity: false)
        onDemandVideoKeyByID.removeAll(keepingCapacity: false)
        onDemandVideoLoading.removeAll(keepingCapacity: false)
        createdLayerTemplatesByImagePath.removeAll(keepingCapacity: false)
        soundRuntime?.stop()
        soundRuntime = nil
        sceneRenderSize = CGSize(width: 1, height: 1)
        cameraUniforms = .identity
        lastRuntimeUniforms = nil
        lastFramePipeline = nil
        cachedSnapshot = nil
        executor.releaseTransientResources()
        try await load(on: actor)
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

        let scriptFailureBeforePatch = sceneScriptLoadState.currentFailureReason
        let presentationBeforePatch = captureSceneScriptPresentation()
        beginSceneScriptVideoCommands()
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

        if scriptFailureBeforePatch == nil {
            let failureBeforeCommit = sceneScriptLoadState.currentFailureReason
            let committed = failureBeforeCommit == nil
                && finishCurrentSceneScriptVideoCommands()
            if !committed {
                discardSceneScriptVideoCommands()
                invalidateIntroPhaseAlign()
                restoreSceneScriptPresentation(presentationBeforePatch)
                if let failure = failureBeforeCommit ?? sceneScriptLoadState.currentFailureReason {
                    Logger.warning(
                        "Scene \(descriptor.workshopID) discarded its failed SceneScript property traversal: \(failure)",
                        category: .wpeRender
                    )
                }
            }
        } else {
            discardSceneScriptVideoCommands()
        }

        if let pipeline = renderPipeline {
            renderPipeline = pipeline
                .applyingLayerVisibility(liveLayerVisibility)
                .applyingLayerAlpha(liveLayerAlpha)
            // A static scene is paused with setNeedsDisplay disabled, so the flag
            // below is inert and even a forced draw() re-presents the cached
            // outputTexture. Render the patched pipeline once here so the toggle
            // shows immediately instead of waiting for an unrelated live trigger.
            if !needsContinuousFrames, let frame = try? renderCurrentFrame(inputs: makeFrameInputs()) {
                outputTexture = frame
                surfaceControl.drawImmediately()
                return true
            }
        }
        surfaceControl.setNeedsRedraw()
        return true
    }

    // MARK: - Live configuration (Wallpaper*Configurable conformance)

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
            surfaceControl.setNeedsRedraw()
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
            surfaceControl.drawImmediately()
        }
    }

    func setClickCaptureEnabled(_ enabled: Bool) {
        surfaceControl.setClickCaptureEnabled(enabled)
        refreshLiveness()
    }

    /// Re-evaluates the paused/continuous state after a mouse-interaction toggle
    /// flips at runtime, so turning Follow Cursor / Interaction on un-pauses a
    /// previously-static scene (and turning them off lets it re-pause).
    private func refreshLiveness() {
        guard currentProfile == .quality else { return }
        surfaceControl.applyPacing(WPERenderPacingUpdate(
            isPaused: !needsContinuousFrames,
            enableSetNeedsDisplay: !needsContinuousFrames
        ))
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
    var effectiveFPS: Int {
        guard adaptiveThrottleActive else { return userPreferredFPS }
        return min(userPreferredFPS, max(Self.adaptiveThrottleFloorFPS, userPreferredFPS / 2))
    }

    /// Suspended scenes don't drive frames, so the ceiling re-applies on the
    /// next `.quality` transition (mirrors `setFrameRateLimit`'s old guard).
    private func applyEffectiveFrameRate() {
        guard currentProfile != .suspended else { return }
        surfaceControl.applyPacing(WPERenderPacingUpdate(preferredFramesPerSecond: effectiveFPS))
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
    var needsContinuousFrames: Bool {
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
        // `!= 0`, not `> 0`: a negative amount/influence is an INVERTED parallax
        // (WPE multiplies the sign straight in), so it still needs the pointer.
        (mouseInteractionEnabled
            && cameraParallaxSettings.enabled
            && cameraParallaxSettings.amount != 0
            && cameraParallaxSettings.mouseInfluence != 0)
            || mailbox.read().clickCaptureEnabled
    }

    /// A pass animates per-frame when its shader samples `g_Time` /
    /// `g_AudioSpectrum*` — i.e. WPE local effects (`effects/…`) and workshop
    /// custom shaders (`workshop/…`). The static base shaders (`solidcolor`,
    /// `genericimage2/4`, `compose`, `copy`) do not, so a scene built only on
    /// those is genuinely static and may stay on the paused/on-demand path.
    static func pipelineHasAnimatedPasses(_ pipeline: WPEPreparedRenderPipeline) -> Bool {
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
            surfaceControl.applyPacing(WPERenderPacingUpdate(
                isPaused: !needsContinuousFrames,
                enableSetNeedsDisplay: !needsContinuousFrames,
                preferredFramesPerSecond: effectiveFPS
            ))
            // Restart scene audio that a prior `.suspended` paused. No-op when
            // audio never started (deferred startup) or is already running.
            soundRuntime?.resume()
        case .suspended:
            WPESceneScriptExecutionGovernor.processShared.cancelReservations(domainID: sceneScriptTraversalDomainID)
            surfaceControl.applyPacing(WPERenderPacingUpdate(isPaused: true, enableSetNeedsDisplay: true))
            surfaceControl.releaseDrawables()
            // Pause the audio engine + FFT tap so a suspended wallpaper costs no
            // audio CPU; the decoded PCM stays resident for an instant resume.
            soundRuntime?.pause()
            executor.releaseTransientResources()
        }
    }

    // MARK: - Teardown

    func cleanup() {
        WPESceneScriptExecutionGovernor.processShared.forgetDomain(domainID: sceneScriptTraversalDomainID)
        sceneScriptLoadState.retireCurrent()
        didLoad = false
        // Owner is an actor now; quiesce fire-and-forget from this sync teardown.
        // It cancels in-flight reload tasks; the discarded Drain isn't awaited.
        Task { [owner = staticTextureReloadTaskOwner] in _ = await owner.quiesce() }
        loadGeneration &+= 1
        finishAllPendingLivePosterCaptures(image: nil)
        deferredAudioStartupTask?.cancel()
        deferredAudioStartupTask = nil
        pendingAudioStartupDocument = nil
        hasPresentedFrame = false
        surfaceControl.detach()
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
        clearSceneScriptRuntimeState()
        releaseDynamicTextureSources()
        particleSystems.removeAll(keepingCapacity: false)
        particleTextures.removeAll(keepingCapacity: false)
        particleNormalTextures.removeAll(keepingCapacity: false)
        textObjects.removeAll(keepingCapacity: false)
        textRenderer?.releaseAll()
        textRenderer = nil
        msdfTextRenderer = nil
        transformHostLocalTransformsByID.removeAll(keepingCapacity: false)
        onDemandVideoKeyByID.removeAll(keepingCapacity: false)
        onDemandVideoLoading.removeAll(keepingCapacity: false)
        createdLayerTemplatesByImagePath.removeAll(keepingCapacity: false)
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
        #if DEBUG
        releaseDebugActorIfNeeded()
        #endif
    }
    nonisolated func stopEngineAssetsAccessIfNeeded() {
        guard let url = activeEngineAssetsRootURL else { return }
        url.stopAccessingSecurityScopedResource()
        activeEngineAssetsRootURL = nil
    }

    // MARK: - Frame production (driven by the surface's `draw(in:)`)

    func renderAndPresentFrame() {
        guard didLoad else { return }
        do {
            let textureToPresent: MTLTexture?
            if needsContinuousFrames {
                let frame = try renderCurrentFrame(inputs: makeFrameInputs())
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
                    layer: metalLayer.layer,
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
            if presented { hasPresentedFrame = true }
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
}
#endif
