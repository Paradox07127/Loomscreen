#if !LITE_BUILD
import CoreGraphics
import Foundation
import Metal

private func wpeRenderTargetDimension(_ base: CGFloat, scale: Double) -> Int {
    // WPE effect FBO scale is a downsample divisor: scale 4 means one quarter size.
    let divisor = scale.isFinite && scale > 0 ? scale : 1
    return max(Int((Double(base) / divisor).rounded()), 1)
}

/// Identity for a pooled Metal render target. Same name + same scaled
/// dimensions + same format share a slot; if a pass would read its own
/// destination texture (e.g. `.previous` ping-pong), the pool returns the
/// per-slot secondary allocation so Metal never samples from and renders
/// into the same texture in one encoder.
struct WPEMetalRenderTargetKey: Hashable {
    let name: String
    let width: Int
    let height: Int
    let format: String
    let pixelFormat: MTLPixelFormat

    init(name: String, sceneSize: CGSize, scale: Double, format: String, pixelFormat: MTLPixelFormat) {
        self.name = name
        self.width = wpeRenderTargetDimension(sceneSize.width, scale: scale)
        self.height = wpeRenderTargetDimension(sceneSize.height, scale: scale)
        self.format = format.lowercased()
        self.pixelFormat = pixelFormat
    }

    init(name: String, width: Int, height: Int, format: String, pixelFormat: MTLPixelFormat) {
        self.name = name
        self.width = max(width, 1)
        self.height = max(height, 1)
        self.format = format.lowercased()
        self.pixelFormat = pixelFormat
    }
}

/// Persistent FBO/layer-composite allocation pool used by
/// `WPEMetalRenderExecutor`. Allocations live across `render(...)` calls and are
/// released on `applyPerformanceProfile(.suspended)`, `reload()`, `cleanup()`.
///
/// `MTLHeap` is preferred when `heapTextureSizeAndAlign` reports non-zero;
/// otherwise falls back to discrete `makeTexture`. The heap reference is held
/// next to the texture so the heap is not deallocated while the texture is
/// still in the pool.
final class WPEMetalRenderTargetPool {
    private struct Allocation {
        let texture: MTLTexture
        let heap: MTLHeap?
    }

    private final class Slot {
        var primary: Allocation?
        var secondary: Allocation?
    }

    /// A render target's within-frame lifetime `[firstPass, lastPass]` (flattened
    /// pass order), fed by the executor so the pool can pack non-overlapping
    /// targets into one shared heap. Lifetimes are computed conservatively (last
    /// use never under-estimated), so a target is only made aliasable AFTER its
    /// real last GPU use — never before (which would corrupt the frame).
    struct AliasInterval {
        let key: WPEMetalRenderTargetKey
        let firstPass: Int
        let lastPass: Int
    }

    static let fboAliasingDefaultsKey = "WPEMetalFBOAliasingEnabled"
    /// Default ON (on-device validated). Manual override wins:
    /// `defaults write … WPEMetalFBOAliasingEnabled -bool NO` forces the
    /// discrete-per-target path back on. Read once on first use, then cached —
    /// restart to apply (this ran per-target per-frame ≈ 11–17% of render CPU in trace).
    static let isFBOAliasingEnabled: Bool =
        UserDefaults.standard.object(forKey: fboAliasingDefaultsKey) as? Bool ?? true

    static let layerLocalFBOSizingDefaultsKey = "WPEMetalLayerLocalFBOSizing"
    /// Size a layer's OWN local effect FBOs (`layer.localFBOs`, not scene-wide
    /// declared FBOs and not scene aliases) to the layer footprint instead of the
    /// full scene — a small overlay's blur/glow FBO at 4K otherwise allocates and
    /// renders ~99.5% wasted pixels. Default ON (device-validated 2026-06-26: memory
    /// dropped, no visual regression). Manual override wins:
    /// `defaults write … WPEMetalLayerLocalFBOSizing -bool NO` restores full-scene FBOs.
    /// Read once on first use, then cached — restart to apply.
    static let isLayerLocalFBOSizingEnabled: Bool =
        UserDefaults.standard.object(forKey: layerLocalFBOSizingDefaultsKey) as? Bool ?? true

    /// Pixel footprint for a layer-private effect FBO when `isLayerLocalFBOSizingEnabled`:
    /// the layer's own footprint instead of the full scene. Used by BOTH `targetKey`
    /// (allocation) and `diagnosticKey` (alias planning) so they can never mis-key.
    /// nil → keep the full-scene default (scene alias, cross-layer declared FBO, or flag off).
    /// Only `layer.localFBOs` entries qualify (no other layer reads them).
    /// (A `WPEMetalLayerLocalFBOScale` downsample knob was tried + removed: shrinking a
    /// scene-sized FBO to a distinct half-scene size took it OUT of the shared FBO-aliasing
    /// heap → separate allocation → device-measured memory went UP, not down.)
    static func layerLocalFBOPixelSize(
        fboName: String,
        layer: WPERenderLayer,
        sceneSize: CGSize,
        enabled: Bool = isLayerLocalFBOSizingEnabled
    ) -> CGSize? {
        guard enabled,
              !WPEMetalShaderInputs.isSceneAliasName(fboName),
              layer.localFBOs.contains(where: { $0.name == fboName }) else { return nil }
        return layerCompositeSize(for: layer, sceneSize: sceneSize)
    }

    private let device: MTLDevice
    private let maximumTextureDimension2D: Int
    private var slots: [WPEMetalRenderTargetKey: Slot] = [:]
    private var declaredFBOs: [String: WPERenderFBO] = [:]

    // Aliasing state (only populated when WPEMetalFBOAliasingEnabled).
    private var aliasHeap: MTLHeap?
    private var aliasLastPassByKey: [WPEMetalRenderTargetKey: Int] = [:]
    private var aliasFrameTextures: [WPEMetalRenderTargetKey: (texture: MTLTexture, lastPass: Int)] = [:]
    private var aliasPlanSignature: Int?

    init(device: MTLDevice, maximumTextureDimension2D: Int? = nil) {
        self.device = device
        self.maximumTextureDimension2D = maximumTextureDimension2D
            ?? WPEMetalTextureLimits.maximum2DTextureDimension(for: device)
    }

    func prepare(
        pipeline: WPEPreparedRenderPipeline,
        aliasIntervals: [AliasInterval] = []
    ) {
        declaredFBOs.removeAll(keepingCapacity: true)
        for layer in pipeline.layers {
            for fbo in layer.graphLayer.localFBOs {
                declaredFBOs[fbo.name] = fbo
            }
        }

        guard Self.isFBOAliasingEnabled, !aliasIntervals.isEmpty else {
            releaseAliasState()
            return
        }
        prepareAliasPlan(aliasIntervals)
    }

    func releaseAll() {
        slots.removeAll(keepingCapacity: true)
        declaredFBOs.removeAll(keepingCapacity: true)
        releaseAliasState()
    }

    /// Persistent texture outside the per-frame alias plan: a static layer
    /// composite retained across frames must NOT come from the alias heap (whose
    /// textures are made reusable at frame boundaries) — it gets a discrete one.
    func persistentTexture(matching source: MTLTexture, label: String) throws -> MTLTexture {
        try validateTextureDimensions(targetName: label, width: source.width, height: source.height)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: source.pixelFormat,
            width: source.width,
            height: source.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw WPEMetalTextureLoaderError.textureAllocationFailed
        }
        texture.label = label
        WPEMetalTextureMetadataRegistry.shared.register(texture: texture)
        return texture
    }

    /// Start of each `render()`. Drops the prior frame's aliasable textures so
    /// this frame allocates fresh; the single serial command queue guarantees the
    /// prior frame's GPU work finished before this frame reuses the memory.
    func beginAliasFrame() {
        guard Self.isFBOAliasingEnabled, !aliasFrameTextures.isEmpty else { return }
        for entry in aliasFrameTextures.values {
            entry.texture.makeAliasable()
        }
        aliasFrameTextures.removeAll(keepingCapacity: true)
    }

    /// After each pass: any aliased target whose last use is this pass is made
    /// aliasable so a later target can reuse its heap memory. The driver (tracked
    /// automatic heap) inserts the read-before-write barrier.
    func endPass(passIndex: Int) {
        guard Self.isFBOAliasingEnabled, !aliasFrameTextures.isEmpty else { return }
        for (key, entry) in aliasFrameTextures where entry.lastPass == passIndex {
            entry.texture.makeAliasable()
            aliasFrameTextures.removeValue(forKey: key)
        }
    }

    /// Read-only twin of `texture(...)` keying: the slot key a target resolves to
    /// WITHOUT allocating. Used by `WPEMetalFBOMemoryReport` to account FBO memory
    /// statically.
    func diagnosticKey(
        for target: WPERenderTarget,
        layer: WPERenderLayer,
        sceneSize: CGSize,
        declaredFBOs: [String: WPERenderFBO]
    ) -> WPEMetalRenderTargetKey {
        let spec: WPERenderFBO
        switch target {
        case .scene:
            spec = WPERenderFBO(name: "scene", scale: 1, format: "rgba8888")
        case .layerComposite(let name):
            spec = WPERenderFBO(name: name, scale: 1, format: "rgba8888")
        case .fbo(let name):
            spec = declaredFBOs[name]
                ?? layer.localFBOs.first(where: { $0.name == name })
                ?? WPERenderFBO(name: name, scale: 1, format: "rgba8888")
        }

        let pixelFormat = Self.pixelFormat(forFBOFormat: spec.format)
        if case .layerComposite = target {
            let localSize = Self.layerCompositeSize(for: layer, sceneSize: sceneSize)
            return WPEMetalRenderTargetKey(
                name: spec.name,
                width: wpeRenderTargetDimension(localSize.width, scale: spec.scale),
                height: wpeRenderTargetDimension(localSize.height, scale: spec.scale),
                format: spec.format,
                pixelFormat: pixelFormat
            )
        }
        if case .fbo(let fboName) = target,
           let localSize = Self.layerLocalFBOPixelSize(fboName: fboName, layer: layer, sceneSize: sceneSize) {
            return WPEMetalRenderTargetKey(
                name: spec.name,
                width: wpeRenderTargetDimension(localSize.width, scale: spec.scale),
                height: wpeRenderTargetDimension(localSize.height, scale: spec.scale),
                format: spec.format,
                pixelFormat: pixelFormat
            )
        }
        return WPEMetalRenderTargetKey(
            name: spec.name,
            sceneSize: sceneSize,
            scale: spec.scale,
            format: spec.format,
            pixelFormat: pixelFormat
        )
    }

    func texture(
        for target: WPERenderTarget,
        layer: WPERenderLayer,
        sceneSize: CGSize,
        avoiding textureToAvoid: MTLTexture?
    ) throws -> MTLTexture {
        let spec = targetSpec(for: target, layer: layer)
        let pixelFormat = Self.pixelFormat(forFBOFormat: spec.format)
        let key = targetKey(
            for: target,
            spec: spec,
            layer: layer,
            sceneSize: sceneSize,
            pixelFormat: pixelFormat
        )

        // Aliased primary: heap-backed, shared with non-overlapping targets.
        // Ping-pong secondaries (textureToAvoid != nil) and non-planned keys fall
        // through to the discrete per-key path below.
        if Self.isFBOAliasingEnabled, textureToAvoid == nil, let lastPass = aliasLastPassByKey[key] {
            return try aliasTexture(for: key, lastPass: lastPass)
        }

        let slot = slots[key] ?? Slot()
        slots[key] = slot

        if slot.primary == nil {
            slot.primary = try makeAllocation(key: key, label: "primary")
        }

        if let textureToAvoid,
           let primary = slot.primary,
           primary.texture === textureToAvoid {
            if slot.secondary == nil {
                slot.secondary = try makeAllocation(key: key, label: "secondary")
            }
            guard let secondary = slot.secondary else {
                throw WPEMetalTextureLoaderError.textureAllocationFailed
            }
            return secondary.texture
        }

        guard let primary = slot.primary else {
            throw WPEMetalTextureLoaderError.textureAllocationFailed
        }
        return primary.texture
    }

    private func targetSpec(for target: WPERenderTarget, layer: WPERenderLayer) -> WPERenderFBO {
        switch target {
        case .scene:
            return WPERenderFBO(name: "scene", scale: 1, format: "rgba8888")
        case .layerComposite(let name):
            return WPERenderFBO(name: name, scale: 1, format: "rgba8888")
        case .fbo(let name):
            return declaredFBOs[name]
                ?? layer.localFBOs.first(where: { $0.name == name })
                ?? WPERenderFBO(name: name, scale: 1, format: "rgba8888")
        }
    }

    private func targetKey(
        for target: WPERenderTarget,
        spec: WPERenderFBO,
        layer: WPERenderLayer,
        sceneSize: CGSize,
        pixelFormat: MTLPixelFormat
    ) -> WPEMetalRenderTargetKey {
        switch target {
        case .layerComposite:
            let localSize = Self.layerCompositeSize(
                for: layer,
                sceneSize: sceneSize
            )
            return WPEMetalRenderTargetKey(
                name: spec.name,
                width: wpeRenderTargetDimension(localSize.width, scale: spec.scale),
                height: wpeRenderTargetDimension(localSize.height, scale: spec.scale),
                format: spec.format,
                pixelFormat: pixelFormat
            )
        case .scene, .fbo:
            if case .fbo(let fboName) = target,
               let localSize = Self.layerLocalFBOPixelSize(fboName: fboName, layer: layer, sceneSize: sceneSize) {
                return WPEMetalRenderTargetKey(
                    name: spec.name,
                    width: wpeRenderTargetDimension(localSize.width, scale: spec.scale),
                    height: wpeRenderTargetDimension(localSize.height, scale: spec.scale),
                    format: spec.format,
                    pixelFormat: pixelFormat
                )
            }
            return WPEMetalRenderTargetKey(
                name: spec.name,
                sceneSize: sceneSize,
                scale: spec.scale,
                format: spec.format,
                pixelFormat: pixelFormat
            )
        }
    }

    private static func layerCompositeSize(
        for layer: WPERenderLayer,
        sceneSize: CGSize
    ) -> CGSize {
        // WPE compose/project utility layers capture the full frame, so their
        // layer-composite target MUST be scene-sized. Sizing it to the object's
        // scaled footprint was the root of the "picture-in-picture" inset.
        if isSceneCaptureUtilityLayer(layer) {
            return sceneSize
        }

        guard layer.geometry != .identity,
              let size = layer.geometry.size else {
            return sceneSize
        }

        return CGSize(
            width: max(size.width, 1),
            height: max(size.height, 1)
        )
    }

    private static func isSceneCaptureUtilityLayer(_ layer: WPERenderLayer) -> Bool {
        WPEMetalSceneCaptureUtilityModels.isSceneCaptureUtilityModelPath(layer.imagePath)
    }

    private func textureDescriptor(for key: WPEMetalRenderTargetKey) throws -> MTLTextureDescriptor {
        try validateTextureDimensions(targetName: key.name, width: key.width, height: key.height)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: key.pixelFormat,
            width: key.width,
            height: key.height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        return descriptor
    }

    // MARK: - FBO aliasing (placement heap, hazard-tracked by the driver)

    private func aliasTexture(for key: WPEMetalRenderTargetKey, lastPass: Int) throws -> MTLTexture {
        if let existing = aliasFrameTextures[key] {
            return existing.texture
        }
        if let aliasHeap,
           let descriptor = try? textureDescriptor(for: key),
           let texture = aliasHeap.makeTexture(descriptor: descriptor) {
            texture.label = "WPE \(key.name) alias texture"
            WPEMetalTextureMetadataRegistry.shared.register(texture: texture)
            aliasFrameTextures[key] = (texture, lastPass)
            return texture
        }
        // Heap exhausted/unavailable: discrete fallback so a planning shortfall
        // degrades gracefully, never a render failure.
        let slot = slots[key] ?? Slot()
        slots[key] = slot
        if slot.primary == nil {
            slot.primary = try makeAllocation(key: key, label: "primary")
        }
        guard let primary = slot.primary else {
            throw WPEMetalTextureLoaderError.textureAllocationFailed
        }
        return primary.texture
    }

    private func prepareAliasPlan(_ intervals: [AliasInterval]) {
        var plannerIntervals: [WPEMetalFBOAliasPlanner.Interval] = []
        var lastPassByKey: [WPEMetalRenderTargetKey: Int] = [:]
        var maxAlignment = 1
        for (index, interval) in intervals.enumerated() {
            guard interval.firstPass <= interval.lastPass,
                  let descriptor = try? textureDescriptor(for: interval.key) else { continue }
            let sizeAndAlign = device.heapTextureSizeAndAlign(descriptor: descriptor)
            guard sizeAndAlign.size > 0 else { continue }
            maxAlignment = max(maxAlignment, sizeAndAlign.align)
            plannerIntervals.append(.init(
                id: index,
                size: Self.align(sizeAndAlign.size, to: sizeAndAlign.align),
                firstPass: interval.firstPass,
                lastPass: interval.lastPass
            ))
            lastPassByKey[interval.key] = interval.lastPass
        }

        guard !plannerIntervals.isEmpty else {
            releaseAliasState()
            return
        }

        var hasher = Hasher()
        for interval in plannerIntervals {
            hasher.combine(interval.size)
            hasher.combine(interval.firstPass)
            hasher.combine(interval.lastPass)
        }
        let signature = hasher.finalize()
        if aliasPlanSignature == signature, aliasHeap != nil {
            return // same scene/plan as last prepare — keep the heap.
        }

        releaseAliasState()

        let plan = WPEMetalFBOAliasPlanner.plan(plannerIntervals, alignment: maxAlignment)
        guard plan.heapSize > 0 else { return }

        let heapDescriptor = MTLHeapDescriptor()
        heapDescriptor.type = .automatic
        heapDescriptor.storageMode = .private
        heapDescriptor.hazardTrackingMode = .tracked
        heapDescriptor.size = Self.align(plan.heapSize + maxAlignment, to: maxAlignment)
        guard let heap = device.makeHeap(descriptor: heapDescriptor) else { return }

        aliasHeap = heap
        aliasLastPassByKey = lastPassByKey
        aliasPlanSignature = signature
    }

    private func releaseAliasState() {
        aliasFrameTextures.removeAll(keepingCapacity: false)
        aliasLastPassByKey.removeAll(keepingCapacity: false)
        aliasHeap = nil
        aliasPlanSignature = nil
    }

    private func makeAllocation(key: WPEMetalRenderTargetKey, label: String) throws -> Allocation {
        let descriptor = try textureDescriptor(for: key)

        let sizeAndAlign = device.heapTextureSizeAndAlign(descriptor: descriptor)
        if sizeAndAlign.size > 0 {
            let heapDescriptor = MTLHeapDescriptor()
            heapDescriptor.storageMode = descriptor.storageMode
            heapDescriptor.size = Self.align(sizeAndAlign.size, to: sizeAndAlign.align)
            heapDescriptor.hazardTrackingMode = .tracked
            if let heap = device.makeHeap(descriptor: heapDescriptor),
               let texture = heap.makeTexture(descriptor: descriptor) {
                texture.label = "WPE \(key.name) \(label) heap texture"
                WPEMetalTextureMetadataRegistry.shared.register(texture: texture)
                return Allocation(texture: texture, heap: heap)
            }
        }

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw WPEMetalTextureLoaderError.textureAllocationFailed
        }
        texture.label = "WPE \(key.name) \(label) texture"
        WPEMetalTextureMetadataRegistry.shared.register(texture: texture)
        return Allocation(texture: texture, heap: nil)
    }

    private func validateTextureDimensions(targetName: String, width: Int, height: Int) throws {
        guard width <= maximumTextureDimension2D,
              height <= maximumTextureDimension2D else {
            throw WPEMetalRenderExecutorError.renderTargetDimensionsExceedDeviceLimit(
                targetName: targetName,
                width: width,
                height: height,
                limit: maximumTextureDimension2D
            )
        }
    }

    private static func align(_ size: Int, to alignment: Int) -> Int {
        guard alignment > 0 else { return size }
        let remainder = size % alignment
        return remainder == 0 ? size : size + alignment - remainder
    }

    static func pixelFormat(forFBOFormat format: String) -> MTLPixelFormat {
        switch format.lowercased() {
        case "rgba16f", "rgba_half", "rgba16161616f":
            return .rgba16Float
        case "r8", "r8unorm":
            return .r8Unorm
        default:
            return WPEMetalRenderExecutor.outputPixelFormat
        }
    }
}
#endif
