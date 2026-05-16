import Foundation

/// One row in the global Wallpaper Engine import history (LRU, capped at 20).
/// Persisted via `GlobalSettings.recentWPEImports` so the Scene tab can show
/// recently imported workshop projects across all screens.
public struct WPEHistoryEntry: Codable, Equatable, Sendable, Identifiable {
    public let origin: WPEOrigin
    public let importedAt: Date
    public var lastUsedAt: Date?

    public init(origin: WPEOrigin, importedAt: Date, lastUsedAt: Date? = nil) {
        self.origin = origin
        self.importedAt = importedAt
        self.lastUsedAt = lastUsedAt
    }

    public var id: String { origin.workshopID }
}
