import AppKit
import Foundation

/// Flags "the user is gaming" so the policy engine can suspend wallpaper
/// rendering and let the active game claim the GPU.
///
/// The ONLY positive game signal is the frontmost app's own
/// `LSApplicationCategoryType` declaring a game category — the same signal
/// macOS Game Mode itself keys on. macOS exposes no public API for Game Mode
/// state, and install-path / storefront heuristics are deliberately NOT used:
/// they can't cover arbitrary game sources (itch, native, emulators, …) and
/// mis-fire on launchers.
///
/// When the category can't be read the result is `.unknown` → the wallpaper is
/// NOT paused (fail-open). A frozen wallpaper is a worse, more visible failure
/// than a game that wasn't auto-detected, which the user can still cover via an
/// Application Exception or the full-screen pause rule. Low Power Mode forces
/// active as an explicit "yield GPU" request.
@MainActor
final class GameModeDetector {
    static let shared = GameModeDetector()

    enum Classification: String, Equatable, Sendable {
        case game, nonGame, unknown
    }

    var isActive: Bool {
        Self.evaluate(
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            classification: currentClassification()
        )
    }

    /// Cached per bundle path for the process lifetime: an app's declared
    /// category is immutable while it's installed, so one plist read per
    /// distinct frontmost app is enough. Refresh is event-driven off
    /// `didActivateApplication` (never polled), and the map stays small — one
    /// entry per app the user actually switches to.
    private var cache: [String: Classification] = [:]

    func currentClassification() -> Classification {
        guard let bundleURL = NSWorkspace.shared.frontmostApplication?.bundleURL else { return .unknown }
        let key = bundleURL.path
        if let hit = cache[key] { return hit }
        let value = Self.readClassification(infoPlistAt: bundleURL.appendingPathComponent("Contents/Info.plist"))
        cache[key] = value
        return value
    }

    /// Reads the bundle's declared category straight from its `Info.plist`.
    /// Under App Sandbox this succeeds for readable locations and returns
    /// `.unknown` on permission denial / missing key — never throws to the caller.
    nonisolated static func readClassification(infoPlistAt infoPlist: URL) -> Classification {
        classification(forCategory: readCategory(infoPlistAt: infoPlist))
    }

    nonisolated static func readCategory(infoPlistAt infoPlist: URL) -> String? {
        guard let data = try? Data(contentsOf: infoPlist),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else { return nil }
        return plist["LSApplicationCategoryType"] as? String
    }

    nonisolated static func classification(forCategory category: String?) -> Classification {
        guard let category else { return .unknown }
        return isGameCategory(category) ? .game : .nonGame
    }

    nonisolated static func isGameCategory(_ category: String) -> Bool {
        gameCategories.contains(category)
    }

    /// Apple's `public.app-category.games` plus every official game sub-category.
    nonisolated private static let gameCategories: Set<String> = [
        "public.app-category.games",
        "public.app-category.action-games",
        "public.app-category.adventure-games",
        "public.app-category.arcade-games",
        "public.app-category.board-games",
        "public.app-category.card-games",
        "public.app-category.casino-games",
        "public.app-category.dice-games",
        "public.app-category.educational-games",
        "public.app-category.family-games",
        "public.app-category.kids-games",
        "public.app-category.music-games",
        "public.app-category.puzzle-games",
        "public.app-category.racing-games",
        "public.app-category.role-playing-games",
        "public.app-category.simulation-games",
        "public.app-category.sports-games",
        "public.app-category.strategy-games",
        "public.app-category.trivia-games",
        "public.app-category.word-games",
    ]

    /// Single source of the play/pause rule, shared by `isActive` and tests.
    nonisolated static func evaluate(lowPowerMode: Bool, classification: Classification) -> Bool {
        lowPowerMode || classification == .game
    }
}
