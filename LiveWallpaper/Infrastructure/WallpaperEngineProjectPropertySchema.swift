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
    /// so the HTML inspector hides it (default `false`). WPE Metal scenes
    /// need it surfaced — that's the only colour control most authors expose
    /// — so the Scene inspector calls this with `true`.
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
        /// True when this entry is an embedded ad / donation / external-link
        /// block rather than a real wallpaper setting. WPE authors abuse the
        /// properties panel to render clickable HTML (`<a href>`, `<img src>`,
        /// QR codes, Ko-fi / Patreon / 爱发电 links); the engine never binds
        /// these to the render graph, so toggling them changes nothing. The
        /// scene inspector hides them. See `Self.detectPromotionalLink`.
        let isPromotionalLink: Bool

        fileprivate init?(key: String, dict: [String: Any], localization: Localization) {
            self.key = key
            type = PropertyType(rawValue: (dict["type"] as? String)?.lowercased() ?? "") ?? .unsupported
            let rawText = dict["text"] as? String
            displayText = localization.displayText(for: rawText ?? key)
            defaultValue = Self.value(from: dict["value"])
            minimum = Self.double(from: dict["min"])
            maximum = Self.double(from: dict["max"])
            step = Self.double(from: dict["step"])
            precision = Self.int(from: dict["precision"])
            fraction = (dict["fraction"] as? Bool) ?? false
            order = Self.double(from: dict["order"]) ?? Double.greatestFiniteMagnitude
            index = Self.int(from: dict["index"]) ?? Int.max
            condition = (dict["condition"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let rawOptions = dict["options"] as? [[String: Any]]
            if let rawOptions {
                options = rawOptions.compactMap { Option(dict: $0, localization: localization) }
            } else {
                options = []
            }
            fileType = (dict["fileType"] as? String) ?? (dict["filetype"] as? String)
            isPromotionalLink = Self.detectPromotionalLink(
                key: key,
                rawText: rawText ?? "",
                rawOptions: rawOptions,
                localization: localization
            )
        }

        /// Tokens that betray a promotional/donation/external-link entry. They
        /// appear either inside an HTML-derived key (punctuation stripped, e.g.
        /// `ahrefhttpskoficom…`) or in the property's display text / option
        /// labels (with punctuation, e.g. `<a href=`).
        private static let promoKeyTokens = [
            "href", "http", "www", "imgsrc", "kofi", "ko-fi", "patreon", "paypal",
            "donate", "sponsor", "discord", "afdian", "aifadian", "爱发电", "赞助", "赞赏", "打赏"
        ]
        private static let promoTextMarkers = [
            "<a ", "<a>", "href=", "<img", "src=", "http://", "https://", "www.",
            "ko-fi", "kofi", "patreon", "paypal", "donate", "sponsor", "discord.gg",
            "爱发电", "赞助", "赞赏", "打赏"
        ]

        /// Narrow ad/link detector (validated against 57 real workshop scenes:
        /// flags ~12% of editable properties, all genuine links/donations, with
        /// no false hit on settings that merely use `<h2>` / `<font>` for label
        /// styling — those cosmetic tags are stripped for display elsewhere).
        ///
        /// A property is promotional when ANY of:
        ///  - its key is HTML-derived — WPE auto-generates the key from the
        ///    author's HTML text when no explicit `name` is set, yielding keys
        ///    like `ahrefhttpskoficom…` / `imgsrchttp…`. A merely long key is not
        ///    enough; it must also carry a promo token, so a descriptive long key
        ///    for a real control is never hidden;
        ///  - its `text` / option labels (raw *and* localized) contain a
        ///    hyperlink (`<a`, `href=`), an embedded image (`<img`, `src=`), a
        ///    bare URL, or a donation/social keyword (Ko-fi, Patreon, 赞助, …).
        fileprivate static func detectPromotionalLink(
            key: String,
            rawText: String,
            rawOptions: [[String: Any]]?,
            localization: Localization
        ) -> Bool {
            let loweredKey = key.lowercased()
            if ["ahref", "imgsrc", "http"].contains(where: loweredKey.hasPrefix) {
                return true
            }
            if key.count > 40, promoKeyTokens.contains(where: loweredKey.contains) {
                return true
            }

            var candidates = localization.detectionCandidates(for: rawText)
            if let rawOptions {
                for option in rawOptions {
                    if let label = option["label"] as? String {
                        candidates.append(contentsOf: localization.detectionCandidates(for: label))
                    }
                }
            }
            let haystack = candidates.joined(separator: " ").lowercased()
            return promoTextMarkers.contains(where: haystack.contains)
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

private enum KnownWallpaperEngineKeys {
    private static let displayNames: [String: String] = [
        "bgmvolume": "BGM Volume",
        "mouseactions": "Mouse Actions",
        "schemecolor": "Scheme Color",
        "ui_browse_properties_alignment": "Alignment",
        "ui_browse_properties_background_image": "Background Image",
        "ui_browse_properties_blur": "Blur",
        "ui_browse_properties_brightness": "Brightness",
        "ui_browse_properties_color": "Color",
        "ui_browse_properties_contrast": "Contrast",
        "ui_browse_properties_opacity": "Opacity",
        "ui_browse_properties_playback_rate": "Playback Rate",
        "ui_browse_properties_rotation": "Rotation",
        "ui_browse_properties_scale": "Scale",
        "ui_browse_properties_scheme_color": "Scheme Color",
        "ui_browse_properties_schemecolor": "Scheme Color",
        "ui_browse_properties_size": "Size",
        "ui_browse_properties_speed": "Speed",
        "ui_browse_properties_volume": "Volume"
    ]

    static func displayText(for raw: String) -> String? {
        displayNames[raw.lowercased()]
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
        // A localization hit is the author's chosen string — return verbatim.
        // Resolve (known-key map / identifier prettify) only on a miss, where raw
        // WPE keys like `ui_browse_properties_scheme_color` would otherwise leak.
        if let localized = selected[cleaned] ?? fallback[cleaned] {
            return Self.clean(localized)
        }
        return Self.resolveDisplayText(cleaned)
    }

    /// Strings to scan when classifying a property as a promotional link: the
    /// raw author value plus any localized variants it resolves to. Returned
    /// *un-cleaned* so link/image markup (`<a href>`, `<img src>`) that lives
    /// only in a localized string is still visible to the detector.
    func detectionCandidates(for raw: String) -> [String] {
        var candidates = [raw]
        let cleaned = Self.clean(raw)
        guard !cleaned.isEmpty else { return candidates }
        if let localized = selected[cleaned] { candidates.append(localized) }
        if let localized = fallback[cleaned], localized != selected[cleaned] {
            candidates.append(localized)
        }
        return candidates
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

    /// Last-resort display resolution for a label that the project did not
    /// localize: a curated known-key map, then `ui_browse_properties_*` /
    /// snake_case / camelCase prettification. Genuine author text (anything with
    /// whitespace or no identifier shape) passes through untouched.
    private static func resolveDisplayText(_ cleaned: String) -> String {
        if let known = KnownWallpaperEngineKeys.displayText(for: cleaned) {
            return known
        }
        if let suffix = browsePropertySuffix(for: cleaned) {
            return prettifyIdentifier(suffix)
        }
        if isIdentifierLike(cleaned) {
            return prettifyIdentifier(cleaned)
        }
        return cleaned
    }

    private static func browsePropertySuffix(for text: String) -> String? {
        let prefix = "ui_browse_properties_"
        let lowered = text.lowercased()
        guard lowered.hasPrefix(prefix), text.count > prefix.count else { return nil }
        return String(text.dropFirst(prefix.count))
    }

    /// Conservative: only snake_case identifiers are prettified. WPE keys use
    /// underscores; camelCase, hyphenated ranges ("4K-8K"), and short tokens
    /// ("4K") are left untouched so genuine author labels are never mangled.
    private static func isIdentifierLike(_ text: String) -> Bool {
        guard !text.isEmpty,
              text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return false
        }
        return text.contains("_")
    }

    private static func prettifyIdentifier(_ raw: String) -> String {
        let spaced = raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return spaced.split(separator: " ").map(titleCasedIdentifierWord).joined(separator: " ")
    }

    private static func titleCasedIdentifierWord(_ word: Substring) -> String {
        let lower = word.lowercased()
        if ["bgm", "css", "fps", "hdr", "html", "rgb", "rgba", "ui", "url", "wpe"].contains(lower) {
            return lower.uppercased()
        }
        guard let first = lower.first else { return "" }
        return String(first).uppercased() + lower.dropFirst()
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

extension WallpaperEngineProjectPropertySchema {
    /// Evaluates a WPE scene condition-form binding literal (the
    /// `visible.user.condition` value, e.g. `"2"`) against the live value of
    /// the bound property. Reuses the same loose number/string matching as
    /// project-property visibility conditions so `.number(2)`, `.string("2")`
    /// and a condition literal `"2"` all compare equal. Used by the scene
    /// parser (full-reload path) and the renderer (incremental patch path).
    static func sceneConditionMatches(
        value: WallpaperEngineProjectPropertyValue?,
        condition: String
    ) -> Bool {
        ConditionEvaluator.matchesLiteral(value: value, condition: condition)
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

    /// Loose equality between a property value and a single condition literal,
    /// reusing `parseLiteral` (bool/number/string coercion) and `matches`
    /// (number tolerance + cross-type `stringValue` fallback).
    static func matchesLiteral(
        value: WallpaperEngineProjectPropertyValue?,
        condition: String
    ) -> Bool {
        value.matches(parseLiteral(condition))
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
        // Strip every leading `!` so JS-style negation chains (`!!flag`) work.
        // Without the loop, `!!flag` keeps one `!` and looks up the literal key
        // "!flag" (missing) → flips to `true` regardless of the actual value.
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
