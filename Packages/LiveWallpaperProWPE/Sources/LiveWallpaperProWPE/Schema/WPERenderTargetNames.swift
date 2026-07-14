import Foundation

/// Canonical constructors/parsers/classifiers for the renderer's four internal
/// `_rt_*` render-target name families. These names are cross-file, character-
/// exact contracts (graph builder emits, executor/pool judge and reverse-parse);
/// they were previously built from scattered string literals in both layers —
/// ADR-001 B1 appendix A#54 / C#93–95. Name FORMATS are frozen: every function
/// body here is a verbatim move of the pre-existing construction, never a
/// redesign.
public enum WPERenderTargetNames {

    /// `_rt_imageLayerComposite_<objectID>_{a,b}` / `_rt_createdLayerComposite_<key>_{a,b}` pair.
    public struct CompositePair: Equatable, Sendable {
        public let a: String
        public let b: String
    }

    /// `_rt_puppetClip_<objectID>` — puppet clip-mask RT injected by the graph
    /// builder (slot 8) and detected by the executor with exact-equality.
    public enum PuppetClip {
        private static let prefix = "_rt_puppetClip_"

        public static func make(objectID: String) -> String { "\(prefix)\(objectID)" }

        /// index == 0 is the base name; index > 0 is the `<base>_s<index>` derived
        /// source (multi-light clipping, e.g. both eyes). Takes the caller's
        /// existing `base` verbatim — the executor's real data flow is
        /// `plan.clipTargetName` (from the bound texture reference), not a fresh
        /// objectID-derived name.
        public static func makeSource(base: String, index: Int) -> String {
            index == 0 ? base : "\(base)_s\(index)"
        }

        /// Reverse of `makeSource` for the pool's scale/format inheritance: only a
        /// genuine `<base>_s<N>` derived name returns its base; the base name (or
        /// anything else) returns nil so callers keep their `?? name` fallback.
        public static func baseName(of name: String) -> String? {
            guard name.hasPrefix(prefix),
                  let suffixStart = name.range(of: "_s", options: .backwards)?.lowerBound else {
                return nil
            }
            let suffix = name[name.index(suffixStart, offsetBy: 2)...]
            guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else { return nil }
            let base = String(name[..<suffixStart])
            return base.count > prefix.count ? base : nil
        }
    }

    /// `_rt_imageLayerComposite_<objectID>_{a,b}` — a layer's ping-pong composite
    /// pair. The bare `_rt_imageLayerComposite` (no suffix) is a SCENE ALIAS
    /// (`WPETextureReference.isSceneAliasName`), not a member of this family:
    /// `layerID` requires the `_a`/`_b` suffix so the two vocabularies stay
    /// disjoint by construction.
    public enum ImageLayerComposite {
        private static let prefix = "_rt_imageLayerComposite_"

        public static func make(objectID: String) -> CompositePair {
            CompositePair(a: "\(prefix)\(objectID)_a", b: "\(prefix)\(objectID)_b")
        }

        /// Reverse-parse for the graph builder's cross-layer topological sort.
        public static func layerID(from name: String) -> String? {
            guard name.hasPrefix(prefix), name.hasSuffix("_a") || name.hasSuffix("_b") else {
                return nil
            }
            let start = name.index(name.startIndex, offsetBy: prefix.count)
            let end = name.index(name.endIndex, offsetBy: -2)
            guard start < end else { return nil }
            return String(name[start..<end])
        }
    }

    /// `_rt_layerGroup_<objectID>` — composelayer group buffer. Prefix-matched by
    /// the executor (hidden-child skip + `.load` group accumulation).
    public enum LayerGroup {
        private static let prefix = "_rt_layerGroup_"
        public static func make(objectID: String) -> String { "\(prefix)\(objectID)" }
        public static func matches(_ name: String) -> Bool { name.hasPrefix(prefix) }
    }

    /// `_rt_createdLayerComposite_<key>_{a,b}` — script-created layers' runtime
    /// ping-pong pair. Deliberately NO `layerID(from:)`: created layers never
    /// enter the graph builder's static topological sort, so this family's
    /// vocabulary must stay disjoint from `ImageLayerComposite`'s reverse-parse.
    public enum CreatedLayerComposite {
        private static let prefix = "_rt_createdLayerComposite_"
        public static func make(key: String) -> CompositePair {
            CompositePair(a: "\(prefix)\(key)_a", b: "\(prefix)\(key)_b")
        }
    }
}
