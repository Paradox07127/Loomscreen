#if !LITE_BUILD
import Foundation
import Metal

/// Caches `MTLRenderPipelineState` keyed by (fragment, blend, color format,
/// depth format) so identical pipelines can be reused across passes and frames.
final class WPEMetalPipelineCache {
    private let device: MTLDevice
    private let library: MTLLibrary
    private var pipelineStates: [WPEMetalPipelineKey: MTLRenderPipelineState] = [:]

    init(device: MTLDevice, library: MTLLibrary) {
        self.device = device
        self.library = library
    }

    func pipelineState(
        vertexName: String = "wpe_fullscreen_vertex",
        fragmentName: String,
        blendMode: String,
        colorPixelFormat: MTLPixelFormat,
        depthPixelFormat: MTLPixelFormat
    ) throws -> MTLRenderPipelineState {
        let normalizedBlend = blendMode.lowercased()
        let key = WPEMetalPipelineKey(
            vertexName: vertexName,
            fragmentName: fragmentName,
            blendMode: normalizedBlend,
            colorPixelFormat: colorPixelFormat,
            depthPixelFormat: depthPixelFormat
        )
        if let cached = pipelineStates[key] {
            return cached
        }

        guard let vertex = library.makeFunction(name: vertexName),
              let fragment = library.makeFunction(name: fragmentName) else {
            throw WPEMetalRenderExecutorError.pipelineUnavailable(fragmentName)
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        guard let colorAttachment = descriptor.colorAttachments[0] else {
            throw WPEMetalRenderExecutorError.pipelineUnavailable(fragmentName)
        }
        colorAttachment.pixelFormat = colorPixelFormat
        descriptor.depthAttachmentPixelFormat = depthPixelFormat
        Self.applyBlendMode(normalizedBlend, to: colorAttachment)

        let state: MTLRenderPipelineState
        do {
            state = try WPEMetalCompileTimer.measure { try device.makeRenderPipelineState(descriptor: descriptor) }
        } catch {
            let detail = """
            vertex: \(vertexName)
            fragment: \(fragmentName)
            blend: \(normalizedBlend)
            colorFormat: \(colorPixelFormat.rawValue)
            depthFormat: \(depthPixelFormat.rawValue)
            error: \(error.localizedDescription)
            """
            WPESceneDebugArtifacts.shared.recordPipelineFailure(
                fragmentName: fragmentName,
                blendMode: normalizedBlend,
                detail: detail
            )
            throw WPEMetalRenderExecutorError.pipelineStateBuildFailed(
                name: fragmentName,
                detail: error.localizedDescription
            )
        }
        pipelineStates[key] = state
        return state
    }

    static func cullMode(for raw: String) -> MTLCullMode {
        switch raw.lowercased() {
        case "back":
            return .back
        case "front":
            return .front
        default:
            return .none
        }
    }

    private static func applyBlendMode(
        _ mode: String,
        to attachment: MTLRenderPipelineColorAttachmentDescriptor
    ) {
        switch mode {
        case "disabled", "premultiplieddisabled":
            attachment.isBlendingEnabled = false

        // Sources already store premultiplied RGB, so srcRGB=.one.
        case "premultiplied", "premultipliednormal", "premultipliedtranslucent", "premultipliednormalmapped":
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        case "premultipliedadditive":
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .one

        case "additive":
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .one

        case "premultipliedmultiply":
            fallthrough

        case "multiply":
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .destinationColor
            attachment.destinationRGBBlendFactor = .zero
            attachment.sourceAlphaBlendFactor = .zero
            attachment.destinationAlphaBlendFactor = .one

        case "premultipliedscreen", "screen":
            // Premultiplied source: src + dst·(1−src) ≡ WPE's alpha-weighted
            // screen mix(dst, screen(dst,src), a) — black pixels leave dst intact.
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceColor
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        case "translucent", "normalmapped", "normal":
            fallthrough

        default:
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
    }
}
#endif
