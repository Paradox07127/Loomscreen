import Foundation

extension ScreenManager {
    func applyBookmark(_ bookmark: WallpaperBookmark, to screen: Screen) {
        Logger.info("Applying bookmark to screen \(screen.id): \(bookmark.wallpaperType.rawValue)", category: .ui)
        switch bookmark.content {
        case .video(let bookmarkData):
            guard let url = try? ResourceUtilities.resolveBookmark(bookmarkData).url else {
                Logger.warning("Bookmark video unresolvable; user may need to re-pick", category: .fileAccess)
                return
            }
            setVideo(url: url, bookmarkData: bookmarkData, for: screen)
        case .html(let source, let config):
            setHTMLWallpaper(source: source, config: config, for: screen)
        case .metalShader(let preset):
            setShaderWallpaper(preset: preset, for: screen)
        case .scene(let descriptor):
            setSceneWallpaper(descriptor: descriptor, origin: bookmark.wpeOrigin, for: screen)
        }
    }
}
