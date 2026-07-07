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
}
