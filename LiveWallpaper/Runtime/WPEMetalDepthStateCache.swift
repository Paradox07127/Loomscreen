#if !LITE_BUILD
import CoreGraphics
import Foundation
import Metal

/// Owns Metal depth state for one `WPEMetalRenderExecutor` lifetime. The
/// per-frame depth texture dictionary stays on `WPEMetalFrameState`, but its
/// allocation goes through here so descriptor + storage mode stay aligned
/// with the rest of the pipeline.
final class WPEMetalDepthStateCache {
    private let device: MTLDevice
    private var depthStencilStates: [WPEMetalDepthKey: MTLDepthStencilState] = [:]

    init(device: MTLDevice) {
        self.device = device
    }

    func needsAttachment(for pass: WPEPreparedRenderPass) -> Bool {
        pass.pass.depthWrite.lowercased() == "enabled"
            || pass.pass.depthWrite.lowercased() == "true"
            || pass.pass.depthTest.lowercased() != "disabled"
    }

    /// Phase 2C audit fix: depth textures key on (target, exact destination dimensions) so a scaled FBO's depth attachment matches its color attachment dimensions instead of being stuck at scene size.
    func attachmentTexture(
        for destination: (id: WPEMetalTargetID, texture: MTLTexture),
        frameState: inout WPEMetalFrameState
    ) throws -> MTLTexture {
        let key = WPEMetalDepthTextureKey(
            targetID: destination.id,
            width: destination.texture.width,
            height: destination.texture.height
        )
        if let existing = frameState.depthTextures[key] {
            return existing
        }
        let texture = try makeDepthTexture(width: key.width, height: key.height)
        frameState.depthTextures[key] = texture
        return texture
    }

    func stencilState(depthTest: String, depthWrite: String) -> MTLDepthStencilState {
        let key = WPEMetalDepthKey(
            depthTest: depthTest.lowercased(),
            depthWrite: depthWrite.lowercased()
        )
        if let cached = depthStencilStates[key] {
            return cached
        }

        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = Self.compareFunction(for: key.depthTest)
        descriptor.isDepthWriteEnabled = key.depthWrite == "enabled" || key.depthWrite == "true"

        let state = device.makeDepthStencilState(descriptor: descriptor)!
        depthStencilStates[key] = state
        return state
    }

    private func makeDepthTexture(width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float,
            width: max(width, 1),
            height: max(height, 1),
            mipmapped: false
        )
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .private

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw WPEMetalTextureLoaderError.textureAllocationFailed
        }
        texture.label = "WPE Metal executor depth"
        return texture
    }

    private static func compareFunction(for raw: String) -> MTLCompareFunction {
        switch raw.lowercased() {
        case "always":
            return .always
        case "never":
            return .never
        case "less":
            return .less
        case "lequal", "lessequal", "less_equal":
            return .lessEqual
        case "greater":
            return .greater
        case "gequal", "greaterequal", "greater_equal":
            return .greaterEqual
        case "equal":
            return .equal
        case "notequal", "not_equal":
            return .notEqual
        default:
            return .always
        }
    }
}
#endif
