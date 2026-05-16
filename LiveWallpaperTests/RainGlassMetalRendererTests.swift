import CoreImage
import Foundation
import Metal
import Testing
@testable import LiveWallpaper

@Suite("Rain glass Metal renderer")
struct RainGlassMetalRendererTests {
    @Test("Renderer keeps the in-flight texture ring bounded")
    func rendererKeepsTextureRingBounded() {
        #expect(RainGlassMetalRenderer.inFlightTextureCount == 3)
    }

    @Test("Renderer returns an image cropped to the requested extent")
    func rendererReturnsRequestedExtent() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let renderer = try #require(RainGlassMetalRenderer(device: device))
        let input = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 96, height: 64))

        let output = try #require(renderer.render(inputImage: input, time: 1.25, width: 96, height: 64))

        #expect(output.extent == CGRect(x: 0, y: 0, width: 96, height: 64))
    }

    @Test("Water map carries alpha, thickness, and non-neutral refraction")
    func waterMapCarriesDropSignals() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let renderer = try #require(RainGlassMetalRenderer(device: device))

        let waterMap = try #require(renderer.makeWaterMapForTesting(width: 128, height: 96, time: 2.5))
        let bytes = readTextureBytes(waterMap)

        var sawDrop = false
        var sawThickness = false
        var sawRefraction = false
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let r = Int(bytes[i])
            let g = Int(bytes[i + 1])
            let b = Int(bytes[i + 2])
            let a = Int(bytes[i + 3])

            if a > 16 { sawDrop = true }
            if b > 12 { sawThickness = true }
            if a > 16 && (abs(r - 128) > 3 || abs(g - 128) > 3) {
                sawRefraction = true
            }
        }

        #expect(sawDrop)
        #expect(sawThickness)
        #expect(sawRefraction)
    }

    private func readTextureBytes(_ texture: MTLTexture) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        texture.getBytes(
            &bytes,
            bytesPerRow: texture.width * 4,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height),
            mipmapLevel: 0
        )
        return bytes
    }
}
