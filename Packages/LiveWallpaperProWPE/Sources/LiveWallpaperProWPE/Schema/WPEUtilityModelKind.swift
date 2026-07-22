import Foundation
import os

/// Classifies WPE scene-capture utility models shared by graph construction and render execution.
/// Solid-layer utility materials are classified separately by the graph builder.
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

    /// Returns whether the path identifies any scene-capture utility model.
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
