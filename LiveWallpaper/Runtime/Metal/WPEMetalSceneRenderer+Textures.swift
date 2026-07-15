#if !LITE_BUILD
import AppKit
import MetalKit

extension WPEMetalSceneRenderer {
    // MARK: - Loaded texture resource types

    /// Phase 2E: differentiates between a one-shot static texture and a
    /// dynamic source (animated TEX or video) so the renderer can either
    /// stuff the result into `loadedTextures` or hold the source for
    /// per-frame refresh via `texturesForCurrentFrame(time:)`.
    enum WPELoadedTextureResource {
        case staticTexture(MTLTexture)
        case dynamicSource(WPEDynamicTextureSource)
    }

    /// One unique external texture to load, captured before fan-out so the
    /// off-actor lane never races on a shared dedup map.
    private struct WPETextureLoadJob: Sendable {
        let path: String
        let layerName: String
        let candidates: [String]
    }

    /// Outcome of the off-actor resolve+upload lane. `staticTexture` carries a
    /// fully-built Metal texture (a thread-safe object) back to the main actor;
    /// `needsOnActor` flags a dynamic/video/animated/heavy-streaming source
    /// whose construction is `@MainActor`-isolated and is handled serially.
    /// `@unchecked Sendable` is the idiomatic escape hatch for ferrying an
    /// `MTLTexture` (documented thread-safe) across the actor hop.
    private enum WPEParallelTextureResult: @unchecked Sendable {
        case staticTexture(MTLTexture)
        case needsOnActor
    }

    // MARK: - Shader prewarm

    /// Off-thread shader-transpile pre-warm. Builds the deterministic, runtime-independent
    /// compile request for every custom-shader pass on the main actor (deduped by cache key),
    /// then translates + makeLibrary's them in parallel OFF the main actor and seeds
    /// `executor.translatedShaderCache` — so the first synchronous `render()` gets cache hits
    /// instead of paying the ~1.9s lazy GLSL→MSL transpile inline. Launched as an `async let`
    /// during the load window (overlapping texture/particle/text load) and awaited at the
    /// render.firstFrame gate. Flag-gated; per-pass failures are swallowed (the real first
    /// render re-hits and records them as today). Respects `loadGeneration` so a superseded
    /// load never seeds. Captures only `Sendable` values (the compiler protocol is `Sendable`,
    /// requests are `Sendable`) — never the non-`Sendable` executor.
    func prewarmCustomShaders(
        for pipeline: WPEPreparedRenderPipeline,
        textObjects: [WPESceneTextObject]
    ) async {
        // Always pre-compile before the first-frame encode: compiling a pipeline
        // state inline during an open render encoder corrupts the pass (3660962877
        // black bg + green quad).
        let generation = loadGeneration
        debugStage("shader.prewarm", "begin")

        // Build + dedup requests on the main actor (the preprocess is cheap; only the
        // translate+makeLibrary that follows is the heavy CPU). recordFailure:false keeps
        // the warm silent — the real first-frame render stays the sole failure recorder.
        var requestsByKey: [String: WPEShaderCompileRequest] = [:]
        for layer in pipeline.layers {
            for pass in layer.passes where pass.shader?.isBuiltin == false {
                guard let request = try? WPEMetalRenderExecutor.makeCompileRequest(for: pass, recordFailure: false) else { continue }
                requestsByKey[request.translationCacheKey] = request
            }
        }
        // GPU MSDF text loads via a separate path (loadTextOverlays) whose font.frag
        // is otherwise transpiled lazily on the first synchronous drawMSDFText. Warm
        // it here on the same off-thread task group. Gate must match loadTextOverlays.
        if !textObjects.isEmpty,
           UserDefaults.standard.object(forKey: "WPEEnableMSDFText") as? Bool ?? true,
           let fontFragmentSource = resolveMSDFFontFragmentSource() {
            for request in WPEMSDFTextRenderer.prewarmShaderRequests(
                for: textObjects,
                fontFragmentSource: fontFragmentSource,
                resolver: resourceResolver
            ) {
                requestsByKey[request.translationCacheKey] = request
            }
        }
        let requests = Array(requestsByKey.values)
        guard !requests.isEmpty, loadGeneration == generation else {
            debugStage("shader.prewarm.done", "passes=0")
            return
        }

        let compiler = executor.shaderCompiler
        let width = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))

        let warmed: [(key: String, result: WPEShaderCompileResult)]
        do {
            warmed = try await withThrowingTaskGroup(
                of: (key: String, result: WPEShaderCompileResult)?.self
            ) { group in
                var next = 0
                func spawn() -> Bool {
                    guard next < requests.count else { return false }
                    let request = requests[next]
                    next += 1
                    group.addTask(priority: .userInitiated) {
                        try Task.checkCancellation()
                        // Swallow an unsupported shader: leave it uncached so the real
                        // first-frame render re-hits compileCustomShader and records it.
                        guard let result = try? compiler.compile(request, recordFailure: false) else {
                            return nil
                        }
                        return (key: request.translationCacheKey, result: result)
                    }
                    return true
                }
                for _ in 0..<width where spawn() {}
                var collected: [(key: String, result: WPEShaderCompileResult)] = []
                while let entry = try await group.next() {
                    if loadGeneration != generation {
                        group.cancelAll()
                        break
                    }
                    if let entry { collected.append(entry) }
                    _ = spawn()
                }
                return collected
            }
        } catch {
            // A superseded load cancelled the group mid-drain; drop the partial results.
            debugStage("shader.prewarm.cancelled", "\(error)")
            return
        }

        guard loadGeneration == generation else { return }
        executor.seedTranslatedShaderCache(warmed)
        debugStage("shader.prewarm.done", "warmed=\(warmed.count)/\(requests.count)")

        // Second parallel phase: pre-build the pipeline STATES too. makeRenderPipelineState
        // is the dominant residual first-frame cost (transpile/makeLibrary above are already
        // warmed) and was still compiled lazily & serially on the render thread. Enumerate
        // each pass's (shader, blend) against the scene's dominant color format and the two
        // common vertex functions (fullscreen + object-quad); dedup by pipeline identity.
        // Over-/under-prediction only changes the cache-hit rate, never correctness.
        var resultByKey: [String: WPEShaderCompileResult] = [:]
        for entry in warmed { resultByKey[entry.key] = entry.result }
        let sceneColorFormat: MTLPixelFormat = cameraUniforms.sceneHDR
            ? .rgba16Float
            : WPEMetalRenderExecutor.outputPixelFormat
        let vertexCandidates: [String?] = [nil, "wpe_object_quad_vertex"]
        let prewarmDevice = executor.textureSourceDevice
        var pipelinePrewarms: [WPEMetalRenderExecutor.WPETranslatedPipelinePrewarm] = []
        var seenPipelineKeys = Set<String>()
        for layer in pipeline.layers {
            for pass in layer.passes where pass.shader?.isBuiltin == false {
                guard let request = try? WPEMetalRenderExecutor.makeCompileRequest(for: pass, recordFailure: false),
                      let result = resultByKey[request.translationCacheKey] else { continue }
                let blend = pass.pass.blending
                for vertexName in vertexCandidates {
                    let dedup = "\(ObjectIdentifier(result.library))|\(vertexName ?? result.vertexFunctionName)|\(result.fragmentFunctionName)|\(blend.lowercased())|\(sceneColorFormat.rawValue)"
                    guard seenPipelineKeys.insert(dedup).inserted else { continue }
                    pipelinePrewarms.append(.init(
                        device: prewarmDevice,
                        result: result,
                        vertexName: vertexName,
                        blendMode: blend,
                        colorPixelFormat: sceneColorFormat,
                        depthPixelFormat: .invalid
                    ))
                }
            }
        }
        guard loadGeneration == generation, !pipelinePrewarms.isEmpty else {
            debugStage("pipeline.prewarm.done", "combos=0")
            return
        }
        // Compile the pipeline states in parallel OFF the render thread (mirrors the
        // translation task group above — captures only the `@unchecked Sendable` prewarm
        // requests, never the executor), then seed synchronously before the first frame.
        let pipeWidth = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 1))
        let built: [WPEMetalRenderExecutor.WPEPrewarmedPipeline] = await withTaskGroup(
            of: WPEMetalRenderExecutor.WPEPrewarmedPipeline?.self
        ) { group in
            var next = 0
            func spawn() -> Bool {
                guard next < pipelinePrewarms.count else { return false }
                let prewarm = pipelinePrewarms[next]
                next += 1
                group.addTask(priority: .userInitiated) {
                    WPEMetalRenderExecutor.buildTranslatedPipeline(prewarm)
                }
                return true
            }
            for _ in 0..<pipeWidth where spawn() {}
            var collected: [WPEMetalRenderExecutor.WPEPrewarmedPipeline] = []
            while let entry = await group.next() {
                if loadGeneration != generation {
                    group.cancelAll()
                    break
                }
                if let entry { collected.append(entry) }
                _ = spawn()
            }
            return collected
        }
        guard loadGeneration == generation else { return }
        executor.seedTranslatedPipelines(built)
        debugStage("pipeline.prewarm.done", "combos=\(pipelinePrewarms.count) built=\(built.count)")
    }

    // MARK: - Bulk texture loading

    func loadTextures(for pipeline: WPEPreparedRenderPipeline) async throws {
        loadedTextures = [:]
        dynamicTextureSources = [:]
        resetTextureCacheBudgetState()

        // Collect the unique external textures in pipeline order. Deduping up
        // front (instead of the old per-iteration map check) means concurrent
        // resolves never touch the same path, so the @MainActor texture maps
        // are written exactly once each, on this actor.
        var jobs: [WPETextureLoadJob] = []
        var seen = Set<String>()
        for layer in pipeline.layers {
            let layerName = layer.graphLayer.objectName
            if layer.passes.isEmpty {
                if let path = externalTexturePath(for: .image(layer.graphLayer.imagePath)),
                   seen.insert(path).inserted {
                    jobs.append(WPETextureLoadJob(path: path, layerName: layerName, candidates: textureCandidates(for: path)))
                }
                continue
            }
            for preparedPass in layer.passes {
                for reference in requiredTextureReferences(for: preparedPass) {
                    if let path = externalTexturePath(for: reference),
                       seen.insert(path).inserted {
                        jobs.append(WPETextureLoadJob(path: path, layerName: layerName, candidates: textureCandidates(for: path)))
                    }
                }
            }
        }
        guard !jobs.isEmpty else { return }

        // Snapshot the load generation so a reload/cleanup that resets the maps
        // mid-flight can't get a stale texture written into the new load.
        let generation = loadGeneration
        let resolver = resourceResolver
        let loader = textureLoader
        let threshold = Self.lazyAnimationRawByteThreshold
        // Width bounded like the upload lane: parallelizes the per-texture
        // inflate (the on-main serial cost today) without over-subscribing the
        // upload queue, which keeps its own 1-2 slot admission bound.
        let width = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))

        try await withThrowingTaskGroup(of: (Int, WPEParallelTextureResult).self) { group in
            var nextIndex = 0
            func spawnNext() -> Bool {
                guard nextIndex < jobs.count else { return false }
                let index = nextIndex
                nextIndex += 1
                let job = jobs[index]
                group.addTask(priority: .userInitiated) {
                    do {
                        let result = try await Self.resolveStaticTextureOrDefer(
                            relativePath: job.path,
                            label: "WPE texture \(job.path)",
                            candidates: job.candidates,
                            resolver: resolver,
                            loader: loader,
                            streamingThreshold: threshold
                        )
                        return (index, result)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        throw WPEMetalTextureLoadContextError(layerName: job.layerName, path: job.path, underlying: error)
                    }
                }
                return true
            }

            for _ in 0..<width where spawnNext() {}

            while let (index, result) = try await group.next() {
                try Task.checkCancellation()
                guard loadGeneration == generation else {
                    group.cancelAll()
                    return
                }
                switch result {
                case .staticTexture(let texture):
                    recordLoadedStaticTexture(
                        path: jobs[index].path,
                        layerName: jobs[index].layerName,
                        candidates: jobs[index].candidates,
                        texture: texture
                    )
                case .needsOnActor:
                    // Rare: video / multi-frame animation / heavy-streaming
                    // `.tex`. Their source construction is @MainActor-only, so
                    // route through the untouched serial resolver rather than
                    // duplicating that logic in the parallel lane.
                    try await loadDynamicTextureOnActor(path: jobs[index].path, layerName: jobs[index].layerName)
                }
                _ = spawnNext()
            }
        }
    }

    /// Off-actor: resolve + upload a *static* texture, or report that the
    /// reference needs @MainActor construction. Mirrors the candidate-walk in
    /// `makeTextureResource`; only the static-image / static-payload branches
    /// build here (the upload still flows through the bounded upload queue).
    private nonisolated static func resolveStaticTextureOrDefer(
        relativePath: String,
        label: String,
        candidates: [String],
        resolver: WPEMultiRootResourceResolver,
        loader: WPEMetalTextureLoader,
        streamingThreshold: Int
    ) async throws -> WPEParallelTextureResult {
        var lastError: Error?
        for candidate in candidates {
            do {
                if shouldTryTexturePayload(candidate) {
                    do {
                        if detectHeavyStreaming(candidate, resolver: resolver, threshold: streamingThreshold) {
                            return .needsOnActor
                        }
                        let payload = try resolver.resolveTexturePayload(relativePath: candidate)
                        if payload.videoPayload != nil || payload.animationTrack != nil {
                            return .needsOnActor
                        }
                        return .staticTexture(try await loader.makeTexture(from: payload, label: label))
                    } catch {
                        lastError = error
                    }
                }
                let image = try resolver.resolveImage(relativePath: candidate)
                return .staticTexture(try await loader.makeTexture(from: image, label: label))
            } catch {
                lastError = error
            }
        }
        throw lastError ?? WPEMetalRenderExecutorError.missingTexture(.image(relativePath))
    }

    /// `nonisolated` heavy-`.tex` probe matching `resolveStreamingPayloadIfHeavy`'s
    /// decision (same threshold + probe candidates), minus the opt-in debug
    /// marks. When this returns true the on-actor path re-resolves and builds
    /// the lazy streaming source.
    private nonisolated static func detectHeavyStreaming(
        _ candidate: String,
        resolver: WPEMultiRootResourceResolver,
        threshold: Int
    ) -> Bool {
        let ext = (candidate as NSString).pathExtension.lowercased()
        let probeCandidates: [String]
        if ext == "tex" {
            probeCandidates = [candidate]
        } else if ext.isEmpty {
            let stripped = (candidate as NSString).deletingPathExtension
            probeCandidates = [candidate, "materials/\(stripped).tex"]
        } else {
            return false
        }
        for probe in probeCandidates {
            guard let payload = try? resolver.resolveStreamingTexturePayload(relativePath: probe) else {
                continue
            }
            if payload.totalUncompressedImageBytes > threshold {
                return true
            }
        }
        return false
    }

    /// On-actor build for the dynamic/video/animated/heavy-streaming minority,
    /// reusing the serial `makeTextureResource`. Paths are pre-deduped by the
    /// caller, so no map guard is needed here.
    func loadDynamicTextureOnActor(path: String, layerName: String) async throws {
        do {
            let resource = try await makeTextureResource(relativePath: path, label: "WPE texture \(path)")
            try Task.checkCancellation()
            switch resource {
            case .staticTexture(let texture):
                recordLoadedStaticTexture(
                    path: path,
                    layerName: layerName,
                    candidates: textureCandidates(for: path),
                    texture: texture
                )
            case .dynamicSource(let source):
                forgetStaticTextureCacheRecord(path)
                dynamicTextureSources[path] = source
                if let texture = source.texture(at: lastRuntimeUniforms?.time ?? 0) {
                    loadedTextures[path] = texture
                } else {
                    loadedTextures[path] = try makeDynamicPlaceholderTexture(label: "\(path) placeholder")
                }
            }
        } catch is CancellationError {
            // Keep cancellation transparent — wrapping it in the load-context
            // error would defeat the session's `catch is CancellationError`.
            throw CancellationError()
        } catch {
            throw WPEMetalTextureLoadContextError(layerName: layerName, path: path, underlying: error)
        }
    }

    // MARK: - Texture references & resource construction

    func externalTexturePath(for reference: WPETextureReference) -> String? {
        switch reference {
        case .image(let path), .asset(let path):
            return path
        case .fbo, .previous:
            return nil
        }
    }

    func requiredTextureReferences(for pass: WPEPreparedRenderPass) -> [WPETextureReference] {
        switch WPEBuiltinShaderKind(normalizing: pass.pass.shader) {
        case .solidColor?, .solidLayer?:
            return []

        case .compose?:
            let first = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
            let second = pass.textureBindings[1] ?? pass.pass.textures[1] ?? first
            return [first, second].filter(\.isExternalTextureReference)

        case .genericImage4?:
            let primary = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
            var refs: [WPETextureReference] = [primary]
            if let mask = pass.textureBindings[1] ?? pass.pass.textures[1] {
                refs.append(mask)
            }
            // generic4 MODEL materials carry the PBR component map (emissive
            // mask) in slot 2 — the scene-model fragment samples it.
            if let componentMap = pass.textureBindings[2] ?? pass.pass.textures[2] {
                refs.append(componentMap)
            }
            return refs.filter(\.isExternalTextureReference)

        default:
            let reference = pass.pass.binds[0]
                ?? pass.textureBindings[0]
                ?? pass.pass.textures[0]
                ?? pass.pass.source
            var refs: [WPETextureReference] = [reference]
            for slot in 1..<4 {
                if let extra = pass.pass.binds[slot] ?? pass.textureBindings[slot] ?? pass.pass.textures[slot] {
                    refs.append(extra)
                }
            }
            return refs.filter(\.isExternalTextureReference)
        }
    }


    /// Phase 2E rewrite: returns a `WPELoadedTextureResource` instead of a raw texture so the caller can route MP4 video and multi-frame animations through dedicated dynamic sources.
    func makeTextureResource(
        relativePath: String,
        label: String,
        colorSpace: WPEMetalColorSpace = .sRGB
    ) async throws -> WPELoadedTextureResource {
        var lastError: Error?
        for candidate in textureCandidates(for: relativePath) {
            do {
                if shouldTryTexturePayload(candidate) {
                    do {
                        if let streaming = try resolveStreamingPayloadIfHeavy(candidate) {
                            let source = try textureLoader.makeLazyAnimatedTextureSource(
                                from: streaming,
                                label: label
                            )
                            Logger.info(
                                "WPE Metal lazy .tex animation '\(candidate)' raw=\(streaming.totalUncompressedImageBytes)B frames=\(streaming.frames.count)",
                                category: .screenManager
                            )
                            return .dynamicSource(source)
                        }

                        let payload = try resourceResolver.resolveTexturePayload(relativePath: candidate)

                        if payload.videoPayload != nil {
                            let source = try await makeVideoTextureSource(from: payload, label: label)
                            return .dynamicSource(source)
                        }
                        if payload.animationTrack != nil {
                            let source = try await textureLoader.makeAnimatedTextureSource(
                                from: payload,
                                label: label
                            )
                            return .dynamicSource(source)
                        }

                        return .staticTexture(try await textureLoader.makeTexture(from: payload, label: label, colorSpace: colorSpace))
                    } catch {
                        lastError = error
                    }
                }
                let image = try resourceResolver.resolveImage(relativePath: candidate)
                return .staticTexture(try await textureLoader.makeTexture(from: image, label: label, colorSpace: colorSpace))
            } catch {
                lastError = error
            }
        }
        throw lastError ?? WPEMetalRenderExecutorError.missingTexture(.image(relativePath))
    }

    /// Returns a streaming payload only when the source is a `.tex` whose
    /// total raw image footprint clears the lazy threshold. Anything
    /// smaller falls through to the eager path so single-frame textures
    /// and tiny sprite-sheets don't pay the per-frame decompression cost.
    /// Accepts both `.tex`-suffixed candidates and bare names (probes
    /// `<bare>` and `materials/<bare>.tex` in the same order the eager
    /// path uses).
    private func resolveStreamingPayloadIfHeavy(_ candidate: String) throws -> WPETexStreamingPayload? {
        let probeCandidates: [String]
        let ext = (candidate as NSString).pathExtension.lowercased()
        if ext == "tex" {
            probeCandidates = [candidate]
        } else if ext.isEmpty {
            let stripped = (candidate as NSString).deletingPathExtension
            probeCandidates = [candidate, "materials/\(stripped).tex"]
        } else {
            return nil
        }

        for probe in probeCandidates {
            let payload: WPETexStreamingPayload
            do {
                payload = try resourceResolver.resolveStreamingTexturePayload(relativePath: probe)
            } catch let SceneResourceResolver.ResolveError.texture(decodeError) {
                switch decodeError {
                case .unsupportedAnimation, .unsupportedFormat:
                    debugStage(
                        "tex.lazy.skip",
                        "probe=\(probe) reason=\(decodeError)"
                    )
                    continue
                default:
                    debugStage(
                        "tex.lazy.skip",
                        "probe=\(probe) decodeError=\(decodeError)"
                    )
                    continue
                }
            } catch SceneResourceResolver.ResolveError.fileMissing,
                    SceneResourceResolver.ResolveError.unsupportedTexture {
                continue
            } catch {
                debugStage(
                    "tex.lazy.skip",
                    "probe=\(probe) error=\(error)"
                )
                continue
            }
            if payload.totalUncompressedImageBytes <= Self.lazyAnimationRawByteThreshold {
                debugStage(
                    "tex.lazy.skip",
                    "probe=\(probe) raw=\(payload.totalUncompressedImageBytes)B below threshold"
                )
                continue
            }
            debugStage(
                "tex.lazy.hit",
                "probe=\(probe) raw=\(payload.totalUncompressedImageBytes)B images=\(payload.compressedImages.count) frames=\(payload.frames.count)"
            )
            return payload
        }
        return nil
    }

    /// Phase 2E: stages MP4 bytes into the per-process video cache and constructs a `WPEVideoTextureSource` bound to the executor's MTLDevice.
    private func makeVideoTextureSource(
        from payload: WPETexTexturePayload,
        label: String
    ) async throws -> WPEVideoTextureSource {
        guard let videoPayload = payload.videoPayload else {
            throw WPEMetalTextureLoaderError.malformedPayload("missing video payload")
        }
        // Stage into the per-scene disk cache keyed by workshop ID + content
        // hash, so repeated extractions dedup and launch GC can reclaim videos
        // for scenes that are no longer installed.
        let url = try await WPEVideoTextureDiskCache.shared.store(
            videoPayload.bytes,
            workshopID: descriptor.workshopID
        )
        do {
            let source = try WPEVideoTextureSource(
                device: executor.textureSourceDevice,
                videoURL: url,
                // Release the lease (keep the file for reuse) rather than
                // deleting — the cache owns its lifetime now.
                onInvalidate: { staleURL in
                    Task.detached(priority: .utility) {
                        await WPEVideoTextureDiskCache.shared.release(staleURL)
                    }
                }
            )
            _ = label
            return source
        } catch {
            await WPEVideoTextureDiskCache.shared.release(url)
            throw error
        }
    }

    /// Phase 2E: returns a 1×1 transparent texture used as a temporary stand-in for dynamic sources whose first frame has not yet decoded.
    func makeDynamicPlaceholderTexture(label: String) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: WPEMetalRenderExecutor.outputPixelFormat,
            width: 1,
            height: 1,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = executor.textureSourceDevice.makeTexture(descriptor: descriptor) else {
            throw WPEMetalTextureLoaderError.textureAllocationFailed
        }
        texture.label = label
        WPEMetalTextureMetadataRegistry.shared.register(texture: texture)
        var pixel: UInt32 = 0
        texture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0,
            withBytes: &pixel,
            bytesPerRow: 4
        )
        return texture
    }

    // MARK: - Static texture cache & LRU budget

    private func recordLoadedStaticTexture(
        path: String,
        layerName: String,
        candidates: [String],
        texture: MTLTexture
    ) {
        loadedTextures[path] = texture
        staticTexturePlaceholderPaths.remove(path)
        staticTextureReloadThrottles.removeValue(forKey: path)
        let bytes = Self.textureResidentBytes(for: texture)
        staticTextureCacheRecords[path] = StaticTextureCacheRecord(
            layerName: layerName,
            candidates: candidates,
            bytes: bytes
        )
        staticTextureRecordsEpoch += 1
        if textureCacheBudgetBytesInUse != nil {
            textureCacheLRU.admit(path, bytes: bytes)
        }
    }

    private func forgetStaticTextureCacheRecord(_ path: String) {
        staticTextureCacheRecords.removeValue(forKey: path)
        staticTexturePlaceholderPaths.remove(path)
        pendingStaticTextureReloads.remove(path)
        staticTextureReloadThrottles.removeValue(forKey: path)
        staticTextureRecordsEpoch += 1
        textureCacheLRU.remove(path)
    }

    private func resetTextureCacheBudgetState() {
        staticTextureCacheRecords.removeAll(keepingCapacity: false)
        staticTexturePlaceholderPaths.removeAll(keepingCapacity: false)
        pendingStaticTextureReloads.removeAll(keepingCapacity: false)
        staticTextureReloadThrottles.removeAll(keepingCapacity: false)
        cachedActiveStaticPaths.removeAll(keepingCapacity: false)
        cachedActiveStaticSignature = nil
        staticTextureRecordsEpoch += 1
        textureCacheLRU.removeAll()
        textureCacheBudgetBytesInUse = nil
    }

    private func activateTextureCacheBudget(_ budgetBytes: Int) {
        guard textureCacheBudgetBytesInUse != budgetBytes else { return }
        textureCacheLRU = WPEMetalTextureCacheLRU(budgetBytes: budgetBytes)
        textureCacheBudgetBytesInUse = budgetBytes
        for (path, record) in staticTextureCacheRecords
        where loadedTextures[path] != nil && !staticTexturePlaceholderPaths.contains(path) {
            textureCacheLRU.admit(path, bytes: record.bytes)
        }
    }

    private func deactivateTextureCacheBudget() {
        guard textureCacheBudgetBytesInUse != nil else { return }
        textureCacheBudgetBytesInUse = nil
        textureCacheLRU.removeAll()
        // Budget turned off mid-session: reload anything previously evicted so the
        // eager-resident invariant holds again.
        for path in staticTextureCacheRecords.keys where loadedTextures[path] == nil {
            scheduleStaticTextureReload(for: path)
        }
    }

    /// External texture paths the upcoming frame actually samples, restricted to
    /// reloadable static ones (the only eviction candidates). Memoized on a
    /// cheap O(layers) signature — the full layers × passes × refs walk only
    /// reruns when visibility/shape or the record set actually changed.
    private func activeStaticTexturePaths(for pipeline: WPEPreparedRenderPipeline) -> Set<String> {
        var hasher = Hasher()
        hasher.combine(loadGeneration)
        hasher.combine(staticTextureRecordsEpoch)
        hasher.combine(pipeline.layers.count)
        for layer in pipeline.layers {
            hasher.combine(layer.graphLayer.objectID)
            hasher.combine(layer.graphLayer.visible)
            hasher.combine(layer.passes.count)
        }
        let signature = hasher.finalize()
        if signature == cachedActiveStaticSignature {
            return cachedActiveStaticPaths
        }
        let paths = activeExternalTexturePaths(for: pipeline).filter { staticTextureCacheRecords[$0] != nil }
        cachedActiveStaticPaths = paths
        cachedActiveStaticSignature = signature
        return paths
    }

    private func activeExternalTexturePaths(for pipeline: WPEPreparedRenderPipeline) -> Set<String> {
        var paths = Set<String>()
        for layer in pipeline.layers {
            // A plain image layer with no passes is still drawn (encodeCopy) when
            // visible, so its image texture is sampled and must stay protected.
            if layer.passes.isEmpty {
                if layer.graphLayer.visible,
                   let path = externalTexturePath(for: .image(layer.graphLayer.imagePath)) {
                    paths.insert(path)
                }
                continue
            }
            for pass in layer.passes {
                // Hidden layers still encode composite/FBO passes (dependents may
                // sample them); only their scene draw is skipped — mirror that here.
                if !layer.graphLayer.visible {
                    switch pass.pass.target {
                    case .scene:
                        continue
                    case .layerComposite, .fbo:
                        break
                    }
                }
                for reference in requiredTextureReferences(for: pass) {
                    if let path = externalTexturePath(for: reference) {
                        paths.insert(path)
                    }
                }
            }
        }
        return paths
    }

    /// Guarantee every active static path has at least a placeholder this frame
    /// (so an evicted texture never renders as a missing/black draw) and queue a
    /// reload for any that are missing or placeholder-only.
    private func ensureActiveStaticTexturesResident(_ activePaths: Set<String>) throws {
        for path in activePaths {
            if loadedTextures[path] == nil {
                loadedTextures[path] = try makeDynamicPlaceholderTexture(label: "\(path) static placeholder")
                staticTexturePlaceholderPaths.insert(path)
            }
            if staticTexturePlaceholderPaths.contains(path) {
                scheduleStaticTextureReload(for: path)
            }
        }
    }

    private func touchStaticTextureCache(paths: Set<String>) {
        for path in paths {
            textureCacheLRU.touch(path)
        }
    }

    private func evictInactiveStaticTextures(protecting protected: Set<String>) {
        let evicted = textureCacheLRU.evictOverBudget(protecting: protected)
        for path in evicted {
            loadedTextures.removeValue(forKey: path)
            staticTexturePlaceholderPaths.remove(path)
            Logger.info("[WPE.texture-cache] evicted static texture path=\(path)", category: .wpeRender)
        }
    }

    /// Reload an evicted static texture off the main thread, then republish on the
    /// main actor under a `loadGeneration` guard so a reload from a prior scene is
    /// ignored. Triggers a redraw so the placeholder is replaced once resident.
    /// Failed attempts back off per path (`WPEStaticTextureReloadThrottle`).
    private func scheduleStaticTextureReload(for path: String) {
        guard let record = staticTextureCacheRecords[path],
              staticTextureReloadThrottles[path, default: .init()]
                  .allowsAttempt(at: ProcessInfo.processInfo.systemUptime),
              pendingStaticTextureReloads.insert(path).inserted else { return }
        let generation = loadGeneration
        let resolver = resourceResolver
        let loader = textureLoader
        let threshold = Self.lazyAnimationRawByteThreshold
        Task(priority: .utility) { @MainActor [weak self] in
            let result = try? await Self.resolveStaticTextureOrDefer(
                relativePath: path,
                label: "WPE texture \(path)",
                candidates: record.candidates,
                resolver: resolver,
                loader: loader,
                streamingThreshold: threshold
            )
            guard let self, self.loadGeneration == generation else { return }
            self.pendingStaticTextureReloads.remove(path)
            switch result {
            case .staticTexture(let texture):
                self.recordLoadedStaticTexture(
                    path: path,
                    layerName: record.layerName,
                    candidates: record.candidates,
                    texture: texture
                )
            case .needsOnActor:
                do {
                    try await self.loadDynamicTextureOnActor(path: path, layerName: record.layerName)
                } catch {
                    self.noteStaticTextureReloadFailure(path)
                    return
                }
            case .none:
                self.noteStaticTextureReloadFailure(path)
                return
            }
            self.mtkView.setNeedsDisplay(self.mtkView.bounds)
        }
    }

    private func noteStaticTextureReloadFailure(_ path: String) {
        var throttle = staticTextureReloadThrottles[path, default: .init()]
        throttle.recordFailure(at: ProcessInfo.processInfo.systemUptime)
        staticTextureReloadThrottles[path] = throttle
        if throttle.isExhausted {
            Logger.warning("[WPE.texture-cache] reload giving up after \(throttle.failureCount) failures path=\(path)", category: .wpeRender)
        } else {
            Logger.warning("[WPE.texture-cache] reload failed (attempt \(throttle.failureCount)) path=\(path)", category: .wpeRender)
        }
    }

    static func textureResidentBytes(for texture: MTLTexture) -> Int {
        // BC formats are block-compressed in VRAM (the texture loader uploads them
        // compressed); per-pixel math would 4-6x over-count the budget.
        let baseBytes: Int
        switch texture.pixelFormat {
        case .bc1_rgba, .bc1_rgba_srgb:
            baseBytes = compressedTextureBytes(width: texture.width, height: texture.height, bytesPerBlock: 8)
        case .bc2_rgba, .bc2_rgba_srgb, .bc3_rgba, .bc3_rgba_srgb,
             .bc7_rgbaUnorm, .bc7_rgbaUnorm_srgb:
            baseBytes = compressedTextureBytes(width: texture.width, height: texture.height, bytesPerBlock: 16)
        default:
            baseBytes = texture.width * texture.height * textureCacheBytesPerPixel(for: texture.pixelFormat)
        }
        // No loader path generates mips today; the 4/3 mip-chain bound keeps the
        // estimate honest if one ever does.
        return texture.mipmapLevelCount > 1 ? baseBytes * 4 / 3 : baseBytes
    }

    private static func compressedTextureBytes(width: Int, height: Int, bytesPerBlock: Int) -> Int {
        max((width + 3) / 4, 1) * max((height + 3) / 4, 1) * bytesPerBlock
    }

    private static func textureCacheBytesPerPixel(for pixelFormat: MTLPixelFormat) -> Int {
        switch pixelFormat {
        case .rgba16Float: return 8
        case .rg8Unorm: return 2
        case .r8Unorm: return 1
        default: return 4
        }
    }

    // MARK: - Per-frame textures

    /// Phase 2E: pulls fresh `MTLTexture`s from dynamic sources and enforces the
    /// optional static-texture VRAM budget before every render call.
    func texturesForCurrentFrame(time: TimeInterval, pipeline: WPEPreparedRenderPipeline) throws -> [String: MTLTexture] {
        for (path, source) in dynamicTextureSources {
            if let texture = source.texture(at: time) {
                loadedTextures[path] = texture
            }
        }

        // Zero overhead on the unbounded (budget off, nothing evicted) path:
        // only walk active paths when the budget is/was active or a placeholder
        // still awaits reload.
        if textureCacheBudgetBytesResolved != nil
            || textureCacheBudgetBytesInUse != nil
            || !staticTexturePlaceholderPaths.isEmpty {
            let activeStaticPaths = activeStaticTexturePaths(for: pipeline)
            try ensureActiveStaticTexturesResident(activeStaticPaths)
            if let budgetBytes = textureCacheBudgetBytesResolved {
                activateTextureCacheBudget(budgetBytes)
                touchStaticTextureCache(paths: activeStaticPaths)
                evictInactiveStaticTextures(protecting: activeStaticPaths)
            } else {
                deactivateTextureCacheBudget()
            }
        }
        return loadedTextures
    }

    func releaseDynamicTextureSources() {
        dynamicTextureSources.values.forEach { $0.invalidate() }
        dynamicTextureSources.removeAll()
        loadedTextures.removeAll()
        resetTextureCacheBudgetState()
    }

    private func shouldTryTexturePayload(_ path: String) -> Bool {
        Self.shouldTryTexturePayload(path)
    }

    /// `nonisolated` twin so the off-actor parallel-resolve lane can make the
    /// same `.tex`-vs-raster decision the on-actor path uses.
    private nonisolated static func shouldTryTexturePayload(_ path: String) -> Bool {
        let extensionName = (path as NSString).pathExtension.lowercased()
        return !knownRawImageExtensions.contains(extensionName)
    }

    /// Raster image extensions that `WPETextureLoader` can load via ImageIO
    /// without going through the `.tex` container. Path lookups ending in one
    /// of these are taken at face value; anything else (including names that
    /// merely *look* like they end in an extension because they contain a dot)
    /// goes through the materials/-prefix fallback below.
    nonisolated static let knownRawImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "tga", "dds", "bmp", "gif", "webp"
    ]

    // MARK: - Path candidate resolution

    /// Visible to `@testable` test suites that probe the candidate generator without spinning up a full renderer fixture.
    func textureCandidates(for path: String) -> [String] {
        let extensionName = (path as NSString).pathExtension.lowercased()
        if extensionName == "tex" || extensionName == "json" {
            return [path]
        }
        if !extensionName.isEmpty, Self.knownRawImageExtensions.contains(extensionName) {
            // WPE converts source images to `<name>.<ext>.tex` (e.g. a particle
            // sprite `workshop/…/雪花.jpg` is stored as
            // `materials/workshop/…/雪花.jpg.tex`). Try the literal image, then
            // the converted `.tex`, including under the `materials/` root —
            // otherwise extension-bearing refs never find their `.tex`.
            var candidates = [path, "\(path).tex"]
            let anchored = ["materials/", "models/", "shaders/", "fonts/",
                            "scripts/", "particles/", "sounds/", "scenes/", "../", "_"]
            if !anchored.contains(where: path.hasPrefix) {
                candidates.append("materials/\(path)")
                candidates.append("materials/\(path).tex")
            }
            return candidates
        }

        if let dependency = dependencyReference(path) {
            let child = dependency.childPath
            if child.contains("/") {
                return [
                    path,
                    "\(path).tex",
                    "\(path).png",
                    "\(path).jpg",
                    "\(path).jpeg"
                ]
            }
            let prefix = "../\(dependency.workshopID)"
            return [
                "\(prefix)/materials/\(child).tex",
                "\(prefix)/materials/\(child).png",
                "\(prefix)/materials/\(child).jpg",
                "\(prefix)/materials/\(child).jpeg",
                path
            ]
        }

        if path.hasPrefix("_"), !path.hasPrefix("__") {
            return [path]
        }

        if path.contains("/") {
            let anchoredPrefixes = ["materials/", "models/", "shaders/", "fonts/", "scripts/", "particles/", "sounds/", "scenes/"]
            if anchoredPrefixes.contains(where: path.hasPrefix) {
                return [
                    path,
                    "\(path).tex",
                    "\(path).png",
                    "\(path).jpg",
                    "\(path).jpeg"
                ]
            }
            return [
                "materials/\(path).tex",
                "materials/\(path).png",
                "materials/\(path).jpg",
                "materials/\(path).jpeg",
                path,
                "\(path).tex",
                "\(path).png",
                "\(path).jpg",
                "\(path).jpeg"
            ]
        }

        return [
            "materials/\(path).tex",
            "materials/\(path).png",
            "materials/\(path).jpg",
            "materials/\(path).jpeg",
            path
        ]
    }

    private func dependencyReference(_ relativePath: String) -> (workshopID: String, childPath: String)? {
        guard relativePath.hasPrefix("../") else { return nil }
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] == ".." else { return nil }
        return (String(parts[1]), parts.dropFirst(2).joined(separator: "/"))
    }

    // MARK: - Load diagnostics

    /// Maps any error raised during `performLoad()` onto the shared `SceneLoadDiagnostic` taxonomy so the UI gets one consistent failure-reporting path.
    func diagnostic(for error: Error) -> SceneLoadDiagnostic {
        diagnostic(for: error, fallbackPath: nil, layerName: "scene")
    }

    func diagnostic(
        for error: Error,
        fallbackPath: String?,
        layerName: String
    ) -> SceneLoadDiagnostic {
        switch error {
        case let context as WPEMetalTextureLoadContextError:
            return diagnostic(
                for: context.underlying,
                fallbackPath: context.path,
                layerName: context.layerName
            )
        case let executorError as WPEMetalRenderExecutorError:
            switch executorError {
            case .unsupportedShader(let name):
                return .materialUnresolved(layer: layerName, reason: "Shader \"\(name)\" is not supported by the Metal renderer yet.")
            case .shaderTranslatorUnavailable(let name, let reason):
                return .materialUnresolved(
                    layer: layerName,
                    reason: "Shader \"\(name)\" needs the WPE GLSL translator: \(reason)"
                )
            case .pipelineStateBuildFailed(let name, let detail):
                return .materialUnresolved(
                    layer: layerName,
                    reason: "Metal pipeline for \"\(name)\" failed to build: \(detail)"
                )
            case .unsupportedTarget:
                return .materialUnresolved(layer: layerName, reason: "This wallpaper uses an unsupported rendering target.")
            case .renderTargetDimensionsExceedDeviceLimit(let targetName, let width, let height, let limit):
                return .materialUnresolved(
                    layer: layerName,
                    reason: "Render target \"\(targetName)\" is \(width)x\(height), exceeding this device's \(limit)x\(limit) Metal texture limit."
                )
            case .missingTexture(let reference):
                switch reference {
                case .image(let path), .asset(let path), .fbo(let path):
                    return .fileMissing(layer: layerName, path: path)
                case .previous:
                    return .materialUnresolved(layer: layerName, reason: "Previous-frame effects (motion blur, feedback) are not yet supported.")
                }
            case .noRenderablePasses:
                return .materialUnresolved(layer: layerName, reason: "Scene contains no renderable passes.")
            case .commandQueueUnavailable, .libraryUnavailable, .pipelineUnavailable, .commandBufferFailed:
                return .other(layer: layerName, message: executorError.errorDescription ?? "Metal renderer failed.")
            }
        case let loaderError as WPEMetalTextureLoaderError:
            switch loaderError {
            case .unsupportedFormat, .unsupportedCompressedFormat, .malformedPayload, .textureAllocationFailed:
                return .other(layer: layerName, message: loaderError.errorDescription ?? "Texture upload failed.")
            }
        case let resolveError as SceneResourceResolver.ResolveError:
            switch resolveError {
            case .fileMissing:
                return .fileMissing(layer: layerName, path: fallbackPath ?? descriptor.entryFile)
            case .pathEscape:
                return .crossPackageReference(layer: layerName, path: fallbackPath ?? descriptor.entryFile)
            case .materialUnresolved(let reason):
                return .materialUnresolved(layer: layerName, reason: reason)
            case .texture(let texError):
                return .texture(layer: layerName, error: texError)
            case .unsupportedTexture:
                return .legacyUnsupportedTexture(layer: layerName)
            case .decodeFailed:
                return .other(
                    layer: layerName,
                    message: String(
                        localized: "A texture or image file is corrupted and cannot be decoded.",
                        defaultValue: "A texture or image file is corrupted and cannot be decoded.",
                        comment: "Wallpaper Engine fallback diagnostic when a texture decode fails because the file is corrupt."
                    )
                )
            }
        default:
            return .other(layer: layerName, message: error.localizedDescription)
        }
    }
}

/// Phase 2C: filters out FBO/previous references at the texture-discovery
/// layer so the renderer never tries to load an in-graph FBO from disk.
/// Those references resolve at executor time via the frame state.
private extension WPETextureReference {
    var isExternalTextureReference: Bool {
        switch self {
        case .image, .asset:
            return true
        case .fbo, .previous:
            return false
        }
    }
}
#endif
