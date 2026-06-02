import AppKit
import Foundation

/// Pure evaluation of the user's per-app pause rules. `shouldPause` is side-effect
/// free for unit-testing; `isActive(for:)` is the live convenience that samples
/// `NSWorkspace` only when there are rules to check.
enum ApplicationPerformanceRuleEngine {
    /// Live evaluation against the current foreground / running apps. Returns
    /// `false` immediately when no rules are configured (the default), and only
    /// enumerates running apps when a "while running" rule exists — so this is a
    /// cheap call to make on every policy refresh.
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

    /// True if any rule matches the current foreground / running state, meaning
    /// the wallpaper should suspend. Returns `false` immediately for an empty
    /// rule list (the default), so the common case costs nothing.
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
            }
        }
        return false
    }
}
