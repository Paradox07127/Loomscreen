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
