import AppKit

/// Builds non-video wallpaper sessions backed by a window.
@MainActor
final class AmbientWallpaperSessionBuilder {
    func makeHTMLSession(source: HTMLSource, config: HTMLConfig, frame: CGRect) -> AmbientWallpaperSession {
        let window = VideoWallpaperWindow(frame: frame)
        let htmlView = HTMLWallpaperView(frame: frame)
        window.contentView = htmlView

        htmlView.apply(config)
        htmlView.loadSource(source)

        window.orderBack(nil)
        return AmbientWallpaperSession(window: window, wallpaperType: .html, performanceTarget: htmlView)
    }

    func makeShaderSession(preset: MetalShaderPreset, frame: CGRect) -> AmbientWallpaperSession {
        let window = VideoWallpaperWindow(frame: frame)
        let metalView = MetalWallpaperView(frame: frame)
        metalView.setPreset(preset)
        window.contentView = metalView
        window.orderBack(nil)
        return AmbientWallpaperSession(window: window, wallpaperType: .metalShader, performanceTarget: metalView)
    }
}
