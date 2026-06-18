#if !LITE_BUILD
#if DEBUG
import Foundation
import Testing
@testable import LiveWallpaper

/// On-device pixel-diff gate for the output-invariant render flags
/// (`WPEMetalFBOAliasingEnabled`, `WPEMetalShaderPrewarmEnabled`).
///
/// OPT-IN + SLOW + machine-local: it renders the whole local Workshop corpus several
/// times, so it is disabled unless `WPE_CORPUS_DIFF=1` is set, and skips cleanly when
/// no corpus is configured. Serialized so the two runs never fight over the global
/// flag UserDefaults or the GPU.
///
/// Run it with:
///   WPE_CORPUS_DIFF=1 xcodebuild test -scheme LiveWallpaper -destination 'platform=macOS' \
///     -only-testing:LiveWallpaperTests/WPEMetalRenderFlagDiffTests
@Suite(.serialized)
@MainActor
struct WPEMetalRenderFlagDiffTests {
    private nonisolated static var enabled: Bool { ProcessInfo.processInfo.environment["WPE_CORPUS_DIFF"] == "1" }

    private static let baseline = WPEMetalRenderFlagDiff.FlagConfig(label: "baseline(off,off)", aliasing: false, prewarm: false)
    private static let aliasingOnly = WPEMetalRenderFlagDiff.FlagConfig(label: "aliasing(on)", aliasing: true, prewarm: false)
    private static let prewarmOnly = WPEMetalRenderFlagDiff.FlagConfig(label: "prewarm(on)", aliasing: false, prewarm: true)
    private static let bothOn = WPEMetalRenderFlagDiff.FlagConfig(label: "both(on,on)", aliasing: true, prewarm: true)

    /// One pass over the corpus per config (5 total): a determinism calibration plus
    /// each flag isolated and combined, all diffed against the same baseline. Every
    /// comparison must be pixel-identical for the flags to be safe to default on.
    @Test(.enabled(if: WPEMetalRenderFlagDiffTests.enabled))
    func corpusIsPixelIdenticalAcrossFlags() async throws {
        let baselineA = await WPEMetalRenderFlagDiff.captureCorpus(Self.baseline)
        try #require(!baselineA.isEmpty, "No Workshop corpus on this machine — set the library root in the app first.")

        // Determinism calibration: the gate is only meaningful if the SAME config
        // renders byte-identical twice. If this fails, every other result is noise.
        let baselineB = await WPEMetalRenderFlagDiff.captureCorpus(Self.baseline)
        let determinism = WPEMetalRenderFlagDiff.compare(
            baseline: baselineA, variant: baselineB,
            baselineLabel: "baseline#1", variantLabel: "baseline#2"
        )
        determinism.log()

        let aliasing = WPEMetalRenderFlagDiff.compare(
            baseline: baselineA, variant: await WPEMetalRenderFlagDiff.captureCorpus(Self.aliasingOnly),
            baselineLabel: Self.baseline.label, variantLabel: Self.aliasingOnly.label
        )
        aliasing.log()

        let prewarm = WPEMetalRenderFlagDiff.compare(
            baseline: baselineA, variant: await WPEMetalRenderFlagDiff.captureCorpus(Self.prewarmOnly),
            baselineLabel: Self.baseline.label, variantLabel: Self.prewarmOnly.label
        )
        prewarm.log()

        let both = WPEMetalRenderFlagDiff.compare(
            baseline: baselineA, variant: await WPEMetalRenderFlagDiff.captureCorpus(Self.bothOn),
            baselineLabel: Self.baseline.label, variantLabel: Self.bothOn.label
        )
        both.log()

        #expect(determinism.passed, "Renderer is NON-deterministic — hash gate unreliable until 0:\n\(determinism.divergenceLog)")
        #expect(aliasing.passed, "FBO aliasing changed pixels:\n\(aliasing.divergenceLog)")
        #expect(prewarm.passed, "Shader prewarm changed pixels:\n\(prewarm.divergenceLog)")
        #expect(both.passed, "Both flags together changed pixels:\n\(both.divergenceLog)")
    }
}
#endif
#endif
