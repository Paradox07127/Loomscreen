import CoreGraphics
import Foundation
import LiveWallpaperProWPE
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

    @Test("Custom shader without recognizable main surfaces a precise translator error")
    func rejectsUntranslatableCustomShader() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let pass = WPERenderPass(
            id: "1.0",
            phase: .effect(file: "effects/broken/effect.json"),
            shader: "effects/broken",
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
                    shader: WPEShaderProgram(
                        name: "effects/broken",
                        vertexSource: "// no main",
                        fragmentSource: "uniform sampler2D g_Texture0;\n// missing main",
                        isBuiltin: false
                    ),
                    textureBindings: [:],
                    comboValues: [:],
                    uniformValues: [:]
                )]
            )
        ])

        do {
            _ = try executor.render(pipeline: pipeline, size: CGSize(width: 4, height: 4), textures: [:])
            #expect(Bool(false), "Untranslatable shader render should throw")
        } catch let error as WPEMetalRenderExecutorError {
            switch error {
            case .shaderTranslatorUnavailable(let name, let reason):
                #expect(name == "effects/broken")
                #expect(reason.contains("main"))
            default:
                #expect(Bool(false), "Expected .shaderTranslatorUnavailable, got \(error)")
            }
        }
    }

    @Test("Custom shader with valid GLSL is now translated and renders end-to-end")
    func translatesAndRendersCustomShader() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let input = try makeRGBAInputTexture(device: device, bytes: Data([
            0, 0, 255, 255,
            0, 0, 255, 255,
            0, 0, 255, 255,
            0, 0, 255, 255
        ]))
        let pass = WPERenderPass(
            id: "1.0",
            phase: .effect(file: "effects/multiply_red/effect.json"),
            shader: "effects/multiply_red",
            source: .image("materials/base.png"),
            target: .scene,
            textures: [0: .image("materials/base.png")],
            binds: [:],
            constants: [:],
            combos: [:],
            blending: "disabled",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )
        let pipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(
                graphLayer: graphLayer(pass: pass),
                passes: [WPEPreparedRenderPass(
                    pass: pass,
                    shader: WPEShaderProgram(
                        name: "effects/multiply_red",
                        vertexSource: "// fullscreen quad: executor supplies the vertex stage",
                        fragmentSource: """
                        uniform sampler2D g_Texture0;
                        varying vec2 v_TexCoord;
                        void main() {
                            vec4 c = texture(g_Texture0, v_TexCoord);
                            gl_FragColor = vec4(c.r + 1.0, c.g, c.b, c.a);
                        }
                        """,
                        isBuiltin: false
                    ),
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

        #expect(pixel.r >= 250)
        #expect(pixel.b >= 250)
        #expect(pixel.a >= 250)
    }

    @Test("Project effect shader source overrides native effect approximation")
    func projectEffectShaderSourceOverridesNativeApproximation() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let input = try makeRGBAInputTexture(device: device, bytes: Data([
            0, 0, 255, 255,
            0, 0, 255, 255,
            0, 0, 255, 255,
            0, 0, 255, 255
        ]))
        let pass = WPERenderPass(
            id: "waterwaves.0",
            phase: .effect(file: "effects/waterwaves/effect.json"),
            shader: "effects/waterwaves",
            source: .image("materials/base.png"),
            target: .scene,
            textures: [0: .image("materials/base.png")],
            binds: [:],
            constants: [:],
            combos: [:],
            blending: "disabled",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )
        let pipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(
                graphLayer: graphLayer(pass: pass),
                passes: [WPEPreparedRenderPass(
                    pass: pass,
                    shader: WPEShaderProgram(
                        name: "effects/waterwaves",
                        vertexSource: "// fullscreen vertex from executor",
                        fragmentSource: """
                        uniform sampler2D g_Texture0;
                        varying vec2 v_TexCoord;
                        void main() {
                            gl_FragColor = vec4(1.0, 0.0, 0.0, 1.0);
                        }
                        """,
                        isBuiltin: false
                    ),
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

        #expect(pixel.r >= 250)
        #expect(pixel.g <= 5)
        #expect(pixel.b <= 5)
        #expect(pixel.a >= 250)
    }

    @Test("Translated waterwaves squares authored strength before sampling")
    func translatedWaterwavesSquaresAuthoredStrengthBeforeSampling() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        var bytes = [UInt8](repeating: 0, count: 100 * 4)
        for x in 53...56 {
            let index = x * 4
            bytes[index] = 255
            bytes[index + 3] = 255
        }
        for x in 69...72 {
            let index = x * 4
            bytes[index + 1] = 255
            bytes[index + 3] = 255
        }
        let input = try makeRGBAInputTexture(
            device: device,
            width: 100,
            height: 1,
            bytes: Data(bytes)
        )
        let mask = try makeRGBAInputTexture(
            device: device,
            width: 1,
            height: 1,
            bytes: Data([255, 255, 255, 255])
        )
        let pass = WPERenderPass(
            id: "waterwaves.0",
            phase: .effect(file: "effects/waterwaves/effect.json"),
            shader: "effects/waterwaves",
            source: .image("materials/base.png"),
            target: .scene,
            textures: [
                0: .image("materials/base.png"),
                1: .image("materials/mask.png")
            ],
            binds: [:],
            constants: [:],
            combos: [:],
            blending: "disabled",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )
        let pipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(
                graphLayer: graphLayer(pass: pass),
                passes: [
                    WPEPreparedRenderPass(
                        pass: pass,
                        shader: WPEShaderProgram(
                            name: "effects/waterwaves",
                            vertexSource: """
                            uniform vec4 g_Texture1Resolution;
                            uniform float g_Direction;
                            varying vec4 v_TexCoord;
                            varying vec2 v_Direction;
                            """,
                            fragmentSource: """
                            uniform sampler2D g_Texture0;
                            uniform sampler2D g_Texture1;
                            uniform float g_Time;
                            uniform float g_Speed;
                            uniform float g_Scale;
                            uniform float g_Exponent;
                            uniform float g_Strength;
                            varying vec4 v_TexCoord;
                            varying vec2 v_Direction;
                            void main() {
                                float mask = texture(g_Texture1, v_TexCoord.zw).r;
                                vec2 texCoord = v_TexCoord.xy;
                                float distance = g_Time * g_Speed + dot(texCoord, v_Direction) * g_Scale;
                                float strength = g_Strength * g_Strength;
                                vec2 offset = vec2(v_Direction.y, -v_Direction.x);
                                float val1 = sin(distance);
                                float s1 = sign(val1);
                                val1 = pow(abs(val1), g_Exponent);
                                texCoord += val1 * s1 * offset * strength * mask;
                                gl_FragColor = texture(g_Texture0, texCoord);
                            }
                            """,
                            isBuiltin: false
                        ),
                        textureBindings: [
                            0: .image("materials/base.png"),
                            1: .image("materials/mask.png")
                        ],
                        comboValues: [:],
                        uniformValues: [
                            "g_Speed": .number(1),
                            "g_Scale": .number(0),
                            "g_Exponent": .number(1),
                            "g_Strength": .number(0.2),
                            "g_Direction": .number(0)
                        ]
                    )
                ]
            )
        ])

        let output = try executor.render(
            pipeline: pipeline,
            size: CGSize(width: 100, height: 1),
            textures: [
                "materials/base.png": input,
                "materials/mask.png": mask
            ],
            runtimeUniforms: WPEMetalRuntimeUniforms(
                time: Double.pi / 2,
                daytime: 0,
                brightness: 1,
                pointerPosition: SIMD2<Double>(0.5, 0.5)
            )
        )
        let pixel = try readPixel(output, x: 50, y: 0)

        #expect(pixel.r >= 200)
        #expect(pixel.g <= 40)
    }

    @Test("Translated texture resolution uses texture-local dimensions")
    func translatedTextureResolutionUsesTextureLocalDimensions() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let mask = try makeRGBAInputTexture(
            device: device,
            width: 8,
            height: 4,
            bytes: Data(repeating: 255, count: 8 * 4 * 4)
        )
        let destination = try makeRGBAInputTexture(
            device: device,
            width: 16,
            height: 16,
            bytes: Data(repeating: 0, count: 16 * 16 * 4)
        )
        let pass = WPERenderPass(
            id: "resolution.0",
            phase: .effect(file: "effects/resolution/effect.json"),
            shader: "effects/resolution",
            source: .image("materials/base.png"),
            target: .scene,
            textures: [:],
            binds: [:],
            constants: [:],
            combos: [:],
            blending: "disabled",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )
        let prepared = WPEPreparedRenderPass(
            pass: pass,
            shader: nil,
            textureBindings: [:],
            comboValues: [:],
            uniformValues: [:]
        )
        let slots = executor.packTranslatedUniforms(
            for: prepared,
            layout: [
                WPEUniformSlot(
                    name: "g_Texture1Resolution",
                    glslType: "vec4",
                    slot: 0,
                    slotCount: 1
                )
            ],
            texturesBySlot: [1: mask],
            destinationTexture: destination
        )

        #expect(slots[0] == SIMD4<Float>(8, 4, 8, 4))
    }

    @Test("Translated texture resolution preserves TEX logical image size")
    func translatedTextureResolutionPreservesTexLogicalImageSize() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let loader = WPEMetalTextureLoader(device: device)
        let executor = try WPEMetalRenderExecutor(device: device)
        let payload = WPETexTexturePayload(
            info: WPETexInfo(
                containerVersion: 5,
                infoVersion: 1,
                width: 8,
                height: 4,
                textureFormatCode: WPETexFormat.rgba8888.rawValue,
                format: .rgba8888,
                mipmapCount: 1,
                flags: 0,
                imageWidth: 7,
                imageHeight: 3
            ),
            mipmaps: [
                WPETexTextureMipmap(
                    index: 0,
                    width: 8,
                    height: 4,
                    bytes: Data(repeating: 255, count: 8 * 4 * 4)
                )
            ],
            hasAnimationFrames: false
        )
        let texture = try await loader.makeTexture(from: payload, label: "padded test tex")
        let pass = WPERenderPass(
            id: "resolution.0",
            phase: .effect(file: "effects/resolution/effect.json"),
            shader: "effects/resolution",
            source: .image("materials/base.png"),
            target: .scene,
            textures: [:],
            binds: [:],
            constants: [:],
            combos: [:],
            blending: "disabled",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )
        let prepared = WPEPreparedRenderPass(
            pass: pass,
            shader: nil,
            textureBindings: [:],
            comboValues: [:],
            uniformValues: [:]
        )
        let slots = executor.packTranslatedUniforms(
            for: prepared,
            layout: [
                WPEUniformSlot(
                    name: "g_Texture0Resolution",
                    glslType: "vec4",
                    slot: 0,
                    slotCount: 1
                )
            ],
            texturesBySlot: [0: texture]
        )

        #expect(slots[0] == SIMD4<Float>(8, 4, 7, 3))
    }

    @Test("Scalar float[N] audio array packs one bin per slot in .x (both pack overloads)")
    func audioSpectrumArrayPacksOneBinPerSlot() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        // Distinct, recognizable per-bin values so a 4-per-slot mispack (the old
        // `values:` overload bug) or a stride under-read would be obvious.
        let bins = (0..<64).map { Double($0) + 1 }
        let layout = [
            WPEUniformSlot(name: "g_AudioSpectrum64Left", glslType: "float", slot: 0, slotCount: 64, arrayLength: 64)
        ]

        // `values:` overload (MSDF text path) — previously packed every array as vec4[N].
        let slotsValues = executor.packTranslatedUniforms(
            values: ["g_AudioSpectrum64Left": .vector(bins)],
            layout: layout
        )
        for i in 0..<64 {
            #expect(slotsValues[i].x == Float(bins[i]))
            #expect(slotsValues[i].y == 0 && slotsValues[i].z == 0 && slotsValues[i].w == 0)
        }

        // Per-pass overload (live scene path) must agree bin-for-bin.
        let pass = WPEPreparedRenderPass(
            pass: WPERenderPass(
                id: "audio.0",
                phase: .effect(file: "effects/workshop/audio/effect.json"),
                shader: "workshop/audio/bars",
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
            ),
            shader: nil,
            textureBindings: [:],
            comboValues: [:],
            uniformValues: ["g_AudioSpectrum64Left": .vector(bins)]
        )
        let slotsPass = executor.packTranslatedUniforms(for: pass, layout: layout)
        for i in 0..<64 {
            #expect(slotsPass[i].x == Float(bins[i]))
        }
    }

    @Test("vec2[N] array packs two components per slot (.xy), tightly strided")
    func vec2ArrayPacksTwoComponentsPerSlot() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        // 4 elements × 2 components = 8 flat values.
        let flat = (0..<8).map { Double($0) + 1 } // 1,2 | 3,4 | 5,6 | 7,8
        let layout = [
            WPEUniformSlot(name: "u_Points", glslType: "vec2", slot: 0, slotCount: 4, arrayLength: 4)
        ]
        let slots = executor.packTranslatedUniforms(
            values: ["u_Points": .vector(flat)],
            layout: layout
        )
        for i in 0..<4 {
            #expect(slots[i].x == Float(flat[i * 2]))
            #expect(slots[i].y == Float(flat[i * 2 + 1]))
            #expect(slots[i].z == 0 && slots[i].w == 0)
        }
    }

    @Test("Scene-capture utility output geometry: only a small axis-aligned composelayer is subregion")
    func sceneCaptureUtilityOutputGeometryClassifier() throws {
        let scene = CGSize(width: 3840, height: 2160)
        func geo(
            size: CGSize?,
            scale: SIMD3<Double> = SIMD3<Double>(1, 1, 1),
            angles: SIMD3<Double> = SIMD3<Double>(0, 0, 0)
        ) -> WPERenderLayerGeometry {
            WPERenderLayerGeometry(
                origin: SIMD3<Double>(-772.6, 494.6, 0),
                scale: scale,
                angles: angles,
                alignment: .center,
                size: size,
                alpha: 1,
                color: SIMD3<Double>(1, 1, 1),
                brightness: 1
            )
        }
        typealias Models = WPEMetalSceneCaptureUtilityModels

        // The audio-bar box (scene 3460973721): 2560×1440 × 0.5 = 1280×720, axis-aligned.
        #expect(Models.outputGeometry(
            path: "models/util/composelayer.json",
            geometry: geo(size: CGSize(width: 2560, height: 1440), scale: SIMD3<Double>(0.5, 0.5, 0.5)),
            sceneSize: scene
        ) == .subregion)
        // ../<dependencyID>/ resolver prefix is tolerated.
        #expect(Models.outputGeometry(
            path: "../3021673417/models/util/composelayer.json",
            geometry: geo(size: CGSize(width: 2560, height: 1440), scale: SIMD3<Double>(0.5, 0.5, 0.5)),
            sceneSize: scene
        ) == .subregion)

        // fullscreenlayer (DoF) and projectlayer (projection) always fullscreen.
        #expect(Models.outputGeometry(path: "models/util/fullscreenlayer.json",
            geometry: geo(size: CGSize(width: 1280, height: 720)), sceneSize: scene) == .fullscreen)
        #expect(Models.outputGeometry(path: "models/util/projectlayer.json",
            geometry: geo(size: CGSize(width: 1280, height: 720)), sceneSize: scene) == .fullscreen)

        // Scene 3479521040 regression guards: rotated and oversized compose stay fullscreen.
        #expect(Models.outputGeometry(path: "models/util/composelayer.json",
            geometry: geo(size: CGSize(width: 1280, height: 720), angles: SIMD3<Double>(0, 0, 0.4)),
            sceneSize: scene) == .fullscreen)
        #expect(Models.outputGeometry(path: "models/util/composelayer.json",
            geometry: geo(size: CGSize(width: 5000, height: 2300)), sceneSize: scene) == .fullscreen)
        // Mirrored (negative scale) and missing size also stay fullscreen.
        #expect(Models.outputGeometry(path: "models/util/composelayer.json",
            geometry: geo(size: CGSize(width: 1280, height: 720), scale: SIMD3<Double>(-1, 1, 1)),
            sceneSize: scene) == .fullscreen)
        #expect(Models.outputGeometry(path: "models/util/composelayer.json",
            geometry: geo(size: nil), sceneSize: scene) == .fullscreen)
    }

    @Test("Subregion composelayer object quad uses the normal placed-layer anchor")
    func subregionComposeObjectQuadUsesNormalAnchor() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let source = try makeRGBAInputTexture(device: device, bytes: Data(repeating: 255, count: 4))
        // Render-time origin is already in the renderer's TOP-LEFT pixel convention
        // (parser/builder resolved it — confirmed on-device: scene 3460973721 logs
        // origin (1089.35, 1861.99), not the raw scene.json center-origin). The box
        // must use the same `origin - sceneSize/2` anchor as a normal placed layer;
        // an earlier center-origin special-case shoved it off-screen and blanked the
        // audio bars.
        let geometry = WPERenderLayerGeometry(
            origin: SIMD3<Double>(1089.35, 1861.99, 0),
            scale: SIMD3<Double>(1, 1, 1),
            angles: SIMD3<Double>(0, 0, 0),
            alignment: .center,
            size: CGSize(width: 2560, height: 1440),
            alpha: 1,
            color: SIMD3<Double>(1, 1, 1),
            brightness: 1
        )
        let layer = WPERenderLayer(
            objectID: "audio",
            objectName: "音频响应",
            imagePath: "models/util/composelayer.json",
            materialPath: "materials/util/composelayer.json",
            geometry: geometry,
            compositeA: "a",
            compositeB: "b",
            localFBOs: [],
            passes: []
        )
        let quad = executor.objectQuadUniforms(
            for: layer,
            sceneSize: CGSize(width: 3840, height: 2160),
            sourceTexture: source
        )
        // Normal anchor: center = origin - sceneSize/2; size = footprint × scale.
        #expect(abs(quad.centerAndSize.x - (1089.35 - 1920)) < 0.01) // -830.65
        #expect(abs(quad.centerAndSize.y - (1861.99 - 1080)) < 0.01) // 781.99
        #expect(abs(quad.centerAndSize.z - 2560) < 0.01)
        #expect(abs(quad.centerAndSize.w - 1440) < 0.01)
        // Center stays on-screen (the off-screen bug produced centerNDC.y = 1.72).
        let ndcX = quad.centerAndSize.x / (3840 / 2)
        let ndcY = quad.centerAndSize.y / (2160 / 2)
        #expect(ndcX > -1 && ndcX < 0) // -0.43, left of center
        #expect(ndcY > 0 && ndcY < 1)  // +0.72, upper, on-screen
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

    @Test("Multi-pass custom shader reads previous-pass FBO via pass.binds")
    func multiPassEffectChainsFBOsViaBinds() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let input = try makeRGBAInputTexture(device: device, bytes: Data([
            10, 10, 10, 255,
            10, 10, 10, 255,
            10, 10, 10, 255,
            10, 10, 10, 255
        ]))

        let pass0 = WPERenderPass(
            id: "pass0",
            phase: .effect(file: "effects/two_pass/effect.json"),
            shader: "effects/two_pass_first",
            source: .image("materials/base.png"),
            target: .fbo(name: "_rt_two_pass_intermediate"),
            textures: [0: .image("materials/base.png")],
            binds: [:],
            constants: [:],
            combos: [:],
            blending: "disabled",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )
        let pass1 = WPERenderPass(
            id: "pass1",
            phase: .effect(file: "effects/two_pass/effect.json"),
            shader: "effects/two_pass_second",
            source: .image("materials/base.png"),
            target: .scene,
            textures: [:],
            binds: [0: .fbo("_rt_two_pass_intermediate")],
            constants: [:],
            combos: [:],
            blending: "disabled",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )

        let pipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(
                graphLayer: WPERenderLayer(
                    objectID: "layer",
                    objectName: "Layer",
                    imagePath: "materials/base.png",
                    materialPath: nil,
                    geometry: .identity,
                    compositeA: "a",
                    compositeB: "b",
                    localFBOs: [WPERenderFBO(name: "_rt_two_pass_intermediate", scale: 1, format: "rgba8888", unique: false)],
                    passes: []
                ),
                passes: [
                    WPEPreparedRenderPass(
                        pass: pass0,
                        shader: WPEShaderProgram(
                            name: "effects/two_pass_first",
                            vertexSource: "// fullscreen vertex from executor",
                            fragmentSource: """
                            uniform sampler2D g_Texture0;
                            varying vec2 v_TexCoord;
                            void main() {
                                vec4 c = texture(g_Texture0, v_TexCoord);
                                gl_FragColor = vec4(c.r * 25.0, c.g, c.b, c.a);
                            }
                            """,
                            isBuiltin: false
                        ),
                        textureBindings: [0: .image("materials/base.png")],
                        comboValues: [:],
                        uniformValues: [:]
                    ),
                    WPEPreparedRenderPass(
                        pass: pass1,
                        shader: WPEShaderProgram(
                            name: "effects/two_pass_second",
                            vertexSource: "// fullscreen vertex",
                            fragmentSource: """
                            uniform sampler2D g_Texture0;
                            varying vec2 v_TexCoord;
                            void main() {
                                vec4 c = texture(g_Texture0, v_TexCoord);
                                gl_FragColor = vec4(c.r, c.g + 1.0, c.b, c.a);
                            }
                            """,
                            isBuiltin: false
                        ),
                        textureBindings: [:],
                        comboValues: [:],
                        uniformValues: [:]
                    )
                ]
            )
        ])

        let output = try executor.render(
            pipeline: pipeline,
            size: CGSize(width: 2, height: 2),
            textures: ["materials/base.png": input]
        )
        let pixel = try readPixel(output, x: 1, y: 1)

        #expect(pixel.r >= 200, "Multi-pass output should carry pass-0's amplified R; got \(pixel.r)")
        #expect(pixel.g >= 200, "Pass-1 should contribute saturated green; got \(pixel.g)")
        #expect(pixel.a >= 250)
    }

    @Test("genericimage2 native MSL fragment renders texture with color tint")
    func genericImage2RendersWithTint() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let input = try makeRGBAInputTexture(device: device, bytes: Data([
            255, 255, 255, 255,
            255, 255, 255, 255,
            255, 255, 255, 255,
            255, 255, 255, 255
        ]))
        let pass = WPERenderPass(
            id: "img2.0",
            phase: .material,
            shader: "genericimage2",
            source: .image("materials/base.png"),
            target: .scene,
            textures: [0: .image("materials/base.png")],
            binds: [:],
            constants: ["g_Color": .vector([1, 0, 0, 1])],
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
                    shader: WPEShaderProgram(name: "genericimage2", vertexSource: "", fragmentSource: "", isBuiltin: true),
                    textureBindings: [:],
                    comboValues: [:],
                    uniformValues: ["g_Color": .vector([1, 0, 0, 1])]
                )]
            )
        ])

        let output = try executor.render(
            pipeline: pipeline,
            size: CGSize(width: 2, height: 2),
            textures: ["materials/base.png": input]
        )
        let pixel = try readPixel(output, x: 1, y: 1)

        #expect(pixel.r >= 250)
        #expect(pixel.g <= 5)
        #expect(pixel.b <= 5)
        #expect(pixel.a >= 250)
    }

    @Test("Material image pass renders with object quad geometry instead of fullscreen")
    func materialImagePassUsesObjectQuadGeometry() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let input = try makeRGBAInputTexture(
            device: device,
            width: 4,
            height: 4,
            bytes: Data(repeating: 255, count: 4 * 4 * 4)
        )
        let pass = WPERenderPass(
            id: "img2.0",
            phase: .material,
            shader: "genericimage2",
            source: .image("materials/base.png"),
            target: .scene,
            textures: [0: .image("materials/base.png")],
            binds: [:],
            constants: [:],
            combos: [:],
            blending: "disabled",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )
        let geometry = WPERenderLayerGeometry(
            origin: SIMD3<Double>(8, 8, 0),
            scale: SIMD3<Double>(1, 1, 1),
            angles: SIMD3<Double>(0, 0, 0),
            alignment: .center,
            size: CGSize(width: 8, height: 8),
            alpha: 1,
            color: SIMD3<Double>(1, 1, 1),
            brightness: 1
        )
        let pipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(
                graphLayer: graphLayer(pass: pass, geometry: geometry),
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
            size: CGSize(width: 16, height: 16),
            textures: ["materials/base.png": input]
        )
        let bounds = try #require(nonBlackBounds(output))

        #expect(bounds == PixelBounds(minX: 4, minY: 4, maxX: 11, maxY: 11))
    }

    @Test("Puppet material pass renders all meshes into local composite instead of fullscreen atlas")
    func puppetMaterialPassRendersMeshesIntoLocalComposite() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let input = try makeRGBAInputTexture(
            device: device,
            width: 4,
            height: 4,
            bytes: Data(repeating: 255, count: 4 * 4 * 4)
        )
        let materialPass = WPERenderPass(
            id: "puppet.0",
            phase: .material,
            shader: "genericimage2",
            source: .image("materials/base.png"),
            target: .layerComposite(name: "_rt_imageLayerComposite_puppet_a"),
            textures: [0: .image("materials/base.png")],
            binds: [:],
            constants: [:],
            combos: [:],
            blending: "disabled",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )
        let scenePass = WPERenderPass(
            id: "puppet.1",
            phase: .command(file: "materials/util/copy.json"),
            shader: "materials/util/copy.json",
            source: .fbo("_rt_imageLayerComposite_puppet_a"),
            target: .scene,
            textures: [0: .fbo("_rt_imageLayerComposite_puppet_a")],
            binds: [:],
            constants: [:],
            combos: [:],
            blending: "disabled",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )
        let geometry = WPERenderLayerGeometry(
            origin: SIMD3<Double>(8, 8, 0),
            scale: SIMD3<Double>(1, 1, 1),
            angles: SIMD3<Double>(0, 0, 0),
            alignment: .center,
            size: CGSize(width: 8, height: 8),
            alpha: 1,
            color: SIMD3<Double>(1, 1, 1),
            brightness: 1
        )
        let puppet = WPEPuppetModel(version: 23, meshes: [
            WPEPuppetMesh(
                materialPath: "materials/base.png",
                vertices: [
                    WPEPuppetVertex(position: SIMD3<Float>(-4, -4, 0), uv: SIMD2<Float>(0, 1)),
                    WPEPuppetVertex(position: SIMD3<Float>(0, -4, 0), uv: SIMD2<Float>(1, 1)),
                    WPEPuppetVertex(position: SIMD3<Float>(-4, 4, 0), uv: SIMD2<Float>(0, 0)),
                    WPEPuppetVertex(position: SIMD3<Float>(0, 4, 0), uv: SIMD2<Float>(1, 0))
                ],
                indices: [0, 1, 2, 2, 1, 3],
                parts: []
            ),
            WPEPuppetMesh(
                materialPath: "materials/base.png",
                vertices: [
                    WPEPuppetVertex(position: SIMD3<Float>(0, -4, 0), uv: SIMD2<Float>(0, 1)),
                    WPEPuppetVertex(position: SIMD3<Float>(4, -4, 0), uv: SIMD2<Float>(1, 1)),
                    WPEPuppetVertex(position: SIMD3<Float>(0, 4, 0), uv: SIMD2<Float>(0, 0)),
                    WPEPuppetVertex(position: SIMD3<Float>(4, 4, 0), uv: SIMD2<Float>(1, 0))
                ],
                indices: [0, 1, 2, 2, 1, 3],
                parts: []
            )
        ])
        let layer = WPERenderLayer(
            objectID: "puppet",
            objectName: "Puppet",
            imagePath: "models/puppet.json",
            materialPath: "materials/base.json",
            puppetPath: "models/puppet.mdl",
            geometry: geometry,
            compositeA: "_rt_imageLayerComposite_puppet_a",
            compositeB: "_rt_imageLayerComposite_puppet_b",
            localFBOs: [],
            passes: [materialPass, scenePass]
        )
        let pipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(
                graphLayer: layer,
                puppetModel: puppet,
                passes: [
                    WPEPreparedRenderPass(
                        pass: materialPass,
                        shader: WPEShaderProgram(name: "genericimage2", vertexSource: "", fragmentSource: "", isBuiltin: true),
                        textureBindings: [0: .image("materials/base.png")],
                        comboValues: [:],
                        uniformValues: [:]
                    ),
                    WPEPreparedRenderPass(
                        pass: scenePass,
                        shader: WPEShaderProgram(name: "copy", vertexSource: "", fragmentSource: "", isBuiltin: true),
                        textureBindings: [0: .fbo("_rt_imageLayerComposite_puppet_a")],
                        comboValues: [:],
                        uniformValues: [:]
                    )
                ]
            )
        ])

        let output = try executor.render(
            pipeline: pipeline,
            size: CGSize(width: 16, height: 16),
            textures: ["materials/base.png": input]
        )
        let bounds = try #require(nonBlackBounds(output))

        #expect(bounds == PixelBounds(minX: 4, minY: 4, maxX: 11, maxY: 11))
    }

    @Test("Object quad geometry treats 0...1 origins as normalized scene coordinates")
    func objectQuadGeometryNormalizesUnitOrigins() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let input = try makeRGBAInputTexture(
            device: device,
            width: 4,
            height: 4,
            bytes: Data(repeating: 255, count: 4 * 4 * 4)
        )
        let pass = WPERenderPass(
            id: "img2.0",
            phase: .material,
            shader: "genericimage2",
            source: .image("materials/base.png"),
            target: .scene,
            textures: [0: .image("materials/base.png")],
            binds: [:],
            constants: [:],
            combos: [:],
            blending: "disabled",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )
        let geometry = WPERenderLayerGeometry(
            origin: SIMD3<Double>(0.5, 0.5, 0),
            scale: SIMD3<Double>(1, 1, 1),
            angles: SIMD3<Double>(0, 0, 0),
            alignment: .center,
            size: CGSize(width: 8, height: 8),
            alpha: 1,
            color: SIMD3<Double>(1, 1, 1),
            brightness: 1
        )
        let pipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(
                graphLayer: graphLayer(pass: pass, geometry: geometry),
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
            size: CGSize(width: 16, height: 16),
            textures: ["materials/base.png": input]
        )
        let bounds = try #require(nonBlackBounds(output))

        #expect(bounds == PixelBounds(minX: 4, minY: 4, maxX: 11, maxY: 11))
    }

    @Test("Object quad geometry preserves negative scale as texture mirroring")
    func objectQuadGeometryMirrorsTextureForNegativeScale() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let input = try makeRGBAInputTexture(
            device: device,
            width: 4,
            height: 1,
            bytes: Data([
                255, 0, 0, 255,
                255, 0, 0, 255,
                0, 255, 0, 255,
                0, 255, 0, 255
            ])
        )
        let pass = WPERenderPass(
            id: "img2.0",
            phase: .material,
            shader: "genericimage2",
            source: .image("materials/base.png"),
            target: .scene,
            textures: [0: .image("materials/base.png")],
            binds: [:],
            constants: [:],
            combos: [:],
            blending: "disabled",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )
        let geometry = WPERenderLayerGeometry(
            origin: SIMD3<Double>(8, 4, 0),
            scale: SIMD3<Double>(-1, 1, 1),
            angles: SIMD3<Double>(0, 0, 0),
            alignment: .center,
            size: CGSize(width: 8, height: 4),
            alpha: 1,
            color: SIMD3<Double>(1, 1, 1),
            brightness: 1
        )
        let pipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(
                graphLayer: graphLayer(pass: pass, geometry: geometry),
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
            size: CGSize(width: 16, height: 8),
            textures: ["materials/base.png": input]
        )
        let leftPixel = try readPixel(output, x: 5, y: 4)
        let rightPixel = try readPixel(output, x: 10, y: 4)

        #expect(leftPixel.g > leftPixel.r + 80)
        #expect(rightPixel.r > rightPixel.g + 80)
    }

    @Test("Solidcolor material pass renders with object quad geometry instead of fullscreen")
    func solidColorMaterialPassUsesObjectQuadGeometry() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let pass = WPERenderPass(
            id: "solid.0",
            phase: .material,
            shader: "solidcolor",
            source: .previous,
            target: .scene,
            textures: [:],
            binds: [:],
            constants: ["g_Color": .vector([1, 0, 0, 1])],
            combos: [:],
            blending: "disabled",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )
        let geometry = WPERenderLayerGeometry(
            origin: SIMD3<Double>(8, 2, 0),
            scale: SIMD3<Double>(1, 1, 1),
            angles: SIMD3<Double>(0, 0, 0),
            alignment: .center,
            size: CGSize(width: 16, height: 4),
            alpha: 1,
            color: SIMD3<Double>(1, 1, 1),
            brightness: 1
        )
        let pipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(
                graphLayer: graphLayer(pass: pass, geometry: geometry),
                passes: [WPEPreparedRenderPass(
                    pass: pass,
                    shader: WPEShaderProgram(name: "solidcolor", vertexSource: "", fragmentSource: "", isBuiltin: true),
                    textureBindings: [:],
                    comboValues: [:],
                    uniformValues: ["g_Color": .vector([1, 0, 0, 1])]
                )]
            )
        ])

        let output = try executor.render(pipeline: pipeline, size: CGSize(width: 16, height: 16), textures: [:])
        let bounds = try #require(nonBlackBounds(output))

        #expect(bounds == PixelBounds(minX: 0, minY: 12, maxX: 15, maxY: 15))
    }

    @Test("Effect composite from object-sized solid layer preserves transparent FBO areas")
    func solidLayerEffectCompositePreservesTransparentFBOAreas() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let background = solidPass(
            id: "background.0",
            color: [0, 0, 1, 1],
            target: .scene,
            blending: "disabled"
        )
        let compositeName = "_rt_solid_composite"
        let solid = solidPass(
            id: "solid.0",
            color: [1, 1, 1, 1],
            target: .layerComposite(name: compositeName),
            blending: "disabled"
        )
        let tint = WPERenderPass(
            id: "solid.1",
            phase: .effect(file: "effects/tint/effect.json"),
            shader: "effects/tint",
            source: .fbo(compositeName),
            target: .scene,
            textures: [0: .fbo(compositeName)],
            binds: [:],
            constants: ["g_Color": .vector([0, 0, 0, 1])],
            combos: [:],
            blending: "normal",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )
        let solidGeometry = WPERenderLayerGeometry(
            origin: SIMD3<Double>(8, 2, 0),
            scale: SIMD3<Double>(1, 1, 1),
            angles: SIMD3<Double>(0, 0, 0),
            alignment: .center,
            size: CGSize(width: 16, height: 4),
            alpha: 1,
            color: SIMD3<Double>(1, 1, 1),
            brightness: 1
        )
        let pipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(
                graphLayer: graphLayer(pass: background),
                passes: [preparedBuiltinPass(background, uniforms: ["g_Color": .vector([0, 0, 1, 1])])]
            ),
            WPEPreparedRenderLayer(
                graphLayer: graphLayer(pass: solid, geometry: solidGeometry),
                passes: [
                    preparedBuiltinPass(solid, uniforms: ["g_Color": .vector([1, 1, 1, 1])]),
                    preparedBuiltinPass(
                        tint,
                        bindings: [0: .fbo(compositeName)],
                        uniforms: ["g_Color": .vector([0, 0, 0, 1])]
                    )
                ]
            )
        ])

        let output = try executor.render(pipeline: pipeline, size: CGSize(width: 16, height: 16), textures: [:])
        let outsideSolid = try readPixel(output, x: 8, y: 8)
        let insideSolid = try readPixel(output, x: 8, y: 14)

        #expect(outsideSolid.r <= 5)
        #expect(outsideSolid.g <= 5)
        #expect(outsideSolid.b >= 250)
        #expect(outsideSolid.a >= 250)
        #expect(insideSolid.r <= 5)
        #expect(insideSolid.g <= 5)
        #expect(insideSolid.b <= 5)
        #expect(insideSolid.a >= 250)
    }

    @Test("Layer composite effects run in layer-local texture space before object compositing")
    func layerCompositeEffectUsesLayerLocalTextureSpace() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)

        let compositeName = "_rt_imageLayerComposite_layer_a"
        let seedComposite = solidPass(
            id: "layer.0",
            color: [1, 1, 1, 1],
            target: .layerComposite(name: compositeName),
            blending: "disabled"
        )
        let localSpaceProbe = WPERenderPass(
            id: "layer.1",
            phase: .effect(file: "effects/local_space_probe/effect.json"),
            shader: "effects/local_space_probe",
            source: .fbo(compositeName),
            target: .scene,
            textures: [0: .fbo(compositeName)],
            binds: [:],
            constants: [:],
            combos: [:],
            blending: "disabled",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )
        let geometry = WPERenderLayerGeometry(
            origin: SIMD3<Double>(8, 8, 0),
            scale: SIMD3<Double>(1, 1, 1),
            angles: SIMD3<Double>(0, 0, 0),
            alignment: .center,
            size: CGSize(width: 4, height: 4),
            alpha: 1,
            color: SIMD3<Double>(1, 1, 1),
            brightness: 1
        )
        let graphLayer = WPERenderLayer(
            objectID: "layer",
            objectName: "Layer",
            imagePath: "materials/base.png",
            materialPath: nil,
            geometry: geometry,
            compositeA: compositeName,
            compositeB: "_rt_imageLayerComposite_layer_b",
            localFBOs: [],
            passes: [seedComposite, localSpaceProbe]
        )
        let pipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(
                graphLayer: graphLayer,
                passes: [
                    preparedBuiltinPass(seedComposite, uniforms: ["g_Color": .vector([1, 1, 1, 1])]),
                    WPEPreparedRenderPass(
                        pass: localSpaceProbe,
                        shader: WPEShaderProgram(
                            name: "effects/local_space_probe",
                            vertexSource: "// executor supplies the vertex stage",
                            fragmentSource: """
                            uniform sampler2D g_Texture0;
                            uniform vec4 g_Texture0Resolution;
                            varying vec2 v_TexCoord;
                            void main() {
                                float localWidth = 1.0 - step(4.5, g_Texture0Resolution.x);
                                float leftHalf = 1.0 - step(0.5, v_TexCoord.x);
                                gl_FragColor = vec4(localWidth * leftHalf, 0.0, 0.0, 1.0);
                            }
                            """,
                            isBuiltin: false
                        ),
                        textureBindings: [0: .fbo(compositeName)],
                        comboValues: [:],
                        uniformValues: [:]
                    )
                ]
            )
        ])

        let output = try executor.render(pipeline: pipeline, size: CGSize(width: 16, height: 16), textures: [:])
        let leftInsideLayer = try readPixel(output, x: 6, y: 8)
        let rightInsideLayer = try readPixel(output, x: 9, y: 8)
        let outsideLayer = try readPixel(output, x: 1, y: 8)

        #expect(leftInsideLayer.r >= 250)
        #expect(rightInsideLayer.r <= 5)
        #expect(outsideLayer.r <= 5)
        #expect(outsideLayer.g <= 5)
        #expect(outsideLayer.b <= 5)
    }

    @Test("Composelayer fullscreen projection preserves a 1:1 full-frame copy")
    func composelayerFullscreenProjectionPreservesOneToOneCopy() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let sceneTexture = try makeRGBAInputTexture(
            device: device,
            width: 4,
            height: 4,
            bytes: Data([
                255, 0, 0, 255, 255, 0, 0, 255, 0, 255, 0, 255, 0, 255, 0, 255,
                255, 0, 0, 255, 255, 0, 0, 255, 0, 255, 0, 255, 0, 255, 0, 255,
                0, 0, 255, 255, 0, 0, 255, 255, 255, 255, 0, 255, 255, 255, 0, 255,
                0, 0, 255, 255, 0, 0, 255, 255, 255, 255, 0, 255, 255, 255, 0, 255
            ])
        )

        let seedScene = WPERenderPass(
            id: "background.0",
            phase: .material,
            shader: "genericimage2",
            source: .image("materials/quadrants.png"),
            target: .scene,
            textures: [0: .image("materials/quadrants.png")],
            binds: [:],
            constants: [:],
            combos: [:],
            blending: "disabled",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )
        let compositeName = "_rt_imageLayerComposite_region_a"
        let captureRegion = WPERenderPass(
            id: "compose.0",
            phase: .material,
            shader: "compose",
            source: .fbo("_rt_FullFrameBuffer"),
            target: .layerComposite(name: compositeName),
            textures: [0: .fbo("_rt_FullFrameBuffer")],
            binds: [:],
            constants: [:],
            combos: [:],
            blending: "disabled",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )
        let drawRegion = WPERenderPass(
            id: "compose.1",
            phase: .command(file: "materials/util/copy.json"),
            shader: "commands/copy",
            source: .fbo(compositeName),
            target: .scene,
            textures: [0: .fbo(compositeName)],
            binds: [:],
            constants: [:],
            combos: [:],
            blending: "disabled",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )
        // Scene-sized, centered, unrotated composelayer: the identity case that
        // must reproduce the full frame 1:1 (no inset, no offset).
        let regionGeometry = WPERenderLayerGeometry(
            origin: SIMD3<Double>(2, 2, 0),
            scale: SIMD3<Double>(1, 1, 1),
            angles: SIMD3<Double>(0, 0, 0),
            alignment: .center,
            size: CGSize(width: 4, height: 4),
            alpha: 1,
            color: SIMD3<Double>(1, 1, 1),
            brightness: 1
        )
        let regionLayer = WPERenderLayer(
            objectID: "region",
            objectName: "Region",
            imagePath: "models/util/composelayer.json",
            materialPath: "materials/util/composelayer.json",
            geometry: regionGeometry,
            compositeA: compositeName,
            compositeB: "_rt_imageLayerComposite_region_b",
            localFBOs: [],
            passes: [captureRegion, drawRegion]
        )
        let pipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(
                graphLayer: graphLayer(pass: seedScene),
                passes: [
                    preparedBuiltinPass(
                        seedScene,
                        bindings: [0: .image("materials/quadrants.png")]
                    )
                ]
            ),
            WPEPreparedRenderLayer(
                graphLayer: regionLayer,
                passes: [
                    preparedBuiltinPass(
                        captureRegion,
                        bindings: [0: .fbo("_rt_FullFrameBuffer")]
                    ),
                    preparedBuiltinPass(drawRegion, bindings: [0: .fbo(compositeName)])
                ]
            )
        ])

        let output = try executor.render(
            pipeline: pipeline,
            size: CGSize(width: 4, height: 4),
            textures: ["materials/quadrants.png": sceneTexture]
        )

        let topLeft = try readPixel(output, x: 0, y: 0)
        let topRight = try readPixel(output, x: 3, y: 0)
        let bottomLeft = try readPixel(output, x: 0, y: 3)
        let bottomRight = try readPixel(output, x: 3, y: 3)

        #expect(topLeft.r >= 240)
        #expect(topLeft.g <= 10)
        #expect(topLeft.b <= 10)
        #expect(topRight.r <= 10)
        #expect(topRight.g >= 240)
        #expect(topRight.b <= 10)
        #expect(bottomLeft.r <= 10)
        #expect(bottomLeft.g <= 10)
        #expect(bottomLeft.b >= 240)
        #expect(bottomRight.r >= 240)
        #expect(bottomRight.g >= 240)
        #expect(bottomRight.b <= 10)
    }

    @Test("Composelayer projected sampling covers the whole scene with no inset")
    func composelayerProjectedSamplingCoversWholeScene() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        var sourceBytes = Data()
        for _ in 0..<4 {
            for x in 0..<16 {
                if x < 12 {
                    sourceBytes.append(contentsOf: [255, 0, 0, 255])
                } else {
                    sourceBytes.append(contentsOf: [0, 255, 0, 255])
                }
            }
        }
        let sceneTexture = try makeRGBAInputTexture(
            device: device,
            width: 16,
            height: 4,
            bytes: sourceBytes
        )

        let seedScene = WPERenderPass(
            id: "background.0",
            phase: .material,
            shader: "genericimage2",
            source: .image("materials/halves.png"),
            target: .scene,
            textures: [0: .image("materials/halves.png")],
            binds: [:],
            constants: [:],
            combos: [:],
            blending: "disabled",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )
        let compositeName = "_rt_imageLayerComposite_region_capture_a"
        let captureRegion = WPERenderPass(
            id: "compose.0",
            phase: .material,
            shader: "compose",
            source: .fbo("_rt_FullFrameBuffer"),
            target: .layerComposite(name: compositeName),
            textures: [0: .fbo("_rt_FullFrameBuffer")],
            binds: [:],
            constants: [:],
            combos: [:],
            blending: "disabled",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )
        let drawRegion = WPERenderPass(
            id: "compose.1",
            phase: .command(file: "materials/util/copy.json"),
            shader: "commands/copy",
            source: .fbo(compositeName),
            target: .scene,
            textures: [0: .fbo(compositeName)],
            binds: [:],
            constants: [:],
            combos: [:],
            blending: "disabled",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )
        // Scene-sized composelayer: the captured frame must cover the WHOLE
        // output (no shrunken inset), reproducing the halves split 1:1.
        let regionGeometry = WPERenderLayerGeometry(
            origin: SIMD3<Double>(8, 2, 0),
            scale: SIMD3<Double>(1, 1, 1),
            angles: SIMD3<Double>(0, 0, 0),
            alignment: .center,
            size: CGSize(width: 16, height: 4),
            alpha: 1,
            color: SIMD3<Double>(1, 1, 1),
            brightness: 1
        )
        let regionLayer = WPERenderLayer(
            objectID: "region-capture",
            objectName: "Region Capture",
            imagePath: "models/util/composelayer.json",
            materialPath: "materials/util/composelayer.json",
            geometry: regionGeometry,
            compositeA: compositeName,
            compositeB: "_rt_imageLayerComposite_region_capture_b",
            localFBOs: [],
            passes: [captureRegion, drawRegion]
        )
        let pipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(
                graphLayer: graphLayer(pass: seedScene),
                passes: [
                    preparedBuiltinPass(
                        seedScene,
                        bindings: [0: .image("materials/halves.png")]
                    )
                ]
            ),
            WPEPreparedRenderLayer(
                graphLayer: regionLayer,
                passes: [
                    preparedBuiltinPass(
                        captureRegion,
                        bindings: [0: .fbo("_rt_FullFrameBuffer")]
                    ),
                    preparedBuiltinPass(drawRegion, bindings: [0: .fbo(compositeName)])
                ]
            )
        ])

        let output = try executor.render(
            pipeline: pipeline,
            size: CGSize(width: 16, height: 4),
            textures: ["materials/halves.png": sceneTexture]
        )
        let leftSide = try readPixel(output, x: 2, y: 2)
        let rightSide = try readPixel(output, x: 14, y: 2)

        #expect(leftSide.r >= 250)
        #expect(leftSide.g <= 5)
        #expect(rightSide.r <= 5)
        #expect(rightSide.g >= 250)
    }

    @Test("Opacity effect uses mask texture to gate alpha")
    func opacityEffectUsesMaskTextureToGateAlpha() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let source = try makeRGBAInputTexture(
            device: device,
            width: 2,
            height: 2,
            bytes: Data([
                255, 0, 0, 255, 255, 0, 0, 255,
                255, 0, 0, 255, 255, 0, 0, 255
            ])
        )
        let mask = try makeRGBAInputTexture(
            device: device,
            width: 2,
            height: 2,
            bytes: Data([
                0, 0, 0, 255, 255, 255, 255, 255,
                0, 0, 0, 255, 255, 255, 255, 255
            ])
        )
        let pass = WPERenderPass(
            id: "opacity.0",
            phase: .effect(file: "effects/opacity/effect.json"),
            shader: "effects/opacity",
            source: .image("materials/source.png"),
            target: .scene,
            textures: [
                0: .image("materials/source.png"),
                1: .image("materials/mask.png")
            ],
            binds: [:],
            constants: ["alpha": .number(1)],
            combos: [:],
            blending: "disabled",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )
        let pipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(
                graphLayer: graphLayer(pass: pass),
                passes: [
                    preparedBuiltinPass(
                        pass,
                        bindings: [
                            0: .image("materials/source.png"),
                            1: .image("materials/mask.png")
                        ],
                        uniforms: ["alpha": .number(1)]
                    )
                ]
            )
        ])

        let output = try executor.render(
            pipeline: pipeline,
            size: CGSize(width: 2, height: 2),
            textures: [
                "materials/source.png": source,
                "materials/mask.png": mask
            ]
        )
        let maskedOut = try readPixel(output, x: 0, y: 1)
        let visible = try readPixel(output, x: 1, y: 1)

        #expect(maskedOut.r <= 5)
        #expect(maskedOut.a <= 5)
        #expect(visible.r >= 250)
        #expect(visible.a >= 250)
    }

    @Test("genericimage4 alpha mask drops alpha when mask is opaque-black")
    func genericImage4AlphaMaskGatesOutput() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let primary = try makeRGBAInputTexture(device: device, bytes: Data([
            0, 255, 0, 255,
            0, 255, 0, 255,
            0, 255, 0, 255,
            0, 255, 0, 255
        ]))
        let mask = try makeRGBAInputTexture(device: device, bytes: Data([
            0, 0, 0, 0,
            0, 0, 0, 0,
            0, 0, 0, 0,
            0, 0, 0, 0
        ]))
        let pass = WPERenderPass(
            id: "img4.0",
            phase: .material,
            shader: "genericimage4",
            source: .image("materials/base.png"),
            target: .scene,
            textures: [0: .image("materials/base.png"), 1: .image("materials/mask.png")],
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
                    shader: WPEShaderProgram(name: "genericimage4", vertexSource: "", fragmentSource: "", isBuiltin: true),
                    textureBindings: [
                        0: .image("materials/base.png"),
                        1: .image("materials/mask.png")
                    ],
                    comboValues: [:],
                    uniformValues: [:]
                )]
            )
        ])

        let output = try executor.render(
            pipeline: pipeline,
            size: CGSize(width: 2, height: 2),
            textures: [
                "materials/base.png": primary,
                "materials/mask.png": mask
            ]
        )
        let pixel = try readPixel(output, x: 1, y: 1)

        #expect(pixel.a >= 250)
        #expect(pixel.g <= 5)
    }

    @Test("genericimage4 records distinct texture binding diagnostics")
    func genericImage4RecordsDistinctTextureBindingDiagnostics() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let primary = try makeRGBAInputTexture(device: device, bytes: Data([
            0, 255, 0, 255,
            0, 255, 0, 255,
            0, 255, 0, 255,
            0, 255, 0, 255
        ]))
        primary.label = "base-texture"
        let mask = try makeRGBAInputTexture(device: device, bytes: Data([
            0, 0, 0, 0,
            0, 0, 0, 0,
            0, 0, 0, 0,
            0, 0, 0, 0
        ]))
        mask.label = "mask-texture"
        _ = WPESceneDebugArtifacts.shared.drainBindingDiagnosticsForTesting()
        defer { _ = WPESceneDebugArtifacts.shared.drainBindingDiagnosticsForTesting() }

        let pass = WPERenderPass(
            id: "img4.0",
            phase: .material,
            shader: "genericimage4",
            source: .image("materials/base.png"),
            target: .scene,
            textures: [0: .image("materials/base.png"), 1: .image("materials/mask.png")],
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
                    shader: WPEShaderProgram(name: "genericimage4", vertexSource: "", fragmentSource: "", isBuiltin: true),
                    textureBindings: [
                        0: .image("materials/base.png"),
                        1: .image("materials/mask.png")
                    ],
                    comboValues: [:],
                    uniformValues: [:]
                )]
            )
        ])

        _ = try executor.render(
            pipeline: pipeline,
            size: CGSize(width: 2, height: 2),
            textures: [
                "materials/base.png": primary,
                "materials/mask.png": mask
            ]
        )

        let events = WPESceneDebugArtifacts.shared.drainBindingDiagnosticsForTesting()
        #expect(events.contains {
            $0.contains("pass=img4.0")
                && $0.contains("slot=0")
                && $0.contains("reference=image(materials/base.png)")
                && $0.contains("texture=base-texture")
                && $0.contains("fallback=false")
        })
        #expect(events.contains {
            $0.contains("pass=img4.0")
                && $0.contains("slot=1")
                && $0.contains("reference=image(materials/mask.png)")
                && $0.contains("texture=mask-texture")
                && $0.contains("fallback=false")
        })
    }

    @Test("genericimage4 records primary fallback texture binding diagnostics")
    func genericImage4RecordsPrimaryFallbackTextureBindingDiagnostics() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let primary = try makeRGBAInputTexture(device: device, bytes: Data([
            0, 255, 0, 255,
            0, 255, 0, 255,
            0, 255, 0, 255,
            0, 255, 0, 255
        ]))
        primary.label = "base-texture"
        _ = WPESceneDebugArtifacts.shared.drainBindingDiagnosticsForTesting()
        defer { _ = WPESceneDebugArtifacts.shared.drainBindingDiagnosticsForTesting() }

        let pass = WPERenderPass(
            id: "img4.1",
            phase: .material,
            shader: "genericimage4",
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
        let pipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(
                graphLayer: graphLayer(pass: pass),
                passes: [WPEPreparedRenderPass(
                    pass: pass,
                    shader: WPEShaderProgram(name: "genericimage4", vertexSource: "", fragmentSource: "", isBuiltin: true),
                    textureBindings: [0: .image("materials/base.png")],
                    comboValues: [:],
                    uniformValues: [:]
                )]
            )
        ])

        _ = try executor.render(
            pipeline: pipeline,
            size: CGSize(width: 2, height: 2),
            textures: ["materials/base.png": primary]
        )

        let events = WPESceneDebugArtifacts.shared.drainBindingDiagnosticsForTesting()
        #expect(events.contains {
            $0.contains("pass=img4.1")
                && $0.contains("slot=1")
                && $0.contains("reference=<primary>")
                && $0.contains("texture=base-texture")
                && $0.contains("fallback=true")
        })
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
            geometry: .identity,
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

private struct PixelBounds: Equatable, CustomStringConvertible {
    let minX: Int
    let minY: Int
    let maxX: Int
    let maxY: Int

    var description: String {
        "PixelBounds(minX: \(minX), minY: \(minY), maxX: \(maxX), maxY: \(maxY))"
    }
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

private func nonBlackBounds(_ texture: MTLTexture) -> PixelBounds? {
    var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
    texture.getBytes(
        &bytes,
        bytesPerRow: texture.width * 4,
        from: MTLRegionMake2D(0, 0, texture.width, texture.height),
        mipmapLevel: 0
    )
    var minX = Int.max
    var minY = Int.max
    var maxX = Int.min
    var maxY = Int.min
    for y in 0..<texture.height {
        for x in 0..<texture.width {
            let index = (y * texture.width + x) * 4
            let r = bytes[index]
            let g = bytes[index + 1]
            let b = bytes[index + 2]
            if r > 10 || g > 10 || b > 10 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
    }
    guard minX != Int.max else { return nil }
    return PixelBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
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
    @Test("Offscreen output is sRGB-tagged for stable gamma")
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

private func graphLayer(
    pass: WPERenderPass,
    parallaxDepth: Double = 0,
    geometry: WPERenderLayerGeometry = .identity
) -> WPERenderLayer {
    WPERenderLayer(
        objectID: "layer",
        objectName: "Layer",
        imagePath: "materials/base.png",
        materialPath: nil,
        geometry: geometry,
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
    source: WPETextureReference = .previous,
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
        source: source,
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
        geometry: .identity,
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

// `translucent` is a WPE alias for the standard non-premultiplied alpha
// blend (same factors as `normal`). Pre-fix it was wired as premultiplied
// (`src.rgb*1 + dst.rgb*(1-src.a)`), which doubled any pass that wrote
// `vec4(scene.rgb, 0)` into the scene.
private let blendFixtures: [BlendFixture] = [
    BlendFixture(mode: "normal", expected: Pixel(r: 188, g: 0, b: 188, a: 255)),
    BlendFixture(mode: "additive", expected: Pixel(r: 188, g: 0, b: 255, a: 255)),
    BlendFixture(mode: "multiply", expected: Pixel(r: 0, g: 0, b: 0, a: 255)),
    BlendFixture(mode: "translucent", expected: Pixel(r: 188, g: 0, b: 188, a: 255)),
    BlendFixture(mode: "normalmapped", expected: Pixel(r: 188, g: 0, b: 188, a: 255)),
    BlendFixture(mode: "disabled", expected: Pixel(r: 255, g: 0, b: 0, a: 128))
]

private extension WPEMetalRenderExecutorTests {
    static func maximumTextureDimension2D(for device: MTLDevice) -> Int {
        WPEMetalTextureLimits.maximum2DTextureDimension(for: device)
    }

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

    // Guards the head-hole bug: a semi-transparent layer that flows through a
    // multi-pass premultiplied effect chain must NOT lose RGB by alpha^N.
    // A half-alpha red (255,0,0,128) premultiplies to ~(128,0,0,128); the old
    // straight-alpha + .sourceAlpha pipeline re-premultiplied every pass and
    // decayed red toward ~16 after four passes. Premultiplied render targets
    // keep it at ~128.
    @Test("Premultiplied FBO copy chain preserves semi-transparent RGB contribution")
    func premultipliedFBOCopyChainPreservesSemiTransparentRGBContribution() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let input = try makeRGBAInputTexture(
            device: device,
            width: 1,
            height: 1,
            bytes: Data([255, 0, 0, 128])
        )

        let compositeA = "_rt_imageLayerComposite_layer_a"
        let compositeB = "_rt_imageLayerComposite_layer_b"
        let base = WPERenderPass(
            id: "alpha.0",
            phase: .material,
            shader: "genericimage2",
            source: .image("materials/base.png"),
            target: .layerComposite(name: compositeA),
            textures: [0: .image("materials/base.png")],
            binds: [:],
            constants: [:],
            combos: [:],
            blending: "premultiplied",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )
        let copy0 = copyPass(
            id: "alpha.1",
            source: .fbo(compositeA),
            target: .layerComposite(name: compositeB),
            blending: "premultiplied"
        )
        let copy1 = copyPass(
            id: "alpha.2",
            source: .fbo(compositeB),
            target: .layerComposite(name: compositeA),
            blending: "premultiplied"
        )
        let sceneCopy = copyPass(
            id: "alpha.3",
            source: .fbo(compositeA),
            target: .scene,
            blending: "premultiplied"
        )

        let pipeline = preparedPipeline(
            localFBOs: [],
            passes: [
                preparedBuiltinPass(
                    base,
                    bindings: [0: .image("materials/base.png")],
                    uniforms: ["g_Color": .vector([1, 1, 1, 1])]
                ),
                preparedBuiltinPass(copy0, bindings: [0: .fbo(compositeA)]),
                preparedBuiltinPass(copy1, bindings: [0: .fbo(compositeB)]),
                preparedBuiltinPass(sceneCopy, bindings: [0: .fbo(compositeA)])
            ]
        )

        let output = try executor.render(
            pipeline: pipeline,
            size: CGSize(width: 4, height: 4),
            textures: ["materials/base.png": input]
        )
        let pixel = try readPixel(output, x: 2, y: 2)

        // Premultiplied red at alpha 0.5 ≈ 128. The buggy alpha^N decay would
        // drop this below ~40 after four passes.
        #expect(pixel.r >= 100, "RGB contribution decayed across the chain; got \(pixel)")
        #expect(pixel.g <= 8)
        #expect(pixel.b <= 8)
    }

    @Test("Scene alias does not bootstrap from the previous frame")
    func sceneAliasDoesNotBootstrapFromPreviousFrame() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)

        let seedWhite = solidPass(
            id: "seed.0",
            color: [1, 1, 1, 1],
            target: .scene,
            blending: "disabled"
        )
        _ = try executor.render(
            pipeline: preparedPipeline(
                localFBOs: [],
                passes: [preparedBuiltinPass(seedWhite, uniforms: ["g_Color": .vector([1, 1, 1, 1])])]
            ),
            size: CGSize(width: 4, height: 4),
            textures: [:]
        )

        let readFullFrameBuffer = copyPass(
            id: "alias.0",
            source: .fbo("_rt_FullFrameBuffer"),
            target: .scene,
            blending: "disabled"
        )
        let output = try executor.render(
            pipeline: preparedPipeline(
                localFBOs: [],
                passes: [
                    preparedBuiltinPass(readFullFrameBuffer, bindings: [0: .fbo("_rt_FullFrameBuffer")])
                ]
            ),
            size: CGSize(width: 4, height: 4),
            textures: [:]
        )

        let pixel = try readPixel(output, x: 2, y: 2)
        #expect(pixel.r <= 5)
        #expect(pixel.g <= 5)
        #expect(pixel.b <= 5)
    }

    @Test("Routes declared non-underscore FBO target into a later FBO source")
    func routesDeclaredFBOTargetIntoScene() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)

        let fbo = WPERenderFBO(name: "blur_start_2", scale: 1, format: "rgba8888")
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

    @Test("Rejects oversized FBO targets before Metal descriptor allocation")
    func rejectsOversizedFBOTargetBeforeMetalDescriptorAllocation() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let limit = Self.maximumTextureDimension2D(for: device)

        let fbo = WPERenderFBO(name: "_rt_TooLarge", scale: 1.0 / Double(limit + 1), format: "rgba8888")
        let writeFBO = solidPass(
            id: "layer.0",
            color: [1, 0, 0, 1],
            target: .fbo(name: fbo.name),
            blending: "disabled"
        )
        let pipeline = preparedPipeline(
            localFBOs: [fbo],
            passes: [preparedBuiltinPass(writeFBO, uniforms: ["g_Color": .vector([1, 0, 0, 1])])]
        )

        #expect(
            throws: WPEMetalRenderExecutorError.renderTargetDimensionsExceedDeviceLimit(
                targetName: fbo.name,
                width: limit + 1,
                height: limit + 1,
                limit: limit
            )
        ) {
            _ = try executor.render(pipeline: pipeline, size: CGSize(width: 1, height: 1), textures: [:])
        }
    }

    @Test("FBO scale downsamples declared render targets")
    func fboScaleDownsamplesDeclaredRenderTargets() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let pool = WPEMetalRenderTargetPool(device: device)
        let fbo = WPERenderFBO(name: "_downscaled", scale: 4, format: "rgba8888")
        let layer = WPERenderLayer(
            objectID: "layer",
            objectName: "Layer",
            imagePath: "materials/base.png",
            materialPath: nil,
            geometry: .identity,
            compositeA: "_rt_imageLayerComposite_layer_a",
            compositeB: "_rt_imageLayerComposite_layer_b",
            localFBOs: [fbo],
            passes: []
        )

        let texture = try pool.texture(
            for: .fbo(name: fbo.name),
            layer: layer,
            sceneSize: CGSize(width: 8, height: 4),
            avoiding: nil
        )

        #expect(texture.width == 2)
        #expect(texture.height == 1)
    }

    @Test("Composelayer composite target uses full scene size, not the object footprint")
    func composelayerCompositeTargetUsesFullSceneSize() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let pool = WPEMetalRenderTargetPool(device: device)
        let layer = WPERenderLayer(
            objectID: "compose",
            objectName: "Compose",
            imagePath: "models/util/composelayer.json",
            materialPath: "materials/util/composelayer.json",
            geometry: WPERenderLayerGeometry(
                origin: SIMD3<Double>(512, 384, 0),
                scale: SIMD3<Double>(2, 3, 1),
                angles: SIMD3<Double>(0, 0, 0),
                alignment: .center,
                size: CGSize(width: 128, height: 64),
                alpha: 1,
                color: SIMD3<Double>(1, 1, 1),
                brightness: 1
            ),
            compositeA: "_rt_imageLayerComposite_compose_a",
            compositeB: "_rt_imageLayerComposite_compose_b",
            localFBOs: [],
            passes: []
        )

        let texture = try pool.texture(
            for: .layerComposite(name: layer.compositeA),
            layer: layer,
            sceneSize: CGSize(width: 1024, height: 768),
            avoiding: nil
        )

        #expect(texture.width == 1024)
        #expect(texture.height == 768)
    }

    @Test("Projectlayer composite target also uses full scene size")
    func projectlayerCompositeTargetUsesFullSceneSize() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let pool = WPEMetalRenderTargetPool(device: device)
        let layer = WPERenderLayer(
            objectID: "project",
            objectName: "Project",
            imagePath: "models/util/projectlayer.json",
            materialPath: "materials/util/composelayer.json",
            geometry: WPERenderLayerGeometry(
                origin: SIMD3<Double>(512, 384, 0),
                scale: SIMD3<Double>(2, 3, 1),
                angles: SIMD3<Double>(0, 0, 0),
                alignment: .center,
                size: CGSize(width: 128, height: 64),
                alpha: 1,
                color: SIMD3<Double>(1, 1, 1),
                brightness: 1
            ),
            compositeA: "_rt_imageLayerComposite_project_a",
            compositeB: "_rt_imageLayerComposite_project_b",
            localFBOs: [],
            passes: []
        )

        let texture = try pool.texture(
            for: .layerComposite(name: layer.compositeA),
            layer: layer,
            sceneSize: CGSize(width: 1024, height: 768),
            avoiding: nil
        )

        #expect(texture.width == 1024)
        #expect(texture.height == 768)
    }

    @Test("Scene-capture utility classifier matches compose/project models and tolerates a dependency prefix")
    func composeUtilityClassifierHandlesPathsAndDependencyPrefix() {
        #expect(WPEMetalSceneCaptureUtilityModels.isSceneCaptureUtilityModelPath("models/util/composelayer.json"))
        #expect(WPEMetalSceneCaptureUtilityModels.isSceneCaptureUtilityModelPath("models/util/projectlayer.json"))
        #expect(WPEMetalSceneCaptureUtilityModels.isSceneCaptureUtilityModelPath("models/util/fullscreenlayer.json"))
        #expect(WPEMetalSceneCaptureUtilityModels.isSceneCaptureUtilityModelPath("../3479521040/models/util/composelayer.json"))
        #expect(WPEMetalSceneCaptureUtilityModels.isSceneCaptureUtilityModelPath("models\\util\\composelayer.json"))
        #expect(!WPEMetalSceneCaptureUtilityModels.isSceneCaptureUtilityModelPath("models/util/solidlayer.json"))
        #expect(!WPEMetalSceneCaptureUtilityModels.isSceneCaptureUtilityModelPath("materials/quadrants.png"))
    }

    @Test("Composelayer CLEARALPHA clears the captured alpha")
    func composelayerClearAlphaClearsCapturedAlpha() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let seedScene = solidPass(
            id: "background.0",
            color: [1, 0, 0, 1],
            target: .scene,
            blending: "disabled"
        )
        let compositeName = "_rt_imageLayerComposite_clearalpha_a"
        let capture = WPERenderPass(
            id: "clearalpha.0",
            phase: .material,
            shader: "compose",
            source: .fbo("_rt_FullFrameBuffer"),
            target: .layerComposite(name: compositeName),
            textures: [0: .fbo("_rt_FullFrameBuffer")],
            binds: [:],
            constants: [:],
            combos: ["CLEARALPHA": 1],
            blending: "disabled",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )
        let copyToScene = copyPass(
            id: "clearalpha.1",
            source: .fbo(compositeName),
            target: .scene,
            blending: "disabled"
        )
        let layer = WPERenderLayer(
            objectID: "clearalpha",
            objectName: "ClearAlpha",
            imagePath: "models/util/composelayer.json",
            materialPath: "materials/util/composelayer_clearalpha.json",
            geometry: WPERenderLayerGeometry(
                origin: SIMD3<Double>(1, 1, 0),
                scale: SIMD3<Double>(1, 1, 1),
                angles: SIMD3<Double>(0, 0, 0),
                alignment: .center,
                size: CGSize(width: 2, height: 2),
                alpha: 1,
                color: SIMD3<Double>(1, 1, 1),
                brightness: 1
            ),
            compositeA: compositeName,
            compositeB: "_rt_imageLayerComposite_clearalpha_b",
            localFBOs: [],
            passes: [capture, copyToScene]
        )
        let pipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(
                graphLayer: graphLayer(pass: seedScene),
                passes: [preparedBuiltinPass(seedScene, uniforms: ["g_Color": .vector([1, 0, 0, 1])])]
            ),
            WPEPreparedRenderLayer(
                graphLayer: layer,
                passes: [
                    preparedBuiltinPass(capture, bindings: [0: .fbo("_rt_FullFrameBuffer")]),
                    preparedBuiltinPass(copyToScene, bindings: [0: .fbo(compositeName)])
                ]
            )
        ])

        let output = try executor.render(pipeline: pipeline, size: CGSize(width: 2, height: 2), textures: [:])
        let pixel = try readPixel(output, x: 1, y: 1)

        #expect(pixel.a <= 5)
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

    @Test("Resolves previous to the prior render call's scene output")
    func resolvesPreviousFromPriorSceneRender() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)

        let seedScene = solidPass(
            id: "layer.0",
            color: [1, 0, 0, 1],
            target: .scene,
            blending: "disabled"
        )
        let copyPreviousToScene = copyPass(
            id: "layer.0",
            source: .previous,
            target: .scene,
            blending: "disabled"
        )

        _ = try executor.render(
            pipeline: preparedPipeline(
                localFBOs: [],
                passes: [preparedBuiltinPass(seedScene, uniforms: ["g_Color": .vector([1, 0, 0, 1])])]
            ),
            size: CGSize(width: 4, height: 4),
            textures: [:]
        )
        let output = try executor.render(
            pipeline: preparedPipeline(
                localFBOs: [],
                passes: [preparedBuiltinPass(copyPreviousToScene, bindings: [0: .previous])]
            ),
            size: CGSize(width: 4, height: 4),
            textures: [:]
        )
        let pixel = try readPixel(output, x: 2, y: 2)

        #expect(pixel.r >= 250)
        #expect(pixel.g <= 5)
        #expect(pixel.b <= 5)
        #expect(pixel.a >= 250)
    }

    @Test("Bootstraps missing scene previous with a cleared texture on first render")
    func bootstrapsMissingScenePreviousOnFirstRender() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)

        let pass = copyPass(
            id: "layer.0",
            source: .previous,
            target: .scene,
            blending: "disabled"
        )
        let pipeline = preparedPipeline(
            localFBOs: [],
            passes: [preparedBuiltinPass(pass, bindings: [0: .previous])]
        )

        let output = try executor.render(pipeline: pipeline, size: CGSize(width: 2, height: 2), textures: [:])
        let pixel = try readPixel(output, x: 1, y: 1)

        #expect(pixel.r <= 5)
        #expect(pixel.g <= 5)
        #expect(pixel.b <= 5)
        #expect(pixel.a >= 250)
    }

    @Test("Bootstraps missing FBO previous with a transparent cleared texture on first render")
    func bootstrapsMissingFBOPreviousOnFirstRender() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)

        let fbo = WPERenderFBO(name: "_rt_Empty", scale: 1, format: "rgba8888")
        let copyPreviousBackIntoSameFBO = copyPass(
            id: "layer.0",
            source: .previous,
            target: .fbo(name: fbo.name),
            blending: "disabled"
        )
        let copyFBOToScene = copyPass(
            id: "layer.1",
            source: .fbo(fbo.name),
            target: .scene,
            blending: "disabled"
        )
        let pipeline = preparedPipeline(
            localFBOs: [fbo],
            passes: [
                preparedBuiltinPass(copyPreviousBackIntoSameFBO, bindings: [0: .previous]),
                preparedBuiltinPass(copyFBOToScene, bindings: [0: .fbo(fbo.name)])
            ]
        )

        let output = try executor.render(pipeline: pipeline, size: CGSize(width: 2, height: 2), textures: [:])
        let pixel = try readPixel(output, x: 1, y: 1)

        #expect(pixel.r <= 5)
        #expect(pixel.g <= 5)
        #expect(pixel.b <= 5)
        #expect(pixel.a <= 5)
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
    @Test("Source-over rewrite to reused composite clears stale physical texture")
    func sourceOverRewriteToReusedCompositeClearsStalePhysicalTexture() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)

        let compA = "_rt_imageLayerComposite_layer_a"
        let compB = "_rt_imageLayerComposite_layer_b"
        let staleBlue = solidPass(
            id: "layer.1",
            color: [0, 0, 1, 0.5],
            source: .image("materials/base.png"),
            target: .layerComposite(name: compB),
            blending: "normal"
        )
        let intermediate = solidPass(
            id: "layer.2",
            color: [0, 1, 0, 1],
            source: .image("materials/base.png"),
            target: .layerComposite(name: compA),
            blending: "disabled"
        )
        let replacementRed = solidPass(
            id: "layer.3",
            color: [1, 0, 0, 0.5],
            source: .fbo(compA),
            target: .layerComposite(name: compB),
            blending: "normal"
        )
        let copyToScene = copyPass(
            id: "layer.4",
            source: .fbo(compB),
            target: .scene,
            blending: "disabled"
        )

        let pipeline = preparedPipeline(
            localFBOs: [],
            passes: [
                preparedBuiltinPass(staleBlue, uniforms: ["g_Color": .vector([0, 0, 1, 0.5])]),
                preparedBuiltinPass(intermediate, uniforms: ["g_Color": .vector([0, 1, 0, 1])]),
                preparedBuiltinPass(replacementRed, uniforms: ["g_Color": .vector([1, 0, 0, 0.5])]),
                preparedBuiltinPass(copyToScene, bindings: [0: .fbo(compB)])
            ]
        )

        let output = try executor.render(pipeline: pipeline, size: CGSize(width: 4, height: 4), textures: [:])
        let pixel = try readPixel(output, x: 2, y: 2)

        #expect(pixel.r >= 120)
        #expect(pixel.b <= 5, "Second source-over write must not retain stale blue from the earlier compB pass; got \(pixel)")
        #expect(pixel.a >= 120)
    }

    @Test("Additive rewrite to reused composite preserves existing destination")
    func additiveRewriteToReusedCompositePreservesExistingDestination() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)

        let compB = "_rt_imageLayerComposite_layer_b"
        let seedBlue = solidPass(
            id: "layer.1",
            color: [0, 0, 1, 1],
            source: .image("materials/base.png"),
            target: .layerComposite(name: compB),
            blending: "disabled"
        )
        let additiveRed = solidPass(
            id: "layer.2",
            color: [1, 0, 0, 1],
            source: .image("materials/base.png"),
            target: .layerComposite(name: compB),
            blending: "additive"
        )
        let copyToScene = copyPass(
            id: "layer.3",
            source: .fbo(compB),
            target: .scene,
            blending: "disabled"
        )

        let pipeline = preparedPipeline(
            localFBOs: [],
            passes: [
                preparedBuiltinPass(seedBlue, uniforms: ["g_Color": .vector([0, 0, 1, 1])]),
                preparedBuiltinPass(additiveRed, uniforms: ["g_Color": .vector([1, 0, 0, 1])]),
                preparedBuiltinPass(copyToScene, bindings: [0: .fbo(compB)])
            ]
        )

        let output = try executor.render(pipeline: pipeline, size: CGSize(width: 4, height: 4), textures: [:])
        let pixel = try readPixel(output, x: 2, y: 2)

        #expect(pixel.r >= 250)
        #expect(pixel.b >= 250, "Additive writes intentionally accumulate on the existing destination; got \(pixel)")
        #expect(pixel.a >= 250)
    }

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

        expectPixel(pixel, approximately: Pixel(r: 0, g: 0, b: 255, a: 255))
    }
}
