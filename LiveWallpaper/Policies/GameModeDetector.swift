import AppKit
import Foundation

/// Lightweight gate that flags "user is gaming" so the policy engine can
/// suspend wallpaper rendering and let the active game claim the GPU.
///
/// Two signals are merged:
/// - `ProcessInfo.isLowPowerModeEnabled` — treat the explicit system
///   power-saving toggle as a request to yield GPU/decoder work. Not a
///   perfect proxy for Apple's Game Mode (which has no public API), but
///   the user-initiated overlap is high.
/// - Frontmost app bundle ID matches a known game-launcher prefix. Covers
///   the case where Game Mode is off but the user clearly opened Steam /
///   Epic / Battle.net etc. Keeps the rule conservative — we only suspend
///   on the launchers, not random fullscreen apps, to avoid false positives
///   in screensharing / kiosk setups.
///
/// Known limitation: once the launcher hands off to the actual game
/// executable (e.g. `unity.Subnautica`), the bundle prefix no longer
/// matches and this detector falls silent. Most games run fullscreen and
/// are caught by `pauseOnFullScreen` instead, so the residual gap is
/// "windowed game on the same display" — uncommon enough to not maintain
/// a per-title bundle allowlist.
@MainActor
enum GameModeDetector {
    static var isActive: Bool {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return true }
        return frontmostAppMatchesKnownGame()
    }

    private static let knownGameBundlePrefixes: [String] = [
        "com.valvesoftware.steam",
        "com.epicgames",
        "com.blizzard",
        "com.riotgames",
        "com.ea.",
        "com.ubisoft.",
    ]

    private static func frontmostAppMatchesKnownGame() -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              let bundleID = frontmost.bundleIdentifier else { return false }
        return knownGameBundlePrefixes.contains { bundleID.hasPrefix($0) }
    }
}
