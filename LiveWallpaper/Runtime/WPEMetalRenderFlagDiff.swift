#if !LITE_BUILD
#if DEBUG
import Foundation

/// Pixel-diff gate for output-INVARIANT render-flag optimizations — currently FBO
/// placement-heap aliasing (`WPEMetalFBOAliasingEnabled`) and the shader-transpile
/// prewarm (`WPEMetalShaderPrewarmEnabled`). Both are pure scheduling/memory
/// optimizations that must NOT change a single pixel, so the gate renders the whole
/// local Workshop corpus under two flag configs (via `WPECorpusPlaybackHarness` with
/// content-hashing on) and compares each scene's first-frame SHA256.
///
/// Any hash mismatch is a real divergence — an FBO lifetime that aliased too early, or
/// a transpile cache key that diverged — and blocks defaulting the flag on. Always run
/// a baseline-vs-baseline pass first: the gate is only trustworthy if the renderer is
/// deterministic (identical hashes for the same config twice).
@MainActor
enum WPEMetalRenderFlagDiff {
    struct FlagConfig: Sendable {
        var label: String
        var aliasing: Bool
        var prewarm: Bool
    }

    struct SceneDigest: Sendable {
        let workshopID: String
        let title: String
        let outcome: String
        let contentHash: String?
        let visual: String?
    }

    struct Divergence: Sendable, CustomStringConvertible {
        let workshopID: String
        let title: String
        let kind: String
        let detail: String
        var description: String { "[\(kind)] \(workshopID) \"\(title)\" — \(detail)" }
    }

    struct ComparisonReport: Sendable {
        let baselineLabel: String
        let variantLabel: String
        let comparedScenes: Int
        let identical: Int
        let divergences: [Divergence]

        var passed: Bool { divergences.isEmpty }

        var summaryLine: String {
            "[flag-diff] \(baselineLabel) vs \(variantLabel): \(identical)/\(comparedScenes) pixel-identical, "
                + "\(divergences.count) divergent → \(passed ? "PASS ✅" : "FAIL ❌")"
        }

        var divergenceLog: String {
            divergences.isEmpty ? "(no divergences)" : divergences.map(\.description).joined(separator: "\n")
        }

        func log() {
            Logger.notice(summaryLine, category: .performance)
            for divergence in divergences.prefix(60) {
                Logger.notice("  \(divergence.description)", category: .performance)
            }
        }
    }

    /// Render the whole corpus under `config` and return a first-frame digest per
    /// workshop ID. Forces both flags via `UserDefaults` for the duration (each scene
    /// load reads them fresh), restoring the prior values afterward.
    static func captureCorpus(
        _ config: FlagConfig,
        timeoutSeconds: Double = 8,
        workshopIDFilter: Set<String>? = nil,
        progress: @escaping @MainActor (WPECorpusPlaybackHarness.Progress) -> Void = { _ in }
    ) async -> [String: SceneDigest] {
        let defaults = UserDefaults.standard
        let aliasKey = WPEMetalRenderTargetPool.fboAliasingDefaultsKey
        let prewarmKey = WPEMetalRenderExecutor.shaderPrewarmDefaultsKey
        let priorAlias = defaults.object(forKey: aliasKey)
        let priorPrewarm = defaults.object(forKey: prewarmKey)
        defaults.set(config.aliasing, forKey: aliasKey)
        defaults.set(config.prewarm, forKey: prewarmKey)
        defer {
            if let priorAlias { defaults.set(priorAlias, forKey: aliasKey) } else { defaults.removeObject(forKey: aliasKey) }
            if let priorPrewarm { defaults.set(priorPrewarm, forKey: prewarmKey) } else { defaults.removeObject(forKey: prewarmKey) }
        }

        var harnessConfig = WPECorpusPlaybackHarness.Configuration()
        harnessConfig.perSceneTimeoutSeconds = timeoutSeconds
        harnessConfig.captureContentHash = true
        harnessConfig.useDeterministicInputs = true  // pinned clock (t=0) + centered pointer
        harnessConfig.workshopIDFilter = workshopIDFilter
        let harness = WPECorpusPlaybackHarness(configuration: harnessConfig)

        var captured: WPECorpusPlaybackReport?
        await harness.run(
            progress: { event in
                switch event {
                case .finished(let report), .cancelled(let report):
                    captured = report
                default:
                    break
                }
                progress(event)
            },
            isCancelled: { false }
        )

        guard let report = captured else { return [:] }
        var digests: [String: SceneDigest] = [:]
        digests.reserveCapacity(report.entries.count)
        for entry in report.entries {
            digests[entry.workshopID] = SceneDigest(
                workshopID: entry.workshopID,
                title: entry.title,
                outcome: entry.result.rawValue,
                contentHash: entry.visual?.contentHash,
                visual: entry.visual?.oneLine
            )
        }
        return digests
    }

    /// Compare a variant capture against a baseline capture, scene by scene. Pixel
    /// hashes are only compared for scenes that PASSED in both configs; an outcome
    /// flip (pass↔fail/timeout) is itself a divergence.
    static func compare(
        baseline: [String: SceneDigest],
        variant: [String: SceneDigest],
        baselineLabel: String,
        variantLabel: String
    ) -> ComparisonReport {
        var divergences: [Divergence] = []
        var identical = 0
        var compared = 0

        for (id, base) in baseline.sorted(by: { $0.key < $1.key }) {
            guard let other = variant[id] else {
                divergences.append(Divergence(
                    workshopID: id, title: base.title, kind: "missing-in-variant",
                    detail: "scanned in \(baselineLabel) but absent in \(variantLabel)"
                ))
                continue
            }
            compared += 1
            if base.outcome != other.outcome {
                divergences.append(Divergence(
                    workshopID: id, title: base.title, kind: "outcome-changed",
                    detail: "\(baselineLabel)=\(base.outcome) → \(variantLabel)=\(other.outcome)"
                ))
                continue
            }
            // Only pixel-compare scenes that actually rendered in both configs.
            guard base.outcome == "pass" else { identical += 1; continue }
            switch (base.contentHash, other.contentHash) {
            case let (lhs?, rhs?) where lhs == rhs:
                identical += 1
            case let (lhs?, rhs?):
                divergences.append(Divergence(
                    workshopID: id, title: base.title, kind: "pixels-differ",
                    detail: "hash \(lhs.prefix(10))… ≠ \(rhs.prefix(10))… | base \(base.visual ?? "?") | variant \(other.visual ?? "?")"
                ))
            default:
                divergences.append(Divergence(
                    workshopID: id, title: base.title, kind: "no-hash",
                    detail: "passed but no first-frame readback — cannot gate this scene"
                ))
            }
        }

        return ComparisonReport(
            baselineLabel: baselineLabel,
            variantLabel: variantLabel,
            comparedScenes: compared,
            identical: identical,
            divergences: divergences
        )
    }
}
#endif
#endif
