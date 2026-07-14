import Foundation
import os

/// Canonical classifier for WPE's three `models/util/*.json` scene-capture
/// utility models — `composelayer`, `projectlayer`, `fullscreenlayer` — the
/// placeholder geometries WPE uses to host full-frame post-process effects,
/// projections, and layer groups. Single source of truth shared by the graph
/// builder (Infrastructure) and the executor/dispatcher/target pool (Runtime) —
/// both import this Schema package, so neither crosses the Infra↔Runtime
/// boundary. Previously hand-copied in both places (ADR-001 B1: a drift between
/// the two copies causes PiP or fullscreen mis-capture regressions). Does NOT
/// cover `models/util/solidlayer[_depthtest].json` — that is a separate,
/// GraphBuilder-only builtin-material classification with a narrower normalizer.
public enum WPEUtilityModelKind: String, CaseIterable, Equatable, Sendable {
    case composeLayer = "composelayer"
    case projectLayer = "projectlayer"
    case fullScreenLayer = "fullscreenlayer"

    /// WPE authors these paths with a leading `../<dependencyID>/` resolver
    /// prefix, `\`-separated Windows paths, and inconsistent case. Tolerates
    /// all three; matches on the trailing `models/util/<name>.json`.
    public static func classify(_ path: String) -> WPEUtilityModelKind? {
        let stripped = strippedPath(path)
        for kind in allCases where stripped == "models/util/\(kind.rawValue).json" {
            return kind
        }
        return nil
    }

    /// True for any of the three, regardless of which — the executor/
    /// dispatcher/target-pool "is this a scene-capture utility layer at all"
    /// gate before asking which kind for geometry purposes.
    public static func isUtilityModelPath(_ path: String) -> Bool {
        classify(path) != nil
    }

    // MARK: - Normalization (memoized: measured 2.3–2.8% of one core on the
    // executor's per-pass hot path before caching; paths are load-time
    // invariant so this is safe to share across both call sites).

    private static let cache = OSAllocatedUnfairLock(initialState: [String: String]())
    private static let cacheLimit = 512

    private static func strippedPath(_ path: String) -> String {
        cache.withLock { cache in
            if let cached = cache[path] { return cached }
            let result = computeStrippedPath(path)
            if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
            cache[path] = result
            return result
        }
    }

    private static func computeStrippedPath(_ path: String) -> String {
        let normalized = path.replacingOccurrences(of: "\\", with: "/").lowercased()
        guard normalized.hasPrefix("../") else { return normalized }
        let parts = normalized.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count >= 3 ? parts.dropFirst(2).joined(separator: "/") : normalized
    }
}
