import Foundation
import LiveWallpaperCore

enum SettingsSearchAnchor: String, Hashable, Identifiable, Sendable {
    case displayDefaultsVideo
    case displayDefaultsWeb
    case displayDefaultsShader
    case displayDefaultsScene
    case shortcutsMaster
    case shortcutsGlobal
    case storageDashboard
    case storageCaches
    case workshopSetup
    case workshopContent

    var id: String { rawValue }
}

struct SettingsNavigationSearchResult: Identifiable, Equatable {
    let item: SettingsNavigationItem
    let anchor: SettingsSearchAnchor?
    let matchHint: String?

    var id: String {
        "\(item.destination.rawValue):\(anchor?.rawValue ?? "category")"
    }

    var destination: SettingsNavigation { item.destination }
    var title: String { item.title }
    var systemImage: String { item.systemImage }
}

enum SettingsNavigation: String, CaseIterable, Hashable, Identifiable {
    case general
    case displayDefaults
    case performancePower
    case audioResponse
    case weather
    case shortcuts
    case storage
    case backupRestore
    case workshopSetup
    case advanced
    case about

    var id: String { rawValue }

    static func availableItems(
        capabilities: ProductCapabilities,
        includeWorkshopOnline: Bool = false
    ) -> [SettingsNavigationItem] {
        allItems.filter { item in
            switch item.destination {
            case .storage:
                capabilities.enabledFeatures.contains(.wpeImport)
            case .workshopSetup:
                capabilities.sku == .pro
                    && (includeWorkshopOnline || capabilities.enabledFeatures.contains(.workshopOnline))
            default:
                true
            }
        }
    }

    static func filteredItems(
        matching query: String,
        capabilities: ProductCapabilities,
        includeWorkshopOnline: Bool = false
    ) -> [SettingsNavigationItem] {
        filteredResults(
            matching: query,
            capabilities: capabilities,
            includeWorkshopOnline: includeWorkshopOnline
        ).map(\.item)
    }

    static func filteredResults(
        matching query: String,
        capabilities: ProductCapabilities,
        includeWorkshopOnline: Bool = false
    ) -> [SettingsNavigationSearchResult] {
        let items = availableItems(
            capabilities: capabilities,
            includeWorkshopOnline: includeWorkshopOnline
        )
        let terms = query
            .localizedStandardTokens
            .filter { !$0.isEmpty }

        guard !terms.isEmpty else {
            return items.map {
                SettingsNavigationSearchResult(item: $0, anchor: nil, matchHint: nil)
            }
        }

        return items.compactMap { item in
            if let target = item.searchTargets(capabilities: capabilities).first(where: { $0.matches(terms: terms) }) {
                return SettingsNavigationSearchResult(
                    item: item,
                    anchor: target.anchor,
                    matchHint: target.matchHint(matching: terms)
                )
            }

            let searchableText = item.searchableText
            guard terms.allSatisfy({ searchableText.localizedCaseInsensitiveContains($0) }) else {
                return nil
            }
            return SettingsNavigationSearchResult(
                item: item,
                anchor: nil,
                matchHint: item.searchMatchHint(matching: query)
            )
        }
    }

    private static let allItems: [SettingsNavigationItem] = [
        SettingsNavigationItem(
            destination: .general,
            title: "General",
            systemImage: "gearshape",
            keywords: ["language", "login", "dock", "lock screen", "behavior"]
        ),
        SettingsNavigationItem(
            destination: .displayDefaults,
            title: "Display Defaults",
            systemImage: "rectangle.3.group",
            keywords: [
                "display", "defaults", "display defaults", "screen defaults", "screen default",
                "playback defaults", "reset display", "new display", "baseline",
                "frame rate", "fps", "volume", "mute", "scaling", "color space", "interaction",
                "帧率", "屏幕默认", "显示默认", "預設", "影格率", "フレームレート"
            ]
        ),
        SettingsNavigationItem(
            destination: .performancePower,
            title: "Performance",
            systemImage: "bolt.circle",
            keywords: ["power", "battery", "fullscreen", "game", "covered", "frame rate", "fps", "帧率", "memory", "video preload"]
        ),
        SettingsNavigationItem(
            destination: .audioResponse,
            title: "Audio Response",
            systemImage: "waveform",
            keywords: ["audio", "music", "sound", "reactive", "frequency spectrum"]
        ),
        SettingsNavigationItem(
            destination: .weather,
            title: "Weather",
            systemImage: "cloud.sun",
            keywords: ["weather", "location", "rain", "snow", "fog", "conditions"]
        ),
        SettingsNavigationItem(
            destination: .shortcuts,
            title: "Shortcuts",
            systemImage: "command",
            keywords: ["global shortcuts", "hotkeys", "keyboard"]
        ),
        SettingsNavigationItem(
            destination: .storage,
            title: "Storage",
            systemImage: "internaldrive",
            keywords: ["cache", "disk", "wallpaper engine", "downloaded projects", "clear"]
        ),
        SettingsNavigationItem(
            destination: .backupRestore,
            title: "Backup & Restore",
            systemImage: "arrow.triangle.2.circlepath",
            keywords: ["import", "export", "configuration", "backup", "restore", "display defaults", "bookmarks"]
        ),
        SettingsNavigationItem(
            destination: .workshopSetup,
            title: "Workshop",
            systemImage: "cube.transparent",
            keywords: ["steam", "api key", "steamcmd", "doctor", "online browse"]
        ),
        SettingsNavigationItem(
            destination: .advanced,
            title: "Advanced",
            systemImage: "slider.horizontal.3",
            keywords: ["developer mode", "logs", "diagnostics"]
        ),
        SettingsNavigationItem(
            destination: .about,
            title: "About",
            systemImage: "info.circle",
            keywords: ["version", "github", "report bug", "welcome tour"]
        )
    ]
}

struct SettingsNavigationItem: Identifiable, Equatable {
    let destination: SettingsNavigation
    let title: String
    let systemImage: String
    let keywords: [String]

    var id: SettingsNavigation { destination }

    fileprivate var searchableText: String {
        ([title] + keywords).joined(separator: " ")
    }

    fileprivate func searchTargets(capabilities: ProductCapabilities) -> [SettingsNavigationSearchTarget] {
        switch destination {
        case .displayDefaults:
            var targets: [SettingsNavigationSearchTarget] = []
            if capabilities.canRender(.video) {
                targets.append(
                    SettingsNavigationSearchTarget(
                        label: "Video",
                        anchor: .displayDefaultsVideo,
                        keywords: [
                            "video", "frame rate", "fps", "volume", "mute", "scaling",
                            "span displays", "color space", "帧率", "影格率", "フレームレート"
                        ]
                    )
                )
            }
            if capabilities.canRender(.html) {
                targets.append(
                    SettingsNavigationSearchTarget(
                        label: "Web",
                        anchor: .displayDefaultsWeb,
                        keywords: [
                            "web", "html", "interaction", "pointer", "click", "mute audio",
                            "web audio"
                        ]
                    )
                )
            }
            if capabilities.canRender(.metalShader) {
                targets.append(
                    SettingsNavigationSearchTarget(
                        label: "Shader",
                        anchor: .displayDefaultsShader,
                        keywords: ["shader", "metal shader", "frame rate", "fps", "帧率"]
                    )
                )
            }
            if capabilities.canRender(.scene) {
                targets.append(
                    SettingsNavigationSearchTarget(
                        label: "Scene",
                        anchor: .displayDefaultsScene,
                        keywords: [
                            "scene", "wallpaper engine", "frame rate", "fps", "scaling",
                            "interaction", "follow cursor"
                        ]
                    )
                )
            }
            return targets
        case .shortcuts:
            return [
                SettingsNavigationSearchTarget(
                    label: "Shortcuts",
                    anchor: .shortcutsMaster,
                    keywords: ["enable global shortcuts", "master switch", "shortcuts"]
                ),
                SettingsNavigationSearchTarget(
                    label: "Global Shortcuts",
                    anchor: .shortcutsGlobal,
                    keywords: ["global shortcuts", "hotkeys", "keyboard", "bindings"]
                )
            ]
        case .storage:
            return [
                SettingsNavigationSearchTarget(
                    label: "Storage",
                    anchor: .storageDashboard,
                    keywords: [
                        "storage", "downloaded projects", "engine assets", "projects",
                        "archives", "download archives", "reclaim"
                    ]
                ),
                SettingsNavigationSearchTarget(
                    label: "Caches",
                    anchor: .storageCaches,
                    keywords: [
                        "cache", "caches", "video cache", "scene video texture cache",
                        "clear all caches", "wallpaper engine cache"
                    ]
                )
            ]
        case .workshopSetup:
            return [
                SettingsNavigationSearchTarget(
                    label: "Setup",
                    anchor: .workshopSetup,
                    keywords: [
                        "steam", "api key", "steam web api key", "steamcmd",
                        "doctor", "wallpaper engine assets", "engine assets",
                        "download from steam"
                    ]
                ),
                SettingsNavigationSearchTarget(
                    label: "Content",
                    anchor: .workshopContent,
                    keywords: ["mature", "blur mature thumbnails", "hide downloaded", "library"]
                )
            ]
        default:
            return []
        }
    }

    func searchMatchHint(matching query: String) -> String? {
        let terms = query.localizedStandardTokens.filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }

        let candidates = [title] + keywords
        let exactCandidate = candidates.first { candidate in
            terms.allSatisfy { candidate.localizedCaseInsensitiveContains($0) }
        }
        if let exactCandidate, exactCandidate.localizedCaseInsensitiveCompare(title) != .orderedSame {
            return exactCandidate.formattedSearchHint
        }

        let partialCandidates = candidates.filter { candidate in
            terms.contains { candidate.localizedCaseInsensitiveContains($0) }
        }
        let hints = partialCandidates
            .filter { $0.localizedCaseInsensitiveCompare(title) != .orderedSame }
            .prefix(2)
            .map(\.formattedSearchHint)

        guard !hints.isEmpty else { return nil }
        return hints.joined(separator: ", ")
    }
}

private struct SettingsNavigationSearchTarget: Equatable {
    let label: String
    let anchor: SettingsSearchAnchor
    let keywords: [String]

    private var searchableText: String {
        ([label] + keywords).joined(separator: " ")
    }

    func matches(terms: [String]) -> Bool {
        terms.allSatisfy { searchableText.localizedCaseInsensitiveContains($0) }
    }

    func matchHint(matching terms: [String]) -> String {
        let candidates = [label] + keywords
        guard let candidate = candidates.first(where: { candidate in
            terms.allSatisfy { candidate.localizedCaseInsensitiveContains($0) }
        }) else {
            return label
        }

        if candidate.localizedCaseInsensitiveCompare(label) == .orderedSame {
            return label
        }

        return "\(label): \(candidate.formattedSearchHint)"
    }
}

private extension String {
    var localizedStandardTokens: [String] {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    var formattedSearchHint: String {
        split(separator: " ")
            .map { token in
                token.lowercased() == "fps" ? "FPS" : token.capitalized
            }
            .joined(separator: " ")
    }
}
