#if !LITE_BUILD
    import Foundation
    import LiveWallpaperProWPE

    extension WPEMetalSceneRenderer {
        // MARK: - Script tick dispatch (ADR-003 step 1)

        func tickLayerScript(
            _ instance: WPELayerScriptInstance,
            runtimeSeconds: Double,
            pointerFrame: WPEPointerFrame,
            traversalEpoch: WPESceneScriptTraversalEpoch
        ) -> WPELayerScriptOutput? {
            Self.scriptAsyncTickEnabled
                ? instance.liveTick(
                    runtimeSeconds: runtimeSeconds,
                    pointerFrame: pointerFrame,
                    traversalEpoch: traversalEpoch
                )
                : instance.tick(
                    runtimeSeconds: runtimeSeconds,
                    pointerFrame: pointerFrame,
                    traversalEpoch: traversalEpoch
                )
        }

        func tickTransformScript(
            _ instance: WPEDynamicTransformScriptInstance,
            pointer: SIMD2<Double>,
            runtimeSeconds: Double,
            traversalEpoch: WPESceneScriptTraversalEpoch
        ) -> SIMD3<Double>? {
            Self.scriptAsyncTickEnabled
                ? instance.liveTick(
                    pointerPosition: pointer,
                    runtimeSeconds: runtimeSeconds,
                    traversalEpoch: traversalEpoch
                )
                : instance.tick(
                    pointerPosition: pointer,
                    runtimeSeconds: runtimeSeconds,
                    traversalEpoch: traversalEpoch
                )
        }

        func tickTextScript(
            _ instance: WPESceneScriptInstance,
            traversalEpoch: WPESceneScriptTraversalEpoch
        ) -> String {
            Self.scriptAsyncTickEnabled
                ? instance.liveTickString(traversalEpoch: traversalEpoch)
                : instance.tickString(traversalEpoch: traversalEpoch)
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
    }
#endif
