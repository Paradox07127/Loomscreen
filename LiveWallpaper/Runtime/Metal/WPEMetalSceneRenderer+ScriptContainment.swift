#if !LITE_BUILD
    extension WPEMetalSceneRenderer {
        func isCurrentSceneScriptLoad(_ token: WPESceneScriptInstanceLimitToken) -> Bool {
            loadGeneration == token.generation && sceneScriptLoadState.isCurrent(token)
        }

        func checkCurrentSceneScriptLoad(
            _ token: WPESceneScriptInstanceLimitToken
        ) throws {
            guard isCurrentSceneScriptLoad(token) else { throw CancellationError() }
        }

        func constructSceneScript<Instance>(
            for token: WPESceneScriptInstanceLimitToken,
            _ construct: () throws -> Instance
        ) rethrows -> Instance? {
            guard isCurrentSceneScriptLoad(token) else { return nil }
            return try token.withConstructionPermission(construct)
        }

        @discardableResult
        func latchSceneScriptFailure(
            _ error: Error,
            operation: WPESceneScriptOperation,
            token: WPESceneScriptInstanceLimitToken
        ) -> Bool {
            let reason: WPESceneScriptFailClosedReason
            switch error {
            case WPESceneScriptError.executionTimedOut:
                reason = .executionTimedOut(operation: operation)
            case let WPESceneScriptError.capacityUnavailable(rejectedOperation):
                reason = .capacityUnavailable(operation: rejectedOperation)
            default:
                return false
            }
            return token.failClosed(reason)
        }

        /// Load has no prior stable script frame. Any latched setup/resource
        /// failure therefore discards partial init output and renders the baked
        /// graph while leaving the wallpaper itself usable.
        @discardableResult
        func resetSceneScriptsToBakedIfFailed(
            _ token: WPESceneScriptInstanceLimitToken
        ) -> Bool {
            guard let reason = token.failureReason else { return false }
            clearSceneScriptRuntimeState()
            Logger.warning(
                "Scene \(descriptor.workshopID) kept its baked presentation and disabled SceneScript: \(reason)",
                category: .wpeRender
            )
            return true
        }

        /// Builds dynamic origin script instances for image layers whose `origin`
        /// SceneScript depends on live input. Static origin scripts were resolved by
        /// `WPESceneDocumentParser`, so they do not reach this path.
        func loadDynamicOriginScripts(
            from document: WPESceneDocument,
            scriptLoadToken: WPESceneScriptInstanceLimitToken
        ) {
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
            }).map { id, script in
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
            guard isCurrentSceneScriptLoad(scriptLoadToken),
                  scriptLoadToken.allows(.setup) else { return }
            let canvasSize = SIMD2<Double>(
                max(Double(sceneRenderSize.width), 1),
                max(Double(sceneRenderSize.height), 1)
            )
            let sharedState = sceneScriptSharedState
                ?? WPESharedScriptState(sceneScriptLoadToken: scriptLoadToken)
            sceneScriptSharedState = sharedState
            func install(
                _ scripts: [(String, WPESceneTransformScript)],
                into instances: inout [String: WPEDynamicTransformScriptInstance],
                label: String
            ) {
                for (objectID, script) in scripts {
                    do {
                        guard let instance = try constructSceneScript(for: scriptLoadToken, {
                            try WPEDynamicTransformScriptInstance(
                                script: script.script,
                                scriptProperties: script.scriptProperties,
                                seed: script.seed,
                                canvasSize: canvasSize,
                                shared: sharedState
                            )
                        }) else { return }
                        // Seeded after script hosts produce their first shared state.
                        instances[objectID] = instance
                    } catch {
                        _ = latchSceneScriptFailure(error, operation: .setup, token: scriptLoadToken)
                        Logger.warning("Scene \(descriptor.workshopID) [\(label)] init failed for \(objectID): \(error)", category: .wpeRender)
                    }
                }
            }
            install(originScripts, into: &dynamicOriginScriptInstances, label: "OriginScript")
            install(scaleScripts, into: &dynamicScaleScriptInstances, label: "ScaleScript")
            install(anglesScripts, into: &dynamicAnglesScriptInstances, label: "AnglesScript")
        }

        func clearSceneScriptRuntimeState() {
            invalidateIntroPhaseAlign()
            textScriptInstances.removeAll(keepingCapacity: false)
            layerScriptInstances.removeAll(keepingCapacity: false)
            layerAlphaScriptInstances.removeAll(keepingCapacity: false)
            textVisibleScriptInstances.removeAll(keepingCapacity: false)
            textAlphaScriptInstances.removeAll(keepingCapacity: false)
            dynamicOriginScriptInstances.removeAll(keepingCapacity: false)
            dynamicScaleScriptInstances.removeAll(keepingCapacity: false)
            dynamicAnglesScriptInstances.removeAll(keepingCapacity: false)
            sceneScriptSharedState = nil
            lastStableScriptTransforms = LiveScriptTransforms()
            lastStableScriptTextByID.removeAll(keepingCapacity: false)
            layerHoverStates.removeAll(keepingCapacity: false)
            liveLayerVisibility.removeAll(keepingCapacity: false)
            liveTextVisibility.removeAll(keepingCapacity: false)
            liveLayerAlpha.removeAll(keepingCapacity: false)
            liveTextAlpha.removeAll(keepingCapacity: false)
            liveCreatedLayers.removeAll(keepingCapacity: false)
            layerVideoSourceKey.removeAll(keepingCapacity: false)
            layerObjectIDByName.removeAll(keepingCapacity: false)
            sceneScriptVideoCommandBuffer.discard()
            sceneScriptIntroPhaseAlignPending = false
        }
    }
#endif
