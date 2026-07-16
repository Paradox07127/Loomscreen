#if !LITE_BUILD
    import AppKit

    extension WPEMetalSceneRenderer {
        /// Reload an evicted static texture off the main thread, then republish on the
        /// main actor under a `loadGeneration` guard so a reload from a prior scene is
        /// ignored. Triggers a redraw so the placeholder is replaced once resident.
        /// Failed attempts back off per path (`WPEStaticTextureReloadThrottle`).
        func scheduleStaticTextureReload(for path: String) {
            guard didLoad,
                  let record = staticTextureCacheRecords[path],
                  staticTextureReloadThrottles[path, default: .init()]
                  .allowsAttempt(at: ProcessInfo.processInfo.systemUptime) else { return }
            let generation = loadGeneration
            let resolver = resourceResolver
            let loader = textureLoader
            let threshold = Self.lazyAnimationRawByteThreshold
            staticTextureReloadTaskOwner.submit(
                path: path,
                generation: generation
            ) { @MainActor [weak self] ticket in
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
                    guard let self,
                          !Task.isCancelled,
                          loadGeneration == generation,
                          staticTextureReloadTaskOwner.canPublish(ticket) else { return }
                    noteStaticTextureReloadFailure(path)
                    return
                }
                guard let self,
                      !Task.isCancelled,
                      loadGeneration == generation,
                      staticTextureReloadTaskOwner.canPublish(ticket) else { return }
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
                            publicationAllowed: { [weak self] in
                                guard let self else { return false }
                                return loadGeneration == generation
                                    && staticTextureReloadTaskOwner.canPublish(ticket)
                            }
                        )
                    } catch is CancellationError {
                        return
                    } catch {
                        guard !Task.isCancelled,
                              loadGeneration == generation,
                              staticTextureReloadTaskOwner.canPublish(ticket) else { return }
                        noteStaticTextureReloadFailure(path)
                        return
                    }
                }
                guard !Task.isCancelled,
                      loadGeneration == generation,
                      staticTextureReloadTaskOwner.canPublish(ticket) else { return }
                mtkView.setNeedsDisplay(mtkView.bounds)
            }
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
