#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperProWPE
import Metal
import MetalKit
import os
import simd

// GPU-resource setup for particle passes: the blend-mode pipeline-state cache and
// the refraction-background snapshot. Split out of +Particles so the hotspot file
// stays lean.
extension WPEMetalRenderExecutor {
    struct ParticlePipelineKey: Hashable {
        let pixelFormat: UInt
        let blendMode: WPEParticleBlendMode
        let isRope: Bool
        let isRefract: Bool
    }

    /// Blit the scene-so-far into a private cached texture so a REFRACT particle
    /// pass can sample it as the refracted background (can't read+write the live
    /// attachment). Returns nil if the output can't be a blit source. Reuses the
    /// last snapshot when no write touched the same output texture since.
    func snapshotForRefraction(
        of output: MTLTexture,
        into commandBuffer: MTLCommandBuffer,
        frameState: inout WPEMetalFrameState
    ) -> MTLTexture? {
        guard !output.isFramebufferOnly else { return nil }
        let bg: MTLTexture
        if let cached = refractionBackground, cached.width == output.width,
           cached.height == output.height, cached.pixelFormat == output.pixelFormat {
            bg = cached
            if frameState.hasFreshRefractionSnapshot(for: output) {
                return bg
            }
        } else {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: output.pixelFormat, width: output.width,
                height: output.height, mipmapped: false)
            desc.usage = [.shaderRead]
            desc.storageMode = .private
            guard let tex = device.makeTexture(descriptor: desc) else { return nil }
            tex.label = "WPE refraction background"
            refractionBackground = tex
            bg = tex
        }
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: output, to: bg)
        blit.endEncoding()
        frameState.markRefractionSnapshotFresh(for: output)
        return bg
    }

    func particlePipelineState(
        colorPixelFormat: MTLPixelFormat,
        blendMode: WPEParticleBlendMode,
        isRope: Bool = false,
        isRefract: Bool = false
    ) throws -> MTLRenderPipelineState {
        let key = ParticlePipelineKey(
            pixelFormat: colorPixelFormat.rawValue, blendMode: blendMode,
            isRope: isRope, isRefract: isRefract)
        if let cached = particlePipelineCache[key] {
            return cached
        }
        // Rope shares the instanced fragment (frameBlend 0 ⇒ one texture sample)
        // but uses a ribbon-strip vertex stage instead of the per-instance quad.
        // Refract reuses the instanced quad vertex but a fragment that multiplies
        // by the scene framebuffer at a normal-offset screen UV.
        let vertexName = isRope ? "wpe_particle_rope_vertex" : "wpe_particle_vertex"
        let fragmentName = isRefract ? "wpe_particle_refract_fragment" : "wpe_particle_instanced_fragment"
        guard let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: vertexName),
              let fragment = library.makeFunction(name: fragmentName) else {
            throw WPEMetalRenderExecutorError.pipelineUnavailable("wpe_particle_instanced_fragment")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        guard let attachment = descriptor.colorAttachments[0] else {
            throw WPEMetalRenderExecutorError.pipelineUnavailable("wpe_particle_instanced_fragment")
        }
        attachment.pixelFormat = colorPixelFormat
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        // Fragment shader outputs straight (non-premultiplied) alpha. WPE
        // material `blending` strings map to the three classic factor
        // combos — anything else falls back to translucent at parse time.
        switch blendMode {
        case .normal:
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .zero
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .zero
        case .translucent:
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .sourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        case .additive:
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .sourceAlpha
            attachment.destinationAlphaBlendFactor = .one
        }
        let state = try device.makeRenderPipelineState(descriptor: descriptor)
        particlePipelineCache[key] = state
        return state
    }
}
#endif
