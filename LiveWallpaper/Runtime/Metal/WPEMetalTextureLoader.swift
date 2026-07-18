#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperProWPE
import Metal
import MetalKit

// `@unchecked Sendable` so the parallel texture-resolve lane in
// `WPEMetalSceneRenderer.loadTextures` can capture the loader: all stored
// properties are thread-safe and nothing is mutated after init.
struct WPEMetalTextureLoader: @unchecked Sendable {
    private let device: MTLDevice
    private let capabilities: WPEMetalTextureCapabilities
    private let uploadQueue: WPEMetalTextureUploadQueue

    /// Corpus profile: ~47% of `.tex` assets ship a pre-baked mip chain that the
    /// decoder already decompresses in full (`payload.mipmaps`), but the upload
    /// path below only ever wrote level 0 — minified sampling of those textures
    /// aliases instead of filtering down the chain. Default OFF so the existing
    /// level-0-only upload (and constexpr/builtin-shader sampling) stays
    /// byte-identical; ON also requires `WPEMetalRenderExecutor
    /// .customShaderSamplerState` to opt its `.mipFilter` in under the same
    /// flag — builtin shaders' samplers are `constexpr` (compiled ahead of
    /// time) and cannot be flag-gated, so ON only benefits transpiled/custom
    /// shader sampling. Read fresh (not cached) each call: texture uploads
    /// happen once per unique texture at scene load, not per frame, so a
    /// `UserDefaults` read here is not a hot-path cost — unlike the sibling
    /// per-load-cached flags elsewhere in the renderer, this one takes effect
    /// without restarting.
    static let mipChainDefaultsKey = "WPEMetalMipChainEnabled"
    static var isMipChainEnabled: Bool { readMipChainEnabled() }
    static func readMipChainEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: mipChainDefaultsKey)
    }

    init(
        device: MTLDevice,
        capabilities: WPEMetalTextureCapabilities? = nil,
        uploadQueue: WPEMetalTextureUploadQueue = .shared
    ) {
        self.device = device
        self.capabilities = capabilities ?? WPEMetalTextureCapabilities(device: device)
        self.uploadQueue = uploadQueue
    }

    func makeTexture(
        from payload: WPETexTexturePayload,
        label: String,
        colorSpace: WPEMetalColorSpace = .sRGB
    ) async throws -> MTLTexture {
        try Task.checkCancellation()
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
                capabilities: capabilities,
                colorSpace: colorSpace
            )
        }
    }

    /// Lazy LZ4 streaming source for multi-frame `.tex` animations that
    /// would otherwise saturate VRAM if every frame were pre-uploaded.
    /// See `WPETexLazyAnimatedTextureSource` for the on-demand decode +
    /// sub-rect crop + rotating-texture rationale.
    // Not `@MainActor` (M2c1b-3c): called on the renderer's actor.
    func makeLazyAnimatedTextureSource(
        from payload: WPETexStreamingPayload,
        label: String
    ) throws -> WPETexLazyAnimatedTextureSource {
        try WPETexLazyAnimatedTextureSource(payload: payload, device: device, label: label)
    }

    /// **Invariant**: one MTLTexture per unique `imageID` (the whole atlas),
    /// not per-frame sub-rect. The particle renderer's sprite-grid math
    /// (`parseParticleSpriteSheet`) divides atlas pixel dims by `.tex-json`
    /// sprite frame dims to recover `cols/rows` — so frames must reference
    /// the full atlas. Sub-rect metadata is retained on
    /// `WPETexAnimatedFrame.sourceSubRect` for shader-aware consumers
    /// (sprite-sheet background passes).
    // Not `@MainActor` (M2c1b-3c): called on the renderer's actor.
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
            try Task.checkCancellation()
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

    func makeTexture(
        from cgImage: CGImage,
        label: String,
        colorSpace: WPEMetalColorSpace = .sRGB
    ) async throws -> MTLTexture {
        try Task.checkCancellation()
        let device = self.device
        return try await uploadQueue.perform {
            let loader = MTKTextureLoader(device: device)
            do {
                let texture = try loader.newTexture(
                    cgImage: cgImage,
                    options: [
                        MTKTextureLoader.Option.SRGB: colorSpace == .sRGB,
                        MTKTextureLoader.Option.textureUsage: MTLTextureUsage.shaderRead.rawValue
                    ]
                )
                texture.label = label
                WPEMetalTextureMetadataRegistry.shared.register(
                    texture: texture,
                    imageWidth: cgImage.width,
                    imageHeight: cgImage.height
                )
                return texture
            } catch {
                throw WPEMetalTextureLoaderError.malformedPayload(error.localizedDescription)
            }
        }
    }

    /// RG88 is sampled as LUMINANCE_ALPHA (R,R,R,G) for particle glow sprites — but the
    /// shake effect stores its flow masks as RG88 too, with R = x-displacement and G =
    /// y-displacement. Swizzling those collapses `.g` onto `.r`, destroying the y-flow so
    /// the whole composited frame is displaced (full-screen tearing / criss-cross lines,
    /// not the masked-region motion). Flow/data masks live under `masks/` (`shake_mask_*`);
    /// glow sprites never do, so the path name is the reliable discriminator.
    static func rg88NeedsLuminanceAlphaSwizzle(isLuminanceAlpha: Bool, label: String) -> Bool {
        guard isLuminanceAlpha else { return false }
        return !label.lowercased().contains("mask")
    }

    private static func makeTextureSynchronously(
        from payload: WPETexTexturePayload,
        label: String,
        device: MTLDevice,
        capabilities: WPEMetalTextureCapabilities,
        colorSpace: WPEMetalColorSpace = .sRGB
    ) throws -> MTLTexture {
        guard let format = payload.info.format else {
            throw WPEMetalTextureLoaderError.malformedPayload("unknown texture format \(payload.info.textureFormatCode)")
        }
        guard let mip = payload.largestMipmap else {
            throw WPEMetalTextureLoaderError.malformedPayload("missing mipmap")
        }

        let mapping = try WPEMetalTextureFormatMapper.mapping(
            for: format, capabilities: capabilities, colorSpace: colorSpace)
        // Only the level-0 payload is guaranteed present; a real chain needs
        // more than one decoded level before the flag has anything to do.
        let mipChainEligible = Self.isMipChainEnabled && payload.mipmaps.count > 1
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: mapping.pixelFormat,
            width: mip.width,
            height: mip.height,
            mipmapped: mipChainEligible
        )
        if mipChainEligible {
            // The container's chain may be shorter than the full log2 chain
            // `mipmapped: true` would otherwise imply — bound it to exactly
            // the levels we have decoded bytes for.
            descriptor.mipmapLevelCount = payload.mipmaps.count
        }
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        // RG88 particle glow sprites sample as LUMINANCE_ALPHA → (R, R, R, G): R
        // luminance broadcast, G alpha falloff (raw `.rg8Unorm` samples (R, G, 0, 1),
        // rendering opaque — the "red square light" / red-line fog artifacts).
        if Self.rg88NeedsLuminanceAlphaSwizzle(isLuminanceAlpha: payload.info.isRG88LuminanceAlpha, label: label) {
            descriptor.swizzle = MTLTextureSwizzleChannels(red: .red, green: .red, blue: .red, alpha: .green)
        }

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw WPEMetalTextureLoaderError.textureAllocationFailed
        }
        texture.label = label
        WPEMetalTextureMetadataRegistry.shared.register(
            texture: texture,
            imageWidth: payload.info.imageWidth > 0 ? payload.info.imageWidth : mip.width,
            imageHeight: payload.info.imageHeight > 0 ? payload.info.imageHeight : mip.height,
            clampUVs: payload.info.clampUVs,
            noInterpolation: payload.info.noInterpolation
        )

        let expected = format.expectedByteCount(width: mip.width, height: mip.height)
        guard mip.bytes.count >= expected else {
            throw WPEMetalTextureLoaderError.malformedPayload(
                "mip bytes \(mip.bytes.count) smaller than expected \(expected)"
            )
        }
        let bytesPerRow = try bytesPerRow(width: mip.width, mapping: mapping)

        try mip.bytes.withUnsafeBytes { raw in
            guard let baseAddress = raw.baseAddress else {
                throw WPEMetalTextureLoaderError.malformedPayload("Empty mipmap bytes baseAddress")
            }
            texture.replace(
                region: MTLRegionMake2D(0, 0, mip.width, mip.height),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: bytesPerRow
            )
        }

        if mipChainEligible {
            for level in payload.mipmaps.dropFirst() {
                let levelExpected = format.expectedByteCount(width: level.width, height: level.height)
                guard level.bytes.count >= levelExpected else {
                    throw WPEMetalTextureLoaderError.malformedPayload(
                        "mip bytes \(level.bytes.count) smaller than expected \(levelExpected) (level \(level.index))"
                    )
                }
                let levelBytesPerRow = try Self.bytesPerRow(width: level.width, mapping: mapping)
                try level.bytes.withUnsafeBytes { raw in
                    guard let baseAddress = raw.baseAddress else {
                        throw WPEMetalTextureLoaderError.malformedPayload(
                            "Empty mipmap bytes baseAddress (level \(level.index))"
                        )
                    }
                    texture.replace(
                        region: MTLRegionMake2D(0, 0, level.width, level.height),
                        mipmapLevel: level.index,
                        withBytes: baseAddress,
                        bytesPerRow: levelBytesPerRow
                    )
                }
            }
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
