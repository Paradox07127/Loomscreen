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

    // P0: variable-duration TEXS schedules must play at each frame's own
    // duration instead of being collapsed to the average frame rate.
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
        // 0.20001 lands just past the 0.2s boundary; we avoid asserting on
        // exact frame transitions because 0.0+0.2+0.1 != 0.3 in IEEE-754
        // and binary-search comparisons against the exact boundary depend
        // on which side rounding lands on.
        #expect(source.frameIndex(at: 0.20001) == 1)
        #expect(source.frameIndex(at: 0.29999) == 1)
        #expect(source.frameIndex(at: 0.30001) == 2)
        #expect(source.frameIndex(at: 0.59999) == 2)
        // Wraps at total duration (0.6s) — use just past the boundary.
        #expect(source.frameIndex(at: 0.60001) == 0)
    }

    // P0: source returns the cropped per-frame texture, not the source atlas.
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

    private func makeTexture(device: MTLDevice, value: UInt8) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        var bytes = [value, 0, 0, 255]
        texture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0,
            withBytes: &bytes,
            bytesPerRow: 4
        )
        return texture
    }
}
