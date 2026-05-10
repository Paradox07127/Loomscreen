import Foundation

extension ScreenManager {
    func applyBookmark(_ bookmark: WallpaperBookmark, to screen: Screen) {
        Logger.info("Applying bookmark to screen \(screen.id): \(bookmark.wallpaperType.rawValue)", category: .ui)
        switch bookmark.content {
        case .video(let bookmarkData):
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else {
                Logger.warning("Bookmark video unresolvable; user may need to re-pick", category: .fileAccess)
                return
            }
            setVideo(url: url, bookmarkData: bookmarkData, for: screen)
        case .html(let source, let config):
            setHTMLWallpaper(source: source, config: config, for: screen)
        case .metalShader(let preset):
            setShaderWallpaper(preset: preset, for: screen)
        case .scene:
            Logger.warning("Scene bookmark apply is not supported in Phase 2.0", category: .screenManager)
        }
    }
}
