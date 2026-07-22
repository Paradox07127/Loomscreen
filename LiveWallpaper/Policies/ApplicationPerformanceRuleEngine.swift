import AppKit
import Foundation
import LiveWallpaperCore

enum ApplicationPerformanceRuleEngine {
    /// Evaluates configured application rules without enumerating processes unless required.
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

    /// Returns whether the frontmost app vetoes discretionary pauses.
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

    /// Returns whether any foreground or running-app rule requests suspension.
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
