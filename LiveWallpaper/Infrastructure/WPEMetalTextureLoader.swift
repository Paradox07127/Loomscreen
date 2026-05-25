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

    /// Phase 2E + P0 (regressed-and-restored): builds a per-TEXS-frame
    /// schedule against the source atlases.
    ///
    /// Each WPE `.tex` animation frame carries `(imageID, subRect)`. The
    /// modal consumer of the eager animated path is the particle
    /// renderer (`loadParticleSystems` calls `source.texture(at: 0)` and
    /// pipes the texture into `parseParticleSpriteSheet`, which divides
    /// the atlas pixel dimensions by the `.tex-json` sprite frame
    /// dimensions to recover `cols/rows`). That math depends on the
    /// **whole atlas** size, not the per-frame sub-rect.
    ///
    /// Earlier in this branch the loader uploaded one MTLTexture per
    /// TEXS frame, sized to its sub-rect — that visually decimated
    /// particles (every particle saw a 1×1 sprite grid since the cropped
    /// texture was already one sprite). The behaviour the corpus
    /// actually relies on is: one MTLTexture per unique imageID, every
    /// TEXS frame referencing the right atlas. Sub-rect metadata is
    /// retained on `WPETexAnimatedFrame.sourceSubRect` for future
    /// shader-aware consumers (sprite-sheet background passes), but the
    /// texture itself is the source atlas.
    @MainActor
    func makeAnimatedTextureSource(
        from payload: WPETexTexturePayload,
        label: String
    ) async throws -> WPETexAnimatedTextureSource {
        guard let animation = payload.animationTrack else {
            throw WPEMetalTextureLoaderError.malformedPayload("missing animation track")
        }

        // Dedup atlas uploads by imageID — mirrors makeAnimationTrack's
        // mipmapsByImageID cache. Frames sharing a source image reuse
        // the same MTLTexture instead of paying for redundant uploads.
        var atlasTextures: [Int: MTLTexture] = [:]
        var frames: [WPETexAnimatedFrame] = []
        frames.reserveCapacity(animation.frames.count)
        for (frameIndex, frame) in animation.frames.enumerated() {
            guard let atlasMip = frame.mipmaps.first else {
                throw WPEMetalTextureLoaderError.malformedPayload(
                    "animation frame \(frameIndex) is missing its source atlas mipmap"
                )
            }
            let texture: MTLTexture
            if let cached = atlasTextures[frame.imageID] {
                texture = cached
            } else {
                let framePayload = WPETexTexturePayload(
                    info: payload.info,
                    mipmaps: [atlasMip],
                    hasAnimationFrames: false
                )
                texture = try await makeTexture(
                    from: framePayload,
                    label: "\(label) image \(frame.imageID)"
                )
                atlasTextures[frame.imageID] = texture
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
