#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import MetalKit
import os

extension WPEMetalSceneRenderer {
    /// Per-frame inputs shared by the script/particle/encode stages, computed
    /// once at the top of `renderCurrentFrame`.
    struct FrameContext {
        let uniforms: WPEMetalRuntimeUniforms
        let pointer: SIMD2<Double>
        let followPointerIsLive: Bool
        let layerScriptPointerFrame: WPEPointerFrame
        let parallaxFrame: WPECameraParallaxFrame
    }

    /// Advances the frame clock/parallax smoothing, folds in live audio spectra,
    /// and derives the pointer frame layer scripts see from the main-thread
    /// `inputs` snapshot. Touches no AppKit/UI state directly — that is the seam
    /// that lets Phase 2 run this off `@MainActor`.
    func sampleFrameContext(inputs: WPEFrameInputs) -> FrameContext {
        // Pin follow-cursor effects to center when disabled, or when the
        // global cursor belongs to another display. Click capture stays
        // independent because Interaction can be enabled without Follow Cursor.
        // The gate on `mouseInteractionEnabled` (renderer state) stays here; the
        // snapshot always sampled the pointer, so an inactive gate discards it.
        let pointerSample = (mouseInteractionEnabled || inputs.clickCaptureEnabled)
            ? inputs.pointerSample
            : .inactive
        let pointerIsInsideView = pointerSample.isInsideView
        let followPointerIsLive = mouseInteractionEnabled && pointerIsInsideView
        let clickPointerIsLive = inputs.clickCaptureEnabled && pointerIsInsideView
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
                        "[AudioCapture] renderer: capturing=true peakL=\(String(format: "%.3f", peakL)) peakR=\(String(format: "%.3f", peakR)) fps=\(inputs.preferredFramesPerSecond) → feeding g_AudioSpectrum*",
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
            ? inputs.pointerFrame
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
}
#endif
