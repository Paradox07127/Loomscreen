#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import MetalKit
import os
import simd
extension WPEMetalRenderExecutor {
    func releaseTransientResources() {
        targetPool.releaseAll()
        releaseBloomLevels()
        previousFrameHistory = nil
        invalidateStaticLayerCache()
        // Clip-role detection + activation diagnostics are keyed by objectID, which a reload can reuse
        // for a different puppet/material/animation, so drop them when the graph is rebuilt.
        puppetClipPairsCache.removeAll()
        loggedClipActivation.removeAll()
        loggedComponentMapResolveFailures.removeAll()
        characterSheetWarnedReasonByObjectID.removeAll()
        puppetBoundScanDetailByObjectID.removeAll()
        puppetPaletteCacheByObjectID.removeAll()
        lastLoggedPuppetSkinningReason.removeAll()
        bonePaletteBufferPool.drain()
        puppetMeshBufferCache.removeAll()
        // Scene size / pipeline may change across a reload; drop the recycled
        // frame targets so the next render() re-allocates at the right size.
        outputTexturePool.removeAll()
        recentOutputTextureIDs.removeAll()
        bootstrapPreviousTextureCache.removeAll()
        // Pass-id keyed; a reload can reuse an id for a different shader, so drop
        // it here (reload routes through releaseTransientResources). The
        // content-keyed translatedShaderCache is safe to persist and is not cleared.
        compiledShaderResultByPassID.removeAll()
    }

    /// Drops every cached static-layer composite. Called on scene reload /
    /// pipeline rebuild / sceneSize change so a new scene never reads stale pixels.
    func invalidateStaticLayerCache() {
        staticLayerCompositeCache.removeAll()
        staticLayerCacheSceneSize = nil
        loggedStaticLayerCacheHits.removeAll(keepingCapacity: false)
    }

    // MARK: - FBO memory diagnostic (read-only)

    private static func fboReportDeclaredFBOs(in pipeline: WPEPreparedRenderPipeline) -> [String: WPERenderFBO] {
        var declared: [String: WPERenderFBO] = [:]
        for layer in pipeline.layers {
            for fbo in layer.graphLayer.localFBOs {
                declared[fbo.name] = fbo
            }
        }
        return declared
    }

    /// Conservative alias intervals handed to the target pool: per pool-FBO key,
    /// its `[firstPass, lastPass]` over the flattened render order. Reads use the
    /// UNION (`textureReferences`) so a target's last use is never under-counted
    /// — the pool may only make it aliasable AFTER this index, never before
    /// (which would corrupt the frame). Ping-pong secondaries are excluded (they
    /// need two simultaneous textures and stay on the discrete path).
    func fboAliasIntervals(
        pipeline: WPEPreparedRenderPipeline,
        sceneSize: CGSize
    ) -> [WPEMetalRenderTargetPool.AliasInterval] {
        let declaredFBOs = Self.fboReportDeclaredFBOs(in: pipeline)
        var flattened: [(index: Int, layer: WPEPreparedRenderLayer, pass: WPEPreparedRenderPass)] = []
        var passIndex = 0
        for layer in pipeline.layers {
            for pass in layer.passes {
                flattened.append((passIndex, layer, pass))
                passIndex += 1
            }
        }

        func poolKey(for target: WPERenderTarget, layer: WPEPreparedRenderLayer) -> WPEMetalRenderTargetKey? {
            switch target {
            case .scene:
                return nil
            case .fbo, .layerComposite:
                return targetPool.diagnosticKey(for: target, layer: layer.graphLayer, sceneSize: sceneSize, declaredFBOs: declaredFBOs)
            }
        }

        var keysByName: [String: Set<WPEMetalRenderTargetKey>] = [:]
        for item in flattened {
            if let key = poolKey(for: item.pass.pass.target, layer: item.layer) {
                keysByName[key.name, default: []].insert(key)
            }
        }

        var firstPassByKey: [WPEMetalRenderTargetKey: Int] = [:]
        var lastPassByKey: [WPEMetalRenderTargetKey: Int] = [:]
        var secondaryKeys = Set<WPEMetalRenderTargetKey>()
        var nonAliasKeys = Set<WPEMetalRenderTargetKey>()
        var writtenTargets = Set<WPEMetalTargetID>()

        func touch(_ key: WPEMetalRenderTargetKey, _ index: Int) {
            if firstPassByKey[key] == nil { firstPassByKey[key] = index }
            lastPassByKey[key] = max(lastPassByKey[key] ?? index, index)
        }

        for item in flattened {
            let targetID = WPEMetalTargetID(target: item.pass.pass.target)
            let targetKey = poolKey(for: item.pass.pass.target, layer: item.layer)
            if let targetKey {
                touch(targetKey, item.index)
                if writtenTargets.contains(targetID),
                   passReadsCurrentTarget(item.pass, targetID: targetID) {
                    secondaryKeys.insert(targetKey)
                }
            }
            for reference in textureReferences(for: item.pass) {
                switch reference {
                case .fbo(let name):
                    for namedKey in keysByName[name] ?? [] { touch(namedKey, item.index) }
                    if Self.requiresDiscreteDestinationForSourceAliasing(item.pass) {
                        for namedKey in keysByName[name] ?? [] { nonAliasKeys.insert(namedKey) }
                    }
                case .previous:
                    if let targetKey { touch(targetKey, item.index) }
                case .image, .asset:
                    break
                }
            }
            writtenTargets.insert(targetID)
        }

        return firstPassByKey.compactMap { key, first in
            guard !secondaryKeys.contains(key),
                  !nonAliasKeys.contains(key),
                  let last = lastPassByKey[key] else { return nil }
            return WPEMetalRenderTargetPool.AliasInterval(key: key, firstPass: first, lastPass: last)
        }
    }

    /// Snapshots every composite whose last producer is `passIndex` into a
    /// persistent texture, redirects `frameState` so this frame already reads the
    /// snapshot (identical pixels), and — once all of the plan's targets are
    /// captured — commits them to the cache as one layer entry. If the layer's
    /// total exceeds the budget, the partial snapshots are discarded and the
    /// layer keeps re-rendering (slower, never wrong).
    func captureStaticLayerSnapshots(
        at passIndex: Int,
        plan: WPEMetalStaticLayerCachePlan,
        layer: WPERenderLayer,
        commandBuffer: MTLCommandBuffer,
        frameState: inout WPEMetalFrameState,
        snapshots: inout [String: MTLTexture],
        bytes: inout Int
    ) {
        for (targetName, producerIndex) in plan.cachedTargets where producerIndex == passIndex {
            guard snapshots[targetName] == nil,
                  let source = frameState.latestNamedTextures[targetName] else { continue }
            do {
                let cached = try targetPool.persistentTexture(
                    matching: source,
                    label: "WPE static layer cache \(layer.objectID) \(targetName)"
                )
                try copyTexture(source, to: cached, commandBuffer: commandBuffer)
                frameState.seedPreviousTexture(cached, targetID: .named(targetName))
                frameState.markInitialized(cached)
                snapshots[targetName] = cached
                bytes += Self.staticLayerCacheBytes(for: source)
            } catch {
                Logger.warning(
                    "[WPE.static-layer-cache] snapshot failed layer=\(layer.objectID) target=\(targetName): \(error)",
                    category: .wpeRender
                )
            }
        }

        // Commit only once every planned target is captured this frame.
        guard snapshots.count == plan.cachedTargets.count else { return }
        guard staticLayerCompositeCache.canAdmit(bytes: bytes) else {
            Logger.info(
                "[WPE.static-layer-cache] skip cache layer=\(layer.objectID) bytes=\(bytes) over budget",
                category: .wpeRender
            )
            return
        }
        let evicted = staticLayerCompositeCache.insert(
            layerID: layer.objectID,
            texturesByTarget: snapshots,
            bytes: bytes
        )
        Logger.info(
            "[WPE.static-layer-cache] cached layer=\(layer.objectID) targets=\(snapshots.count) passes=\(plan.compositePassCount) bytes=\(bytes)",
            category: .wpeRender
        )
        for layerID in evicted where layerID != layer.objectID {
            loggedStaticLayerCacheHits.remove(layerID)
            Logger.info("[WPE.static-layer-cache] evicted layer=\(layerID)", category: .wpeRender)
        }
    }

    private static func staticLayerCacheBytes(for texture: MTLTexture) -> Int {
        texture.width * texture.height * staticLayerCacheBytesPerPixel(for: texture.pixelFormat)
    }

    private static func staticLayerCacheBytesPerPixel(for pixelFormat: MTLPixelFormat) -> Int {
        switch pixelFormat {
        case .rgba16Float: return 8
        case .r8Unorm: return 1
        default: return 4
        }
    }

    /// Targets used by more than one depth pass (depth-write OR depth-test) — a
    /// later pass can `.load` an earlier pass's depth (e.g. `depthTest:less` across
    /// encoders), so their depth must stay persistent rather than transient/memoryless.
    func computePersistentDepthTargetIDs(
        for pipeline: WPEPreparedRenderPipeline
    ) -> Set<WPEMetalTargetID> {
        var depthPassCounts: [WPEMetalTargetID: Int] = [:]
        for layer in pipeline.layers {
            for pass in layer.passes where depthCache.needsAttachment(for: pass) {
                depthPassCounts[WPEMetalTargetID(target: pass.pass.target), default: 0] += 1
            }
        }
        return Set(depthPassCounts.compactMap { $0.value > 1 ? $0.key : nil })
    }

    func makeOutputTexture(size: CGSize) throws -> MTLTexture {
        let width = max(Int(size.width), 1)
        let height = max(Int(size.height), 1)
        let pixelFormat = currentOutputPixelFormat
        outputTexturePool.removeAll {
            $0.width != width || $0.height != height || $0.pixelFormat != pixelFormat
        }
        if let recycled = outputTexturePool.first(where: isOutputTextureReusable) {
            noteVendedOutputTexture(recycled)
            return recycled
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw WPEMetalTextureLoaderError.textureAllocationFailed
        }
        texture.label = "WPE Metal executor output"
        outputTexturePool.append(texture)
        // Steady state needs 3 (in-render + re-presented latest + history);
        // anything beyond that came from transient stalls — let ARC reap
        // the dropped one once its holders release it.
        if outputTexturePool.count > 4 {
            outputTexturePool.removeFirst()
        }
        noteVendedOutputTexture(texture)
        return texture
    }

    private func isOutputTextureReusable(_ texture: MTLTexture) -> Bool {
        let id = ObjectIdentifier(texture)
        if recentOutputTextureIDs.contains(id) {
            return false
        }
        if let history = previousFrameHistory?.sceneTexture, history === texture {
            return false
        }
        return !presentTracker.isInFlight(id)
    }

    private func noteVendedOutputTexture(_ texture: MTLTexture) {
        let id = ObjectIdentifier(texture)
        recentOutputTextureIDs.removeAll { $0 == id }
        recentOutputTextureIDs.append(id)
        // Keep the last `maxFramesInFlight` vended targets out of the reuse set:
        // under async submission their render may still be running, and the
        // in-flight semaphore guarantees it has finished by the time the target
        // ages out of this window. Keep at least 2 for the static-scene re-present
        // + `previousFrameHistory` reads even when only 1 frame is in flight.
        let retain = max(2, Self.maxFramesInFlight)
        if recentOutputTextureIDs.count > retain {
            recentOutputTextureIDs.removeFirst(recentOutputTextureIDs.count - retain)
        }
    }

    func targetTexture(
        for target: WPERenderTarget,
        layer: WPERenderLayer,
        frameState: inout WPEMetalFrameState,
        avoiding textureToAvoid: MTLTexture? = nil
    ) throws -> (id: WPEMetalTargetID, texture: MTLTexture) {
        let targetID = WPEMetalTargetID(target: target)
        switch target {
        case .scene:
            return (targetID, frameState.output)
        case .fbo, .layerComposite:
            let texture = try targetPool.texture(
                for: target,
                layer: layer,
                sceneSize: frameState.sceneSize,
                avoiding: textureToAvoid
            )
            return (targetID, texture)
        }
    }

    func previousTextureForRead(
        targetID: WPEMetalTargetID,
        matching destination: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        frameState: inout WPEMetalFrameState
    ) throws -> MTLTexture {
        if let texture = frameState.latestTexture(for: targetID) {
            return texture
        }
        let texture = try makeClearedPreviousTexture(
            matching: destination,
            targetID: targetID,
            commandBuffer: commandBuffer
        )
        frameState.seedPreviousTexture(texture, targetID: targetID)
        frameState.markInitialized(texture)
        return texture
    }

    /// A stable snapshot of the live scene `output` for a pass that reads
    /// `.previous` while also writing the scene (see the read-write hazard note at
    /// the call site). Copies the scene-so-far into a cached scratch (one per
    /// size/format, reused every frame since it's re-copied before each read) so
    /// `.previous` binds to a frozen image instead of the texture being drawn.
    func sceneReadHazardSnapshot(
        matching source: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) throws -> MTLTexture {
        let key = BootstrapPreviousKey(
            targetID: .scene,
            width: source.width,
            height: source.height,
            pixelFormat: source.pixelFormat
        )
        let snapshot: MTLTexture
        if let cached = sceneReadHazardSnapshotCache[key] {
            snapshot = cached
        } else {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: source.pixelFormat,
                width: source.width,
                height: source.height,
                mipmapped: false
            )
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            guard let made = device.makeTexture(descriptor: descriptor) else {
                throw WPEMetalTextureLoaderError.textureAllocationFailed
            }
            made.label = "WPE Metal scene .previous read snapshot"
            sceneReadHazardSnapshotCache[key] = made
            snapshot = made
        }
        try copyTexture(source, to: snapshot, commandBuffer: commandBuffer)
        return snapshot
    }

    private func makeClearedPreviousTexture(
        matching texture: MTLTexture,
        targetID: WPEMetalTargetID,
        commandBuffer: MTLCommandBuffer
    ) throws -> MTLTexture {
        // Bootstrap textures are read-only for their whole life (writes go to
        // the pool/output, never to the seeded `.previous` source), so one
        // cleared allocation per (target, size, format) serves every frame —
        // previously this allocated + cleared a scene-sized texture per frame.
        let key = BootstrapPreviousKey(
            targetID: targetID,
            width: texture.width,
            height: texture.height,
            pixelFormat: texture.pixelFormat
        )
        if let cached = bootstrapPreviousTextureCache[key] {
            return cached
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat,
            width: texture.width,
            height: texture.height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let cleared = device.makeTexture(descriptor: descriptor) else {
            throw WPEMetalTextureLoaderError.textureAllocationFailed
        }
        cleared.label = "WPE Metal bootstrap previous"

        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = cleared
        renderPass.colorAttachments[0].loadAction = .clear
        renderPass.colorAttachments[0].storeAction = .store
        renderPass.colorAttachments[0].clearColor = clearColor(for: targetID)
        gpuPassProfiler?.attach(renderPass, to: commandBuffer, label: "bootstrapClear")
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }
        encoder.endEncoding()
        bootstrapPreviousTextureCache[key] = cleared
        return cleared
    }

}
#endif
