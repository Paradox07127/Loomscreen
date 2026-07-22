import LiveWallpaperProWPE
import Testing
@testable import LiveWallpaper

@Suite("WPE Metal shader dispatcher")
struct WPEMetalShaderDispatcherTests {

    @Test("Builtin shader kind raw values match the dispatch-table snapshot")
    func builtinShaderKindSnapshot() {
        let expected: Set<String> = [
            "solidcolor",
            "solidlayer",
            "copy",
            "compose",
            "effect_colorbalance",
            "effect_blur",
            "effect_vignette",
            "effect_water",
            "genericimage2",
            "genericimage4",
            "effect_opacity",
            "effect_scroll",
            "effect_pulse",
            "effect_iris",
            "effect_waterwaves",
            "effect_spin",
            "effect_tint",
            "effect_foliagesway",
            "effect_waterripple",
            "effect_blend",
            "effect_waterflow",
            "effect_color_grading",
            "effect_shimmer",
            "genericparticle",
            "effect_shake",
            "wpe_blend_composite",
        ]
        #expect(Set(WPEBuiltinShaderKind.allCases.map(\.rawValue)) == expected)
        #expect(WPEBuiltinShaderKind.allCases.count == expected.count)
    }

    @Test("Builtin shader kind raw values are normalizer fixed points")
    func builtinShaderKindRawValuesAreNormalizerFixedPoints() {
        for kind in WPEBuiltinShaderKind.allCases {
            #expect(WPEMetalShaderInputs.normalizedBuiltinShaderName(kind.rawValue) == kind.rawValue)
        }
    }

    @Test("Effect dispatch table matches the migrated-case snapshot")
    func effectDispatchTableSnapshot() {
        struct Expected {
            let fragment: String
            let quad: Bool
            var parallax: Bool = true
        }
        let expected: [WPEBuiltinShaderKind: Expected] = [
            .effectColorBalance: Expected(fragment: "wpe_effect_colorbalance_fragment", quad: false),
            .effectBlur: Expected(fragment: "wpe_effect_blur_fragment", quad: false),
            .effectVignette: Expected(fragment: "wpe_effect_vignette_fragment", quad: false),
            .effectWater: Expected(fragment: "wpe_effect_water_fragment", quad: false),
            .effectOpacity: Expected(fragment: "wpe_effect_opacity_fragment", quad: true),
            .effectScroll: Expected(fragment: "wpe_effect_scroll_fragment", quad: true),
            .effectWaterWaves: Expected(fragment: "wpe_effect_waterwaves_fragment", quad: true, parallax: false),
            .effectPulse: Expected(fragment: "wpe_effect_pulse_fragment", quad: true),
            .effectIris: Expected(fragment: "wpe_effect_iris_fragment", quad: true),
            .effectSpin: Expected(fragment: "wpe_effect_spin_fragment", quad: true),
            .effectTint: Expected(fragment: "wpe_effect_tint_fragment", quad: true),
            .effectFoliageSway: Expected(fragment: "wpe_effect_foliagesway_fragment", quad: true),
            .effectWaterRipple: Expected(fragment: "wpe_effect_waterripple_fragment", quad: true),
            .effectBlend: Expected(fragment: "wpe_effect_blend_fragment", quad: true),
            .effectWaterFlow: Expected(fragment: "wpe_effect_waterflow_fragment", quad: true),
            .effectColorGrading: Expected(fragment: "wpe_effect_color_grading_fragment", quad: true),
            .effectShimmer: Expected(fragment: "wpe_effect_shimmer_fragment", quad: true),
            .effectShake: Expected(fragment: "wpe_effect_shake_fragment", quad: true),
        ]
        #expect(Set(WPEEffectDispatchDescriptor.table.keys) == Set(expected.keys))
        let effectKinds = Set(WPEBuiltinShaderKind.allCases.filter { $0.rawValue.hasPrefix("effect_") })
        #expect(Set(expected.keys) == effectKinds)
        for (kind, entry) in expected {
            let descriptor = WPEEffectDispatchDescriptor.table[kind]
            #expect(descriptor?.kind == kind)
            #expect(descriptor?.fragmentName == entry.fragment)
            #expect(descriptor?.supportsObjectQuad == entry.quad)
            #expect(descriptor?.appliesCameraParallax == entry.parallax)
            #expect(descriptor?.fragmentName == "wpe_\(kind.rawValue)_fragment")
        }
    }

    @Test("waterFlow direction preserves the legacy two-step lookup chain")
    func waterFlowDirectionChain() {
        #expect(WPEEffectDispatchDescriptor.waterFlowDirection(
            for: effectFixturePass(shader: "effects/waterflow")
        ) == SIMD2<Float>(0, 0.1))
        #expect(WPEEffectDispatchDescriptor.waterFlowDirection(
            for: effectFixturePass(shader: "effects/waterflow", constants: ["u_Direction": .vector([0.3, 0.4])])
        ) == SIMD2<Float>(0.3, 0.4))
        #expect(WPEEffectDispatchDescriptor.waterFlowDirection(
            for: effectFixturePass(
                shader: "effects/waterflow",
                constants: ["u_Direction": .vector([9, 9])],
                uniforms: ["u_Direction": .vector([0.5, 0.6])]
            )
        ) == SIMD2<Float>(0.5, 0.6))
        #expect(WPEEffectDispatchDescriptor.waterFlowDirection(
            for: effectFixturePass(
                shader: "effects/waterflow",
                constants: ["direction": .vector([9, 9])],
                uniforms: ["direction": .vector([9, 9])]
            )
        ) == SIMD2<Float>(0, 0.1))
        #expect(WPEEffectDispatchDescriptor.waterFlowDirection(
            for: effectFixturePass(shader: "effects/waterflow", constants: ["u_Direction": .vector([0.7])])
        ) == SIMD2<Float>(0.7, 0.1))
    }

    @Test("scroll speed preserves the legacy three-step lookup chain")
    func scrollSpeedChain() {
        #expect(WPEEffectDispatchDescriptor.scrollSpeed(
            for: effectFixturePass(shader: "effects/scroll")
        ) == SIMD2<Float>(0.1, 0))
        #expect(WPEEffectDispatchDescriptor.scrollSpeed(
            for: effectFixturePass(shader: "effects/scroll", constants: ["speed": .vector([0.5, 0.2])])
        ) == SIMD2<Float>(0.5, 0.2))
        #expect(WPEEffectDispatchDescriptor.scrollSpeed(
            for: effectFixturePass(
                shader: "effects/scroll",
                constants: ["u_Speed": .vector([1, 2]), "speed": .vector([9, 9])]
            )
        ) == SIMD2<Float>(1, 2))
        #expect(WPEEffectDispatchDescriptor.scrollSpeed(
            for: effectFixturePass(
                shader: "effects/scroll",
                constants: ["u_Speed": .vector([1, 2])],
                uniforms: ["u_Speed": .vector([3, 4])]
            )
        ) == SIMD2<Float>(3, 4))
        #expect(WPEEffectDispatchDescriptor.scrollSpeed(
            for: effectFixturePass(shader: "effects/scroll", uniforms: ["speed": .vector([9, 9])])
        ) == SIMD2<Float>(0.1, 0))
        #expect(WPEEffectDispatchDescriptor.scrollSpeed(
            for: effectFixturePass(shader: "effects/scroll", constants: ["u_Speed": .vector([0.7])])
        ) == SIMD2<Float>(0.7, 0))
    }

    @Test("opacity/waterwaves mask reference preserves the legacy slot-1 chain")
    func opacityMaskReferenceChain() {
        #expect(WPEEffectDispatchDescriptor.opacityMaskReference(
            for: effectFixturePass(shader: "effects/opacity")
        ) == nil)
        #expect(WPEEffectDispatchDescriptor.opacityMaskReference(
            for: effectFixturePass(shader: "effects/opacity", binds: [1: .asset("masks/a.tex")])
        ) == .asset("masks/a.tex"))
        #expect(WPEEffectDispatchDescriptor.opacityMaskReference(
            for: effectFixturePass(
                shader: "effects/opacity",
                textures: [1: .asset("masks/tex.tex")],
                binds: [1: .asset("masks/bind.tex")]
            )
        ) == .asset("masks/tex.tex"))
        #expect(WPEEffectDispatchDescriptor.opacityMaskReference(
            for: effectFixturePass(
                shader: "effects/opacity",
                textures: [1: .asset("masks/tex.tex")],
                binds: [1: .asset("masks/bind.tex")],
                bindings: [1: .asset("masks/binding.tex")]
            )
        ) == .asset("masks/binding.tex"))
        #expect(WPEEffectDispatchDescriptor.opacityMaskReference(
            for: effectFixturePass(shader: "effects/opacity", textures: [0: .asset("masks/zero.tex")])
        ) == nil)
    }

    @Test("colorGrading preserves the legacy uniformValues-only lookup")
    func colorGradingLookupGap() {
        let authoredOnly = WPEEffectDispatchDescriptor.colorGradingUniforms(
            for: effectFixturePass(
                shader: "effects/colorgrading",
                constants: [
                    "u_Lift": .vector([0.5, 0.5, 0.5, 0.5]),
                    "u_Gamma": .vector([2, 2, 2, 2]),
                    "u_Gain": .vector([3, 3, 3, 3]),
                ]
            )
        )
        #expect(authoredOnly.lift == SIMD4<Float>(0, 0, 0, 0))
        #expect(authoredOnly.gamma == SIMD4<Float>(1, 1, 1, 1))
        #expect(authoredOnly.gain == SIMD4<Float>(1, 1, 1, 1))
        let runtime = WPEEffectDispatchDescriptor.colorGradingUniforms(
            for: effectFixturePass(
                shader: "effects/colorgrading",
                uniforms: ["u_Gain": .vector([2, 2, 2, 2])]
            )
        )
        #expect(runtime.gain == SIMD4<Float>(2, 2, 2, 2))
        #expect(runtime.lift == SIMD4<Float>(0, 0, 0, 0))
        let short = WPEEffectDispatchDescriptor.colorGradingUniforms(
            for: effectFixturePass(
                shader: "effects/colorgrading",
                uniforms: ["u_Gamma": .vector([2])]
            )
        )
        #expect(short.gamma == SIMD4<Float>(2, 1, 1, 1))
    }
}

private func effectFixturePass(
    shader: String,
    constants: [String: WPESceneShaderConstantValue] = [:],
    uniforms: [String: WPESceneShaderConstantValue] = [:],
    textures: [Int: WPETextureReference] = [:],
    binds: [Int: WPETextureReference] = [:],
    bindings: [Int: WPETextureReference] = [:]
) -> WPEPreparedRenderPass {
    WPEPreparedRenderPass(
        pass: WPERenderPass(
            id: "fx.0",
            phase: .effect(file: "effects/fixture/effect.json"),
            shader: shader,
            source: .previous,
            target: .layerComposite(name: "_rt_imageLayerComposite_fx_a"),
            textures: textures,
            binds: binds,
            constants: constants,
            combos: [:],
            blending: "normal",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        ),
        shader: WPEShaderProgram(name: shader, vertexSource: "", fragmentSource: "", isBuiltin: true),
        textureBindings: bindings,
        comboValues: [:],
        uniformValues: uniforms
    )
}
