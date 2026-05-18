import AppKit
import Metal

struct HTMLWallpaperCompatibilityResult {
    let config: HTMLConfig
    let trust: HTMLTrust
    let enabledPhysicalPixelLayout: Bool
}

enum HTMLWallpaperCompatibilityPolicy {
    static func runtimeConfig(
        source: HTMLSource,
        config: HTMLConfig,
        trustedOrigins: Set<TrustedHTMLOrigin>
    ) -> HTMLWallpaperCompatibilityResult {
        let trust = HTMLTrust.evaluate(source: source, trustedOrigins: trustedOrigins)
        var effective = config
        effective.allowJavaScript = trust.effectiveAllowJavaScript(requested: config.allowJavaScript)

        let shouldEnablePhysicalPixels = !effective.physicalPixelLayout
            && looksLikeWallpaperEngineFolder(source)
        if shouldEnablePhysicalPixels {
            effective.physicalPixelLayout = true
        }

        return HTMLWallpaperCompatibilityResult(
            config: effective,
            trust: trust,
            enabledPhysicalPixelLayout: shouldEnablePhysicalPixels
        )
    }

    /// Wallpaper Engine workshop projects ship a `project.json` next to the entry HTML; presence is a strong signal we should run them in Windows-DIP mode.
    static func looksLikeWallpaperEngineFolder(_ source: HTMLSource) -> Bool {
        guard case .folder(let bookmarkData, _) = source else { return false }
        guard case .success(let resolved) = SecurityScopedBookmarkResolver.shared.resolve(
            bookmarkData,
            target: .transient
        ) else { return false }
        let folderURL = resolved.url
        let didStart = folderURL.startAccessingSecurityScopedResource()
        defer { if didStart { folderURL.stopAccessingSecurityScopedResource() } }
        let manifest = folderURL.appendingPathComponent("project.json")
        return FileManager.default.fileExists(atPath: manifest.path)
    }
}

/// Builds non-video wallpaper sessions backed by a window.
@MainActor
final class AmbientWallpaperSessionBuilder {
    func makeHTMLSession(source: HTMLSource, config: HTMLConfig, frame: CGRect) -> AmbientWallpaperSession {
        let window = VideoWallpaperWindow(frame: frame)

        let compatibility = HTMLWallpaperCompatibilityPolicy.runtimeConfig(
            source: source,
            config: config,
            trustedOrigins: TrustedHostStore.shared.originSet
        )
        let effective = compatibility.config
        if case .untrustedRemote(let origin) = compatibility.trust, config.allowJavaScript {
            Logger.warning("HTML wallpaper: dropping JS for untrusted origin \(origin.rawValue)", category: .screenManager)
        }
        if compatibility.enabledPhysicalPixelLayout {
            Logger.info("HTML wallpaper: detected Wallpaper Engine project — enabling physical-pixel layout", category: .screenManager)
        }

        let htmlView = HTMLWallpaperView(frame: frame, initialEphemeral: effective.useEphemeralStorage)
        window.contentView = htmlView

        let session = AmbientWallpaperSession(window: window, wallpaperType: .html, performanceTarget: htmlView)
        htmlView.onError = { [weak session] error in
            session?.recordRuntimeError(error)
        }

        htmlView.apply(effective)
        htmlView.loadSource(source)

        window.setWallpaperMouseInteractionEnabled(config.allowMouseInteraction)
        return session
    }

    func makeShaderSession(preset: MetalShaderPreset, frame: CGRect) -> AmbientWallpaperSession {
        let window = VideoWallpaperWindow(frame: frame)
        let metalView = MetalWallpaperView(frame: frame)
        metalView.setPreset(preset)
        window.contentView = metalView
        window.orderBack(nil)
        return AmbientWallpaperSession(window: window, wallpaperType: .metalShader, performanceTarget: metalView)
    }

    #if !LITE_BUILD
    /// Builds a scene wallpaper session.
    func makeSceneSession(
        descriptor: SceneDescriptor,
        frame: CGRect,
        dependencyMounts: [WPEAssetMount] = [],
        engineAssetsRootURL: URL? = nil,
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

        guard WPEPathSafety.isSafeCacheRelativePath(descriptor.cacheRelativePath) else {
            Logger.warning("Scene descriptor cache path failed safety check: \(descriptor.cacheRelativePath)", category: .screenManager)
            return nil
        }
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
        let entryProbe = SceneResourceResolver(cacheRootURL: cacheURL)
        guard (try? entryProbe.resolveExistingFileURL(relativePath: descriptor.entryFile)) != nil else {
            Logger.warning("Scene descriptor entry file failed safety check: \(descriptor.entryFile)", category: .screenManager)
            return nil
        }

        let rendererFrame = CGRect(origin: .zero, size: frame.size)
        guard let device = MTLCreateSystemDefaultDevice() else {
            Logger.warning("Metal scene renderer requested but Metal is unavailable", category: .screenManager)
            return nil
        }
        let renderer: WPESceneRenderer
        do {
            renderer = try WPEMetalSceneRenderer(
                descriptor: descriptor,
                cacheRootURL: cacheURL,
                dependencyMounts: dependencyMounts,
                engineAssetsRootURL: engineAssetsRootURL,
                frame: rendererFrame,
                device: device
            )
        } catch {
            Logger.warning("Metal scene renderer could not be created: \(error.localizedDescription)", category: .screenManager)
            return nil
        }

        let window = VideoWallpaperWindow(frame: frame)
        window.contentView = renderer.nsView
        window.orderBack(nil)

        let session = SceneWallpaperSession(window: window, renderer: renderer)
        session.startLoadIfNeeded()
        return session
    }
    #endif

}
