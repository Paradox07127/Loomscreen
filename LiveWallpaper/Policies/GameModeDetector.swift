import AppKit
import Foundation

/// Lightweight gate that flags "user is gaming" so the policy engine can
/// suspend wallpaper rendering and let the active game claim the GPU.
///
/// macOS Game Mode itself has no public query API, but Apple documents its
/// trigger: it activates when the **frontmost app declares a game
/// `LSApplicationCategoryType`** and goes full-screen. We detect that same
/// category signal — which, unlike a launcher bundle-ID allowlist, keeps
/// matching after Steam/Epic/Battle.net hand off to the actual game
/// executable (the game declares `public.app-category.*games`). The
/// full-screen half of Apple's condition is intentionally *not* required
/// here so a windowed game still yields; `pauseOnFullScreen` covers the
/// full-screen overlap independently.
///
/// Signals merged (any → active):
/// - Frontmost app's `LSApplicationCategoryType` is a game category.
/// - Frontmost app matches a known launcher prefix (fast path for when the
///   launcher itself — not yet a game category — is in front).
/// - `ProcessInfo.isLowPowerModeEnabled` — the explicit system power-saving
///   toggle, treated as a request to yield GPU/decoder work.
@MainActor
enum GameModeDetector {
    static var isActive: Bool {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return true }
        return frontmostAppIsGame()
    }

    private static let knownGameBundlePrefixes: [String] = [
        "com.valvesoftware.steam",
        "com.epicgames",
        "com.blizzard",
        "com.riotgames",
        "com.ea.",
        "com.ubisoft.",
    ]

    private static func frontmostAppIsGame() -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return false }
        if let bundleID = frontmost.bundleIdentifier,
           knownGameBundlePrefixes.contains(where: { bundleID.hasPrefix($0) }) {
            return true
        }
        return isGameCategory(frontmost)
    }

    /// Reads the frontmost app's declared App Store category from its bundle.
    /// Game categories are `public.app-category.games` plus the genre variants
    /// (`action-games`, `role-playing-games`, …) — all contain "games".
    private static func isGameCategory(_ app: NSRunningApplication) -> Bool {
        guard let bundleURL = app.bundleURL,
              let bundle = Bundle(url: bundleURL),
              let category = bundle.infoDictionary?["LSApplicationCategoryType"] as? String
        else { return false }
        return category.hasPrefix("public.app-category.") && category.contains("games")
    }
}
