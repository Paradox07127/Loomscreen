import AppKit

/// Builds non-video wallpaper sessions backed by a window.
@MainActor
final class AmbientWallpaperSessionBuilder {
    func makeHTMLSession(source: HTMLSource, config: HTMLConfig, frame: CGRect) -> AmbientWallpaperSession {
        let window = VideoWallpaperWindow(frame: frame)
        let htmlView = HTMLWallpaperView(frame: frame)
        window.contentView = htmlView

        // Untrusted remote URLs run with JS off no matter what config says.
        let trust = HTMLTrust.evaluate(source: source, trustedHosts: TrustedHostStore.shared.hostSet)
        var effective = config
        effective.allowJavaScript = trust.effectiveAllowJavaScript(requested: config.allowJavaScript)
        if case .untrustedRemote(let host) = trust, config.allowJavaScript {
            Logger.warning("HTML wallpaper: dropping JS for untrusted host \(host)", category: .screenManager)
        }

        // Auto-enable physical-pixel layout for Wallpaper Engine folders
        // (detected by sibling project.json) so canvas coords match Windows DIP.
        if !effective.physicalPixelLayout, Self.looksLikeWallpaperEngineFolder(source) {
            effective.physicalPixelLayout = true
            Logger.info("HTML wallpaper: detected Wallpaper Engine project — enabling physical-pixel layout", category: .screenManager)
        }

        htmlView.apply(effective)
        htmlView.loadSource(source)

        // 必须在 contentView 装好之后再切交互态。该方法已经负责 ordering
        // (interactive → makeKeyAndOrderFront / passive → orderBack)，
        // 别再追加额外的 orderBack — 否则会把抬升的交互窗户拉回桌面层、
        // 导致 "Click wallpaper to reveal desktop" 重新生效。
        window.setWallpaperMouseInteractionEnabled(config.allowMouseInteraction)
        return AmbientWallpaperSession(window: window, wallpaperType: .html, performanceTarget: htmlView)
    }

    /// Wallpaper Engine workshop projects ship a `project.json` next to the
    /// entry HTML; presence is a strong signal we should run them in
    /// Windows-DIP mode.
    private static func looksLikeWallpaperEngineFolder(_ source: HTMLSource) -> Bool {
        guard case .folder(let bookmarkData, _) = source else { return false }
        var isStale = false
        guard let folderURL = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return false }
        let didStart = folderURL.startAccessingSecurityScopedResource()
        defer { if didStart { folderURL.stopAccessingSecurityScopedResource() } }
        let manifest = folderURL.appendingPathComponent("project.json")
        return FileManager.default.fileExists(atPath: manifest.path)
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
