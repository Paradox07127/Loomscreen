import Foundation

/// User-saved shortcut to a video / HTML / shader wallpaper, persisted globally
/// so it survives app relaunch and can be applied to any screen on demand.
struct WallpaperBookmark: Identifiable, Codable, Equatable {
    let id: UUID
    var label: String
    let createdAt: Date
    var content: WallpaperContent
    var sourceDisplayName: String?

    init(
        label: String,
        content: WallpaperContent,
        id: UUID = UUID(),
        createdAt: Date = Date(),
        sourceDisplayName: String? = nil
    ) {
        self.id = id
        self.label = label
        self.content = content
        self.createdAt = createdAt
        self.sourceDisplayName = sourceDisplayName
    }

    var wallpaperType: WallpaperType { content.wallpaperType }

    /// Tells the row what icon and color to paint.
    var iconName: String {
        switch content {
        case .video: return "play.rectangle"
        case .html(let source, _): return source.iconName
        case .metalShader: return "sparkles.rectangle.stack"
        case .scene: return "cube.transparent"
        }
    }
}
