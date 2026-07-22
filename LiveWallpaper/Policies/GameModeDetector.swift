import AppKit
import Foundation

/// Detects games from the frontmost app's declared macOS category.
/// Unreadable categories fail open; Low Power Mode always yields the GPU.
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

    /// App categories are immutable for an installed bundle, so cache them for the process lifetime.
    private var cache: [String: Classification] = [:]
    private var pendingLookups: [String: Task<Void, Never>] = [:]

    func currentClassification() -> Classification {
        guard let bundleURL = NSWorkspace.shared.frontmostApplication?.bundleURL else { return .unknown }
        return classification(forBundleAt: bundleURL)
    }

    /// Unknown bundles fail open while their property list is read off the main actor.
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

    /// Reads the declared category and returns `.unknown` when sandbox access or data is unavailable.
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

    /// Applies the game and Low Power Mode suspension rule.
    nonisolated static func evaluate(lowPowerMode: Bool, classification: Classification) -> Bool {
        lowPowerMode || classification == .game
    }
}
