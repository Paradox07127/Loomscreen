import CoreGraphics
import Foundation
import Metal
import Testing
@testable import LiveWallpaper

@Suite("WPE TEX animated texture source")
struct WPETexAnimatedTextureSourceTests {

    @MainActor
    @Test("Selects frames at 25 FPS from runtime time")
    func selectsFramesAt25FPS() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let textures = try (0..<4).map { index in
            try makeTexture(device: device, value: UInt8(index))
        }
        let source = WPETexAnimatedTextureSource(
            frames: textures,
            frameRate: 25,
            loop: true
        )

        #expect(source.frameIndex(at: 0.000) == 0)
        #expect(source.frameIndex(at: 0.039) == 0)
        #expect(source.frameIndex(at: 0.041) == 1)
        #expect(source.frameIndex(at: 0.079) == 1)
        #expect(source.frameIndex(at: 0.081) == 2)
        #expect(source.frameIndex(at: 0.121) == 3)
        #expect(source.frameIndex(at: 0.161) == 0)
    }

    @MainActor
    @Test("Returns current frame texture for runtime time")
    func returnsCurrentFrameTexture() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let textures = try (0..<4).map { index in
            try makeTexture(device: device, value: UInt8(index))
        }
        let source = WPETexAnimatedTextureSource(
            frames: textures,
            frameRate: 25,
            loop: true
        )

        #expect(source.texture(at: 0.000) === textures[0])
        #expect(source.texture(at: 0.041) === textures[1])
        #expect(source.texture(at: 0.081) === textures[2])
        #expect(source.texture(at: 0.121) === textures[3])
    }

    @MainActor
    @Test("Non-loop animation clamps at the last frame")
    func nonLoopAnimationClampsAtLastFrame() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let textures = try (0..<3).map { index in
            try makeTexture(device: device, value: UInt8(index))
        }
        let source = WPETexAnimatedTextureSource(
            frames: textures,
            frameRate: 25,
            loop: false
        )

        #expect(source.frameIndex(at: 5.0) == 2)
    }

    @MainActor
    @Test("Variable-duration frames advance on each frame's own timeline")
    func variableDurationFramesAdvanceOnOwnTimeline() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let textures = try (0..<3).map { index in
            try makeTexture(device: device, value: UInt8(index))
        }
        let frames = [
            WPETexAnimatedFrame(texture: textures[0], sourceSubRect: nil, duration: 0.2),
            WPETexAnimatedFrame(texture: textures[1], sourceSubRect: nil, duration: 0.1),
            WPETexAnimatedFrame(texture: textures[2], sourceSubRect: nil, duration: 0.3)
        ]
        let source = WPETexAnimatedTextureSource(frames: frames, frameRate: 5, loop: true)

        #expect(source.frameIndex(at: 0.00) == 0)
        #expect(source.frameIndex(at: 0.19) == 0)
        #expect(source.frameIndex(at: 0.20001) == 1)
        #expect(source.frameIndex(at: 0.29999) == 1)
        #expect(source.frameIndex(at: 0.30001) == 2)
        #expect(source.frameIndex(at: 0.59999) == 2)
        #expect(source.frameIndex(at: 0.60001) == 0)
    }

    @MainActor
    @Test("texture(at:) returns the frame texture matching the current time")
    func textureAtReturnsCurrentFrameTexture() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let textures = try (0..<3).map { index in
            try makeTexture(device: device, value: UInt8(index))
        }
        let frames = [
            WPETexAnimatedFrame(texture: textures[0], sourceSubRect: CGRect(x: 0, y: 0, width: 1, height: 1), duration: 0.1),
            WPETexAnimatedFrame(texture: textures[1], sourceSubRect: CGRect(x: 1, y: 0, width: 1, height: 1), duration: 0.1),
            WPETexAnimatedFrame(texture: textures[2], sourceSubRect: CGRect(x: 0, y: 1, width: 1, height: 1), duration: 0.1)
        ]
        let source = WPETexAnimatedTextureSource(frames: frames, frameRate: 10, loop: true)

        #expect(source.texture(at: 0.0) === textures[0])
        #expect(source.texture(at: 0.1) === textures[1])
        #expect(source.texture(at: 0.2) === textures[2])
    }

    @MainActor
    @Test("Normalizes TEXS source sub-rects against atlas dimensions")
    func normalizesSourceSubRectsForParticleSpriteSheets() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let atlas = try makeTexture(device: device, value: 0, width: 100, height: 50)
        let frames = [
            WPETexAnimatedFrame(texture: atlas, sourceSubRect: CGRect(x: 0, y: 0, width: 25, height: 25), duration: 0.1),
            WPETexAnimatedFrame(texture: atlas, sourceSubRect: CGRect(x: 25, y: 0, width: 25, height: 25), duration: 0.1),
            WPETexAnimatedFrame(texture: atlas, sourceSubRect: CGRect(x: 0, y: 25, width: 25, height: 25), duration: 0.1)
        ]
        let source = WPETexAnimatedTextureSource(frames: frames, frameRate: 10, loop: true)

        #expect(source.spriteSheetFrameRate == 10)
        #expect(source.spriteSheetFrameRectsNormalized() == [
            SIMD4<Float>(0, 0, 0.25, 0.5),
            SIMD4<Float>(0.25, 0, 0.5, 0.5),
            SIMD4<Float>(0, 0.5, 0.25, 1.0)
        ])
    }

    private func makeTexture(
        device: MTLDevice,
        value: UInt8,
        width: Int = 1,
        height: Int = 1
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        var bytes = Array(repeating: UInt8(0), count: width * height * 4)
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            bytes[offset] = value
            bytes[offset + 3] = 255
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: &bytes,
            bytesPerRow: width * 4
        )
        return texture
    }
}
