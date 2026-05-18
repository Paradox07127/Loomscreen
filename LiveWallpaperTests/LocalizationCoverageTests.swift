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
}

private struct StringCatalog: Decodable {
    let sourceLanguage: String
    let strings: [String: Entry]

    static func load(named name: String, filePath: String = #filePath) throws -> StringCatalog {
        let testsDirectory = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        let projectRoot = testsDirectory.deletingLastPathComponent()
        let url = projectRoot.appendingPathComponent("LiveWallpaper/Resources/\(name)")
        let data = try Data(contentsOf: url)
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
        let value: String
    }
}
