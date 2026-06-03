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
        effective.muteAudio = trust.effectiveMuteAudio(requested: config.muteAudio)
        effective.audioVolume = trust.effectiveAudioVolume(requested: config.audioVolume)

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
        if case .untrustedRemote(let origin) = compatibility.trust {
            if config.allowJavaScript {
                Logger.warning("HTML wallpaper: dropping JS for untrusted origin \(origin.rawValue)", category: .screenManager)
            }
            if !config.muteAudio || config.audioVolume > 0 {
                Logger.warning("HTML wallpaper: force-muting untrusted origin \(origin.rawValue)", category: .screenManager)
            }
        }
        if compatibility.enabledPhysicalPixelLayout {
            Logger.info("HTML wallpaper: detected Wallpaper Engine project — enabling physical-pixel layout", category: .screenManager)
        }

        let htmlView = HTMLWallpaperView(frame: frame, initialEphemeral: effective.requiresEphemeralStorage)
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

    #if !LITE_BUILD
    func makeShaderSession(source: ShaderSource, frame: CGRect) -> AmbientWallpaperSession {
        let window = VideoWallpaperWindow(frame: frame)
        let metalView = MetalWallpaperView(frame: frame)
        metalView.apply(source: source)
        window.contentView = metalView
        window.orderBack(nil)
        return AmbientWallpaperSession(window: window, wallpaperType: .metalShader, performanceTarget: metalView)
    }
    #endif

    #if !LITE_BUILD
    /// Builds a scene wallpaper session.
    func makeSceneSession(
        descriptor: SceneDescriptor,
        origin: WPEOrigin? = nil,
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
        // Package-/source-backed scenes read assets in place; only the legacy
        // cache backing requires the extracted directory to exist. The cache
        // root URL is still passed through for the small `project.json` the
        // property schema reads (kept even for package-backed imports).
        let assetProvider = sceneAssetProvider(descriptor: descriptor, origin: origin, fileManager: fileManager)
        switch descriptor.assetStorage {
        case .cache:
            guard fileManager.fileExists(atPath: cacheURL.path) else {
                Logger.warning("Scene descriptor cache directory missing: \(cacheURL.path)", category: .screenManager)
                return nil
            }
        case .sourceDirectory, .packageSource:
            guard assetProvider != nil else {
                Logger.warning("Scene source unavailable for in-place read: \(descriptor.workshopID)", category: .screenManager)
                return nil
            }
        }

        let entryAvailable: Bool
        if let assetProvider {
            entryAvailable = assetProvider.exists(atRelativePath: descriptor.entryFile)
        } else {
            entryAvailable = (try? SceneResourceResolver(cacheRootURL: cacheURL)
                .resolveExistingFileURL(relativePath: descriptor.entryFile)) != nil
        }
        guard entryAvailable else {
            Logger.warning("Scene descriptor entry file failed safety check: \(descriptor.entryFile)", category: .screenManager)
            return nil
        }

        let rendererFrame = CGRect(origin: .zero, size: frame.size)
        // Metal is the only scene renderer. A Metal failure surfaces as the
        // session's loadError without falling back to another backend.
        guard let device = MTLCreateSystemDefaultDevice() else {
            Logger.warning("Metal scene renderer unavailable on this Mac", category: .screenManager)
            return nil
        }
        let renderer: WPEMetalSceneRenderer
        do {
            renderer = try WPEMetalSceneRenderer(
                descriptor: descriptor,
                cacheRootURL: cacheURL,
                assetProvider: assetProvider,
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

    /// Builds the in-place asset provider for a scene. Returns `nil` for legacy
    /// `.cache` scenes (the renderer then defaults to the cache directory) and
    /// for source-/package-backed scenes whose source can't be opened (the
    /// caller treats that as a failed build).
    private func sceneAssetProvider(
        descriptor: SceneDescriptor,
        origin: WPEOrigin?,
        fileManager: FileManager
    ) -> (any WPESceneAssetProvider)? {
        switch descriptor.assetStorage {
        case .cache:
            return nil
        case .sourceDirectory:
            guard let source = resolveSourceFolder(origin: origin) else { return nil }
            let provider = WPEDirectorySceneAssetProvider(rootURL: source.url)
            return WPESecurityScopedSceneAssetProvider(
                wrapped: provider, scopedURL: source.url, didStartAccessing: source.didStart
            )
        case .packageSource(let fileName):
            guard let source = resolveSourceFolder(origin: origin) else { return nil }
            let packageURL = source.url.appendingPathComponent(fileName, isDirectory: false)
            guard fileManager.fileExists(atPath: packageURL.path),
                  let provider = try? WPEPackageSceneAssetProvider(packageURL: packageURL) else {
                if source.didStart { source.url.stopAccessingSecurityScopedResource() }
                Logger.warning("Scene package missing/unreadable: \(packageURL.lastPathComponent)", category: .screenManager)
                return nil
            }
            return WPESecurityScopedSceneAssetProvider(
                wrapped: provider, scopedURL: source.url, didStartAccessing: source.didStart
            )
        }
    }

    /// Resolves a scene's source folder from its origin bookmark and opens its
    /// security scope. The caller owns the scope for the provider's lifetime.
    private func resolveSourceFolder(origin: WPEOrigin?) -> (url: URL, didStart: Bool)? {
        guard let origin,
              case .success(let resolved) = SecurityScopedBookmarkResolver.shared.resolve(
                origin.sourceFolderBookmark, target: .transient
              ) else {
            return nil
        }
        return (resolved.url, resolved.url.startAccessingSecurityScopedResource())
    }
    #endif

}
