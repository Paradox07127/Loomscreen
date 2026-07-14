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
    private var pendingLookups: [String: Task<Void, Never>] = [:]

    func currentClassification() -> Classification {
        guard let bundleURL = NSWorkspace.shared.frontmostApplication?.bundleURL else { return .unknown }
        return classification(forBundleAt: bundleURL)
    }

    /// First sight of a bundle answers fail-open `.unknown` immediately and
    /// resolves the plist off the main thread — the read is normally
    /// sub-millisecond but can stall on slow/network volumes, and this path
    /// runs on the MainActor that also drives UI and render policy. The cached
    /// value takes effect on the next policy refresh (app switch, thermal,
    /// power, or full-screen change — all frequent while a game spins up).
    func classification(forBundleAt bundleURL: URL) -> Classification {
        let key = bundleURL.path
        if let hit = cache[key] { return hit }
        scheduleClassification(for: bundleURL, key: key)
        return .unknown
    }

    private func scheduleClassification(for bundleURL: URL, key: String) {
        guard pendingLookups[key] == nil else { return }
        let infoPlist = bundleURL.appendingPathComponent("Contents/Info.plist")
        pendingLookups[key] = Task.detached(priority: .utility) { [weak self] in
            let value = Self.readClassification(infoPlistAt: infoPlist)
            await self?.finishClassification(key: key, value: value)
        }
    }

    private func finishClassification(key: String, value: Classification) {
        pendingLookups[key] = nil
        cache[key] = value
    }

    /// Test hook: waits until every in-flight plist read has landed in `cache`.
    func awaitPendingClassifications() async {
        while let task = pendingLookups.values.first {
            await task.value
        }
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
