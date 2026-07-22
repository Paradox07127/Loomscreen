#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperProWPE
import Metal
import MetalKit
import os
import simd

extension WPEMetalRenderExecutor {
    /// One render encoder for particle draws into `output` (`.load`/`.store` so it
    /// composites over the scene so far). Shared across consecutive non-refract
    /// systems by `flushParticles`.
    func makeParticleOutputEncoder(
        output: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) throws -> MTLRenderCommandEncoder {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = output
        descriptor.colorAttachments[0].loadAction = .load
        descriptor.colorAttachments[0].storeAction = .store
        gpuPassProfiler?.attach(descriptor, to: commandBuffer, label: "particles")
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }
        return encoder
    }

    /// Encode one particle system on top of `output`, into either its own render
    /// pass (loadAction `.load`) or a caller-owned `sharedEncoder`, on the SHARED
    /// scene command buffer — so particles interleave with layers at their paint
    /// index. Returns false (no encode) when the system has no drawable particles
    /// or its texture is missing.
    @discardableResult
    func encodeParticleSystem(
        _ system: WPEParticleSystem,
        into commandBuffer: MTLCommandBuffer,
        output: MTLTexture,
        sceneSize: CGSize,
        cameraParallax: WPECameraParallaxFrame,
        texturesByMaterial: [ObjectIdentifier: MTLTexture],
        normalsByMaterial: [ObjectIdentifier: MTLTexture],
        frameState: inout WPEMetalFrameState,
        traceIndex: Int,
        sharedEncoder: MTLRenderCommandEncoder? = nil
    ) throws -> Bool {
        guard system.liveInstanceCount > 0 else { return false }
        // A rope needs ≥2 knots (4 verts) for a strip; a degenerate/empty ribbon
        // draws nothing, so skip the pass entirely rather than encode an empty one.
        if system.isRope, system.ropeVertexCount < 4 { return false }
        // Systems whose texture failed to load were filtered at scene-load; skip
        // defensively so a stale texture-slot binding can't leak in.
        guard let texture = texturesByMaterial[ObjectIdentifier(system)] else { return false }
        // REFRACT: needs the normal map AND a snapshot of the scene drawn so far
        // (= `_rt_FullFrameBuffer`) to sample as the refracted background. The
        // snapshot is a blit encoder that cannot coexist with a shared open render
        // encoder, so refraction is only available on this system's OWN pass
        // (`sharedEncoder == nil`); `flushParticles` only ever batches non-refract.
        let refractNormal = (sharedEncoder == nil && !system.isRope)
            ? normalsByMaterial[ObjectIdentifier(system)] : nil
        let refractBackground: MTLTexture? = refractNormal == nil ? nil
            : snapshotForRefraction(of: output, into: commandBuffer, frameState: &frameState)
        let isRefract = refractNormal != nil && refractBackground != nil
        let state = try particlePipelineState(
            colorPixelFormat: output.pixelFormat,
            blendMode: system.blendMode,
            isRope: system.isRope,
            isRefract: isRefract
        )

        let ownsEncoder = sharedEncoder == nil
        let encoder = try sharedEncoder
            ?? makeParticleOutputEncoder(output: output, commandBuffer: commandBuffer)

        var projection = WPEParticleProjection(
            sceneSize: SIMD4<Float>(
                Float(max(sceneSize.width, 1)),
                Float(max(sceneSize.height, 1)),
                0, 0
            )
        )
        // Translate the whole system by its camera-parallax depth (pixels),
        // carried in `padding.xy` and added to each particle's screen position.
        let parallax = cameraParallax.pixelOffset(
            depth: system.parallaxDepth,
            sceneSize: sceneSize
        )
        // A keyframed ancestor `origin` shifts the whole system, exactly like the
        // parallax offset does — ride the same channel rather than rebuilding the
        // system's baked transform every frame.
        projection.padding = SIMD4<Float>(
            parallax.x + system.hostOriginOffset.x,
            parallax.y + system.hostOriginOffset.y,
            0, 0
        )
        // `spritetrail` orient + stretch. WPE's `genericparticle` TRAILRENDERER path
        // (common_particles.h `ComputeParticleTrailTangents`) does TWO things: it
        // orients the quad's height axis ALONG velocity (`up = normalize(velocity)`),
        // then stretches by `clamp(speed*length, minlen, maxlength)`. `g_RenderVar0 =
        // (length, maxlength, minlen, …)`; catsout WPSceneParser.cpp fills length/
        // maxlength verbatim — NOT unit-converted. `trail.w > 0.5` enables the path.
        //
        // The velocity orientation is load-bearing even at stretch 1×: with velocity
        // pointing down, `ComputeParticlePosition`'s `-up*(uv.y-0.5)` puts texture-top
        // at screen-BOTTOM — a 180° flip. rain's `particle/drop` (32×128) is authored
        // bulb-at-top / tail-at-bottom precisely so this flip lands the bulb leading
        // the fall. Drop the orientation and the drop renders head-up (WRONG).
        //   - `ropetrail` (kind `.rope`) is a different shader (`genericropeparticle`)
        //     that ribbons through position history; length is a UV segment scale, not
        //     a velocity stretch. We have no history buffer → plain sprite (no orient).
        //   - perspective systems (flags&4): keep the velocity orientation, but PIN the
        //     stretch to its 1× floor (length→0 kills the speed coupling, minlen→1).
        //     `perspectiveDepthScale` only grows near particles, never shrinks far ones,
        //     so the full `speed*length`≈15× stretch turned every 32×128 drop into a
        //     full-screen line. 1× keeps the bare 4:1 drop the team validated, now
        //     correctly oriented, until real perspective far-shrink exists.
        if let trail = system.definition.trailRenderer, trail.kind == .sprite {
            if system.definition.isPerspective {
                projection.trail = SIMD4<Float>(0, Float(trail.maxLength), 1, 1)
            } else {
                projection.trail = SIMD4<Float>(Float(trail.length), Float(trail.maxLength), 0, 1)
            }
        }

        // WPE's particle quad is NOT square: `ComputeParticlePosition` scales the
        // `up` axis by `textureRatio` so the quad carries the sprite's aspect
        // (common_particles.h). Non-spritesheet reads it off the texture
        // (`g_Texture0Resolution.y / .x`); a sprite sheet uses the FRAME aspect
        // (`g_RenderVar1.w`). Forcing every particle square squashed the
        // shooting star's 256×832 streak into a blob and flattened the size
        // differences between layers.
        let texW = Float(max(texture.width, 1))
        let texH = Float(max(texture.height, 1))
        var textureRatio = texH / texW
        if let sheet = system.spriteSheet, sheet.frameCount > 1 {
            let cols = Float(max(sheet.cols, 1))
            let rows = Float(max(sheet.rows, 1))
            textureRatio = (texH / rows) / (texW / cols)
        }
        projection.padding.z = textureRatio

        let useFrameRects = system.frameRectsBuffer != nil
        var sprite = WPEParticleSpriteParams(
            grid: SIMD4<Float>(
                Float(system.spriteSheet?.cols ?? 1),
                Float(system.spriteSheet?.rows ?? 1),
                Float(system.spriteSheet?.frameCount ?? 1),
                (system.spriteSheet?.isAlphaMask ?? false) ? 1 : 0
            ),
            frameRectMode: SIMD4<Float>(
                useFrameRects ? 1 : 0,
                Float(system.spriteSheet?.frameRects?.count ?? 0),
                system.overbright,
                isRefract ? system.refractAmount : 0   // .w = g_RefractAmount (0 ⇒ non-refract)
            )
        )
        // Compose-group opacity mask (region confine) + tint, baked from the
        // particle's parent composelayer. Refract binds texture(1)/(2) itself;
        // the two never co-occur (matrix rain is additive-sprite, not refract).
        let groupMask = isRefract ? nil : system.groupOpacityMask
        sprite.tintAndMask = SIMD4<Float>(
            system.groupTint.x, system.groupTint.y, system.groupTint.z,
            groupMask != nil ? 1 : 0
        )

        encoder.setRenderPipelineState(state)
        encoder.setVertexBytes(&projection, length: MemoryLayout<WPEParticleProjection>.stride, index: 2)
        encoder.setFragmentBytes(&sprite, length: MemoryLayout<WPEParticleSpriteParams>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        if let groupMask {
            encoder.setFragmentTexture(groupMask, index: 1)
        }
        if isRefract {
            // g_Texture1 = refraction normal map ; g_Texture3-equivalent = the
            // scene-so-far snapshot. sceneSize (projection) lets the fragment turn
            // its pixel position into a screen UV for the background sample.
            encoder.setFragmentTexture(refractNormal, index: 1)
            encoder.setFragmentTexture(refractBackground, index: 2)
            encoder.setFragmentBytes(&projection, length: MemoryLayout<WPEParticleProjection>.stride, index: 1)
        }
        if system.isRope, let ropeBuffer = system.ropeVertexBuffer {
            // One continuous ribbon strip: 2 edge vertices per knot, built by
            // `tick`. No instancing, no sprite-sheet rects.
            encoder.setVertexBuffer(ropeBuffer, offset: 0, index: 1)
            encoder.drawPrimitives(
                type: .triangleStrip,
                vertexStart: 0,
                vertexCount: system.ropeVertexCount
            )
        } else {
            encoder.setVertexBuffer(system.instanceBuffer, offset: 0, index: 1)
            encoder.setVertexBytes(&sprite, length: MemoryLayout<WPEParticleSpriteParams>.stride, index: 3)
            // Buffer(4) must always be bound for the vertex function's signature.
            // Use the system's pre-allocated frame-rect buffer (any frame count);
            // a 1-element dummy covers the uniform-grid path.
            if let frameRectsBuffer = system.frameRectsBuffer {
                encoder.setVertexBuffer(frameRectsBuffer, offset: 0, index: 4)
            } else {
                var dummyFrameRect = SIMD4<Float>(0, 0, 1, 1)
                encoder.setVertexBytes(&dummyFrameRect, length: MemoryLayout<SIMD4<Float>>.stride, index: 4)
            }
            encoder.drawPrimitives(
                type: .triangleStrip,
                vertexStart: 0,
                vertexCount: 4,
                instanceCount: system.liveInstanceCount
            )
        }
        if ownsEncoder {
            encoder.endEncoding()
            // Mark the scene target written so a later scene pass loads (instead of
            // clearing away) the particles, previous-frame history + full-frame
            // aliases see them, and any refraction snapshot taken before this draw is
            // invalidated before the next interleaved pass requests another. A shared
            // run defers both to `flushParticles` when it ends the run.
            frameState.registerWrite(texture: output, targetID: .scene)
        }

        #if !LITE_BUILD && DEBUG
        WPECanonicalTraceRecorder.shared.recordParticlePass(
            index: traceIndex,
            particleCount: system.liveInstanceCount,
            sprite: texture,
            blendMode: system.blendMode.rawValue,
            target: output,
            spriteSheet: system.spriteSheet.map {
                (cols: $0.cols, rows: $0.rows, frames: $0.frameCount, alphaMask: $0.isAlphaMask)
            },
            overbright: system.overbright
        )
        if WPESceneDebugArtifacts.shared.isEnabled {
            WPESceneDebugArtifacts.shared.recordNoteOnce(
                name: "particle-state-\(traceIndex).txt",
                contents: system.particleStateDumpText())
        }
        #endif
        return true
    }

    /// Mirrors `WPEParticleSpriteParams` in `WPEMetalBuiltins.metal` —
    /// `grid.xy = (cols, rows)`, `grid.z = frameCount` (loop modulo),
    /// `grid.w = 1` flags an r8 alpha-mask atlas (fog particles) so the
    /// fragment shader pulls colour from the per-particle tint and uses
    /// the texture sample only as the opacity.
    ///
    /// `frameRectMode.x = 1` switches the vertex shader from uniform-grid
    /// slicing to explicit `frameRects` from buffer(4); `.y` is the rect count;
    /// `.z` is the material overbright colour multiplier (1 = unchanged).
    struct WPEParticleSpriteParams {
        var grid: SIMD4<Float>
        var frameRectMode: SIMD4<Float>
        /// Compose-group effect baked from the particle's parent composelayer:
        /// `.xyz` = tint colour multiplier (1,1,1 = none), `.w` = 1 when an
        /// opacity mask is bound at fragment texture(1).
        var tintAndMask: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 0)
    }

    /// Packs per-particle uniforms.
    func genericParticleUniforms(for pass: WPEPreparedRenderPass) -> WPEGenericParticleUniforms {
        WPEGenericParticleUniforms(
            color: WPEMetalShaderInputs.colorVector(for: pass),
            sizeAndAge: SIMD4<Float>(
                WPEMetalShaderInputs.floatScalar(named: ["g_Alpha", "u_Alpha", "alpha"], in: pass, default: 1),
                WPEMetalShaderInputs.floatScalar(named: ["g_Brightness", "u_Brightness", "brightness"], in: pass, default: 1),
                0,
                0
            )
        )
    }

}
#endif
