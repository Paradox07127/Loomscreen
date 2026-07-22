import Foundation
import Testing

@Suite("Localization coverage")
struct LocalizationCoverageTests {
    private static let requiredLocales = ["zh-Hans", "zh-Hant", "ja"]

    @Test("String catalogs include supported localizations for every entry")
    func catalogsIncludeSupportedTranslations() throws {
        for catalogName in ["Localizable.xcstrings", "InfoPlist.xcstrings"] {
            let catalog = try StringCatalog.load(named: catalogName)
            for locale in Self.requiredLocales {
                let missing = catalog.keysMissingLocalization(locale)

                #expect(
                    missing.isEmpty,
                    "\(catalogName) is missing \(locale) translations for: \(missing.prefix(20).joined(separator: ", "))"
                )
            }
        }
    }

    @Test("Supported translations preserve string format placeholders")
    func supportedTranslationsPreservePlaceholders() throws {
        for catalogName in ["Localizable.xcstrings", "InfoPlist.xcstrings"] {
            let catalog = try StringCatalog.load(named: catalogName)
            for locale in Self.requiredLocales {
                let mismatches = catalog.placeholderMismatches(for: locale)

                #expect(
                    mismatches.isEmpty,
                    "\(catalogName) has \(locale) placeholder mismatches: \(mismatches.prefix(20).joined(separator: "; "))"
                )
            }
        }
    }

    @Test("String catalogs do not localize literal percent signs")
    func stringCatalogsDoNotLocalizeLiteralPercentSigns() throws {
        for catalogName in ["Localizable.xcstrings", "InfoPlist.xcstrings"] {
            let catalog = try StringCatalog.load(named: catalogName)
            let issues = catalog.literalPercentIssues()

            #expect(
                issues.isEmpty,
                "\(catalogName) contains literal percent signs that should be formatted in code: \(issues.prefix(20).joined(separator: "; "))"
            )
        }
    }

    @Test("String catalogs do not keep stale extraction entries")
    func stringCatalogsDoNotKeepStaleEntries() throws {
        for catalogName in ["Localizable.xcstrings", "InfoPlist.xcstrings"] {
            let catalog = try StringCatalog.load(named: catalogName)
            let stale = catalog.staleKeys()

            #expect(
                stale.isEmpty,
                "\(catalogName) contains stale extraction entries: \(stale.prefix(20).joined(separator: ", "))"
            )
        }
    }

    @Test("Shared package UI resolves app-localized Text from the app bundle")
    func sharedPackageUIResolvesTextFromAppBundle() throws {
        let source = try Self.projectFile("Packages/LiveWallpaperCore/Sources/LiveWallpaperCore/UI/Components/SettingRow.swift")

        #expect(source.contains("Text(title, bundle: .main)"))
        #expect(source.contains("Text($0, bundle: .main)"))
        #expect(source.contains("let info: String.LocalizationValue?"))
        #expect(source.contains("@AppStorage(AppLanguagePreference.storageKey)"))
        #expect(source.contains(".help(localizedText)"))
        #expect(source.contains("Text(verbatim: localizedText)"))
        #expect(!source.contains(".help(text)"))
        #expect(!source.contains("self.title = Text(title)"))
        #expect(!source.contains("self.subtitle = subtitle.map { Text($0) }"))
        #expect(!source.contains("self.info = info.map { Text($0) }"))
    }

    @Test("Shortcut action copy remains localizable at render time")
    func shortcutActionCopyRemainsLocalizableAtRenderTime() throws {
        let shortcutView = try Self.projectFile("LiveWallpaper/Views/Settings/ShortcutsSettingsView.swift")
        let actionModel = try Self.projectFile("Packages/LiveWallpaperCore/Sources/LiveWallpaperCore/Schema/GlobalShortcutAction.swift")

        #expect(!shortcutView.contains("Text(verbatim: action.displayName)"))
        #expect(shortcutView.contains("Text(action.displayNameKey, bundle: .main)"))
        #expect(shortcutView.contains("Text(action.displayDescriptionKey, bundle: .main)"))
        #expect(actionModel.contains("var displayNameKey: LocalizedStringKey"))
        #expect(actionModel.contains("var displayDescriptionKey: LocalizedStringKey"))
    }

    @Test("Onboarding unsupported-import copy remains statically catalogued for both capabilities")
    func onboardingUnsupportedImportCopyIsCatalogued() throws {
        let catalog = try StringCatalog.load(named: "Localizable.xcstrings")
        let keys = [
            "That file type isn't supported. Pick a video or web page.",
            "That file type isn't supported. Pick a video, web page, or scene.",
        ]
        for key in keys {
            #expect(catalog.strings[key] != nil, "Missing onboarding recovery key: \(key)")
            for locale in [catalog.sourceLanguage] + Self.requiredLocales {
                #expect(
                    catalog.strings[key]?.localizations?[locale]?.stringUnit?.value.isEmpty == false,
                    "Missing \(locale) onboarding recovery copy for: \(key)"
                )
                #expect(
                    catalog.strings[key]?.localizations?[locale]?.stringUnit?.state == "translated",
                    "Onboarding recovery copy is not translated for \(locale): \(key)"
                )
            }
        }

        let source = try Self.projectFile("LiveWallpaper/Views/Onboarding/OnboardingPickerView.swift")
        #expect(source.contains("unsupportedFileTypeMessage(sceneCapable: Bool) -> LocalizedStringResource"))
        #expect(source.contains("return \"That file type isn't supported. Pick a video or web page.\""))
        #expect(source.contains("return \"That file type isn't supported. Pick a video, web page, or scene.\""))
        #expect(
            Self.hasDirectOnboardingSceneCapabilityWiring(source),
            "OnboardingPickerView.sceneCapable must directly use the tested .scene catalog policy"
        )
        #expect(
            Self.hasDirectOnboardingSceneCapabilityPolicy(source),
            "The onboarding scene policy must directly query FeatureCatalog's .scene capability"
        )
        #expect(source.contains(
            "return fail(OnboardingImportCopy.unsupportedFileTypeMessage(sceneCapable: sceneCapable))"
        ))

        let invertedWiringProbe = """
        private var sceneCapable: Bool {
            !OnboardingImportCopy.sceneCapable(in: featureCatalog)
        }
        """
        #expect(
            !Self.hasDirectOnboardingSceneCapabilityWiring(invertedWiringProbe),
            "The capability-wiring guard must reject an inverted scene feature"
        )

        let invertedPolicyProbe = """
        static func sceneCapable(in catalog: FeatureCatalog) -> Bool {
            !catalog.isEnabled(.scene)
        }
        """
        #expect(
            !Self.hasDirectOnboardingSceneCapabilityPolicy(invertedPolicyProbe),
            "The capability-policy guard must reject an inverted FeatureCatalog query"
        )
    }

    @Test("Workshop import copy describes local copied projects, not online Workshop connection")
    func workshopImportCopyAvoidsOnlineConnectionLanguage() throws {
        var scanned = RepositoryRoot.swiftFiles(under: "LiveWallpaper")
        scanned.append(RepositoryRoot.url("LiveWallpaper/Resources/Localizable.xcstrings"))
        #expect(scanned.count > 100, "App source sweep collapsed to \(scanned.count) files — the copy scan is unenforced")

        let source = try scanned.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")

        let disallowedPhrases = [
            "Connect Steam Workshop",
            "Search Workshop",
            "Scanning workshop folder",
            "Workshop folder access expired",
            "Workshop folder access denied",
            "Workshop folder is unreachable",
            "Discover Workshop projects under your Steam library",
            "Discover Workshop projects from your Steam Workshop folder",
            "Open a display first, then choose a Workshop wallpaper to apply.",
            "Choose the Wallpaper Engine folder that contains your subscribed project folders.",
            "No Workshop projects found",
            "Recent Workshop Projects",
            "Return to the recent Workshop projects grid",
            "Wallpaper Engine project:",
            "Wallpaper Engine project type is unknown",
            "We couldn't recognize this Wallpaper Engine project type.",
            "Opens a folder chooser to apply a Wallpaper Engine project",
            "Select your Wallpaper Engine projects folder",
            "Auto-enabled for Wallpaper Engine folders.",
            "Browse Wallpaper Engine workshop projects",
            "Wallpaper Engine scenes across every connected display.",
            "Wallpaper Engine scene imports.",
            "Wallpaper Engine Cache",
        ]

        let hits = disallowedPhrases.filter { source.contains($0) }
        #expect(hits.isEmpty, "User-facing import copy still implies online Workshop/WPE coupling: \(hits)")
        #expect(source.contains("Workshop Library"), "The product decision keeps the Workshop Library page label.")
    }

    private static func projectFile(_ relativePath: String) throws -> String {
        try RepositoryRoot.source(relativePath)
    }

    private static func hasDirectOnboardingSceneCapabilityWiring(_ source: String) -> Bool {
        let normalized = source.filter { !$0.isWhitespace }
        let expected = "privatevarsceneCapable:Bool{OnboardingImportCopy.sceneCapable(in:featureCatalog)}"
        return normalized.components(separatedBy: expected).count - 1 == 1
            && normalized.components(separatedBy: "privatevarsceneCapable:Bool{").count - 1 == 1
    }

    private static func hasDirectOnboardingSceneCapabilityPolicy(_ source: String) -> Bool {
        let normalized = source.filter { !$0.isWhitespace }
        let expected = "staticfuncsceneCapable(incatalog:FeatureCatalog)->Bool{catalog.isEnabled(.scene)}"
        return normalized.components(separatedBy: expected).count - 1 == 1
            && normalized.components(separatedBy: "staticfuncsceneCapable(incatalog:FeatureCatalog)->Bool{").count - 1 == 1
    }
}

private struct StringCatalog: Decodable {
    let sourceLanguage: String
    let strings: [String: Entry]

    static func load(named name: String) throws -> StringCatalog {
        let data = try RepositoryRoot.data("LiveWallpaper/Resources/\(name)")
        return try JSONDecoder().decode(StringCatalog.self, from: data)
    }

    func keysMissingLocalization(_ locale: String) -> [String] {
        strings.keys.sorted().filter { key in
            guard let unit = strings[key]?.localizations?[locale]?.stringUnit else {
                return true
            }
            return !key.isEmpty && unit.value.isEmpty
        }
    }

    func placeholderMismatches(for locale: String) -> [String] {
        strings.keys.sorted().compactMap { key in
            let sourceValue = strings[key]?.localizations?[sourceLanguage]?.stringUnit?.value ?? key
            guard let localizedValue = strings[key]?.localizations?[locale]?.stringUnit?.value else {
                return nil
            }

            let sourcePlaceholders = Self.placeholders(in: sourceValue)
            let localizedPlaceholders = Self.placeholders(in: localizedValue)
            guard !Self.placeholdersMatch(sourcePlaceholders, localizedPlaceholders) else {
                return nil
            }

            return "\(key) expected \(sourcePlaceholders) but found \(localizedPlaceholders)"
        }
    }

    func literalPercentIssues() -> [String] {
        strings.keys.sorted().flatMap { key in
            let localizations = strings[key]?.localizations ?? [:]
            return localizations.keys.sorted().compactMap { locale -> String? in
                guard let value = localizations[locale]?.stringUnit?.value,
                      Self.containsLiteralPercent(in: value) else {
                    return nil
                }
                return "\(key) [\(locale)]"
            }
        }
    }

    func staleKeys() -> [String] {
        strings.keys.sorted().filter { key in
            strings[key]?.extractionState == "stale"
        }
    }

    private static func placeholders(in value: String) -> [String] {
        let pattern = #"%(?:(\d+)\$)?[+\- #0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|ll|[hlLzjtq])?[diuoxXfFeEgGaAcCsSp@]"#
        let expression = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression?.matches(in: value, range: range).compactMap { match in
            Range(match.range, in: value).map { String(value[$0]) }
        } ?? []
    }

    private static func placeholdersMatch(_ source: [String], _ localized: [String]) -> Bool {
        let usesExplicitPositions = source.allSatisfy {
            $0.range(of: #"%\d+\$"#, options: .regularExpression) != nil
        }
        return usesExplicitPositions ? source.sorted() == localized.sorted() : source == localized
    }

    private static func containsLiteralPercent(in value: String) -> Bool {
        let placeholderPattern = #"%(?:(\d+)\$)?[+\- #0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|ll|[hlLzjtq])?[diuoxXfFeEgGaAcCsSp@]"#
        guard let expression = try? NSRegularExpression(pattern: placeholderPattern) else {
            return value.contains("%")
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        let stripped = expression.stringByReplacingMatches(in: value, range: range, withTemplate: "")
        return stripped.contains("%")
    }

    struct Entry: Decodable {
        let extractionState: String?
        let localizations: [String: Localization]?
    }

    struct Localization: Decodable {
        let stringUnit: StringUnit?
    }

    struct StringUnit: Decodable {
        let state: String?
        let value: String
    }
}
