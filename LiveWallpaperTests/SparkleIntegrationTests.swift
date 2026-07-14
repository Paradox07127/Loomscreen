import Foundation
import Testing

@Suite("Sparkle test integration")
struct SparkleIntegrationTests {
    private static let expectedPublicKey = "pfIShU4dEXqPd5ObYNfDBiQWcXozk7estwzTnF9BamQ="

    @Test("Info plists carry local-only Sparkle test feed settings")
    func infoPlistsCarrySparkleTestFeedSettings() throws {
        let cases: [(plist: String, feed: String)] = [
            ("LiveWallpaperInfo.plist", "http://127.0.0.1:8123/livewallpaper-appcast.xml"),
            ("LoomscreenInfo.plist", "http://127.0.0.1:8123/loomscreen-appcast.xml"),
        ]

        for testCase in cases {
            let plist = try Self.plistDictionary(testCase.plist)
            #expect(plist["SUFeedURL"] as? String == testCase.feed)
            #expect(plist["SUPublicEDKey"] as? String == Self.expectedPublicKey)
            #expect(plist["SUEnableAutomaticChecks"] as? Bool == false)
            #expect(plist["SUEnableInstallerLauncherService"] as? Bool == true)
        }
    }

    @Test("Sandbox entitlements allow Sparkle installer XPC communication")
    func sandboxEntitlementsAllowSparkleInstallerXPC() throws {
        let entitlements = try Self.plistDictionary("LiveWallpaper/LiveWallpaper.entitlements")
        let machLookup = entitlements[
            "com.apple.security.temporary-exception.mach-lookup.global-name"
        ] as? [String] ?? []

        #expect(machLookup.contains("$(PRODUCT_BUNDLE_IDENTIFIER)-spks"))
        #expect(machLookup.contains("$(PRODUCT_BUNDLE_IDENTIFIER)-spki"))
    }

    @Test("Xcode project links Sparkle to both app targets")
    func xcodeProjectLinksSparkleToAppTargets() throws {
        let project = try Self.projectFile("LiveWallpaper.xcodeproj/project.pbxproj")

        #expect(project.contains("https://github.com/sparkle-project/Sparkle"))
        #expect(project.contains("XCRemoteSwiftPackageReference \"Sparkle\""))
        #expect(project.contains("Sparkle in Frameworks"))

        let productDependencyCount = project.components(separatedBy: "/* Sparkle */").count - 1
        #expect(productDependencyCount >= 2)
    }

    @Test("App source keeps Sparkle marked as testing-only")
    func appSourceKeepsSparkleMarkedAsTestingOnly() throws {
        let configuration = try Self.projectFile("LiveWallpaper/Infrastructure/SparkleUpdateConfiguration.swift")
        let panel = try Self.projectFile("LiveWallpaper/Views/Settings/SparkleUpdateTestPanel.swift")
        let aboutTab = try Self.projectFile("LiveWallpaper/Views/GeneralSettingsAboutTab.swift")

        #expect(configuration.contains("static let isPublicDistributionEnabled = false"))
        #expect(configuration.contains("!isPublicDistributionEnabled"))
        #expect(configuration.contains("SparkleTestManualChecksEnabled"))
        #expect(panel.contains(".disabled(!configuration.manualChecksEnabled)"))
        #expect(aboutTab.contains("if SparkleUpdateConfiguration.manualChecksEnabled"))
    }

    private static func plistDictionary(_ relativePath: String) throws -> [String: Any] {
        let data = try RepositoryRoot.data(relativePath)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try #require(plist as? [String: Any])
    }

    private static func projectFile(_ relativePath: String) throws -> String {
        try RepositoryRoot.source(relativePath)
    }
}
