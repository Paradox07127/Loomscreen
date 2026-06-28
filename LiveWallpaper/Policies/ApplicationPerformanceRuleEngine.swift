import AppKit
import Foundation

enum ApplicationPerformanceRuleEngine {
    /// Returns `false` immediately when no rules are configured (the default),
    /// and only enumerates running apps when a "while running" rule exists — so
    /// this is a cheap call to make on every policy refresh.
    @MainActor
    static func isActive(for settings: GlobalSettings) -> Bool {
        let rules = settings.applicationPerformanceRules
        guard !rules.isEmpty else { return false }
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let running: Set<String> = rules.contains(where: { $0.trigger == .running })
            ? Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            : []
        return shouldPause(frontmostBundleID: frontmost, runningBundleIDs: running, rules: rules)
    }

    /// True when the frontmost app carries a `.neverPause` exception — the
    /// policy engine uses this to veto discretionary pauses.
    @MainActor
    static func isFrontmostExcluded(for settings: GlobalSettings) -> Bool {
        let rules = settings.applicationPerformanceRules
        guard rules.contains(where: { $0.trigger == .neverPause }) else { return false }
        return frontmostIsExcluded(
            frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            rules: rules
        )
    }

    static func frontmostIsExcluded(frontmostBundleID: String?, rules: [ApplicationPerformanceRule]) -> Bool {
        guard let frontmostBundleID else { return false }
        return rules.contains { $0.trigger == .neverPause && $0.bundleID == frontmostBundleID }
    }

    /// True if any rule matches the current foreground / running state, meaning
    /// the wallpaper should suspend.
    static func shouldPause(
        frontmostBundleID: String?,
        runningBundleIDs: Set<String>,
        rules: [ApplicationPerformanceRule]
    ) -> Bool {
        guard !rules.isEmpty else { return false }
        for rule in rules {
            switch rule.trigger {
            case .frontmost:
                if let frontmostBundleID, frontmostBundleID == rule.bundleID { return true }
            case .running:
                if runningBundleIDs.contains(rule.bundleID) { return true }
            case .neverPause:
                continue
            }
        }
        return false
    }
}
