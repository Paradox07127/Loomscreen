import Foundation

/// One row in the global Wallpaper Engine import history (LRU, capped at 20).
/// Persisted via `GlobalSettings.recentWPEImports` so the Scene tab can show
/// recently imported workshop projects across all screens.
struct WPEHistoryEntry: Codable, Equatable, Sendable, Identifiable {
    let origin: WPEOrigin
    let importedAt: Date
    var lastUsedAt: Date?

    var id: String { origin.workshopID }
}
