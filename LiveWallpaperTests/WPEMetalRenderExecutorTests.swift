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
        let offset = WPEMetalShaderInputs.parallaxUVOffset(
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

// MARK: - Phase 2C helpers and tests

private func solidPass(
    id: String,
    color: [Double],
    target: WPERenderTarget,
    blending: String = "normal",
    cullMode: String = "nocull",
    depthTest: String = "disabled",
    depthWrite: String = "disabled"
) -> WPERenderPass {
    WPERenderPass(
        id: id,
        phase: .material,
        shader: "solidcolor",
        source: .previous,
        target: target,
        textures: [:],
        binds: [:],
        constants: ["g_Color": .vector(color)],
        combos: [:],
        blending: blending,
        cullMode: cullMode,
        depthTest: depthTest,
        depthWrite: depthWrite
    )
}

private func copyPass(
    id: String,
    source: WPETextureReference,
    target: WPERenderTarget,
    blending: String = "normal",
    cullMode: String = "nocull",
    depthTest: String = "disabled",
    depthWrite: String = "disabled"
) -> WPERenderPass {
    WPERenderPass(
        id: id,
        phase: .command(file: "effects/copy/effect.json"),
        shader: "commands/copy",
        source: source,
        target: target,
        textures: [0: source],
        binds: [:],
        constants: [:],
        combos: [:],
        blending: blending,
        cullMode: cullMode,
        depthTest: depthTest,
        depthWrite: depthWrite
    )
}

private func preparedPipeline(
    localFBOs: [WPERenderFBO],
    passes: [WPEPreparedRenderPass]
) -> WPEPreparedRenderPipeline {
    let layer = WPERenderLayer(
        objectID: "layer",
        objectName: "Layer",
        imagePath: "materials/base.png",
        materialPath: nil,
        compositeA: "_rt_imageLayerComposite_layer_a",
        compositeB: "_rt_imageLayerComposite_layer_b",
        localFBOs: localFBOs,
        passes: passes.map(\.pass)
    )
    return WPEPreparedRenderPipeline(layers: [
        WPEPreparedRenderLayer(graphLayer: layer, passes: passes)
    ])
}

private func preparedBuiltinPass(
    _ pass: WPERenderPass,
    bindings: [Int: WPETextureReference] = [:],
    uniforms: [String: WPESceneShaderConstantValue] = [:]
) -> WPEPreparedRenderPass {
    WPEPreparedRenderPass(
        pass: pass,
        shader: WPEShaderProgram(name: pass.shader, vertexSource: "", fragmentSource: "", isBuiltin: true),
        textureBindings: bindings,
        comboValues: [:],
        uniformValues: uniforms
    )
}

private func makeCheckerTexture(device: MTLDevice) throws -> MTLTexture {
    try makeRGBAInputTexture(device: device, width: 2, height: 2, bytes: Data([
        255, 0,   0,   255,
        0,   255, 0,   255,
        0,   0,   255, 255,
        255, 255, 0,   255
    ]))
}

private struct BlendFixture: Sendable {
    let mode: String
    let expected: Pixel
}

private let blendFixtures: [BlendFixture] = [
    BlendFixture(mode: "normal", expected: Pixel(r: 188, g: 0, b: 188, a: 255)),
    BlendFixture(mode: "additive", expected: Pixel(r: 188, g: 0, b: 255, a: 255)),
    BlendFixture(mode: "multiply", expected: Pixel(r: 0, g: 0, b: 0, a: 255)),
    BlendFixture(mode: "translucent", expected: Pixel(r: 255, g: 0, b: 188, a: 255)),
    BlendFixture(mode: "normalmapped", expected: Pixel(r: 188, g: 0, b: 188, a: 255)),
    BlendFixture(mode: "disabled", expected: Pixel(r: 255, g: 0, b: 0, a: 128))
]

private extension WPEMetalRenderExecutorTests {
    @Test("Routes layerComposite target into a later FBO source")
    func routesLayerCompositeTargetIntoScene() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)

        let compositeName = "_rt_imageLayerComposite_layer_a"
        let writeComposite = solidPass(
            id: "layer.0",
            color: [1, 0, 0, 1],
            target: .layerComposite(name: compositeName),
            blending: "disabled"
        )
        let copyToScene = copyPass(
            id: "layer.1",
            source: .fbo(compositeName),
            target: .scene,
            blending: "disabled"
        )

        let pipeline = preparedPipeline(
            localFBOs: [],
            passes: [
                preparedBuiltinPass(writeComposite, uniforms: ["g_Color": .vector([1, 0, 0, 1])]),
                preparedBuiltinPass(copyToScene, bindings: [0: .fbo(compositeName)])
            ]
        )

        let output = try executor.render(pipeline: pipeline, size: CGSize(width: 4, height: 4), textures: [:])
        let pixel = try readPixel(output, x: 2, y: 2)

        #expect(pixel.r >= 250)
        #expect(pixel.g <= 5)
        #expect(pixel.b <= 5)
        #expect(pixel.a >= 250)
    }

    @Test("Routes declared FBO target into a later FBO source")
    func routesDeclaredFBOTargetIntoScene() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)

        let fbo = WPERenderFBO(name: "_rt_CustomBuffer", scale: 1, format: "rgba8888")
        let writeFBO = solidPass(
            id: "layer.0",
            color: [0, 1, 0, 1],
            target: .fbo(name: fbo.name),
            blending: "disabled"
        )
        let copyToScene = copyPass(
            id: "layer.1",
            source: .fbo(fbo.name),
            target: .scene,
            blending: "disabled"
        )

        let pipeline = preparedPipeline(
            localFBOs: [fbo],
            passes: [
                preparedBuiltinPass(writeFBO, uniforms: ["g_Color": .vector([0, 1, 0, 1])]),
                preparedBuiltinPass(copyToScene, bindings: [0: .fbo(fbo.name)])
            ]
        )

        let output = try executor.render(pipeline: pipeline, size: CGSize(width: 4, height: 4), textures: [:])
        let pixel = try readPixel(output, x: 2, y: 2)

        #expect(pixel.r <= 5)
        #expect(pixel.g >= 250)
        #expect(pixel.b <= 5)
        #expect(pixel.a >= 250)
    }

    @Test("Resolves previous to the most recent write to the same FBO target")
    func resolvesPreviousWithinSameFBOTarget() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)

        let checker = try makeCheckerTexture(device: device)
        let fbo = WPERenderFBO(name: "_rt_Checker", scale: 1, format: "rgba8888")

        let seedFBO = copyPass(
            id: "layer.0",
            source: .image("materials/checker.png"),
            target: .fbo(name: fbo.name),
            blending: "disabled"
        )
        let copyPreviousBackIntoSameFBO = copyPass(
            id: "layer.1",
            source: .previous,
            target: .fbo(name: fbo.name),
            blending: "disabled"
        )
        let copyFBOToScene = copyPass(
            id: "layer.2",
            source: .fbo(fbo.name),
            target: .scene,
            blending: "disabled"
        )

        let pipeline = preparedPipeline(
            localFBOs: [fbo],
            passes: [
                preparedBuiltinPass(seedFBO, bindings: [0: .image("materials/checker.png")]),
                preparedBuiltinPass(copyPreviousBackIntoSameFBO, bindings: [0: .previous]),
                preparedBuiltinPass(copyFBOToScene, bindings: [0: .fbo(fbo.name)])
            ]
        )

        let output = try executor.render(
            pipeline: pipeline,
            size: CGSize(width: 2, height: 2),
            textures: ["materials/checker.png": checker]
        )

        #expect(try readPixel(output, x: 0, y: 0).r >= 250)
        #expect(try readPixel(output, x: 1, y: 0).g >= 250)
        #expect(try readPixel(output, x: 0, y: 1).b >= 250)
        #expect(try readPixel(output, x: 1, y: 1).r >= 250)
        #expect(try readPixel(output, x: 1, y: 1).g >= 250)
    }

    @Test("Missing previous fails closed before any write to the current target")
    func missingPreviousFailsClosed() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)

        let fbo = WPERenderFBO(name: "_rt_Empty", scale: 1, format: "rgba8888")
        let pass = copyPass(
            id: "layer.0",
            source: .previous,
            target: .fbo(name: fbo.name),
            blending: "disabled"
        )
        let pipeline = preparedPipeline(
            localFBOs: [fbo],
            passes: [preparedBuiltinPass(pass, bindings: [0: .previous])]
        )

        #expect(throws: WPEMetalRenderExecutorError.missingTexture(.previous)) {
            _ = try executor.render(pipeline: pipeline, size: CGSize(width: 2, height: 2), textures: [:])
        }
    }

    @Test("Applies WPE blend factors", arguments: blendFixtures)
    func appliesWPEBlendFactors(fixture: BlendFixture) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)

        let destination = solidPass(
            id: "layer.0",
            color: [0, 0, 1, 1],
            target: .scene,
            blending: "disabled"
        )
        let source = solidPass(
            id: "layer.1",
            color: [1, 0, 0, 0.5],
            target: .scene,
            blending: fixture.mode
        )

        let pipeline = preparedPipeline(
            localFBOs: [],
            passes: [
                preparedBuiltinPass(destination, uniforms: ["g_Color": .vector([0, 0, 1, 1])]),
                preparedBuiltinPass(source, uniforms: ["g_Color": .vector([1, 0, 0, 0.5])])
            ]
        )

        let output = try executor.render(pipeline: pipeline, size: CGSize(width: 4, height: 4), textures: [:])
        let pixel = try readPixel(output, x: 2, y: 2)

        #expect(abs(Int(pixel.r) - Int(fixture.expected.r)) <= 2)
        #expect(abs(Int(pixel.g) - Int(fixture.expected.g)) <= 2)
        #expect(abs(Int(pixel.b) - Int(fixture.expected.b)) <= 2)
        #expect(abs(Int(pixel.a) - Int(fixture.expected.a)) <= 2)
    }

    @Test("Front culling discards the fullscreen built-in quad")
    func frontCullingDiscardsFullscreenQuad() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)

        let red = solidPass(id: "layer.0", color: [1, 0, 0, 1], target: .scene, blending: "disabled")
        let culledBlue = solidPass(
            id: "layer.1",
            color: [0, 0, 1, 1],
            target: .scene,
            blending: "disabled",
            cullMode: "front"
        )

        let pipeline = preparedPipeline(
            localFBOs: [],
            passes: [
                preparedBuiltinPass(red, uniforms: ["g_Color": .vector([1, 0, 0, 1])]),
                preparedBuiltinPass(culledBlue, uniforms: ["g_Color": .vector([0, 0, 1, 1])])
            ]
        )

        let output = try executor.render(pipeline: pipeline, size: CGSize(width: 4, height: 4), textures: [:])
        let pixel = try readPixel(output, x: 2, y: 2)

        #expect(pixel.r >= 250)
        #expect(pixel.g <= 5)
        #expect(pixel.b <= 5)
    }

    @Test("Depth less test rejects equal-depth fullscreen pass")
    func depthLessRejectsEqualDepthPass() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)

        let red = solidPass(
            id: "layer.0",
            color: [1, 0, 0, 1],
            target: .scene,
            blending: "disabled",
            depthTest: "always",
            depthWrite: "enabled"
        )
        let rejectedBlue = solidPass(
            id: "layer.1",
            color: [0, 0, 1, 1],
            target: .scene,
            blending: "disabled",
            depthTest: "less",
            depthWrite: "disabled"
        )

        let pipeline = preparedPipeline(
            localFBOs: [],
            passes: [
                preparedBuiltinPass(red, uniforms: ["g_Color": .vector([1, 0, 0, 1])]),
                preparedBuiltinPass(rejectedBlue, uniforms: ["g_Color": .vector([0, 0, 1, 1])])
            ]
        )

        let output = try executor.render(pipeline: pipeline, size: CGSize(width: 4, height: 4), textures: [:])
        let pixel = try readPixel(output, x: 2, y: 2)

        #expect(pixel.r >= 250)
        #expect(pixel.g <= 5)
        #expect(pixel.b <= 5)
    }

    @Test("solidlayer writes color multiplied by alpha")
    func solidlayerWritesColorMultipliedByAlpha() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)

        let pass = WPERenderPass(
            id: "solidlayer.0",
            phase: .material,
            shader: "materials/util/solidlayer.json",
            source: .previous,
            target: .scene,
            textures: [:],
            binds: [:],
            constants: ["g_Color": .vector([0, 1, 0, 0.5])],
            combos: [:],
            blending: "disabled",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )

        let output = try executor.render(
            pipeline: preparedPipeline(
                localFBOs: [],
                passes: [preparedBuiltinPass(pass, uniforms: ["g_Color": .vector([0, 1, 0, 0.5])])]
            ),
            size: CGSize(width: 4, height: 4),
            textures: [:]
        )
        let pixel = try readPixel(output, x: 2, y: 2)

        #expect(pixel.r <= 5)
        #expect(abs(Int(pixel.g) - 188) <= 4)
        #expect(pixel.b <= 5)
        #expect(abs(Int(pixel.a) - 128) <= 4)
    }

    @Test("compose tints layer composites into the scene")
    func composeTintsLayerCompositesIntoScene() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)

        let compositeA = "_rt_imageLayerComposite_layer_a"
        let solid = solidPass(
            id: "layer.0",
            color: [1, 1, 1, 1],
            target: .layerComposite(name: compositeA),
            blending: "disabled"
        )
        let compose = WPERenderPass(
            id: "layer.1",
            phase: .command(file: "effects/compose/effect.json"),
            shader: "materials/util/compose.json",
            source: .fbo(compositeA),
            target: .scene,
            textures: [0: .fbo(compositeA), 1: .fbo(compositeA)],
            binds: [:],
            constants: ["g_Color": .vector([0, 1, 0, 1])],
            combos: [:],
            blending: "disabled",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )

        let output = try executor.render(
            pipeline: preparedPipeline(
                localFBOs: [],
                passes: [
                    preparedBuiltinPass(solid, uniforms: ["g_Color": .vector([1, 1, 1, 1])]),
                    preparedBuiltinPass(
                        compose,
                        bindings: [0: .fbo(compositeA), 1: .fbo(compositeA)],
                        uniforms: ["g_Color": .vector([0, 1, 0, 1])]
                    )
                ]
            ),
            size: CGSize(width: 4, height: 4),
            textures: [:]
        )
        let pixel = try readPixel(output, x: 2, y: 2)

        #expect(pixel.r <= 5)
        #expect(pixel.g >= 250)
        #expect(pixel.b <= 5)
        #expect(pixel.a >= 250)
    }
}

// MARK: - Phase 2D-C effect tests

private func effectPass(
    id: String,
    shader: String,
    source: WPETextureReference,
    target: WPERenderTarget = .scene,
    constants: [String: WPESceneShaderConstantValue],
    blending: String = "disabled"
) -> WPERenderPass {
    WPERenderPass(
        id: id,
        phase: .effect(file: "\(shader)/effect.json"),
        shader: shader,
        source: source,
        target: target,
        textures: [0: source],
        binds: [:],
        constants: constants,
        combos: [:],
        blending: blending,
        cullMode: "nocull",
        depthTest: "disabled",
        depthWrite: "disabled"
    )
}

private func expectPixel(
    _ pixel: Pixel,
    approximately expected: Pixel,
    tolerance: Int = 4
) {
    #expect(abs(Int(pixel.r) - Int(expected.r)) <= tolerance)
    #expect(abs(Int(pixel.g) - Int(expected.g)) <= tolerance)
    #expect(abs(Int(pixel.b) - Int(expected.b)) <= tolerance)
    #expect(abs(Int(pixel.a) - Int(expected.a)) <= tolerance)
}

private extension WPEMetalRenderExecutorTests {
    @Test("Color balance built-in desaturates red to luminance")
    func colorBalanceDesaturatesRedToLuminance() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let input = try makeRGBAInputTexture(
            device: device,
            width: 1,
            height: 1,
            bytes: Data([255, 0, 0, 255])
        )

        let pass = effectPass(
            id: "effect.colorbalance",
            shader: "effects/colorbalance",
            source: .image("materials/red.png"),
            constants: [
                "u_Brightness": .number(0),
                "u_Contrast": .number(1),
                "u_Saturation": .number(0)
            ]
        )
        let pipeline = preparedPipeline(
            localFBOs: [],
            passes: [
                preparedBuiltinPass(
                    pass,
                    bindings: [0: .image("materials/red.png")],
                    uniforms: pass.constants
                )
            ]
        )

        let output = try executor.render(
            pipeline: pipeline,
            size: CGSize(width: 1, height: 1),
            textures: ["materials/red.png": input]
        )
        let pixel = try readPixel(output, x: 0, y: 0)

        // Linear luma for red is 0.2126; storing to rgba8Unorm_srgb reads back ~127.
        expectPixel(pixel, approximately: Pixel(r: 127, g: 127, b: 127, a: 255))
    }

    @Test("Blur built-in applies centered 9 tap kernel")
    func blurAppliesCenteredNineTapKernel() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)

        let input = try makeRGBAInputTexture(
            device: device,
            width: 9,
            height: 1,
            bytes: Data([
                0, 0, 0, 255,
                0, 0, 0, 255,
                0, 0, 0, 255,
                0, 0, 0, 255,
                255, 0, 0, 255,
                0, 0, 0, 255,
                0, 0, 0, 255,
                0, 0, 0, 255,
                0, 0, 0, 255
            ])
        )

        let pass = effectPass(
            id: "effect.blur",
            shader: "effects/blur",
            source: .image("materials/pulse.png"),
            constants: ["u_Radius": .number(1)]
        )
        let pipeline = preparedPipeline(
            localFBOs: [],
            passes: [
                preparedBuiltinPass(
                    pass,
                    bindings: [0: .image("materials/pulse.png")],
                    uniforms: pass.constants
                )
            ]
        )

        let output = try executor.render(
            pipeline: pipeline,
            size: CGSize(width: 9, height: 1),
            textures: ["materials/pulse.png": input]
        )
        let pixel = try readPixel(output, x: 4, y: 0)

        // Center weight 0.18; storing 0.18 linear red to sRGB reads back ~118.
        expectPixel(pixel, approximately: Pixel(r: 118, g: 0, b: 0, a: 255))
    }

    @Test("Vignette built-in darkens outside outer radius")
    func vignetteDarkensOutsideOuterRadius() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)

        let input = try makeRGBAInputTexture(
            device: device,
            width: 4,
            height: 4,
            bytes: Data(repeating: 255, count: 4 * 4 * 4)
        )

        let pass = effectPass(
            id: "effect.vignette",
            shader: "effects/vignette/vignette.json",
            source: .image("materials/white.png"),
            constants: [
                "u_InnerRadius": .number(0),
                "u_OuterRadius": .number(0.5),
                "u_Intensity": .number(1)
            ]
        )
        let pipeline = preparedPipeline(
            localFBOs: [],
            passes: [
                preparedBuiltinPass(
                    pass,
                    bindings: [0: .image("materials/white.png")],
                    uniforms: pass.constants
                )
            ]
        )

        let output = try executor.render(
            pipeline: pipeline,
            size: CGSize(width: 4, height: 4),
            textures: ["materials/white.png": input]
        )
        let pixel = try readPixel(output, x: 0, y: 0)

        expectPixel(pixel, approximately: Pixel(r: 0, g: 0, b: 0, a: 255))
    }

    @Test("Water built-in displaces UVs with time driven wave")
    func waterDisplacesUVsWithWave() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)

        let input = try makeRGBAInputTexture(
            device: device,
            width: 2,
            height: 2,
            bytes: Data([
                255, 0, 0, 255,
                255, 0, 0, 255,
                0, 0, 255, 255,
                0, 0, 255, 255
            ])
        )

        let pass = effectPass(
            id: "effect.water",
            shader: "effects/distort",
            source: .image("materials/two_rows.png"),
            constants: [
                "u_Amplitude": .number(1),
                "u_Frequency": .number(0),
                "u_Speed": .number(0)
            ]
        )
        let pipeline = preparedPipeline(
            localFBOs: [],
            passes: [
                preparedBuiltinPass(
                    pass,
                    bindings: [0: .image("materials/two_rows.png")],
                    uniforms: pass.constants
                )
            ]
        )

        let output = try executor.render(
            pipeline: pipeline,
            size: CGSize(width: 2, height: 2),
            textures: ["materials/two_rows.png": input],
            runtimeUniforms: WPEMetalRuntimeUniforms(
                time: 0,
                daytime: 0,
                brightness: 1,
                pointerPosition: SIMD2<Double>(0.5, 0.5)
            )
        )
        let pixel = try readPixel(output, x: 0, y: 0)

        // amplitude 1 + frequency 0 + speed 0 → wave = (sin(0), cos(0)) * 1 = (0, 1).
        // UV (0.25, 0.25) + (0, 1) clamps to (0.25, 1.0) → bottom row → blue.
        expectPixel(pixel, approximately: Pixel(r: 0, g: 0, b: 255, a: 255))
    }

    @Test("Shake built-in applies bounded deterministic UV offset")
    func shakeAppliesBoundedDeterministicUVOffset() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)

        let input = try makeRGBAInputTexture(
            device: device,
            width: 4,
            height: 1,
            bytes: Data([
                255, 0, 0, 255,
                0, 255, 0, 255,
                0, 0, 255, 255,
                255, 255, 255, 255
            ])
        )

        let pass = effectPass(
            id: "effect.shake",
            shader: "effects/shake/shake.json",
            source: .image("materials/stripe.png"),
            constants: [
                "u_Magnitude": .number(0.25),
                "u_Frequency": .number(1)
            ]
        )
        let pipeline = preparedPipeline(
            localFBOs: [],
            passes: [
                preparedBuiltinPass(
                    pass,
                    bindings: [0: .image("materials/stripe.png")],
                    uniforms: pass.constants
                )
            ]
        )

        let output = try executor.render(
            pipeline: pipeline,
            size: CGSize(width: 4, height: 1),
            textures: ["materials/stripe.png": input],
            runtimeUniforms: WPEMetalRuntimeUniforms(
                time: 0,
                daytime: 0,
                brightness: 1,
                pointerPosition: SIMD2<Double>(0.5, 0.5)
            )
        )
        let pixel = try readPixel(output, x: 1, y: 0)

        // At time 0, phase = floor(0*1) = 0; jitter = (cos(0), sin(0)) * 0.25 = (0.25, 0).
        // Pixel x=1 (uv ≈ 0.375) + 0.25 = 0.625 → samples source x ≈ 2 → blue.
        expectPixel(pixel, approximately: Pixel(r: 0, g: 0, b: 255, a: 255))
    }
}
