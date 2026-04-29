import AppKit

/// Builds non-video wallpaper sessions backed by a window.
@MainActor
final class AmbientWallpaperSessionBuilder {
    func makeHTMLSession(source: HTMLSource, config: HTMLConfig, frame: CGRect) -> AmbientWallpaperSession {
        let window = VideoWallpaperWindow(frame: frame)
        let htmlView = HTMLWallpaperView(frame: frame)
        window.setWallpaperMouseInteractionEnabled(config.allowMouseInteraction)
        window.contentView = htmlView

        // Untrusted remote URLs run with JS off no matter what config says.
        let trust = HTMLTrust.evaluate(source: source, trustedHosts: TrustedHostStore.shared.hostSet)
        var effective = config
        effective.allowJavaScript = trust.effectiveAllowJavaScript(requested: config.allowJavaScript)
        if case .untrustedRemote(let host) = trust, config.allowJavaScript {
            Logger.warning("HTML wallpaper: dropping JS for untrusted host \(host)", category: .screenManager)
        }

        htmlView.apply(effective)
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
