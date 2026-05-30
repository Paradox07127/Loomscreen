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
/// `WPEMetalRenderExecutor`. Allocations live across `render(...)` calls
/// (so per-frame work avoids reallocating large textures) and are released
/// on `applyPerformanceProfile(.suspended)`, `reload()`, and `cleanup()`.
///
/// `MTLHeap` is preferred when `device.heapTextureSizeAndAlign(descriptor:)`
/// reports a non-zero size; otherwise the pool falls back to discrete
/// `device.makeTexture(descriptor:)` allocation. The heap reference is held
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

    private let device: MTLDevice
    private let maximumTextureDimension2D: Int
    private var slots: [WPEMetalRenderTargetKey: Slot] = [:]
    private var declaredFBOs: [String: WPERenderFBO] = [:]

    init(device: MTLDevice, maximumTextureDimension2D: Int? = nil) {
        self.device = device
        self.maximumTextureDimension2D = maximumTextureDimension2D
            ?? WPEMetalTextureLimits.maximum2DTextureDimension(for: device)
    }

    func prepare(pipeline: WPEPreparedRenderPipeline) {
        declaredFBOs.removeAll(keepingCapacity: true)
        for layer in pipeline.layers {
            for fbo in layer.graphLayer.localFBOs {
                declaredFBOs[fbo.name] = fbo
            }
        }
    }

    func releaseAll() {
        slots.removeAll(keepingCapacity: true)
        declaredFBOs.removeAll(keepingCapacity: true)
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
            let localSize = Self.layerCompositeSize(for: layer, sceneSize: sceneSize)
            return WPEMetalRenderTargetKey(
                name: spec.name,
                width: wpeRenderTargetDimension(localSize.width, scale: spec.scale),
                height: wpeRenderTargetDimension(localSize.height, scale: spec.scale),
                format: spec.format,
                pixelFormat: pixelFormat
            )
        case .scene, .fbo:
            return WPEMetalRenderTargetKey(
                name: spec.name,
                sceneSize: sceneSize,
                scale: spec.scale,
                format: spec.format,
                pixelFormat: pixelFormat
            )
        }
    }

    private static func layerCompositeSize(for layer: WPERenderLayer, sceneSize: CGSize) -> CGSize {
        guard layer.geometry != .identity,
              let declaredSize = layer.geometry.size else {
            return sceneSize
        }

        if isSceneCaptureUtilityLayer(layer) {
            // composelayer/projectlayer capture a screen-space region that is
            // later drawn at the object's scaled footprint.
            let scaleX = finiteMagnitude(layer.geometry.scale.x, fallback: 1)
            let scaleY = finiteMagnitude(layer.geometry.scale.y, fallback: 1)
            return CGSize(
                width: max(declaredSize.width * scaleX, 1),
                height: max(declaredSize.height * scaleY, 1)
            )
        }

        // Puppet layers whose mesh exceeds the declared footprint render into a
        // larger, aspect-locked local composite so the mesh is not clipped; that
        // composite is later blitted (full UV) back into the declared scene
        // footprint, shrinking the mesh uniformly. `nil` for everything else.
        let size = layer.geometry.localCompositeSize ?? declaredSize
        return CGSize(
            width: max(size.width, 1),
            height: max(size.height, 1)
        )
    }

    private static func isSceneCaptureUtilityLayer(_ layer: WPERenderLayer) -> Bool {
        let imagePath = normalizedPath(layer.imagePath)
        return imagePath == "models/util/composelayer.json"
            || imagePath == "models/util/projectlayer.json"
    }

    private static func normalizedPath(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/").lowercased()
    }

    private static func finiteMagnitude(_ value: Double, fallback: CGFloat) -> CGFloat {
        guard value.isFinite else {
            return fallback
        }
        return CGFloat(abs(value))
    }

    private func makeAllocation(key: WPEMetalRenderTargetKey, label: String) throws -> Allocation {
        let width = key.width
        let height = key.height
        try validateTextureDimensions(targetName: key.name, width: width, height: height)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: key.pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private

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
