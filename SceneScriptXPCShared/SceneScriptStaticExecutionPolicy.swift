import Foundation

/// Canonical static-resolvability gate shared by the parser and the independently compiled XPC worker.
/// The worker revalidates each batch because the process boundary is untrusted.
enum SceneScriptStaticExecutionPolicy {
    /// Dynamic markers are case-sensitive because a case-insensitive `Date` check also matches `update`.
    static let dynamicTokens = [
        "getTimeOfDay", "engine.runtime", "frametime", "frameTime", "getTime", "Date",
        "Math.random", "getFrequency", "getFrequencies", "audio", "elapsed",
        "input.cursorWorldPosition", "shared.", "shared["
    ]

    /// Loop and evaluation forms are rejected to keep static JavaScriptCore evaluation bounded.
    static let blocklistPatterns = [
        #"\bwhile\s*\("#,
        #"\bfor\s*\("#,
        #"\bdo\s*\{"#,
        #"\beval\s*\("#,
        #"\bFunction\s*\("#
    ]

    static func isStaticallyResolvable(_ script: String) -> Bool {
        guard !dynamicTokens.contains(where: script.contains) else { return false }
        return !blocklistPatterns.contains {
            script.range(of: $0, options: .regularExpression) != nil
        }
    }
}
