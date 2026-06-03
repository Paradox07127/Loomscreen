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
        // Package-/source-backed scenes read assets — and `project.json` — in
        // place from the source, leaving wpe-cache empty for that id. Only the
        // legacy `.cache` backing requires the extracted directory to exist.
        guard let assets = sceneAssets(
            descriptor: descriptor,
            origin: origin,
            cacheURL: cacheURL,
            fileManager: fileManager
        ) else {
            Logger.warning("Scene source unavailable for in-place read: \(descriptor.workshopID)", category: .screenManager)
            return nil
        }
        if descriptor.assetStorage == .cache {
            guard fileManager.fileExists(atPath: cacheURL.path) else {
                Logger.warning("Scene descriptor cache directory missing: \(cacheURL.path)", category: .screenManager)
                return nil
            }
        }

        let entryAvailable: Bool
        if let provider = assets.provider {
            entryAvailable = provider.exists(atRelativePath: descriptor.entryFile)
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
                assetProvider: assets.provider,
                projectManifestRootURL: assets.projectRoot,
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

    /// Resolves both the in-place asset provider AND the `project.json` root for
    /// a scene. Legacy `.cache` scenes get a `nil` provider (renderer defaults to
    /// the cache directory) with the cache dir as project root. Source-/package-
    /// backed scenes get an in-place provider with the *source folder* as project
    /// root (where `project.json` sits next to the assets), so nothing is cached;
    /// returns `nil` if that source can't be opened. The returned provider owns
    /// the source's security scope for its lifetime, which also covers the
    /// renderer's `project.json` reads under the same root.
    private func sceneAssets(
        descriptor: SceneDescriptor,
        origin: WPEOrigin?,
        cacheURL: URL,
        fileManager: FileManager
    ) -> (provider: (any WPESceneAssetProvider)?, projectRoot: URL)? {
        switch descriptor.assetStorage {
        case .cache:
            return (nil, cacheURL)
        case .sourceDirectory:
            guard let source = resolveSourceFolder(origin: origin) else { return nil }
            let provider = WPESecurityScopedSceneAssetProvider(
                wrapped: WPEDirectorySceneAssetProvider(rootURL: source.url),
                scopedURL: source.url,
                didStartAccessing: source.didStart
            )
            return (provider, source.url)
        case .packageSource(let fileName):
            guard let source = resolveSourceFolder(origin: origin) else { return nil }
            let packageURL = source.url.appendingPathComponent(fileName, isDirectory: false)
            guard fileManager.fileExists(atPath: packageURL.path),
                  let pkg = try? WPEPackageSceneAssetProvider(packageURL: packageURL) else {
                if source.didStart { source.url.stopAccessingSecurityScopedResource() }
                Logger.warning("Scene package missing/unreadable: \(packageURL.lastPathComponent)", category: .screenManager)
                return nil
            }
            let provider = WPESecurityScopedSceneAssetProvider(
                wrapped: pkg, scopedURL: source.url, didStartAccessing: source.didStart
            )
            return (provider, source.url)
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
