import CoreGraphics
import Foundation
import Metal
import Testing
@testable import LiveWallpaper

@Suite("WPE Metal render executor")
struct WPEMetalRenderExecutorTests {

    @Test("Renders solidcolor pass to offscreen texture")
    func rendersSolidColor() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let pass = solidPass()
        let pipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(
                graphLayer: graphLayer(pass: pass),
                passes: [WPEPreparedRenderPass(
                    pass: pass,
                    shader: WPEShaderProgram(name: "solidcolor", vertexSource: "", fragmentSource: "", isBuiltin: true),
                    textureBindings: [:],
                    comboValues: [:],
                    uniformValues: ["g_Color": .vector([1, 0, 0, 1])]
                )]
            )
        ])

        let output = try executor.render(pipeline: pipeline, size: CGSize(width: 4, height: 4), textures: [:])
        let pixel = try readPixel(output, x: 2, y: 2)

        #expect(pixel.r >= 250)
        #expect(pixel.g <= 5)
        #expect(pixel.b <= 5)
        #expect(pixel.a >= 250)
    }

    @Test("Fails closed for non-built-in shader programs")
    func rejectsCustomShader() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let pass = WPERenderPass(
            id: "1.0",
            phase: .effect(file: "effects/custom/effect.json"),
            shader: "effects/custom",
            source: .image("materials/base.png"),
            target: .scene,
            textures: [:],
            binds: [:],
            constants: [:],
            combos: [:],
            blending: "normal",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )
        let pipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(
                graphLayer: graphLayer(pass: pass),
                passes: [WPEPreparedRenderPass(
                    pass: pass,
                    shader: WPEShaderProgram(name: "effects/custom", vertexSource: "", fragmentSource: "", isBuiltin: false),
                    textureBindings: [:],
                    comboValues: [:],
                    uniformValues: [:]
                )]
            )
        ])

        #expect(throws: WPEMetalRenderExecutorError.unsupportedShader("effects/custom")) {
            _ = try executor.render(pipeline: pipeline, size: CGSize(width: 4, height: 4), textures: [:])
        }
    }

    @Test("Copies sampled input texture to offscreen output")
    func copiesInputTexture() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let input = try makeRGBAInputTexture(device: device, bytes: Data([
            0, 255, 0, 255,
            0, 255, 0, 255,
            0, 255, 0, 255,
            0, 255, 0, 255
        ]))
        let pass = copyPass()
        let pipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(
                graphLayer: graphLayer(pass: pass),
                passes: [WPEPreparedRenderPass(
                    pass: pass,
                    shader: WPEShaderProgram(name: "genericimage2", vertexSource: "", fragmentSource: "", isBuiltin: true),
                    textureBindings: [0: .image("materials/base.png")],
                    comboValues: [:],
                    uniformValues: [:]
                )]
            )
        ])

        let output = try executor.render(
            pipeline: pipeline,
            size: CGSize(width: 2, height: 2),
            textures: ["materials/base.png": input]
        )
        let pixel = try readPixel(output, x: 1, y: 1)

        #expect(pixel.r <= 5)
        #expect(pixel.g >= 250)
        #expect(pixel.b <= 5)
        #expect(pixel.a >= 250)
    }

    @Test("Copies image layers that have no material passes")
    func copiesImageLayerWithoutPasses() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let input = try makeRGBAInputTexture(device: device, bytes: Data([
            0, 0, 255, 255,
            0, 0, 255, 255,
            0, 0, 255, 255,
            0, 0, 255, 255
        ]))
        let layer = WPERenderLayer(
            objectID: "layer",
            objectName: "Layer",
            imagePath: "materials/base.png",
            materialPath: nil,
            compositeA: "a",
            compositeB: "b",
            localFBOs: [],
            passes: []
        )
        let pipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(graphLayer: layer, passes: [])
        ])

        let output = try executor.render(
            pipeline: pipeline,
            size: CGSize(width: 2, height: 2),
            textures: ["materials/base.png": input]
        )
        let pixel = try readPixel(output, x: 1, y: 1)

        #expect(pixel.r <= 5)
        #expect(pixel.g <= 5)
        #expect(pixel.b >= 250)
        #expect(pixel.a >= 250)
    }
}

private struct Pixel {
    let r: UInt8
    let g: UInt8
    let b: UInt8
    let a: UInt8
}

private func readPixel(_ texture: MTLTexture, x: Int, y: Int) throws -> Pixel {
    var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
    texture.getBytes(
        &bytes,
        bytesPerRow: texture.width * 4,
        from: MTLRegionMake2D(0, 0, texture.width, texture.height),
        mipmapLevel: 0
    )
    let index = (y * texture.width + x) * 4
    return Pixel(r: bytes[index], g: bytes[index + 1], b: bytes[index + 2], a: bytes[index + 3])
}

private func solidPass() -> WPERenderPass {
    WPERenderPass(
        id: "solid.0",
        phase: .material,
        shader: "solidcolor",
        source: .previous,
        target: .scene,
        textures: [:],
        binds: [:],
        constants: ["g_Color": .vector([1, 0, 0, 1])],
        combos: [:],
        blending: "normal",
        cullMode: "nocull",
        depthTest: "disabled",
        depthWrite: "disabled"
    )
}

private func copyPass() -> WPERenderPass {
    WPERenderPass(
        id: "copy.0",
        phase: .material,
        shader: "genericimage2",
        source: .image("materials/base.png"),
        target: .scene,
        textures: [0: .image("materials/base.png")],
        binds: [:],
        constants: [:],
        combos: [:],
        blending: "normal",
        cullMode: "nocull",
        depthTest: "disabled",
        depthWrite: "disabled"
    )
}

private func makeRGBAInputTexture(device: MTLDevice, bytes: Data) throws -> MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba8Unorm,
        width: 2,
        height: 2,
        mipmapped: false
    )
    descriptor.usage = [.shaderRead]
    descriptor.storageMode = .shared
    let texture = try #require(device.makeTexture(descriptor: descriptor))
    bytes.withUnsafeBytes { raw in
        texture.replace(
            region: MTLRegionMake2D(0, 0, 2, 2),
            mipmapLevel: 0,
            withBytes: raw.baseAddress!,
            bytesPerRow: 8
        )
    }
    return texture
}

private func graphLayer(pass: WPERenderPass) -> WPERenderLayer {
    WPERenderLayer(
        objectID: "layer",
        objectName: "Layer",
        imagePath: "materials/base.png",
        materialPath: nil,
        compositeA: "a",
        compositeB: "b",
        localFBOs: [],
        passes: [pass]
    )
}
