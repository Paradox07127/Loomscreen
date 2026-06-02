import Foundation
import Testing
@testable import LiveWallpaper
@testable import LiveWallpaperCore

@Suite("Application performance rules")
struct ApplicationPerformanceRuleTests {

    @Test("Empty rule list never pauses")
    func emptyNeverPauses() {
        #expect(!ApplicationPerformanceRuleEngine.shouldPause(
            frontmostBundleID: "com.apple.dt.Xcode",
            runningBundleIDs: ["com.apple.dt.Xcode"],
            rules: []
        ))
    }

    @Test("Frontmost trigger matches only when the app is frontmost")
    func frontmostTrigger() {
        let rule = ApplicationPerformanceRule(bundleID: "com.apple.dt.Xcode", displayName: "Xcode", trigger: .frontmost)
        #expect(ApplicationPerformanceRuleEngine.shouldPause(
            frontmostBundleID: "com.apple.dt.Xcode", runningBundleIDs: [], rules: [rule]
        ))
        // Running but not frontmost → no pause for a .frontmost rule.
        #expect(!ApplicationPerformanceRuleEngine.shouldPause(
            frontmostBundleID: "com.apple.Safari", runningBundleIDs: ["com.apple.dt.Xcode"], rules: [rule]
        ))
    }

    @Test("Running trigger matches even when the app is in the background")
    func runningTrigger() {
        let rule = ApplicationPerformanceRule(bundleID: "com.apple.FinalCut", displayName: "Final Cut Pro", trigger: .running)
        #expect(ApplicationPerformanceRuleEngine.shouldPause(
            frontmostBundleID: "com.apple.Safari", runningBundleIDs: ["com.apple.FinalCut"], rules: [rule]
        ))
        #expect(!ApplicationPerformanceRuleEngine.shouldPause(
            frontmostBundleID: "com.apple.Safari", runningBundleIDs: ["com.apple.Music"], rules: [rule]
        ))
    }

    @Test("An active app rule forces the suspended profile")
    func policyEngineORsRule() {
        let settings = GlobalSettings() // defaults: nothing else would suspend here
        let profile = WallpaperPolicyEngine.performanceProfile(
            globalSettings: settings,
            powerSource: .external,
            isHiddenByFullScreen: false,
            isWindowOccluding: false,
            isApplicationRuleActive: true,
            thermalState: .nominal,
            isGameModeActive: false
        )
        #expect(profile == .suspended)
    }

    @Test("GlobalSettings defaults to no rules and round-trips through Codable")
    func codableDefaultsAndRoundTrip() throws {
        let emptyJSON = Data("{}".utf8)
        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: emptyJSON)
        #expect(decoded.applicationPerformanceRules.isEmpty)

        var settings = GlobalSettings()
        settings.applicationPerformanceRules = [
            ApplicationPerformanceRule(bundleID: "com.example.app", displayName: "Example", trigger: .running)
        ]
        let data = try JSONEncoder().encode(settings)
        let back = try JSONDecoder().decode(GlobalSettings.self, from: data)
        #expect(back.applicationPerformanceRules == settings.applicationPerformanceRules)
    }
}
