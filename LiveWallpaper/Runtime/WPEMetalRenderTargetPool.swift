#if !LITE_BUILD
import CoreGraphics
import Foundation
import Metal

/// Identity for a pooled Metal render target. Same name + same scaled
/// dimensions + same format share a slot; if a pass would read its own
/// destination texture (e.g. `.previous` ping-pong), the pool returns the
/// per-slot secondary allocation so Metal never samples from and renders
/// into the same texture in one encoder.
struct WPEMetalRenderTargetKey: Hashable {
    let name: String
    let sceneWidth: Int
    let sceneHeight: Int
    let scale: Double
    let format: String
    let pixelFormat: MTLPixelFormat

    init(name: String, sceneSize: CGSize, scale: Double, format: String, pixelFormat: MTLPixelFormat) {
        self.name = name
        self.sceneWidth = max(Int(sceneSize.width.rounded()), 1)
        self.sceneHeight = max(Int(sceneSize.height.rounded()), 1)
        self.scale = scale
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
    private var slots: [WPEMetalRenderTargetKey: Slot] = [:]
    private var declaredFBOs: [String: WPERenderFBO] = [:]

    init(device: MTLDevice) {
        self.device = device
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
        let key = WPEMetalRenderTargetKey(
            name: spec.name,
            sceneSize: sceneSize,
            scale: spec.scale,
            format: spec.format,
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

    private func makeAllocation(key: WPEMetalRenderTargetKey, label: String) throws -> Allocation {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: key.pixelFormat,
            width: max(Int((Double(key.sceneWidth) * key.scale).rounded()), 1),
            height: max(Int((Double(key.sceneHeight) * key.scale).rounded()), 1),
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
                return Allocation(texture: texture, heap: heap)
            }
        }

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw WPEMetalTextureLoaderError.textureAllocationFailed
        }
        texture.label = "WPE \(key.name) \(label) texture"
        return Allocation(texture: texture, heap: nil)
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
