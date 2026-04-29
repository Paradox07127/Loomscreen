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

        // 必须在 contentView 装好之后再切交互态。该方法已经负责 ordering
        // (interactive → makeKeyAndOrderFront / passive → orderBack)，
        // 别再追加额外的 orderBack — 否则会把抬升的交互窗户拉回桌面层、
        // 导致 "Click wallpaper to reveal desktop" 重新生效。
        window.setWallpaperMouseInteractionEnabled(config.allowMouseInteraction)
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
