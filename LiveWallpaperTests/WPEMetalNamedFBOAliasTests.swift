import Foundation
import Metal
import Testing
@testable import LiveWallpaper

@Suite("WPEMetalShaderInputs — named FBO alias lookup")
struct WPEMetalNamedFBOAliasTests {

    @Test("Exact-name lookup is unaffected by alias logic")
    func exactNameWins() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let texture = Self.makeScratchTexture(device: device) else {
            return
        }
        var frameState = Self.makeFrameState(output: texture)
        frameState.latestNamedTextures["blur_start"] = texture
        let resolved = WPEMetalShaderInputs.resolveAliasedNamedTexture(
            name: "blur_start",
            frameState: frameState
        )
        // resolveAliasedNamedTexture is the *fuzzy* helper; exact-name
        // matches happen in `resolve(...)`'s primary path, so the fuzzy
        // helper deliberately does not return on exact hit. Verify it
        // returns nil so the caller still takes the exact-match branch.
        #expect(resolved == nil)
    }

    @Test("`_rt_` prefix is stripped when probing aliases")
    func stripsRTPrefix() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let texture = Self.makeScratchTexture(device: device) else {
            return
        }
        var frameState = Self.makeFrameState(output: texture)
        frameState.latestNamedTextures["blur_start"] = texture
        let resolved = WPEMetalShaderInputs.resolveAliasedNamedTexture(
            name: "_rt_blur_start",
            frameState: frameState
        )
        #expect(resolved != nil)
    }

    @Test("`_rt_` prefix is added when probing aliases")
    func addsRTPrefix() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let texture = Self.makeScratchTexture(device: device) else {
            return
        }
        var frameState = Self.makeFrameState(output: texture)
        frameState.latestNamedTextures["_rt_blur_start"] = texture
        let resolved = WPEMetalShaderInputs.resolveAliasedNamedTexture(
            name: "blur_start",
            frameState: frameState
        )
        #expect(resolved != nil)
    }

    @Test("Case-insensitive fallback catches stray capitalization")
    func caseInsensitiveFallback() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let texture = Self.makeScratchTexture(device: device) else {
            return
        }
        var frameState = Self.makeFrameState(output: texture)
        frameState.latestNamedTextures["Blur_Start_2"] = texture
        let resolved = WPEMetalShaderInputs.resolveAliasedNamedTexture(
            name: "blur_start_2",
            frameState: frameState
        )
        #expect(resolved != nil)
    }

    @Test("Unknown names still return nil so the caller raises missingTexture")
    func unknownNameReturnsNil() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let texture = Self.makeScratchTexture(device: device) else {
            return
        }
        var frameState = Self.makeFrameState(output: texture)
        frameState.latestNamedTextures["something_else"] = texture
        let resolved = WPEMetalShaderInputs.resolveAliasedNamedTexture(
            name: "blur_start",
            frameState: frameState
        )
        #expect(resolved == nil)
    }

    private static func makeFrameState(output: MTLTexture) -> WPEMetalFrameState {
        WPEMetalFrameState(
            output: output,
            sceneSize: CGSize(width: 4, height: 4)
        )
    }

    private static func makeScratchTexture(device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 4,
            height: 4,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)
    }
}
