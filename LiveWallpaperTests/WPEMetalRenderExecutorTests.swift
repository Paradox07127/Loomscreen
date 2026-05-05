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

private struct Pixel: Equatable {
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

private extension WPEMetalRenderExecutorTests {
    @Test("Offscreen output is sRGB-tagged for SpriteKit gamma parity")
    func outputTextureIsSRGB() throws {
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
                    uniformValues: ["g_Color": .vector([1, 1, 1, 1])]
                )]
            )
        ])

        let output = try executor.render(pipeline: pipeline, size: CGSize(width: 4, height: 4), textures: [:])

        #expect(output.pixelFormat == .rgba8Unorm_srgb)
        #expect(WPEMetalRenderExecutor.outputPixelFormat == .rgba8Unorm_srgb)
    }

    @Test("solidcolor mid-tone uniform round-trips through sRGB target without gamma double-encoding")
    func solidcolorMidToneSRGBRoundTrip() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let pass = WPERenderPass(
            id: "midgray.0",
            phase: .material,
            shader: "solidcolor",
            source: .previous,
            target: .scene,
            textures: [:],
            binds: [:],
            constants: ["g_Color": .vector([0.5, 0.5, 0.5, 1])],
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
                    shader: WPEShaderProgram(name: "solidcolor", vertexSource: "", fragmentSource: "", isBuiltin: true),
                    textureBindings: [:],
                    comboValues: [:],
                    uniformValues: ["g_Color": .vector([0.5, 0.5, 0.5, 1])]
                )]
            )
        ])

        let output = try executor.render(pipeline: pipeline, size: CGSize(width: 4, height: 4), textures: [:])
        let pixel = try readPixel(output, x: 2, y: 2)

        // sRGB "0.5" round-trips back to byte 128 ±2 when uniforms are
        // linearized before reaching the sRGB-tagged target. Without the
        // sRGB→linear conversion the byte would read ~188 (gamma double-
        // encoded). This test pins the H3 gamma fix.
        #expect(abs(Int(pixel.r) - 128) <= 3)
        #expect(abs(Int(pixel.g) - 128) <= 3)
        #expect(abs(Int(pixel.b) - 128) <= 3)
        #expect(pixel.a >= 250)
    }

    @Test("Runtime clock uniforms do not change solidcolor built-in output")
    func runtimeClockDoesNotChangeSolidColorOutput() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let pass = solidPass()
        let pipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(
                graphLayer: graphLayer(pass: pass, parallaxDepth: 0),
                passes: [
                    WPEPreparedRenderPass(
                        pass: pass,
                        shader: WPEShaderProgram(
                            name: "solidcolor",
                            vertexSource: "",
                            fragmentSource: "",
                            isBuiltin: true
                        ),
                        textureBindings: [:],
                        comboValues: [:],
                        uniformValues: ["g_Color": .vector([0.5, 0.5, 0.5, 1])]
                    )
                ]
            )
        ])
        let camera = WPEMetalCameraUniforms(
            orthogonalProjection: WPESceneOrthogonalProjection(width: 4, height: 4, auto: true),
            sceneCamera: .defaultCamera
        )

        let output0 = try executor.render(
            pipeline: pipeline,
            size: CGSize(width: 4, height: 4),
            textures: [:],
            runtimeUniforms: WPEMetalRuntimeUniforms(
                time: 0,
                daytime: 0,
                brightness: 1,
                pointerPosition: SIMD2<Double>(0.5, 0.5)
            ),
            cameraUniforms: camera
        )
        let output1 = try executor.render(
            pipeline: pipeline,
            size: CGSize(width: 4, height: 4),
            textures: [:],
            runtimeUniforms: WPEMetalRuntimeUniforms(
                time: 1,
                daytime: 0.5,
                brightness: 1,
                pointerPosition: SIMD2<Double>(0.9, 0.1)
            ),
            cameraUniforms: camera
        )

        #expect(try readPixel(output0, x: 2, y: 2) == readPixel(output1, x: 2, y: 2))
    }

    @Test("Generic image parallax offset is bounded by pointer delta and layer depth")
    func genericImageParallaxOffsetIsBounded() throws {
        let offset = WPEMetalRenderExecutor.parallaxUVOffset(
            pointerPosition: SIMD2<Double>(1.5, 0.5),
            parallaxDepth: 0.1
        )

        #expect(abs(offset.x - 0.01) < 0.0001)
        #expect(abs(offset.y) < 0.0001)
    }

    @Test("Generic image copy path shifts samples when parallax depth is non-zero")
    func genericImageCopyPathShiftsSamplesWithParallax() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)

        var bytes = Data()
        for x in 0..<100 {
            bytes.append(UInt8(x))
            bytes.append(0)
            bytes.append(0)
            bytes.append(255)
        }
        let input = try makeRGBAInputTexture(device: device, width: 100, height: 1, bytes: bytes)
        let pass = copyPass()
        let layer = graphLayer(pass: pass, parallaxDepth: 0.1)
        let pipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(
                graphLayer: layer,
                passes: [
                    WPEPreparedRenderPass(
                        pass: pass,
                        shader: WPEShaderProgram(
                            name: "genericimage2",
                            vertexSource: "",
                            fragmentSource: "",
                            isBuiltin: true
                        ),
                        textureBindings: [0: .image("materials/base.png")],
                        comboValues: [:],
                        uniformValues: [:]
                    )
                ]
            )
        ])

        let camera = WPEMetalCameraUniforms(
            orthogonalProjection: WPESceneOrthogonalProjection(width: 100, height: 1, auto: true),
            sceneCamera: .defaultCamera
        )
        let baseline = try executor.render(
            pipeline: pipeline,
            size: CGSize(width: 100, height: 1),
            textures: ["materials/base.png": input],
            runtimeUniforms: WPEMetalRuntimeUniforms(
                time: 0,
                daytime: 0,
                brightness: 1,
                pointerPosition: SIMD2<Double>(0.5, 0.5)
            ),
            cameraUniforms: camera
        )
        let shifted = try executor.render(
            pipeline: pipeline,
            size: CGSize(width: 100, height: 1),
            textures: ["materials/base.png": input],
            runtimeUniforms: WPEMetalRuntimeUniforms(
                time: 0,
                daytime: 0,
                brightness: 1,
                pointerPosition: SIMD2<Double>(1.5, 0.5)
            ),
            cameraUniforms: camera
        )

        let baselinePixel = try readPixel(baseline, x: 50, y: 0)
        let shiftedPixel = try readPixel(shifted, x: 50, y: 0)

        #expect(shiftedPixel.r >= baselinePixel.r)
        #expect(Int(shiftedPixel.r) - Int(baselinePixel.r) <= 10)
    }
}

private func makeRGBAInputTexture(
    device: MTLDevice,
    width: Int = 2,
    height: Int = 2,
    bytes: Data
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
    bytes.withUnsafeBytes { raw in
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: raw.baseAddress!,
            bytesPerRow: width * 4
        )
    }
    return texture
}

private func graphLayer(pass: WPERenderPass, parallaxDepth: Double = 0) -> WPERenderLayer {
    WPERenderLayer(
        objectID: "layer",
        objectName: "Layer",
        imagePath: "materials/base.png",
        materialPath: nil,
        compositeA: "a",
        compositeB: "b",
        localFBOs: [],
        passes: [pass],
        parallaxDepth: parallaxDepth
    )
}
