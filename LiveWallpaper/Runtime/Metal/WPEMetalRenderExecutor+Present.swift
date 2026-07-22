#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import MetalKit
import os
import QuartzCore
import simd
extension WPEMetalRenderExecutor {
    // Not `@MainActor` (M2c1b-3c): the present path runs on the renderer's
    // `WPEDisplayRenderActor`. `CAMetalLayer.nextDrawable()` is safe off-main.
    func present(
        texture source: MTLTexture,
        layer: CAMetalLayer,
        fitMode: WPEPresentFitMode = .stretch,
        presentCompletion: (@Sendable (MTLTexture, MTLCommandBuffer, @escaping @Sendable () -> Void) -> Void)? = nil
    ) throws -> Bool {
        // Pull the drawable straight from the layer. `MTKView.currentDrawable`
        // is exactly a cached `layer.nextDrawable()`, so this is equivalent while
        // MTKView remains the pacing source — but the executor no longer needs
        // the view. The MTKView draw path never touches `currentDrawable`, so
        // there's no double-acquire.
        guard let drawable = layer.nextDrawable() else {
            #if DEBUG
            Logger.info(
                "[present] layer.nextDrawable()=nil — source=\(source.width)x\(source.height) drawableSize=\(layer.drawableSize)",
                category: .wpeRender
            )
            #endif
            return false
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        let copyState = try renderPipeline(
            vertexName: "wpe_present_vertex",
            fragmentName: "wpe_present_fragment",
            blendMode: "disabled",
            colorPixelFormat: drawable.texture.pixelFormat
        )
        gpuPassProfiler?.attach(descriptor, to: commandBuffer, label: "present")
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }
        encoder.setRenderPipelineState(copyState)
        encoder.setFragmentTexture(source, index: 0)
        // Fit the scene texture's aspect to the drawable. Stretch reproduces the
        // legacy full-bleed; Fit/Fill preserve aspect (letterbox / crop) so
        // non-16:9 displays don't distort the scene.
        var presentUniforms = WPEPresentUniforms.make(
            fitMode: fitMode,
            sourceWidth: source.width,
            sourceHeight: source.height,
            targetWidth: drawable.texture.width,
            targetHeight: drawable.texture.height
        )
        encoder.setVertexBytes(&presentUniforms, length: MemoryLayout<WPEPresentUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        // The present buffer reads `source` asynchronously; refcount it so the
        // output ring doesn't hand the texture to the next frame's render
        // while this GPU read is still in flight.
        let sourceID = ObjectIdentifier(source)
        let completionSource = PresentCompletionTexture(texture: source)
        let tracker = presentTracker
        let sink = gpuErrorSink
        tracker.increment(sourceID)
        commandBuffer.addCompletedHandler { cb in
            let releaseSource: @Sendable () -> Void = {
                tracker.decrement(sourceID)
            }
            if cb.status == .error {
                sink.record("present: \(cb.error?.localizedDescription ?? "unknown")")
            }
            if let presentCompletion {
                presentCompletion(completionSource.texture, cb, releaseSource)
            } else {
                releaseSource()
            }
        }
        commandBuffer.commit()
        return true
    }

    func clearColor(for targetID: WPEMetalTargetID) -> MTLClearColor {
        switch targetID {
        case .scene:
            return MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        case .named:
            return MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        }
    }

    /// WPE HDR bloom pyramid (RenderDoc-verified structure on 3509243656):
    /// prefilter (soft-knee threshold + strength/17 + tint) into a half-res
    /// chain, 4-tap box downsamples, scatter-weighted SRC_ALPHA/ONE upsamples,
    /// additive composite back onto the scene. HDR scenes (`general.hdr`) render
    /// to an rgba16Float output (`currentOutputPixelFormat` + FBO promotion), so
    /// the prefilter sees real >1 overbright — oracle-verified on 3509243656
    /// (every RT in the trace is format 115 = rgba16Float). Only `hdr:false`
    /// scenes clamp at their 8-bit scene write, matching WPE's own LDR chain.
    func encodeSceneBloomIfNeeded(
        cameraUniforms: WPEMetalCameraUniforms,
        output: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) throws {
        guard Self.isSceneBloomEnabled, let bloom = cameraUniforms.bloom else { return }
        ensureBloomLevels(for: output, levelCount: min(max(bloom.iterations, 1), 6))
        let levels = bloomLevelTextures.count
        guard levels >= 1 else { return }

        let threshold = Float(bloom.threshold)
        let knee = threshold * Float(1 - min(max(bloom.feather, 0), 1))
        let kneeSpan = max(threshold - knee, 0.0001)
        let blendParams = SIMD4<Float>(threshold, knee, 2 * kneeSpan, 0.25 / kneeSpan)
        let strength = Float(bloom.strength) / 17
        let scatterAlpha = min(max(Float(bloom.scatter) * 0.25, 0), 1)
        let tint = SIMD4<Float>(Float(bloom.tint.x), Float(bloom.tint.y), Float(bloom.tint.z), 1)

        func texel(of texture: MTLTexture) -> SIMD2<Float> {
            SIMD2<Float>(1 / Float(max(texture.width, 1)), 1 / Float(max(texture.height, 1)))
        }

        func draw(
            into destination: MTLTexture,
            source: MTLTexture,
            fragment: String,
            blendMode: String,
            uniforms: WPEBloomUniforms
        ) throws {
            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = destination
            // "disabled" = the prefilter/downsample passes fully overwrite the target
            // (blending off, see applyBlendMode), so their prior content can be discarded.
            // Was "normal", which fell through applyBlendMode to straight-alpha blend and
            // read this .dontCare (undefined) destination whenever a source pixel had
            // alpha < 1 — inert only because the bloom shaders hardcode alpha = 1.
            descriptor.colorAttachments[0].loadAction = blendMode == "disabled" ? .dontCare : .load
            descriptor.colorAttachments[0].storeAction = .store
            gpuPassProfiler?.attach(descriptor, to: commandBuffer, label: "bloom|\(fragment)")
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                throw WPEMetalRenderExecutorError.commandBufferFailed
            }
            defer { encoder.endEncoding() }
            encoder.setRenderPipelineState(try renderPipeline(
                vertexName: "wpe_fullscreen_vertex",
                fragmentName: fragment,
                blendMode: blendMode,
                colorPixelFormat: destination.pixelFormat,
                depthPixelFormat: .invalid
            ))
            var uniforms = uniforms
            encoder.setFragmentTexture(source, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPEBloomUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        let sceneTexel = texel(of: output)
        try draw(
            into: bloomLevelTextures[0],
            source: output,
            fragment: "wpe_bloom_prefilter_fragment",
            blendMode: "disabled",
            uniforms: WPEBloomUniforms(
                texelAndWeight: SIMD4<Float>(sceneTexel.x, sceneTexel.y, strength, 0),
                blendParams: blendParams,
                tint: tint
            )
        )
        for level in 1..<levels {
            let source = bloomLevelTextures[level - 1]
            let t = texel(of: source)
            try draw(
                into: bloomLevelTextures[level],
                source: source,
                fragment: "wpe_bloom_downsample_fragment",
                blendMode: "disabled",
                uniforms: WPEBloomUniforms(
                    texelAndWeight: SIMD4<Float>(t.x, t.y, 0, 0),
                    blendParams: .zero,
                    tint: tint
                )
            )
        }
        var level = levels - 1
        while level >= 1 {
            let destination = bloomLevelTextures[level - 1]
            let t = texel(of: destination)
            try draw(
                into: destination,
                source: bloomLevelTextures[level],
                fragment: "wpe_bloom_upsample_fragment",
                blendMode: "additive",
                uniforms: WPEBloomUniforms(
                    texelAndWeight: SIMD4<Float>(t.x, t.y, scatterAlpha, 0),
                    blendParams: .zero,
                    tint: tint
                )
            )
            level -= 1
        }
        let compositeTexel = texel(of: bloomLevelTextures[0])
        try draw(
            into: output,
            source: bloomLevelTextures[0],
            fragment: "wpe_bloom_upsample_fragment",
            blendMode: "additive",
            uniforms: WPEBloomUniforms(
                texelAndWeight: SIMD4<Float>(compositeTexel.x, compositeTexel.y, 1, 0),
                blendParams: .zero,
                tint: tint
            )
        )
    }

    private func ensureBloomLevels(for output: MTLTexture, levelCount: Int) {
        if bloomLevelBaseWidth == output.width,
           bloomLevelBaseHeight == output.height,
           bloomLevelPixelFormat == output.pixelFormat,
           bloomLevelRequestedCount == levelCount {
            return
        }
        releaseBloomLevels()
        bloomLevelBaseWidth = output.width
        bloomLevelBaseHeight = output.height
        bloomLevelPixelFormat = output.pixelFormat
        bloomLevelRequestedCount = levelCount

        var descriptors: [MTLTextureDescriptor] = []
        var width = output.width / 2
        var height = output.height / 2
        for _ in 0..<levelCount {
            guard width >= 8, height >= 8 else { break }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: output.pixelFormat,
                width: width,
                height: height,
                mipmapped: false
            )
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            descriptors.append(descriptor)
            width /= 2
            height /= 2
        }
        guard !descriptors.isEmpty else { return }

        var heapSize = 0
        var maxAlign = 1
        for descriptor in descriptors {
            let sizeAndAlign = device.heapTextureSizeAndAlign(descriptor: descriptor)
            guard sizeAndAlign.size > 0 else { heapSize = 0; break }
            maxAlign = max(maxAlign, sizeAndAlign.align)
            heapSize += Self.alignUp(sizeAndAlign.size, to: sizeAndAlign.align)
        }
        if heapSize > 0 {
            let heapDescriptor = MTLHeapDescriptor()
            heapDescriptor.type = .automatic
            heapDescriptor.storageMode = .private
            heapDescriptor.hazardTrackingMode = .tracked
            heapDescriptor.size = Self.alignUp(heapSize + maxAlign, to: maxAlign)
            bloomLevelHeap = device.makeHeap(descriptor: heapDescriptor)
        }

        for (index, descriptor) in descriptors.enumerated() {
            let texture = bloomLevelHeap?.makeTexture(descriptor: descriptor)
                ?? device.makeTexture(descriptor: descriptor)
            guard let texture else { break }
            texture.label = "wpe.bloom.level\(index)"
            bloomLevelTextures.append(texture)
        }
    }

    func releaseBloomLevels() {
        bloomLevelTextures = []
        bloomLevelHeap = nil
        bloomLevelBaseWidth = 0
        bloomLevelBaseHeight = 0
        bloomLevelPixelFormat = .invalid
        bloomLevelRequestedCount = 0
    }

    private static func alignUp(_ size: Int, to alignment: Int) -> Int {
        guard alignment > 0 else { return size }
        let remainder = size % alignment
        return remainder == 0 ? size : size + alignment - remainder
    }

}
#endif
