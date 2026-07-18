#if !LITE_BUILD
    import AppKit
    import LiveWallpaperCore

    extension WPEMetalSceneRenderer {
        /// Reload an evicted static texture off the main thread, then republish on the
        /// main actor under a `loadGeneration` guard so a reload from a prior scene is
        /// ignored. Triggers a redraw so the placeholder is replaced once resident.
        /// Failed attempts back off per path (`WPEStaticTextureReloadThrottle`).
        func scheduleStaticTextureReload(for path: String) {
            guard didLoad,
                  let record = staticTextureCacheRecords[path],
                  staticTextureReloadThrottles[path, default: .init()]
                  .allowsAttempt(at: ProcessInfo.processInfo.systemUptime),
                  let actor = displayActor else { return }
            let generation = loadGeneration
            let resolver = resourceResolver
            let loader = textureLoader
            let threshold = Self.lazyAnimationRawByteThreshold
            let owner = staticTextureReloadTaskOwner
            // Submit is an async actor method now, so spawn to reach it. The
            // operation captures only Sendable values (path/record/resolver/loader/
            // threshold + the actor) and hops to the render actor to run the reload.
            Task { [owner, actor] in
                _ = await owner.submit(path: path, generation: generation) { ticket in
                    await actor.performStaticReload(
                        path: path,
                        record: record,
                        resolver: resolver,
                        loader: loader,
                        threshold: threshold,
                        ticket: ticket
                    )
                }
            }
        }

        /// Body of one static-texture reload, run on the render actor. Resolves +
        /// uploads off-actor, then republishes here under a `loadGeneration` +
        /// `canPublish` guard so a reload from a prior scene is ignored.
        func performStaticTextureReload(
            path: String,
            record: StaticTextureCacheRecord,
            resolver: WPEMultiRootResourceResolver,
            loader: WPEMetalTextureLoader,
            threshold: Int,
            ticket: WPEStaticTextureReloadTaskOwner.Ticket,
            on actor: isolated WPEDisplayRenderActor
        ) async {
            let generation = ticket.generation
            let result: WPEParallelTextureResult
            do {
                result = try await Self.resolveStaticTextureOrDefer(
                    relativePath: path,
                    label: "WPE texture \(path)",
                    candidates: record.candidates,
                    resolver: resolver,
                    loader: loader,
                    streamingThreshold: threshold
                )
            } catch is CancellationError {
                return
            } catch {
                // `canPublish` is an async hop; re-evaluate the sync guards AFTER
                // it resumes so a cancellation / generation bump during the hop is
                // caught at the last moment before we touch the throttle.
                guard await staticTextureReloadTaskOwner.canPublish(ticket),
                      !Task.isCancelled, loadGeneration == generation else { return }
                noteStaticTextureReloadFailure(path)
                return
            }
            guard await staticTextureReloadTaskOwner.canPublish(ticket),
                  !Task.isCancelled, loadGeneration == generation else { return }
            switch result {
            case let .staticTexture(texture):
                recordLoadedStaticTexture(
                    path: path,
                    layerName: record.layerName,
                    candidates: record.candidates,
                    texture: texture
                )
            case .needsOnActor:
                do {
                    try await loadDynamicTextureOnActor(
                        path: path,
                        layerName: record.layerName,
                        // Full ticket-level admission (async hop to the @MainActor
                        // owner), matching the pre-3c gate exactly.
                        publicationAllowed: { [weak self] in
                            guard let self, self.loadGeneration == generation else { return false }
                            return await self.staticTextureReloadTaskOwner.canPublish(ticket)
                        },
                        on: actor
                    )
                } catch is CancellationError {
                    return
                } catch {
                    // Re-evaluate the sync guards after the async `canPublish` hop.
                    guard await staticTextureReloadTaskOwner.canPublish(ticket),
                          !Task.isCancelled, loadGeneration == generation else { return }
                    noteStaticTextureReloadFailure(path)
                    return
                }
            }
            guard await staticTextureReloadTaskOwner.canPublish(ticket),
                  !Task.isCancelled, loadGeneration == generation else { return }
            surfaceControl.setNeedsRedraw()
        }

        private func noteStaticTextureReloadFailure(_ path: String) {
            var throttle = staticTextureReloadThrottles[path, default: .init()]
            throttle.recordFailure(at: ProcessInfo.processInfo.systemUptime)
            staticTextureReloadThrottles[path] = throttle
            if throttle.isExhausted {
                Logger.warning(
                    "[WPE.texture-cache] reload giving up after \(throttle.failureCount) failures path=\(path)",
                    category: .wpeRender
                )
            } else {
                Logger.warning(
                    "[WPE.texture-cache] reload failed (attempt \(throttle.failureCount)) path=\(path)",
                    category: .wpeRender
                )
            }
        }
    }
#endif
