import AppKit
import Foundation

/// Lightweight gate that flags "user is gaming" so the policy engine can
/// suspend wallpaper rendering and let the active game claim the GPU.
///
/// macOS exposes **no** public, sandbox-safe API for its Game Mode state, so
/// this is a heuristic on the frontmost app. The frontmost app is classified
/// as a game when ANY of these hold:
///
/// 1. Its executable / bundle lives under a known game-library install root
///    (`…/steamapps/common/…`, Epic, Battle.net, GOG). This is the load-bearing
///    signal: a game launched through Steam/Epic runs its OWN executable, whose
///    bundle ID is not a storefront prefix and which very often declares no
///    `LSApplicationCategoryType` at all — so the older category/prefix checks
///    missed essentially every real game. The install path does not, and a
///    normal app (Safari, Finder, an editor under `/Applications` or `/System`)
///    never matches it, so it cleanly separates "a game" from "a maximised
///    non-game window".
/// 2. The frontmost bundle ID matches a storefront/launcher prefix — the fast
///    path for when the launcher window itself is in front.
/// 3. It declares a `public.app-category.*games` `LSApplicationCategoryType`
///    (catches store-installed games outside the path roots).
///
/// Plus `ProcessInfo.isLowPowerModeEnabled` as an explicit "yield GPU" request.
/// Full-screen is intentionally NOT required (a windowed game still yields);
/// `pauseOnFullScreen` covers full-screen overlap of non-games independently.
enum GameModeDetector {
    struct FrontmostApp: Equatable, Sendable {
        var bundleID: String?
        var bundlePath: String?
        var executablePath: String?
        /// `LSApplicationCategoryType` from the app's Info.plist, if readable.
        var category: String?
    }

    @MainActor
    static var isActive: Bool {
        evaluate(
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            frontmost: snapshotFrontmost()
        )
    }

    static func evaluate(lowPowerMode: Bool, frontmost: FrontmostApp?) -> Bool {
        if lowPowerMode { return true }
        guard let frontmost else { return false }
        return isGame(frontmost)
    }

    /// See the three signals in the type doc.
    static func isGame(_ app: FrontmostApp) -> Bool {
        if let path = app.executablePath ?? app.bundlePath, isGameInstallPath(path) {
            return true
        }
        if let bundleID = app.bundleID,
           knownGameBundlePrefixes.contains(where: { bundleID.hasPrefix($0) }) {
            return true
        }
        return isGameCategory(app.category)
    }

    /// True when a filesystem path sits under a known game-library install root.
    /// Markers are full path segments (e.g. `/steamapps/common/`, not just
    /// `Steam`) so a launcher's own helper processes don't match.
    static func isGameInstallPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        return gameInstallPathMarkers.contains { lower.contains($0) }
    }

    static func isGameCategory(_ category: String?) -> Bool {
        guard let category, category.hasPrefix("public.app-category.") else { return false }
        return category.contains("games")
    }

    private static let gameInstallPathMarkers: [String] = [
        "/steamapps/common/",   // Steam (default library + custom SteamLibrary folders)
        "/epic games/",         // Epic Games Launcher
        "/battle.net/",         // Blizzard Battle.net
        "/gog games/",          // GOG
        "/goggalaxy/",          // GOG Galaxy
    ]

    private static let knownGameBundlePrefixes: [String] = [
        "com.valvesoftware.steam",
        "com.epicgames",
        "com.blizzard",
        "com.riotgames",
        "com.ea.",
        "com.ubisoft.",
    ]

    @MainActor
    private static func snapshotFrontmost() -> FrontmostApp? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let category = app.bundleURL
            .flatMap { Bundle(url: $0)?.infoDictionary?["LSApplicationCategoryType"] as? String }
        return FrontmostApp(
            bundleID: app.bundleIdentifier,
            bundlePath: app.bundleURL?.path,
            executablePath: app.executableURL?.path,
            category: category
        )
    }
}
