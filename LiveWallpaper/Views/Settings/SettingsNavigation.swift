import Foundation
import LiveWallpaperCore

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
        let items = availableItems(
            capabilities: capabilities,
            includeWorkshopOnline: includeWorkshopOnline
        )
        let terms = query
            .localizedStandardTokens
            .filter { !$0.isEmpty }

        guard !terms.isEmpty else { return items }

        return items.filter { item in
            let searchableText = item.searchableText
            return terms.allSatisfy { searchableText.localizedCaseInsensitiveContains($0) }
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
