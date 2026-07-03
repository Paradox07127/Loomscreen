import Testing
@testable import LiveWallpaper

@Suite("Settings navigation")
struct SettingsNavigationTests {
    @Test("Search matches settings titles and keywords")
    func searchMatchesTitlesAndKeywords() {
        let items = SettingsNavigation.filteredItems(
            matching: "battery",
            capabilities: .pro,
            includeWorkshopOnline: false
        )

        #expect(items.map(\.destination).contains(.performancePower))
        #expect(!items.map(\.destination).contains(.general))
    }

    @Test("Settings navigation stays scoped to settings tasks")
    func settingsNavigationStaysScopedToSettingsTasks() {
        let titles = SettingsNavigation.availableItems(
            capabilities: .pro,
            includeWorkshopOnline: false
        ).map(\.title)

        #expect(titles.contains("General"))
        #expect(titles.contains("Performance"))
        #expect(!titles.contains("Performance & Power"))
        #expect(titles.contains("Audio Response"))
        #expect(titles.contains("Weather"))
        #expect(titles.contains("Display Defaults"))
        #expect(!titles.contains("Audio & Weather"))
        #expect(!titles.contains("Bookmarks"))
        #expect(!titles.contains("Apple Aerials"))
        #expect(!titles.contains("Steam Workshop"))
    }

    @Test("Audio and weather search route to separate settings pages")
    func audioAndWeatherSearchRouteSeparately() {
        let audioItems = SettingsNavigation.filteredItems(
            matching: "audio",
            capabilities: .pro,
            includeWorkshopOnline: false
        )
        let weatherItems = SettingsNavigation.filteredItems(
            matching: "weather",
            capabilities: .pro,
            includeWorkshopOnline: false
        )

        #expect(audioItems.map(\.destination).contains(.audioResponse))
        #expect(!audioItems.map(\.destination).contains(.weather))
        #expect(weatherItems.map(\.destination).contains(.weather))
        #expect(!weatherItems.map(\.destination).contains(.audioResponse))
    }

    @Test("Settings search keeps performance concise and hides global reset")
    func settingsSearchKeepsPerformanceConciseAndHidesGlobalReset() {
        let performanceItems = SettingsNavigation.filteredItems(
            matching: "power",
            capabilities: .pro,
            includeWorkshopOnline: false
        )
        let resetItems = SettingsNavigation.filteredItems(
            matching: "reset defaults",
            capabilities: .pro,
            includeWorkshopOnline: false
        )

        #expect(performanceItems.map(\.title).contains("Performance"))
        #expect(!performanceItems.map(\.title).contains("Performance & Power"))
        #expect(resetItems.map(\.destination) == [.displayDefaults])
    }

    @Test("Lite settings hide Pro-only storage")
    func liteSettingsHideProOnlyStorage() {
        let items = SettingsNavigation.availableItems(
            capabilities: .lite,
            includeWorkshopOnline: true
        )

        #expect(!items.map(\.destination).contains(.storage))
        #expect(!items.map(\.destination).contains(.workshopSetup))
    }

    @Test("Display defaults and diagnostics are searchable")
    func displayDefaultsAndDiagnosticsAreSearchable() {
        let defaultsItems = SettingsNavigation.filteredItems(
            matching: "playback defaults",
            capabilities: .pro,
            includeWorkshopOnline: false
        )
        let diagnosticsItems = SettingsNavigation.filteredItems(
            matching: "diagnostics",
            capabilities: .pro,
            includeWorkshopOnline: false
        )

        #expect(defaultsItems.map(\.destination).contains(.displayDefaults))
        #expect(diagnosticsItems.map(\.destination).contains(.advanced))
    }

    @Test("Localized frame-rate search reaches display defaults")
    func localizedFrameRateSearchReachesDisplayDefaults() {
        let items = SettingsNavigation.filteredItems(
            matching: "帧率",
            capabilities: .pro,
            includeWorkshopOnline: false
        )

        #expect(items.map(\.destination).contains(.displayDefaults))
    }

    @Test("Search results expose the matched setting hint")
    func searchResultsExposeMatchedSettingHint() {
        let item = SettingsNavigation.availableItems(
            capabilities: .pro,
            includeWorkshopOnline: false
        ).first { $0.destination == .displayDefaults }

        #expect(item?.searchMatchHint(matching: "frame rate") == "Frame Rate")
    }
}
