import Foundation
import Testing

@Suite("Localization coverage")
struct LocalizationCoverageTests {
    @Test("String catalogs include Simplified Chinese for every entry")
    func catalogsIncludeSimplifiedChineseTranslations() throws {
        for catalogName in ["Localizable.xcstrings", "InfoPlist.xcstrings"] {
            let catalog = try StringCatalog.load(named: catalogName)
            let missing = catalog.keysMissingLocalization("zh-Hans")

            #expect(
                missing.isEmpty,
                "\(catalogName) is missing zh-Hans translations for: \(missing.prefix(20).joined(separator: ", "))"
            )
        }
    }

    @Test("Simplified Chinese translations preserve string format placeholders")
    func simplifiedChineseTranslationsPreservePlaceholders() throws {
        for catalogName in ["Localizable.xcstrings", "InfoPlist.xcstrings"] {
            let catalog = try StringCatalog.load(named: catalogName)
            let mismatches = catalog.placeholderMismatches(for: "zh-Hans")

            #expect(
                mismatches.isEmpty,
                "\(catalogName) has placeholder mismatches: \(mismatches.prefix(20).joined(separator: "; "))"
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

    private static func placeholders(in value: String) -> [String] {
        let pattern = #"%(?:(\d+)\$)?[+\- #0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?[hlLzjtq]?[diuoxXfFeEgGaAcCsSp@]"#
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

    struct Entry: Decodable {
        let localizations: [String: Localization]?
    }

    struct Localization: Decodable {
        let stringUnit: StringUnit?
    }

    struct StringUnit: Decodable {
        let value: String
    }
}
