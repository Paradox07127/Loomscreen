import LiveWallpaperCore

/// Single source of truth for the WallpaperType → SF Symbol mapping used by display rows (sidebar `ScreenRow`, menu-bar `MenuBarDisplayRow`).
extension WallpaperType {
    var displaySymbolName: String {
        switch self {
        case .video:
            return "play.rectangle"
        case .html:
            return "globe"
        case .metalShader:
            return "sparkles.rectangle.stack"
        case .scene:
            return "cube.transparent"
        case .monitor:
            return "gauge.with.dots.needle.67percent"
        }
    }

    /// `nil` = no wallpaper configured; falls back to the bare display glyph.
    static func displaySymbolName(for type: WallpaperType?) -> String {
        type?.displaySymbolName ?? "display"
    }
}
