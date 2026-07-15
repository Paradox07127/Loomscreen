import Testing
@testable import LiveWallpaper

@Suite("WPE Metal shader dispatcher")
struct WPEMetalShaderDispatcherTests {

    /// ADR-001 step 0 drift guard: the typed dispatch table must stay in exact
    /// sync with the builtin cases the legacy string switch handled. Adding or
    /// removing a builtin requires updating the enum, this snapshot, and the
    /// slot-contract doc on `WPEMetalShaderDispatcher`.
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

    /// Every raw value must be a fixed point of the builtin-name normalizer,
    /// otherwise its switch case would be unreachable from `dispatch`.
    @Test("Builtin shader kind raw values are normalizer fixed points")
    func builtinShaderKindRawValuesAreNormalizerFixedPoints() {
        for kind in WPEBuiltinShaderKind.allCases {
            #expect(WPEMetalShaderInputs.normalizedBuiltinShaderName(kind.rawValue) == kind.rawValue)
        }
    }

    /// ADR-001 B2 drift guard: the effect dispatch table's keys must exactly
    /// match the set of kinds the dispatcher switch routes through
    /// `dispatchEffect` (this is what makes the switch's force-unwrap safe),
    /// and each entry's literals are pinned against the legacy switch bodies.
    /// `supportsObjectQuad == false` is load-bearing data for exactly the four
    /// pre-Phase-2D-E effects that never routed through the object quad;
    /// `appliesCameraParallax == false` is load-bearing for waterwaves only.
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
        // Terminal-state exhaustiveness (B2 complete): every effect_* builtin
        // kind is table-migrated — the switch keeps only the compose/image/
        // particle families as code paths.
        let effectKinds = Set(WPEBuiltinShaderKind.allCases.filter { $0.rawValue.hasPrefix("effect_") })
        #expect(Set(expected.keys) == effectKinds)
        for (kind, entry) in expected {
            let descriptor = WPEEffectDispatchDescriptor.table[kind]
            #expect(descriptor?.kind == kind)
            #expect(descriptor?.fragmentName == entry.fragment)
            #expect(descriptor?.supportsObjectQuad == entry.quad)
            #expect(descriptor?.appliesCameraParallax == entry.parallax)
            // Convention check (informational lock): every builtin effect
            // fragment today is `wpe_<rawValue>_fragment`. The descriptor still
            // stores the literal; an intentional future irregular name updates
            // this test, not a string-concat call site.
            #expect(descriptor?.fragmentName == "wpe_\(kind.rawValue)_fragment")
        }
    }

    /// B2 pixel invariant: effect_waterflow's `u_Direction` lookup consults
    /// ONLY the exact-case `u_Direction` key (runtime values → authored
    /// constants) — a lowercase `direction` key is ignored entirely, unlike
    /// the standard `floatScalar(named:)` chains. Locked verbatim.
    @Test("waterFlow direction preserves the legacy two-step lookup chain")
    func waterFlowDirectionChain() {
        // Absent everywhere → legacy default (0, 0.1).
        #expect(WPEEffectDispatchDescriptor.waterFlowDirection(
            for: effectFixturePass(shader: "effects/waterflow")
        ) == SIMD2<Float>(0, 0.1))
        // Authored constants are honored.
        #expect(WPEEffectDispatchDescriptor.waterFlowDirection(
            for: effectFixturePass(shader: "effects/waterflow", constants: ["u_Direction": .vector([0.3, 0.4])])
        ) == SIMD2<Float>(0.3, 0.4))
        // Runtime uniform values win over authored constants.
        #expect(WPEEffectDispatchDescriptor.waterFlowDirection(
            for: effectFixturePass(
                shader: "effects/waterflow",
                constants: ["u_Direction": .vector([9, 9])],
                uniforms: ["u_Direction": .vector([0.5, 0.6])]
            )
        ) == SIMD2<Float>(0.5, 0.6))
        // Lowercase `direction` is NOT part of this chain (the legacy gap).
        #expect(WPEEffectDispatchDescriptor.waterFlowDirection(
            for: effectFixturePass(
                shader: "effects/waterflow",
                constants: ["direction": .vector([9, 9])],
                uniforms: ["direction": .vector([9, 9])]
            )
        ) == SIMD2<Float>(0, 0.1))
        // Single-component vector: y falls back to the legacy 0.1.
        #expect(WPEEffectDispatchDescriptor.waterFlowDirection(
            for: effectFixturePass(shader: "effects/waterflow", constants: ["u_Direction": .vector([0.7])])
        ) == SIMD2<Float>(0.7, 0.1))
    }

    /// B2 pixel invariant: effect_scroll's `u_Speed` lookup is the legacy
    /// three-step chain — runtime `u_Speed` → authored `u_Speed` → authored
    /// lowercase `speed`. A lowercase `speed` in the RUNTIME values is ignored
    /// (it only counts in authored constants). Locked verbatim.
    @Test("scroll speed preserves the legacy three-step lookup chain")
    func scrollSpeedChain() {
        // Absent everywhere → legacy default (0.1, 0).
        #expect(WPEEffectDispatchDescriptor.scrollSpeed(
            for: effectFixturePass(shader: "effects/scroll")
        ) == SIMD2<Float>(0.1, 0))
        // Third step: authored lowercase `speed`.
        #expect(WPEEffectDispatchDescriptor.scrollSpeed(
            for: effectFixturePass(shader: "effects/scroll", constants: ["speed": .vector([0.5, 0.2])])
        ) == SIMD2<Float>(0.5, 0.2))
        // Second step beats third: authored `u_Speed` over authored `speed`.
        #expect(WPEEffectDispatchDescriptor.scrollSpeed(
            for: effectFixturePass(
                shader: "effects/scroll",
                constants: ["u_Speed": .vector([1, 2]), "speed": .vector([9, 9])]
            )
        ) == SIMD2<Float>(1, 2))
        // First step beats second: runtime `u_Speed` over authored `u_Speed`.
        #expect(WPEEffectDispatchDescriptor.scrollSpeed(
            for: effectFixturePass(
                shader: "effects/scroll",
                constants: ["u_Speed": .vector([1, 2])],
                uniforms: ["u_Speed": .vector([3, 4])]
            )
        ) == SIMD2<Float>(3, 4))
        // Runtime lowercase `speed` is NOT part of the chain (the legacy gap).
        #expect(WPEEffectDispatchDescriptor.scrollSpeed(
            for: effectFixturePass(shader: "effects/scroll", uniforms: ["speed": .vector([9, 9])])
        ) == SIMD2<Float>(0.1, 0))
        // Single-component vector: y falls back to the legacy 0.
        #expect(WPEEffectDispatchDescriptor.scrollSpeed(
            for: effectFixturePass(shader: "effects/scroll", constants: ["u_Speed": .vector([0.7])])
        ) == SIMD2<Float>(0.7, 0))
    }

    /// B2 pixel invariant: the slot-1 opacity-mask chain (effect_opacity +
    /// effect_waterwaves) is `textureBindings[1] ?? textures[1] ?? binds[1]`,
    /// with `binds` LAST — the reverse of the custom-shader slot chain. `nil`
    /// drives has-mask = 0 with the source rebound at slot 1.
    @Test("opacity/waterwaves mask reference preserves the legacy slot-1 chain")
    func opacityMaskReferenceChain() {
        // Absent everywhere → nil (has-mask cleared downstream).
        #expect(WPEEffectDispatchDescriptor.opacityMaskReference(
            for: effectFixturePass(shader: "effects/opacity")
        ) == nil)
        // binds-only still yields a mask (the third step).
        #expect(WPEEffectDispatchDescriptor.opacityMaskReference(
            for: effectFixturePass(shader: "effects/opacity", binds: [1: .asset("masks/a.tex")])
        ) == .asset("masks/a.tex"))
        // Authored textures beat binds.
        #expect(WPEEffectDispatchDescriptor.opacityMaskReference(
            for: effectFixturePass(
                shader: "effects/opacity",
                textures: [1: .asset("masks/tex.tex")],
                binds: [1: .asset("masks/bind.tex")]
            )
        ) == .asset("masks/tex.tex"))
        // The pipeline-builder's normalized bindings beat both.
        #expect(WPEEffectDispatchDescriptor.opacityMaskReference(
            for: effectFixturePass(
                shader: "effects/opacity",
                textures: [1: .asset("masks/tex.tex")],
                binds: [1: .asset("masks/bind.tex")],
                bindings: [1: .asset("masks/binding.tex")]
            )
        ) == .asset("masks/binding.tex"))
        // Slot 0 never leaks into the mask slot.
        #expect(WPEEffectDispatchDescriptor.opacityMaskReference(
            for: effectFixturePass(shader: "effects/opacity", textures: [0: .asset("masks/zero.tex")])
        ) == nil)
    }

    /// B2 pixel invariant: effect_color_grading reads ONLY runtime
    /// `uniformValues` — authored `constants` are ignored (the legacy gap vs
    /// the standard priority chain). Locked verbatim, including per-component
    /// fallbacks for short vectors.
    @Test("colorGrading preserves the legacy uniformValues-only lookup")
    func colorGradingLookupGap() {
        // Authored constants alone are IGNORED → identity fallbacks.
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
        // Runtime values are honored.
        let runtime = WPEEffectDispatchDescriptor.colorGradingUniforms(
            for: effectFixturePass(
                shader: "effects/colorgrading",
                uniforms: ["u_Gain": .vector([2, 2, 2, 2])]
            )
        )
        #expect(runtime.gain == SIMD4<Float>(2, 2, 2, 2))
        #expect(runtime.lift == SIMD4<Float>(0, 0, 0, 0))
        // Short vector: missing components fall back per-component.
        let short = WPEEffectDispatchDescriptor.colorGradingUniforms(
            for: effectFixturePass(
                shader: "effects/colorgrading",
                uniforms: ["u_Gamma": .vector([2])]
            )
        )
        #expect(short.gamma == SIMD4<Float>(2, 1, 1, 1))
    }
}

/// Minimal effect-pass fixture for value-resolution chain tests (no Metal).
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
