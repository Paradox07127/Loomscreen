import CoreGraphics
import Metal
import MetalKit

struct WPEMetalTextureLoader {
    private let device: MTLDevice
    private let capabilities: WPEMetalTextureCapabilities
    private let uploadQueue: WPEMetalTextureUploadQueue

    init(
        device: MTLDevice,
        capabilities: WPEMetalTextureCapabilities? = nil,
        uploadQueue: WPEMetalTextureUploadQueue = .shared
    ) {
        self.device = device
        self.capabilities = capabilities ?? WPEMetalTextureCapabilities(device: device)
        self.uploadQueue = uploadQueue
    }

    func makeTexture(from payload: WPETexTexturePayload, label: String) async throws -> MTLTexture {
        // Phase 2E: video and animation payloads are routed via the dynamic
        // texture sources; this static path must reject them so a stale
        // upload does not silently take a single-frame snapshot.
        if payload.videoPayload != nil {
            throw WPEMetalTextureLoaderError.malformedPayload(
                "video payload must be routed through WPEVideoTextureSource"
            )
        }
        if payload.animationTrack != nil {
            throw WPEMetalTextureLoaderError.malformedPayload(
                "animated payload must be routed through WPETexAnimatedTextureSource"
            )
        }
        let device = self.device
        let capabilities = self.capabilities
        return try await uploadQueue.perform {
            try Self.makeTextureSynchronously(
                from: payload,
                label: label,
                device: device,
                capabilities: capabilities
            )
        }
    }

    /// Phase 2E: pre-uploads every animation frame to GPU as a separate
    /// `MTLTexture` and hands the pre-baked array to
    /// `WPETexAnimatedTextureSource`. Frame selection by `g_Time` happens at
    /// render time without any per-frame upload cost.
    @MainActor
    func makeAnimatedTextureSource(
        from payload: WPETexTexturePayload,
        label: String
    ) async throws -> WPETexAnimatedTextureSource {
        guard let animation = payload.animationTrack else {
            throw WPEMetalTextureLoaderError.malformedPayload("missing animation track")
        }

        var frameTextures: [MTLTexture] = []
        frameTextures.reserveCapacity(animation.frames.count)
        for (frameIndex, frame) in animation.frames.enumerated() {
            let framePayload = WPETexTexturePayload(
                info: payload.info,
                mipmaps: frame.mipmaps,
                hasAnimationFrames: false
            )
            frameTextures.append(try await makeTexture(
                from: framePayload,
                label: "\(label) frame \(frameIndex)"
            ))
        }

        return WPETexAnimatedTextureSource(
            frames: frameTextures,
            frameRate: animation.frameRate,
            loop: animation.loop
        )
    }

    func makeTexture(from image: DecodedRGBAImage, label: String) async throws -> MTLTexture {
        let payload = WPETexTexturePayload(
            info: WPETexInfo(
                containerVersion: 0,
                infoVersion: 0,
                width: image.width,
                height: image.height,
                textureFormatCode: WPETexFormat.rgba8888.rawValue,
                format: .rgba8888,
                mipmapCount: 1,
                flags: 0
            ),
            mipmaps: [WPETexTextureMipmap(index: 0, width: image.width, height: image.height, bytes: image.pixels)],
            hasAnimationFrames: false
        )
        return try await makeTexture(from: payload, label: label)
    }

    func makeTexture(from cgImage: CGImage, label: String) async throws -> MTLTexture {
        let device = self.device
        return try await uploadQueue.perform {
            // Phase 2A H3: explicitly request sRGB so untagged CGImages do not
            // fall back to the linear path and re-introduce gamma divergence.
            let loader = MTKTextureLoader(device: device)
            do {
                let texture = try loader.newTexture(
                    cgImage: cgImage,
                    options: [
                        MTKTextureLoader.Option.SRGB: true,
                        MTKTextureLoader.Option.textureUsage: MTLTextureUsage.shaderRead.rawValue
                    ]
                )
                texture.label = label
                return texture
            } catch {
                throw WPEMetalTextureLoaderError.malformedPayload(error.localizedDescription)
            }
        }
    }

    private static func makeTextureSynchronously(
        from payload: WPETexTexturePayload,
        label: String,
        device: MTLDevice,
        capabilities: WPEMetalTextureCapabilities
    ) throws -> MTLTexture {
        guard let format = payload.info.format else {
            throw WPEMetalTextureLoaderError.malformedPayload("unknown texture format \(payload.info.textureFormatCode)")
        }
        guard let mip = payload.largestMipmap else {
            throw WPEMetalTextureLoaderError.malformedPayload("missing mipmap")
        }

        let mapping = try WPEMetalTextureFormatMapper.mapping(for: format, capabilities: capabilities)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: mapping.pixelFormat,
            width: mip.width,
            height: mip.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw WPEMetalTextureLoaderError.textureAllocationFailed
        }
        texture.label = label

        let expected = format.expectedByteCount(width: mip.width, height: mip.height)
        guard mip.bytes.count >= expected else {
            throw WPEMetalTextureLoaderError.malformedPayload(
                "mip bytes \(mip.bytes.count) smaller than expected \(expected)"
            )
        }
        let bytesPerRow = try bytesPerRow(width: mip.width, mapping: mapping)

        mip.bytes.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegionMake2D(0, 0, mip.width, mip.height),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: bytesPerRow
            )
        }
        return texture
    }

    private static func bytesPerRow(width: Int, mapping: WPEMetalTextureFormatMapping) throws -> Int {
        if let bytesPerPixel = mapping.bytesPerPixel {
            return width * bytesPerPixel
        }
        if let bytesPerBlock = mapping.bytesPerBlock {
            return max((width + 3) / 4, 1) * bytesPerBlock
        }
        throw WPEMetalTextureLoaderError.malformedPayload("missing row-stride information")
    }
}
