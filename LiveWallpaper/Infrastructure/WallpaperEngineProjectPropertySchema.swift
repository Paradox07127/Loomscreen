import Foundation
import LiveWallpaperCore

/// Parsed `project.json -> general -> properties` schema for Wallpaper Engine
/// web projects. The UI uses this to mirror the author's right-hand property
/// list while runtime code sends values to `applyUserProperties`.
struct WallpaperEngineProjectPropertySchema: Equatable, Sendable {
    var properties: [Property]

    var hasMeaningfulSettings: Bool {
        properties.contains { $0.type.isEditable }
    }

    var defaultValues: [String: WallpaperEngineProjectPropertyValue] {
        Dictionary(uniqueKeysWithValues: properties.compactMap { property in
            property.defaultValue.map { (property.key, $0) }
        })
    }

    static func read(
        from folder: URL,
        preferredLanguages: [String] = Locale.preferredLanguages,
        includeSchemeColor: Bool = false
    ) throws -> WallpaperEngineProjectPropertySchema {
        let manifestURL = folder.appendingPathComponent("project.json")
        let data = try Data(contentsOf: manifestURL)
        return try parse(
            data: data,
            preferredLanguages: preferredLanguages,
            includeSchemeColor: includeSchemeColor
        )
    }

    /// HTML web projects already render their own `schemecolor` via CSS,
    /// so the HTML inspector hides it (default `false`). WPE Metal/WebGL
    /// scenes need it surfaced — that's the only colour control most
    /// authors expose — so the Scene inspector calls this with `true`.
    static func parse(
        data: Data,
        preferredLanguages: [String] = Locale.preferredLanguages,
        includeSchemeColor: Bool = false
    ) throws -> WallpaperEngineProjectPropertySchema {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let general = root["general"] as? [String: Any],
              let rawProperties = general["properties"] as? [String: Any] else {
            return WallpaperEngineProjectPropertySchema(properties: [])
        }

        let localization = Localization(
            raw: general["localization"] as? [String: Any],
            preferredLanguages: preferredLanguages
        )

        let properties = rawProperties.compactMap { key, raw -> Property? in
            if !includeSchemeColor && key == "schemecolor" { return nil }
            guard let dict = raw as? [String: Any] else { return nil }
            return Property(key: key, dict: dict, localization: localization)
        }
        .sorted { lhs, rhs in
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            if lhs.index != rhs.index { return lhs.index < rhs.index }
            return lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
        }

        return WallpaperEngineProjectPropertySchema(properties: properties)
    }

    func effectiveValues(
        overrides: [String: WallpaperEngineProjectPropertyValue]
    ) -> [String: WallpaperEngineProjectPropertyValue] {
        defaultValues.merging(overrides) { _, override in override }
    }

    /// Effective user-property values for a scene at render time: the project
    /// schema defaults merged with the descriptor's persisted overrides. If the
    /// cache has no readable `project.json`, falls back to just the overrides
    /// (un-overridden fields then keep the scene envelope's own `value`).
    static func effectiveSceneValues(
        descriptor: SceneDescriptor,
        cacheRootURL: URL
    ) -> [String: WallpaperEngineProjectPropertyValue] {
        do {
            return try read(
                from: cacheRootURL,
                includeSchemeColor: true
            ).effectiveValues(overrides: descriptor.propertyOverrides)
        } catch {
            return descriptor.propertyOverrides
        }
    }

    func visibleProperties(
        values: [String: WallpaperEngineProjectPropertyValue]
    ) -> [Property] {
        properties.filter { property in
            ConditionEvaluator.isVisible(condition: property.condition, values: values)
        }
    }
}

extension WallpaperEngineProjectPropertySchema {
    struct Property: Identifiable, Equatable, Sendable {
        var id: String { key }

        let key: String
        let type: PropertyType
        let displayText: String
        let defaultValue: WallpaperEngineProjectPropertyValue?
        let minimum: Double?
        let maximum: Double?
        let step: Double?
        let precision: Int?
        let fraction: Bool
        let order: Double
        let index: Int
        let condition: String?
        let options: [Option]
        let fileType: String?

        fileprivate init?(key: String, dict: [String: Any], localization: Localization) {
            self.key = key
            type = PropertyType(rawValue: (dict["type"] as? String)?.lowercased() ?? "") ?? .unsupported
            displayText = localization.displayText(for: dict["text"] as? String ?? key)
            defaultValue = Self.value(from: dict["value"])
            minimum = Self.double(from: dict["min"])
            maximum = Self.double(from: dict["max"])
            step = Self.double(from: dict["step"])
            precision = Self.int(from: dict["precision"])
            fraction = (dict["fraction"] as? Bool) ?? false
            order = Self.double(from: dict["order"]) ?? Double.greatestFiniteMagnitude
            index = Self.int(from: dict["index"]) ?? Int.max
            condition = (dict["condition"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            if let rawOptions = dict["options"] as? [[String: Any]] {
                options = rawOptions.compactMap { Option(dict: $0, localization: localization) }
            } else {
                options = []
            }
            fileType = (dict["fileType"] as? String) ?? (dict["filetype"] as? String)
        }

        fileprivate static func value(from raw: Any?) -> WallpaperEngineProjectPropertyValue? {
            if let value = raw as? Bool { return .bool(value) }
            if let value = raw as? Int { return .number(Double(value)) }
            if let value = raw as? Double { return .number(value) }
            if let value = raw as? String { return .string(value) }
            if let value = raw as? NSNumber { return .number(value.doubleValue) }
            return nil
        }

        private static func double(from raw: Any?) -> Double? {
            if let value = raw as? Double { return value }
            if let value = raw as? Int { return Double(value) }
            if let value = raw as? NSNumber { return value.doubleValue }
            if let value = raw as? String { return Double(value) }
            return nil
        }

        private static func int(from raw: Any?) -> Int? {
            if let value = raw as? Int { return value }
            if let value = raw as? NSNumber { return value.intValue }
            if let value = raw as? String { return Int(value) }
            return nil
        }
    }

    struct Option: Identifiable, Equatable, Sendable {
        var id: String { value.stringValue + displayLabel }

        let displayLabel: String
        let value: WallpaperEngineProjectPropertyValue

        fileprivate init?(dict: [String: Any], localization: Localization) {
            guard let value = Property.value(from: dict["value"]) else { return nil }
            self.value = value
            displayLabel = localization.displayText(for: dict["label"] as? String ?? value.stringValue)
        }
    }

    enum PropertyType: String, Equatable {
        case bool
        case slider
        case combo
        case color
        case textinput
        case text
        case file
        case directory
        case group
        case unsupported

        var isEditable: Bool {
            switch self {
            case .bool, .slider, .combo, .color, .textinput, .file, .directory:
                return true
            case .text, .group, .unsupported:
                return false
            }
        }
    }
}

private struct Localization: Equatable {
    private let selected: [String: String]
    private let fallback: [String: String]

    init(raw: [String: Any]?, preferredLanguages: [String]) {
        let maps = raw?.compactMapValues { $0 as? [String: String] } ?? [:]
        selected = Self.selectMap(from: maps, preferredLanguages: preferredLanguages) ?? [:]
        fallback = maps["en-us"] ?? maps["en"] ?? [:]
    }

    func displayText(for raw: String) -> String {
        let cleaned = Self.clean(raw)
        if let localized = selected[cleaned] ?? fallback[cleaned] {
            return Self.clean(localized)
        }
        return cleaned
    }

    private static func selectMap(
        from maps: [String: [String: String]],
        preferredLanguages: [String]
    ) -> [String: String]? {
        let normalizedMaps = Dictionary(uniqueKeysWithValues: maps.map { ($0.key.lowercased(), $0.value) })
        for language in preferredLanguages.map({ $0.lowercased() }) {
            let candidates = localeCandidates(for: language)
            for candidate in candidates {
                if let map = normalizedMaps[candidate] { return map }
            }
        }
        return nil
    }

    private static func localeCandidates(for language: String) -> [String] {
        var candidates = [language]
        if let prefix = language.split(separator: "-").first {
            candidates.append(String(prefix))
        }
        if language.hasPrefix("zh") {
            candidates.append(contentsOf: ["zh-chs", "zh-cn", "zh-hans"])
        }
        if language.hasPrefix("en") {
            candidates.append("en-us")
        }
        return Array(NSOrderedSet(array: candidates)) as? [String] ?? candidates
    }

    private static func clean(_ raw: String) -> String {
        var text = raw
            .replacingOccurrences(of: #"<br\s*/?>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"</?(h[1-6]|p|big|small|b|center|hr)[^>]*>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum ConditionEvaluator {
    static func isVisible(
        condition: String?,
        values: [String: WallpaperEngineProjectPropertyValue]
    ) -> Bool {
        guard let condition, !condition.isEmpty else { return true }
        return condition
            .components(separatedBy: "||")
            .map { evaluateAndGroup($0, values: values) }
            .contains(true)
    }

    private static func evaluateAndGroup(
        _ rawGroup: String,
        values: [String: WallpaperEngineProjectPropertyValue]
    ) -> Bool {
        rawGroup
            .components(separatedBy: "&&")
            .map { evaluateClause($0, values: values) }
            .allSatisfy { $0 }
    }

    private static func evaluateClause(
        _ rawClause: String,
        values: [String: WallpaperEngineProjectPropertyValue]
    ) -> Bool {
        var clause = rawClause.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip every leading `!` so JS-style truthy coercion (`!!flag`) and
        // longer negation chains evaluate correctly — without the loop,
        // `!!flag` would lose only one `!` and then look up the literal
        // string "!flag" as a (missing) key, flipping to `true` regardless
        // of the actual value.
        var negationCount = 0
        while clause.hasPrefix("!") {
            clause.removeFirst()
            clause = clause.trimmingCharacters(in: .whitespacesAndNewlines)
            negationCount += 1
        }
        let negated = negationCount.isMultiple(of: 2) == false

        let result: Bool
        if clause.caseInsensitiveCompare("true") == .orderedSame {
            result = true
        } else if clause.caseInsensitiveCompare("false") == .orderedSame {
            result = false
        } else if let includeMatch = evaluateIncludes(clause, values: values) {
            result = includeMatch
        } else if let range = clause.range(of: "==") {
            let key = propertyKey(from: String(clause[..<range.lowerBound]))
            let expected = parseLiteral(String(clause[range.upperBound...]))
            result = values[key].matches(expected)
        } else if let range = clause.range(of: "!=") {
            let key = propertyKey(from: String(clause[..<range.lowerBound]))
            let expected = parseLiteral(String(clause[range.upperBound...]))
            result = !values[key].matches(expected)
        } else {
            let key = propertyKey(from: clause)
            result = values[key].isTruthy
        }

        return negated ? !result : result
    }

    private static func evaluateIncludes(
        _ clause: String,
        values: [String: WallpaperEngineProjectPropertyValue]
    ) -> Bool? {
        guard let includeRange = clause.range(of: ".includes("),
              clause.hasSuffix(")") else {
            return nil
        }

        let rawList = String(clause[..<includeRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard rawList.hasPrefix("["),
              rawList.hasSuffix("]") else {
            return nil
        }

        let argumentStart = includeRange.upperBound
        let argumentEnd = clause.index(before: clause.endIndex)
        let key = propertyKey(from: String(clause[argumentStart..<argumentEnd]))
        let candidates = rawList
            .dropFirst()
            .dropLast()
            .split(separator: ",")
            .map { parseLiteral(String($0)) }

        return candidates.contains { values[key].matches($0) }
    }

    private static func propertyKey(from raw: String) -> String {
        // WPE condition strings reference a property via `<key>.value`; the
        // suffix is decorative and must be stripped before lookup. Only
        // strip it as a trailing suffix so keys that legitimately contain
        // "value" in the middle (e.g. `slider.value.max`) survive intact.
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix(".value") {
            return String(trimmed.dropLast(".value".count))
        }
        return trimmed
    }

    private static func parseLiteral(_ raw: String) -> WallpaperEngineProjectPropertyValue {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if trimmed.caseInsensitiveCompare("true") == .orderedSame { return .bool(true) }
        if trimmed.caseInsensitiveCompare("false") == .orderedSame { return .bool(false) }
        if let number = Double(trimmed) { return .number(number) }
        return .string(trimmed)
    }
}

private extension Optional where Wrapped == WallpaperEngineProjectPropertyValue {
    var isTruthy: Bool {
        guard let value = self else { return false }
        switch value {
        case .bool(let bool):
            return bool
        case .number(let number):
            return abs(number) > 0.000_001
        case .string(let string):
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty
                && trimmed.caseInsensitiveCompare("false") != .orderedSame
                && trimmed != "0"
        }
    }

    func matches(_ expected: WallpaperEngineProjectPropertyValue) -> Bool {
        guard let value = self else { return false }
        switch (value, expected) {
        case (.bool(let lhs), .bool(let rhs)):
            return lhs == rhs
        case (.number(let lhs), .number(let rhs)):
            return abs(lhs - rhs) < 0.000_001
        case (.string(let lhs), .string(let rhs)):
            return lhs == rhs
        default:
            return value.stringValue == expected.stringValue
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
