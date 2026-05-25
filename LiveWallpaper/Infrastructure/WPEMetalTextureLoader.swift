#if !LITE_BUILD
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

    /// Lazy LZ4 streaming source for multi-frame `.tex` animations that
    /// would otherwise saturate VRAM if every frame were pre-uploaded.
    /// See `WPETexLazyAnimatedTextureSource` for the on-demand decode +
    /// sub-rect crop + rotating-texture rationale.
    @MainActor
    func makeLazyAnimatedTextureSource(
        from payload: WPETexStreamingPayload,
        label: String
    ) throws -> WPETexLazyAnimatedTextureSource {
        try WPETexLazyAnimatedTextureSource(payload: payload, device: device, label: label)
    }

    /// Phase 2E + P0: pre-uploads every animation frame to GPU as a
    /// separate `MTLTexture` sized to the TEXS sub-rect, and hands the
    /// pre-baked frames to `WPETexAnimatedTextureSource`.
    ///
    /// Pre-P0 this method passed `frame.mipmaps` straight through, which
    /// meant every TEXS frame got a Metal texture sized to the **whole
    /// atlas** and the sub-rect was silently dropped. Sprite sheets in
    /// the corpus (27/29 animated samples in the 431960 audit) rendered
    /// the entire atlas as one frame because of it.
    @MainActor
    func makeAnimatedTextureSource(
        from payload: WPETexTexturePayload,
        label: String
    ) async throws -> WPETexAnimatedTextureSource {
        guard let animation = payload.animationTrack else {
            throw WPEMetalTextureLoaderError.malformedPayload("missing animation track")
        }
        guard let format = payload.info.format else {
            throw WPEMetalTextureLoaderError.malformedPayload(
                "unknown texture format \(payload.info.textureFormatCode)"
            )
        }
        let mapping = try WPEMetalTextureFormatMapper.mapping(for: format, capabilities: capabilities)

        var frames: [WPETexAnimatedFrame] = []
        frames.reserveCapacity(animation.frames.count)
        let device = self.device
        for (frameIndex, frame) in animation.frames.enumerated() {
            guard let atlasMip = frame.mipmaps.first else {
                throw WPEMetalTextureLoaderError.malformedPayload(
                    "animation frame \(frameIndex) is missing its source atlas mipmap"
                )
            }
            let frameLabel = "\(label) frame \(frameIndex)"
            let subRect = frame.subRect
            // CPU crop + GPU upload both run on the dedicated upload
            // queue (per-frame allocate already lives there). Keeping
            // crop inside the same `perform` block avoids pulling large
            // memcpys onto MainActor — sprite sheets can run 60+ frames
            // and a 4k atlas crop per frame is multi-MB of memmove.
            let texture = try await uploadQueue.perform {
                let cropped: WPETexSubRectCropper.CroppedTextureBytes
                do {
                    cropped = try WPETexSubRectCropper.crop(
                        atlasBytes: atlasMip.bytes,
                        atlasWidth: atlasMip.width,
                        atlasHeight: atlasMip.height,
                        subRect: subRect,
                        mapping: mapping
                    )
                } catch {
                    throw WPEMetalTextureLoaderError.malformedPayload(
                        "animation frame \(frameIndex) sub-rect crop failed: \(error)"
                    )
                }
                return try Self.uploadCroppedFrame(
                    cropped: cropped,
                    mapping: mapping,
                    label: frameLabel,
                    device: device
                )
            }
            frames.append(WPETexAnimatedFrame(
                texture: texture,
                sourceSubRect: frame.subRect,
                duration: frame.duration
            ))
        }

        return WPETexAnimatedTextureSource(
            frames: frames,
            frameRate: animation.frameRate,
            loop: animation.loop
        )
    }

    /// Allocates a Metal texture sized to the cropped frame and uploads
    /// the bytes. Reused by raw `.tex` (P0) and encoded PNG/JPEG + TEXS
    /// (P1) paths so both produce pixel-identical frame textures.
    static func uploadCroppedFrame(
        cropped: WPETexSubRectCropper.CroppedTextureBytes,
        mapping: WPEMetalTextureFormatMapping,
        label: String,
        device: MTLDevice
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: mapping.pixelFormat,
            width: max(cropped.width, 1),
            height: max(cropped.height, 1),
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw WPEMetalTextureLoaderError.textureAllocationFailed
        }
        texture.label = label

        cropped.bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, cropped.width, cropped.height),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: cropped.bytesPerRow
            )
        }
        return texture
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
#endif
