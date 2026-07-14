#if !LITE_BUILD
import Foundation
import LiveWallpaperCore

struct WPEProjectSettingsPresentation: Equatable {
    struct Section: Identifiable, Equatable {
        let id: String
        let title: String
        let properties: [WallpaperEngineProjectPropertySchema.Property]
    }

    enum Row: Identifiable, Equatable {
        case sectionHeader(Section)
        case property(WallpaperEngineProjectPropertySchema.Property)

        var id: String {
            switch self {
            case .sectionHeader(let section):
                return "section:\(section.id)"
            case .property(let property):
                return "property:\(property.key)"
            }
        }
    }

    let values: [String: WallpaperEngineProjectPropertyValue]
    let sections: [Section]
    let visibleKeys: Set<String>
    let hasVisibleOverrides: Bool

    init(
        schema: WallpaperEngineProjectPropertySchema,
        overrides: [String: WallpaperEngineProjectPropertyValue],
        excludedKeys: Set<String> = [],
        isInteractive: (WallpaperEngineProjectPropertySchema.PropertyType) -> Bool = Self.isSceneInteractive
    ) {
        let values = schema.effectiveValues(overrides: overrides)
        var sections: [Section] = []
        var currentID: String?
        var currentTitle: String?
        var currentGroupIsVisible = false
        var currentProperties: [WallpaperEngineProjectPropertySchema.Property] = []
        var visibleKeys = Set<String>()

        func flushCurrentSection() {
            guard let currentID,
                  let currentTitle,
                  currentGroupIsVisible,
                  !currentProperties.isEmpty else {
                currentProperties.removeAll(keepingCapacity: true)
                return
            }
            sections.append(Section(
                id: currentID,
                title: currentTitle,
                properties: currentProperties
            ))
            currentProperties.removeAll(keepingCapacity: true)
        }

        for property in schema.properties {
            if property.type == .group {
                flushCurrentSection()
                currentID = property.key
                currentTitle = property.displayText
                currentGroupIsVisible = Self.isVisible(property.condition, values: values)
                continue
            }

            guard !excludedKeys.contains(property.key),
                  isInteractive(property.type),
                  !property.isPromotionalLink,
                  Self.isVisible(property.condition, values: values) else {
                continue
            }

            if currentID == nil {
                currentID = "__ungrouped"
                currentTitle = "Settings"
                currentGroupIsVisible = true
            }

            guard currentGroupIsVisible else {
                continue
            }

            currentProperties.append(property)
            visibleKeys.insert(property.key)
        }
        flushCurrentSection()

        self.values = values
        self.sections = sections
        self.visibleKeys = visibleKeys
        self.hasVisibleOverrides = overrides.keys.contains { visibleKeys.contains($0) }
    }

    static func isSceneInteractive(_ type: WallpaperEngineProjectPropertySchema.PropertyType) -> Bool {
        switch type {
        case .bool, .slider, .combo, .color, .textinput: return true
        case .file, .directory, .group, .text, .unsupported: return false
        }
    }

    static func prunedSectionIDs(
        _ sectionIDs: Set<String>,
        for sections: [Section]
    ) -> Set<String> {
        sectionIDs.intersection(sections.map(\.id))
    }

    func rows(expandedSectionIDs: Set<String>) -> [Row] {
        if sections.count == 1, sections.first?.id == "__ungrouped" {
            guard let section = sections.first else { return [] }
            return section.properties.map(Row.property)
        }

        return sections.flatMap { section -> [Row] in
            var rows: [Row] = [.sectionHeader(section)]
            guard expandedSectionIDs.contains(section.id) else { return rows }
            rows.append(contentsOf: section.properties.map(Row.property))
            return rows
        }
    }

    private static func isVisible(
        _ condition: String?,
        values: [String: WallpaperEngineProjectPropertyValue]
    ) -> Bool {
        WallpaperEngineProjectPropertySchema.visiblePropertyConditionMatches(
            condition: condition,
            values: values
        )
    }
}
#endif
