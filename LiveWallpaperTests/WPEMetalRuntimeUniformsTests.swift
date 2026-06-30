import AppKit
import QuartzCore
import Testing
@testable import LiveWallpaper

@MainActor
@Suite("WPE Metal runtime uniforms")
struct WPEMetalRuntimeUniformsTests {

    @Test("Frame clock computes time daytime brightness and pointer uniforms")
    func frameClockComputesRuntimeUniforms() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let date = try #require(DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 5,
            day: 5,
            hour: 6,
            minute: 30,
            second: 0
        ).date)

        let clock = WPEMetalFrameClock(
            loadTime: 10,
            currentMediaTime: { 12.5 },
            currentDate: { date },
            calendar: calendar
        )

        let uniforms = clock.runtimeUniforms(
            profile: .quality,
            pointerPosition: SIMD2<Double>(0.25, 0.75)
        )

        #expect(abs(uniforms.time - 2.5) < 0.0001)
        #expect(abs(uniforms.daytime - 0.2708333333) < 0.0001)
        #expect(uniforms.brightness == 1)
        #expect(uniforms.pointerPosition == SIMD2<Double>(0.25, 0.75))
        #expect(uniforms.uniformValues["g_Time"]?.numberValue == 2.5)
        #expect(uniforms.uniformValues["g_Brightness"]?.numberValue == 1)
        #expect(uniforms.uniformValues["g_PointerPosition"]?.vectorValue == [0.25, 0.75])
    }

    @Test("Suspended profile keeps brightness uniform at one")
    func suspendedProfileKeepsBrightnessAtOne() {
        // g_Brightness multiplies image-shader albedo, so 0 rendered every
        // genericimage layer as a black silhouette on frames produced while
        // suspended (859db5b). Suspension saves power via mtkView.isPaused,
        // not by dimming content — brightness must stay 1.
        let uniforms = WPEMetalRuntimeUniforms(
            time: 4,
            daytime: 0.5,
            brightness: WallpaperPerformanceProfile.suspended.metalBrightnessUniformValue,
            pointerPosition: SIMD2<Double>(0.5, 0.5)
        )

        #expect(uniforms.brightness == 1)
        #expect(uniforms.uniformValues["g_Brightness"]?.numberValue == 1)
    }

    @Test("WPE 2.8 neutral frame defaults disable optional effects and pass through SDR")
    func provides28NeutralFrameDefaults() {
        let uniforms = WPEMetalRuntimeUniforms(
            time: 0,
            daytime: 0,
            brightness: 1,
            pointerPosition: SIMD2<Double>(0.5, 0.5)
        )
        let values = uniforms.uniformValues

        // g_RenderVar0…3 zero ⇒ every optional font effect (outline/blur/shadow)
        // stays disabled until the MSDF text path overrides them per-draw.
        for name in ["g_RenderVar0", "g_RenderVar1", "g_RenderVar2", "g_RenderVar3"] {
            #expect(values[name]?.vectorValue == [0, 0, 0, 0])
        }

        // g_HDRParams.y = 0.5 ⇒ combine_video_hdr maxHDR = 1.0 ⇒ exact SDR
        // pass-through. (y = 0 would divide by zero → NaN/black.)
        #expect(values["g_HDRParams"]?.vectorValue == [1, 0.5])
    }

    @Test("Center present mode preserves source pixel size and centers")
    func centerPresentModePreservesSourcePixelSizeAndCenters() {
        let smaller = WPEPresentUniforms.make(
            fitMode: .center,
            sourceWidth: 960,
            sourceHeight: 540,
            targetWidth: 1920,
            targetHeight: 1080
        )

        #expect(smaller.ndcScale == SIMD2<Float>(0.5, 0.5))
        #expect(smaller.uvScale == SIMD2<Float>(1, 1))
        #expect(smaller.uvOffset == SIMD2<Float>(0, 0))

        let larger = WPEPresentUniforms.make(
            fitMode: .center,
            sourceWidth: 3840,
            sourceHeight: 2160,
            targetWidth: 1920,
            targetHeight: 1080
        )

        #expect(larger.ndcScale == SIMD2<Float>(2, 2))
        #expect(larger.uvScale == SIMD2<Float>(1, 1))
        #expect(larger.uvOffset == SIMD2<Float>(0, 0))
    }

    @Test("Pointer sampler normalizes global mouse position to top-left scene UV")
    func pointerSamplerNormalizesGlobalMousePosition() throws {
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 200, height: 100),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        window.contentView = view

        let uv = WPEMetalPointerSampler.normalizedSceneUV(
            mouseLocation: CGPoint(x: 200, y: 125),
            in: view
        )

        #expect(abs(uv.x - 0.5) < 0.0001)
        #expect(abs(uv.y - 0.75) < 0.0001)
    }

    @Test("Orthographic camera uses scene projection dimensions")
    func orthographicCameraUsesSceneProjectionDimensions() {
        let projection = WPESceneOrthogonalProjection(width: 200, height: 100, auto: true)
        let camera = WPEMetalCameraUniforms(
            orthogonalProjection: projection,
            sceneCamera: .defaultCamera
        )

        #expect(camera.renderSize == CGSize(width: 200, height: 100))
        #expect(camera.viewProjectionMatrix.count == 16)
        #expect(abs(camera.viewProjectionMatrix[0] - 0.01) < 0.0001)
        #expect(abs(camera.viewProjectionMatrix[5] + 0.02) < 0.0001)
        #expect(abs(camera.viewProjectionMatrix[12] + 1.0) < 0.0001)
        #expect(abs(camera.viewProjectionMatrix[13] - 1.0) < 0.0001)
    }

    @Test("Prepared pipeline receives runtime and camera uniforms without losing material uniforms")
    func preparedPipelineReceivesRuntimeAndCameraUniforms() {
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
            blending: "normal",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )
        let layer = WPERenderLayer(
            objectID: "layer",
            objectName: "Layer",
            imagePath: "materials/base.png",
            materialPath: nil,
            geometry: .identity,
            compositeA: "a",
            compositeB: "b",
            localFBOs: [],
            passes: [pass]
        )
        let pipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(
                graphLayer: layer,
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
                        uniformValues: ["g_Color": .vector([1, 0, 0, 1])]
                    )
                ]
            )
        ])

        let runtime = WPEMetalRuntimeUniforms(
            time: 1,
            daytime: 0.25,
            brightness: 1,
            pointerPosition: SIMD2<Double>(0.2, 0.8)
        )
        let camera = WPEMetalCameraUniforms(
            orthogonalProjection: WPESceneOrthogonalProjection(width: 64, height: 32, auto: true),
            sceneCamera: .defaultCamera
        )

        let prepared = pipeline.addingMetalRuntimeUniforms(runtime, camera: camera)
        let values = prepared.layers[0].passes[0].uniformValues

        #expect(values["g_Color"]?.vectorValue == [1, 0, 0, 1])
        #expect(values["g_Time"]?.numberValue == 1)
        #expect(values["g_Daytime"]?.numberValue == 0.25)
        #expect(values["g_Brightness"]?.numberValue == 1)
        #expect(values["g_PointerPosition"]?.vectorValue == [0.2, 0.8])
        #expect(values["g_ViewProjectionMatrix"]?.vectorValue?.count == 16)
        // `.identity` geometry must inject identity per-object 2.8 transforms.
        #expect(values["g_ModelMatrix"]?.vectorValue == [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])
        #expect(values["g_NormalModelMatrix"]?.vectorValue == [1, 0, 0, 0, 1, 0, 0, 0, 1])
    }

    @Test("Prepared pipeline applies dynamic origin overrides before object uniforms")
    func preparedPipelineAppliesDynamicOriginOverrides() {
        let pass = WPERenderPass(
            id: "image.0",
            phase: .material,
            shader: "genericimage",
            source: .previous,
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
        let layer = WPERenderLayer(
            objectID: "154",
            objectName: "苍月草1/Nemophila1",
            imagePath: "models/nemophila.json",
            materialPath: nil,
            geometry: WPERenderLayerGeometry(
                origin: SIMD3<Double>(860, 133, 0),
                scale: SIMD3<Double>(1, 1, 1),
                angles: SIMD3<Double>(0, 0, 0),
                alignment: .center,
                size: CGSize(width: 360, height: 248),
                alpha: 1,
                color: SIMD3<Double>(1, 1, 1),
                brightness: 1
            ),
            compositeA: "a",
            compositeB: "b",
            localFBOs: [],
            passes: [pass]
        )
        let pipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(
                graphLayer: layer,
                passes: [
                    WPEPreparedRenderPass(
                        pass: pass,
                        shader: nil,
                        textureBindings: [:],
                        comboValues: [:],
                        uniformValues: [:]
                    )
                ]
            )
        ])

        let runtime = WPEMetalRuntimeUniforms(
            time: 1,
            daytime: 0,
            brightness: 1,
            pointerPosition: SIMD2<Double>(0.25, 0.75)
        )
        let prepared = pipeline
            .applyingLayerOrigins(["154": SIMD3<Double>(960, 1620, 0)])
            .addingMetalRuntimeUniforms(
                runtime,
                camera: WPEMetalCameraUniforms(
                    orthogonalProjection: WPESceneOrthogonalProjection(width: 3840, height: 2160, auto: true),
                    sceneCamera: .defaultCamera
                )
            )

        let values = prepared.layers[0].passes[0].uniformValues
        let model = values["g_ModelMatrix"]?.vectorValue
        #expect(model?[12] == 960)
        #expect(model?[13] == 1620)
    }

    @Test("Animated single shader constants clamp to final keyframe after their duration")
    func animatedSingleShaderConstantsClampToFinalKeyframe() throws {
        let animatedAlpha = try #require(Self.animatedScalarConstant(
            mode: "single",
            wrapLoop: nil,
            length: 90,
            keys: [
                (0, 1),
                (60, 1),
                (90, 0)
            ]
        ))
        let pipeline = Self.pipelineWithUniform("alpha", value: animatedAlpha)

        let prepared = pipeline.addingMetalRuntimeUniforms(
            WPEMetalRuntimeUniforms(
                time: 4,
                daytime: 0,
                brightness: 1,
                pointerPosition: SIMD2<Double>(0.5, 0.5)
            ),
            camera: .identity
        )

        #expect(prepared.layers[0].passes[0].uniformValues["alpha"]?.numberValue == 0)
    }

    @Test("Animated loop shader constants wrap by authored animation length")
    func animatedLoopShaderConstantsWrapByLength() throws {
        let animatedAlpha = try #require(Self.animatedScalarConstant(
            mode: "loop",
            wrapLoop: true,
            length: 90,
            keys: [
                (0, 0),
                (30, 1),
                (90, 0)
            ]
        ))
        let pipeline = Self.pipelineWithUniform("alpha", value: animatedAlpha)

        let prepared = pipeline.addingMetalRuntimeUniforms(
            WPEMetalRuntimeUniforms(
                time: 4,
                daytime: 0,
                brightness: 1,
                pointerPosition: SIMD2<Double>(0.5, 0.5)
            ),
            camera: .identity
        )

        #expect(prepared.layers[0].passes[0].uniformValues["alpha"]?.numberValue == 1)
    }

    private static func animatedScalarConstant(
        mode: String,
        wrapLoop: Bool?,
        length: Int,
        keys: [(frame: Int, value: Double)]
    ) -> WPESceneShaderConstantValue? {
        var options: [String: Any] = [
            "fps": 30,
            "length": length,
            "mode": mode
        ]
        options["wraploop"] = wrapLoop as Any
        return WPEValueParser.shaderConstant([
            "value": keys.first?.value ?? 0,
            "animation": [
                "c0": keys.map { key in
                    [
                        "frame": key.frame,
                        "value": key.value
                    ]
                },
                "options": options
            ]
        ])
    }

    private static func pipelineWithUniform(
        _ name: String,
        value: WPESceneShaderConstantValue
    ) -> WPEPreparedRenderPipeline {
        let pass = WPERenderPass(
            id: "opacity.0",
            phase: .effect(file: "effects/opacity/effect.json"),
            shader: "effects/opacity",
            source: .previous,
            target: .scene,
            textures: [:],
            binds: [:],
            constants: [name: value],
            combos: [:],
            blending: "normal",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )
        let layer = WPERenderLayer(
            objectID: "layer",
            objectName: "Layer",
            imagePath: "models/layer.json",
            materialPath: nil,
            geometry: .identity,
            compositeA: "a",
            compositeB: "b",
            localFBOs: [],
            passes: [pass]
        )
        return WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(
                graphLayer: layer,
                passes: [
                    WPEPreparedRenderPass(
                        pass: pass,
                        shader: WPEShaderProgram(
                            name: "effects/opacity",
                            vertexSource: "",
                            fragmentSource: "",
                            isBuiltin: true
                        ),
                        textureBindings: [:],
                        comboValues: [:],
                        uniformValues: [name: value]
                    )
                ]
            )
        ])
    }
}
