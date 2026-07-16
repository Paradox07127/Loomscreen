import Foundation

/// Canonical static-resolvability gate for SceneScript transform origins.
///
/// The same rule is enforced in two independently-compiled places on purpose:
/// the parser package (`WPETransformScriptStaticAnalysis`) admits candidates at
/// bake/dispatch time, and the XPC worker re-validates every batch because it
/// must never trust the client across the process boundary. Keeping the token
/// and pattern lists here — compiled into both the app and the helper from one
/// source — lets a test assert the two gates never drift; a drift would make the
/// worker reject items the client already accepted, silently falling the whole
/// batch back to baked values.
enum SceneScriptStaticExecutionPolicy {
    /// Markers that make a transform time/audio/random-driven and thus not
    /// statically resolvable. CASE-SENSITIVE on purpose — `update` contains a
    /// lowercase "date", so a case-insensitive `Date` check would wrongly
    /// classify every origin script as dynamic.
    static let dynamicTokens = [
        "getTimeOfDay", "engine.runtime", "frametime", "frameTime", "getTime", "Date",
        "Math.random", "getFrequency", "getFrequencies", "audio", "elapsed",
        "input.cursorWorldPosition", "shared.", "shared["
    ]

    /// Loop/eval forms are rejected conservatively: at parse time a hung
    /// JSContext is worse than falling back to the baked value.
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
