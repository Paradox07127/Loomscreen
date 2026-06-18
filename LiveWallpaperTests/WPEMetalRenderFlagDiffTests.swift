#if !LITE_BUILD
#if DEBUG
import Foundation
import Testing
@testable import LiveWallpaper

/// On-device pixel-diff gate for the output-invariant render flags
/// (`WPEMetalFBOAliasingEnabled`, `WPEMetalShaderPrewarmEnabled`).
///
/// OPT-IN + SLOW + machine-local: it renders the whole local Workshop corpus several
/// times, so it is gated behind a UserDefault and skips cleanly when no corpus is
/// configured. Serialized so the two runs never fight over the global flag
/// UserDefaults or the GPU.
///
/// Enable, run, then clean up (the gate is read from the app's own preference domain,
/// the same one every other `defaults write Taijia.LiveWallpaper …` flag uses — a CLI
/// env var does NOT reach the test-host process):
///   defaults write Taijia.LiveWallpaper WPERunCorpusDiff -bool YES
///   xcodebuild test -scheme LiveWallpaper -destination 'platform=macOS' \
///     -only-testing:LiveWallpaperTests/WPEMetalRenderFlagDiffTests
///   defaults delete Taijia.LiveWallpaper WPERunCorpusDiff
@Suite(.serialized)
@MainActor
struct WPEMetalRenderFlagDiffTests {
    /// Gate. UserDefault is the reliable trigger (matches the project's flag
    /// convention); the env var is a fallback for harnesses that can inject it.
    private nonisolated static var enabled: Bool {
        UserDefaults.standard.bool(forKey: "WPERunCorpusDiff")
            || ProcessInfo.processInfo.environment["WPE_CORPUS_DIFF"] == "1"
    }

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
        // The test host has no Workshop library bookmark (that security-scoped
        // bookmark lives only in the real app session), so this test usually finds
        // an empty corpus and no-ops — the in-app Developer Tools "render-flag pixel
        // diff" button is the real path. Skip cleanly rather than red-fail.
        guard !baselineA.isEmpty else {
            Logger.notice("[flag-diff] no corpus in test host — run the Developer Tools button instead", category: .performance)
            return
        }

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
