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
        let settings = GlobalSettings()
        let profile = WallpaperPolicyEngine.performanceProfile(
            inputs: .test(isApplicationRuleActive: true),
            settings: settings
        )
        #expect(profile == .suspended)
    }

    @Test("A neverPause trigger is not itself a pause match")
    func neverPauseDoesNotPause() {
        let rule = ApplicationPerformanceRule(bundleID: "com.example.tool", displayName: "Tool", trigger: .neverPause)
        #expect(!ApplicationPerformanceRuleEngine.shouldPause(
            frontmostBundleID: "com.example.tool", runningBundleIDs: ["com.example.tool"], rules: [rule]
        ))
    }

    @Test("frontmostIsExcluded matches only a neverPause rule on the frontmost app")
    func frontmostExcludedMatching() {
        let never = ApplicationPerformanceRule(bundleID: "com.example.tool", displayName: "Tool", trigger: .neverPause)
        let pause = ApplicationPerformanceRule(bundleID: "com.example.tool", displayName: "Tool", trigger: .frontmost)
        #expect(ApplicationPerformanceRuleEngine.frontmostIsExcluded(frontmostBundleID: "com.example.tool", rules: [never]))
        #expect(!ApplicationPerformanceRuleEngine.frontmostIsExcluded(frontmostBundleID: "com.other.app", rules: [never]))
        #expect(!ApplicationPerformanceRuleEngine.frontmostIsExcluded(frontmostBundleID: "com.example.tool", rules: [pause]))
    }

    @Test("A frontmost neverPause exception vetoes discretionary pauses but not safety ones")
    func neverPauseVetoesDiscretionaryOnly() {
        let settings = GlobalSettings(pauseInGameMode: true)
        // Game mode would pause, but the exclusion vetoes it.
        #expect(WallpaperPolicyEngine.performanceProfile(
            inputs: .test(isGameModeActive: true, isFrontmostExcludedByRule: true),
            settings: settings
        ) == .quality)
        // Thermal is a safety pause — the exclusion can't veto it.
        #expect(WallpaperPolicyEngine.performanceProfile(
            inputs: .test(thermalState: .critical, isFrontmostExcludedByRule: true),
            settings: settings
        ) == .suspended)
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
