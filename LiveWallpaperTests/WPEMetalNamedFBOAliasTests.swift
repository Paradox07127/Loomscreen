import Foundation
import LiveWallpaperProWPE
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

    @Test("Scene writes bump the generation so alias snapshots can detect staleness")
    func sceneWriteGenerationTracksSnapshotStaleness() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let texture = Self.makeScratchTexture(device: device) else {
            return
        }
        var frameState = Self.makeFrameState(output: texture)

        // Snapshot taken at generation 0 (how snapshotFullFrameBufferIfAliasingScene records it).
        frameState.latestNamedTextures["_rt_FullFrameBuffer"] = texture
        frameState.sceneAliasSnapshotGenerations["_rt_FullFrameBuffer"] = frameState.sceneWriteGeneration
        #expect(frameState.sceneAliasSnapshotGenerations["_rt_FullFrameBuffer"] == frameState.sceneWriteGeneration)

        // Scene draws (beams, halos) after the capture make it stale — 3521337568's
        // filmgrain must re-capture or its full-frame redraw erases those layers.
        frameState.registerWrite(texture: texture, targetID: .scene)
        #expect(frameState.sceneAliasSnapshotGenerations["_rt_FullFrameBuffer"] != frameState.sceneWriteGeneration)

        // FBO writes don't invalidate scene-alias snapshots…
        frameState.registerWrite(texture: texture, targetID: .named("_rt_imageLayerComposite_x_a"))
        let generationAfterFBOWrite = frameState.sceneWriteGeneration
        frameState.sceneAliasSnapshotGenerations["_rt_FullFrameBuffer"] = generationAfterFBOWrite
        #expect(frameState.sceneWriteGeneration == generationAfterFBOWrite)

        // …but a REAL write to an alias-named target retires its snapshot entry,
        // so the snapshot logic never clobbers real chain output.
        frameState.sceneAliasSnapshotGenerations["_rt_HalfFrameBuffer"] = frameState.sceneWriteGeneration
        frameState.registerWrite(texture: texture, targetID: .named("_rt_HalfFrameBuffer"))
        #expect(frameState.sceneAliasSnapshotGenerations["_rt_HalfFrameBuffer"] == nil)
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

@Suite("WPEMetalShaderInputs — declared-FBO first-read zero fill")
struct WPEMetalDeclaredFBOZeroFillTests {
    private static let declaredName = "_rt_FullCompoBuffer1"

    @Test("A declared-but-unwritten FBO first read returns a cached zero stand-in")
    func declaredFBOFirstReadReturnsZeroTexture() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let output = try #require(Self.makeScratchTexture(device: device))
        let pool = WPEMetalRenderTargetPool(device: device)
        pool.prepare(pipeline: Self.pipelineDeclaring(Self.declaredName))

        let frameState = WPEMetalFrameState(
            output: output,
            sceneSize: CGSize(width: 4, height: 4),
            renderTargetPool: pool
        )
        // No pass has written the RT this frame — WPE reads it as all-zero.
        let resolved = try WPEMetalShaderInputs.resolve(
            reference: .fbo(Self.declaredName),
            textures: [:],
            frameState: frameState,
            currentTargetID: .scene
        )
        #expect(resolved.pixelFormat == WPEMetalRenderExecutor.outputPixelFormat)

        // Re-reading the same declared name reuses the cached stand-in (no per-frame
        // re-allocation).
        let again = try WPEMetalShaderInputs.resolve(
            reference: .fbo(Self.declaredName),
            textures: [:],
            frameState: frameState,
            currentTargetID: .scene
        )
        #expect(resolved === again)
    }

    @Test("An UNDECLARED FBO name still throws missingTexture")
    func undeclaredFBONameStillThrows() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let output = try #require(Self.makeScratchTexture(device: device))
        let pool = WPEMetalRenderTargetPool(device: device)
        pool.prepare(pipeline: Self.pipelineDeclaring(Self.declaredName))

        let frameState = WPEMetalFrameState(
            output: output,
            sceneSize: CGSize(width: 4, height: 4),
            renderTargetPool: pool
        )
        // A name no layer declares is a genuine graph bug — must stay loud.
        #expect(throws: (any Error).self) {
            try WPEMetalShaderInputs.resolve(
                reference: .fbo("_rt_NotDeclaredAnywhere"),
                textures: [:],
                frameState: frameState,
                currentTargetID: .scene
            )
        }
    }

    private static func pipelineDeclaring(_ fboName: String) -> WPEPreparedRenderPipeline {
        let layer = WPERenderLayer(
            objectID: "obj",
            objectName: "obj",
            imagePath: "",
            materialPath: nil,
            geometry: .identity,
            compositeA: "comp_a",
            compositeB: "comp_b",
            localFBOs: [WPERenderFBO(name: fboName, scale: 1, format: "rgba8888", unique: true)],
            passes: []
        )
        return WPEPreparedRenderPipeline(
            layers: [WPEPreparedRenderLayer(graphLayer: layer, passes: [])]
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
