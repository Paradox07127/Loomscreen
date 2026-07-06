import Foundation

/// User-saved shortcut to a video / HTML / shader / WPE scene wallpaper,
/// persisted globally so it survives app relaunch and can be applied to any
/// screen on demand.
///
/// `playbackSettings` carries the rest of the screen's playback / effect
/// state at the moment the bookmark was saved. Applying a bookmark restores
/// the full plan, not just the content pointer. Nil = legacy bookmark
/// (saved before the expansion); the apply path leaves the target screen's
/// existing settings alone in that case.
public struct WallpaperBookmark: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var label: String
    public let createdAt: Date
    public var content: WallpaperContent
    public var sourceDisplayName: String?
    /// Full playback + effect snapshot. Nil on legacy bookmarks.
    public var playbackSettings: BookmarkPlaybackSettings?
    /// Optional Workshop metadata needed to restore WPE scene dependencies and
    /// source-folder access when a scene bookmark is applied later.
    public var wpeOrigin: WPEOrigin?

    public init(
        label: String,
        content: WallpaperContent,
        id: UUID = UUID(),
        createdAt: Date = Date(),
        sourceDisplayName: String? = nil,
        playbackSettings: BookmarkPlaybackSettings? = nil,
        wpeOrigin: WPEOrigin? = nil
    ) {
        self.id = id
        self.label = label
        self.content = content
        self.createdAt = createdAt
        self.sourceDisplayName = sourceDisplayName
        self.playbackSettings = playbackSettings
        self.wpeOrigin = wpeOrigin
    }

    public var wallpaperType: WallpaperType { content.wallpaperType }

    public var iconName: String {
        switch content {
        case .video: return "play.rectangle"
        case .html(let source, _): return source.iconName
        case .metalShader: return "sparkles.rectangle.stack"
        case .scene: return "cube.transparent"
        case .monitor: return "gauge.with.dots.needle.67percent"
        }
    }

}
