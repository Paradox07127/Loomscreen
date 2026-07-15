import Foundation

enum SparkleUpdateConfiguration {
    static let isPublicDistributionEnabled = false
    static let manualChecksDefaultsKey = "SparkleTestManualChecksEnabled"
    static let manualChecksEnvironmentKey = "LOOMSCREEN_SPARKLE_TESTING"

    static var manualChecksEnabled: Bool {
        !isPublicDistributionEnabled
            && (
                ProcessInfo.processInfo.environment[manualChecksEnvironmentKey] == "1"
                    || UserDefaults.standard.bool(forKey: manualChecksDefaultsKey)
            )
    }

    static var currentFeedURL: URL {
        feedURL(bundleIdentifier: Bundle.main.bundleIdentifier)
    }

    static var feedSummary: String {
        currentFeedURL.absoluteString
    }

    static func feedURL(bundleIdentifier: String?) -> URL {
        let path = bundleIdentifier == "com.loomscreen"
            ? "loomscreen-appcast.xml"
            : "livewallpaper-appcast.xml"
        return URL(string: "http://127.0.0.1:8123/\(path)") ?? URL(fileURLWithPath: "/")
    }
}
