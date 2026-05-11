import AppKit
import Metal

/// Builds non-video wallpaper sessions backed by a window.
@MainActor
final class AmbientWallpaperSessionBuilder {
    func makeHTMLSession(source: HTMLSource, config: HTMLConfig, frame: CGRect) -> AmbientWallpaperSession {
        let window = VideoWallpaperWindow(frame: frame)

        // Untrusted remote URLs run with JS off no matter what config says.
        let trust = HTMLTrust.evaluate(source: source, trustedOrigins: TrustedHostStore.shared.originSet)
        var effective = config
        effective.allowJavaScript = trust.effectiveAllowJavaScript(requested: config.allowJavaScript)
        if case .untrustedRemote(let origin) = trust, config.allowJavaScript {
            Logger.warning("HTML wallpaper: dropping JS for untrusted origin \(origin.rawValue)", category: .screenManager)
        }

        // Auto-enable physical-pixel layout for Wallpaper Engine folders
        // (detected by sibling project.json) so canvas coords match Windows DIP.
        if !effective.physicalPixelLayout, Self.looksLikeWallpaperEngineFolder(source) {
            effective.physicalPixelLayout = true
            Logger.info("HTML wallpaper: detected Wallpaper Engine project — enabling physical-pixel layout", category: .screenManager)
        }

        // `WKWebsiteDataStore` is locked into the configuration at WKWebView
        // init time, so the ephemeral preference must be resolved here before
        // we instantiate the view.
        let htmlView = HTMLWallpaperView(frame: frame, initialEphemeral: effective.useEphemeralStorage)
        window.contentView = htmlView

        let session = AmbientWallpaperSession(window: window, wallpaperType: .html, performanceTarget: htmlView)
        // Bridge HTML navigation failures to the session before kicking off the
        // first load so an immediate sandbox failure still surfaces.
        htmlView.onError = { [weak session] error in
            session?.recordRuntimeError(error)
        }

        htmlView.apply(effective)
        htmlView.loadSource(source)

        // 必须在 contentView 装好之后再切交互态。该方法已经负责 ordering
        // (interactive → makeKeyAndOrderFront / passive → orderBack)，
        // 别再追加额外的 orderBack — 否则会把抬升的交互窗户拉回桌面层、
        // 导致 "Click wallpaper to reveal desktop" 重新生效。
        window.setWallpaperMouseInteractionEnabled(config.allowMouseInteraction)
        return session
    }

    /// Wallpaper Engine workshop projects ship a `project.json` next to the
    /// entry HTML; presence is a strong signal we should run them in
    /// Windows-DIP mode.
    private static func looksLikeWallpaperEngineFolder(_ source: HTMLSource) -> Bool {
        guard case .folder(let bookmarkData, _) = source else { return false }
        guard let folderURL = try? ResourceUtilities.resolveBookmark(bookmarkData).url else { return false }
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

    /// Builds a scene wallpaper session.
    /// Returns nil when the descriptor's cache directory cannot be located —
    /// caller falls back to the not-configured Scene tab placeholder rather
    /// than mounting an empty renderer view.
    func makeSceneSession(
        descriptor: SceneDescriptor,
        frame: CGRect,
        dependencyMounts: [WPEAssetMount] = [],
        rendererBackend: WPESceneRendererBackend = .spriteKit,
        applicationSupportRootURL: URL? = nil,
        fileManager: FileManager = .default
    ) -> SceneWallpaperSession? {
        let supportRoot: URL
        if let applicationSupportRootURL {
            supportRoot = applicationSupportRootURL
        } else if let resolved = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            supportRoot = resolved.appendingPathComponent("LiveWallpaper", isDirectory: true)
        } else {
            return nil
        }

        // Re-validate cache path before joining — a tampered descriptor
        // with `..` segments must never escape application support.
        guard WPEPathSafety.isSafeCacheRelativePath(descriptor.cacheRelativePath) else {
            Logger.warning("Scene descriptor cache path failed safety check: \(descriptor.cacheRelativePath)", category: .screenManager)
            return nil
        }
        // Resolve symlinks BEFORE the containment check — otherwise a cache
        // root that is itself a symlink (e.g. from a malicious migration
        // tool) would point outside Application Support and still pass the
        // textual prefix match.
        let safeSupportRoot = supportRoot.standardizedFileURL.resolvingSymlinksInPath()
        let cacheURL = safeSupportRoot
            .appendingPathComponent(descriptor.cacheRelativePath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard WPEPathSafety.contains(cacheURL, in: safeSupportRoot) else {
            Logger.warning("Scene descriptor cache escapes app support: \(descriptor.cacheRelativePath)", category: .screenManager)
            return nil
        }
        guard fileManager.fileExists(atPath: cacheURL.path) else {
            Logger.warning("Scene descriptor cache directory missing: \(cacheURL.path)", category: .screenManager)
            return nil
        }
        // Last-mile entry file probe so we don't mount an SKView that the
        // controller will immediately throw out of `load()`.
        let entryProbe = SceneResourceResolver(cacheRootURL: cacheURL)
        guard (try? entryProbe.resolveExistingFileURL(relativePath: descriptor.entryFile)) != nil else {
            Logger.warning("Scene descriptor entry file failed safety check: \(descriptor.entryFile)", category: .screenManager)
            return nil
        }

        let rendererFrame = CGRect(origin: .zero, size: frame.size)
        let renderer: WPESceneRenderer
        switch rendererBackend {
        case .spriteKit:
            renderer = SceneRenderingController(
                descriptor: descriptor,
                cacheRootURL: cacheURL,
                dependencyMounts: dependencyMounts,
                frame: rendererFrame
            )
        case .metalExperimental:
            guard let device = MTLCreateSystemDefaultDevice() else {
                Logger.warning("Experimental Metal scene renderer requested but Metal is unavailable", category: .screenManager)
                return nil
            }
            do {
                renderer = try WPEMetalSceneRenderer(
                    descriptor: descriptor,
                    cacheRootURL: cacheURL,
                    dependencyMounts: dependencyMounts,
                    frame: rendererFrame,
                    device: device
                )
            } catch {
                Logger.warning("Experimental Metal scene renderer could not be created: \(error.localizedDescription)", category: .screenManager)
                return nil
            }
        }

        let window = VideoWallpaperWindow(frame: frame)
        window.contentView = renderer.nsView
        window.orderBack(nil)

        let session = SceneWallpaperSession(window: window, renderer: renderer)
        session.startLoadIfNeeded()
        return session
    }

}
