import AppKit
import LiveWallpaperCore
import LiveWallpaperVideoWeb
import Metal

#if !LITE_BUILD
import LiveWallpaperProWPE
#endif

#if LITE_BUILD
private enum WPEPathSafety {
    static func isSafeRelativePath(_ value: String) -> Bool {
        !value.isEmpty
            && !value.hasPrefix("/")
            && !value.contains("..")
            && value != "."
    }

    static func isSafeCacheRelativePath(_ path: String) -> Bool {
        path.hasPrefix("wpe-cache/")
            && !path.contains("\\")
            && !path.contains("..")
            && !path.contains("//")
    }

    static func contains(_ child: URL, in parent: URL) -> Bool {
        let childPath = normalizedPath(child.path(percentEncoded: false))
        let parentPath = normalizedPath(parent.path(percentEncoded: false))
        return childPath == parentPath || childPath.hasPrefix(parentPath + "/")
    }

    static func resourceURL(root: URL, relativePath: String) -> URL? {
        guard isSafeRelativePath(relativePath) else { return nil }
        return containedResourceURL(root: root, relativePath: relativePath)
    }

    private static func containedResourceURL(root: URL, relativePath: String) -> URL? {
        let rootURL = root.standardizedFileURL.resolvingSymlinksInPath()
        let url = rootURL
            .appendingPathComponent(relativePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard contains(url, in: rootURL) else { return nil }
        return url
    }

    private static func normalizedPath(_ path: String) -> String {
        var normalized = path
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
}
#endif

struct HTMLWallpaperCompatibilityResult {
    let config: HTMLConfig
    let trust: HTMLTrust
    let enabledPhysicalPixelLayout: Bool
}

enum HTMLWallpaperCompatibilityPolicy {
    static func runtimeConfig(
        source: HTMLSource,
        config: HTMLConfig,
        trustedOrigins: Set<TrustedHTMLOrigin>,
        bookmarkResolver: SecurityScopedBookmarkResolver = .shared
    ) -> HTMLWallpaperCompatibilityResult {
        let trust = HTMLTrust.evaluate(source: source, trustedOrigins: trustedOrigins)
        var effective = config
        effective.allowJavaScript = trust.effectiveAllowJavaScript(requested: config.allowJavaScript)
        effective.muteAudio = trust.effectiveMuteAudio(requested: config.muteAudio)
        effective.audioVolume = trust.effectiveAudioVolume(requested: config.audioVolume)

        let shouldEnablePhysicalPixels = !effective.physicalPixelLayout
            && shouldAutoEnablePhysicalPixelLayout(source, bookmarkResolver: bookmarkResolver)
        if shouldEnablePhysicalPixels {
            effective.physicalPixelLayout = true
        }

        return HTMLWallpaperCompatibilityResult(
            config: effective,
            trust: trust,
            enabledPhysicalPixelLayout: shouldEnablePhysicalPixels
        )
    }

    /// Wallpaper Engine workshop projects ship a `project.json` next to the
    /// entry HTML. Older canvas payloads generally need physical-pixel layout,
    /// while modern Three/PIXI-style pages that read `devicePixelRatio` already
    /// size their own backing store and must remain in CSS-point layout.
    static func shouldAutoEnablePhysicalPixelLayout(
        _ source: HTMLSource,
        bookmarkResolver: SecurityScopedBookmarkResolver = .shared
    ) -> Bool {
        guard case .folder(_, let indexFileName) = source else { return false }
        return withResolvedFolderURL(source, bookmarkResolver: bookmarkResolver) { folderURL in
            shouldAutoEnablePhysicalPixelLayout(folderURL: folderURL, indexFileName: indexFileName)
        } ?? false
    }

    static func shouldAutoEnablePhysicalPixelLayout(folderURL: URL, indexFileName: String) -> Bool {
        let manifest = folderURL.appendingPathComponent("project.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else { return false }
        return !entryHTMLLooksDPRAware(folderURL: folderURL, indexFileName: indexFileName)
    }

    private static func withResolvedFolderURL<T>(
        _ source: HTMLSource,
        bookmarkResolver: SecurityScopedBookmarkResolver,
        _ body: (URL) -> T
    ) -> T? {
        guard case .folder(let bookmarkData, _) = source else { return nil }
        guard case .success(let resolved) = bookmarkResolver.resolve(
            bookmarkData,
            target: .transient
        ) else { return nil }
        let folderURL = resolved.url
        let didStart = folderURL.startAccessingSecurityScopedResource()
        defer { if didStart { folderURL.stopAccessingSecurityScopedResource() } }
        return body(folderURL)
    }

    private static func entryHTMLLooksDPRAware(folderURL: URL, indexFileName: String) -> Bool {
        guard let entryURL = WPEPathSafety.resourceURL(root: folderURL, relativePath: indexFileName) else {
            return false
        }
        guard let data = try? Data(contentsOf: entryURL, options: .mappedIfSafe),
              let source = String(data: data, encoding: .utf8) else {
            return false
        }
        let lowered = source.lowercased()
        return lowered.contains("setpixelratio(")
            || lowered.contains("devicepixelratio")
    }
}

@MainActor
final class AmbientWallpaperSessionBuilder {
    typealias BookmarkRefreshHandler = @MainActor (_ original: Data, _ refreshed: Data) -> Void
    typealias WPEOriginRefreshHandler = @MainActor (_ origin: WPEOrigin, _ refreshed: Data) -> Void

    private let bookmarkResolver: SecurityScopedBookmarkResolver

    init(bookmarkResolver: SecurityScopedBookmarkResolver = .shared) {
        self.bookmarkResolver = bookmarkResolver
    }

    func makeHTMLSession(
        source: HTMLSource,
        config: HTMLConfig,
        frame: CGRect,
        onBookmarkRefresh: @escaping BookmarkRefreshHandler = { _, _ in }
    ) -> AmbientWallpaperSession {
        // Resolve once before the compatibility probe. Otherwise that probe can
        // consume the stale bookmark's grace resolve and leave WKWebView trying
        // the obsolete Data a second time. The refreshed source is both
        // persisted by its owner and carried through the rest of this build.
        let effectiveSource = refreshingHTMLSource(
            source,
            onBookmarkRefresh: onBookmarkRefresh
        )
        let window = VideoWallpaperWindow(frame: frame)

        let compatibility = HTMLWallpaperCompatibilityPolicy.runtimeConfig(
            source: effectiveSource,
            config: config,
            trustedOrigins: TrustedHostStore.shared.originSet,
            bookmarkResolver: bookmarkResolver
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

        let htmlView = HTMLWallpaperView(
            frame: frame,
            initialEphemeral: effective.requiresEphemeralStorage,
            bookmarkResolver: bookmarkResolver,
            onBookmarkRefresh: onBookmarkRefresh
        )
        window.contentView = htmlView

        let session = AmbientWallpaperSession(window: window, wallpaperType: .html, performanceTarget: htmlView)
        htmlView.onError = { [weak session] error in
            session?.recordRuntimeError(error)
        }

        htmlView.apply(effective)
        htmlView.loadSource(effectiveSource)

        window.setWallpaperMouseInteractionEnabled(config.allowMouseInteraction)
        return session
    }

    /// Runtime preflight for local HTML owners. Kept internal so the injected
    /// resolver path can be exercised without constructing WebKit in tests.
    func refreshingHTMLSource(
        _ source: HTMLSource,
        onBookmarkRefresh: BookmarkRefreshHandler = { _, _ in }
    ) -> HTMLSource {
        guard let original = source.localBookmarkData,
              case .success(let resolved) = bookmarkResolver.resolve(
                original,
                target: .transient
              ),
              resolved.didRefresh,
              let refreshedSource = source.replacingLocalBookmark(
                matching: original,
                with: resolved.bookmarkData
              ) else { return source }
        onBookmarkRefresh(original, resolved.bookmarkData)
        return refreshedSource
    }

    /// Mounts the native Monitor v2 widget board. Ships in both SKUs;
    /// `agentFleetEnabled` (Pro-only) decides whether the AI-agent / usage
    /// widgets are wired up — Lite passes `false` and the host strips those
    /// placements. `onConfigurationEdited` carries committed board edits back to
    /// the caller (ScreenManager) for persistence.
    func makeMonitorSession(
        _ config: MonitorBoardConfiguration,
        agentFleetEnabled: Bool,
        frame: CGRect,
        onConfigurationEdited: @escaping (MonitorBoardConfiguration) -> Void
    ) -> AmbientWallpaperSession {
        let window = VideoWallpaperWindow(frame: frame)
        let monitorView = MonitorWallpaperView(
            frame: frame,
            configuration: config,
            agentFleetEnabled: agentFleetEnabled
        )
        monitorView.onConfigurationEdited = onConfigurationEdited
        window.contentView = monitorView
        let session = AmbientWallpaperSession(window: window, wallpaperType: .monitor, performanceTarget: monitorView)
        // Click-through unless the per-screen toggle opts in; the view mirrors
        // the same flag in its `hitTest`.
        window.setWallpaperMouseInteractionEnabled(config.mouseInteractionEnabled)
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
    func makeSceneSession(
        descriptor: SceneDescriptor,
        origin: WPEOrigin? = nil,
        frame: CGRect,
        dependencyMounts: [WPEAssetMount] = [],
        engineAssetsRootURL: URL? = nil,
        applicationSupportRootURL: URL? = nil,
        fileManager: FileManager = .default,
        onOriginBookmarkRefresh: @escaping WPEOriginRefreshHandler = { _, _ in }
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
            fileManager: fileManager,
            onOriginBookmarkRefresh: onOriginBookmarkRefresh
        ) else {
            Logger.warning("Scene source unavailable for in-place read: \(descriptor.workshopID)", category: .screenManager)
            return nil
        }
        // A legacy `.cache` scene needs its extracted directory only when we
        // actually fell back to it (`provider == nil`). When the cache was
        // purged but the import source was still resolvable, `sceneAssets`
        // returns an in-place provider instead, so the missing directory is fine.
        if descriptor.assetStorage == .cache, assets.provider == nil {
            guard fileManager.fileExists(atPath: cacheURL.path) else {
                Logger.warning("Scene descriptor cache directory missing: \(cacheURL.lastPathComponent)", category: .screenManager)
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
        // M2c1b-2: build the main-thread surface up-front, then stand up the
        // per-display render actor (main-backed unless the off-main flag is set)
        // and inject the surface. No frame call is dispatched through the actor
        // yet — it is parked on the session and shut down with it (a no-op for the
        // default `.main` backing).
        let backing = WPEOffMainRenderFlag.backing
        let surface = WPERenderSurface(frame: rendererFrame, device: device)
        let renderActor = WPEDisplayRenderActor(backing: backing)
        // M2c2: the pacing seam forks by backing. `.renderThread` drives a
        // render-thread CADisplayLink through the pacer (MTKView becomes a pure
        // host); `.main` keeps pacing the MTKView through the bare surface exactly
        // as before. This is the whole divergence — everything downstream is shared.
        let surfaceControl: any WPESurfaceControl
        switch backing {
        case .main:
            surfaceControl = surface
        case .renderThread:
            surfaceControl = WPERenderThreadFramePacer(surface: surface, renderActor: renderActor)
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
                surfaceControl: surfaceControl,
                mailbox: surface.mailbox,
                presentLayer: WPEPresentLayer(layer: surface.metalLayer),
                drawableSize: surface.metalLayer.drawableSize,
                device: device
            )
        } catch {
            Logger.warning("Metal scene renderer could not be created: \(error.localizedDescription)", category: .screenManager)
            return nil
        }

        // Wire the delivery shim onto the surface (M2c1b-3c). The surface owns the
        // shim, the shim targets the render actor — a graph entirely separate from
        // the renderer, so the renderer stays `sending`-adoptable.
        let shim = WPERenderSurfaceClientShim(renderActor: renderActor, backing: backing)
        surface.attach(client: shim)

        let window = VideoWallpaperWindow(frame: frame)
        window.contentView = surface.mtkView
        window.orderBack(nil)

        // M2c2: the view now has a window/screen, so stand up the CADisplayLink
        // frame driver. `.main` mode never starts it — the MTKView paces there.
        if case .renderThread = backing {
            surface.startDisplayLinkDriver(renderActor: renderActor)
        }

        // Adopt the freshly-constructed renderer into the render actor, then drive
        // the load. The renderer is a disconnected local here (it holds only the
        // Sendable surface seams), so it transfers cleanly and never enters the
        // session's region. The session keeps the surface (+ shim) alive.
        let session = SceneWallpaperSession(window: window, renderActor: renderActor, surface: surface)
        // Hand the renderer to its actor through the one-shot carrier (see
        // `WPERendererHandoff`): it is constructed on main and never touched here
        // again, so the transfer is safe even though the surface seams keep region
        // isolation from proving it. The session owns the adopt+load task so
        // cleanup() can cancel and drain it before tearing the actor down.
        session.startAdoptingRenderer(WPERendererHandoff(renderer: renderer))
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
        fileManager: FileManager,
        onOriginBookmarkRefresh: @escaping WPEOriginRefreshHandler
    ) -> (provider: (any WPESceneAssetProvider)?, projectRoot: URL)? {
        switch descriptor.assetStorage {
        case .cache:
            // The known-good extracted copy wins whenever it is present — it was
            // validated against a fingerprint at import and can't have drifted.
            // Only when it is gone (purged / reclaimed) do we read in place from
            // the still-resolvable import source, so clearing the cache no longer
            // kills a legacy scene. The stale cache descriptor is left as-is;
            // launch orphan GC / manual cleanup reclaim the directory later.
            if fileManager.fileExists(atPath: cacheURL.path) {
                return (nil, cacheURL)
            }
            if let upgraded = cacheFallbackSourceProvider(
                origin: origin,
                fileManager: fileManager,
                onOriginBookmarkRefresh: onOriginBookmarkRefresh
            ) {
                Logger.info("WPE scene cache absent; reading in place from source for \(descriptor.workshopID)", category: .screenManager)
                return upgraded
            }
            return (nil, cacheURL)
        case .sourceDirectory:
            guard let source = resolveSourceFolder(
                origin: origin,
                onOriginBookmarkRefresh: onOriginBookmarkRefresh
            ) else { return nil }
            let provider = WPESecurityScopedSceneAssetProvider(
                wrapped: WPEDirectorySceneAssetProvider(rootURL: source.url),
                scopedURL: source.url,
                didStartAccessing: source.didStart
            )
            return (provider, source.url)
        case .packageSource(let fileName):
            guard let source = resolveSourceFolder(
                origin: origin,
                onOriginBookmarkRefresh: onOriginBookmarkRefresh
            ) else { return nil }
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
    private func resolveSourceFolder(
        origin: WPEOrigin?,
        onOriginBookmarkRefresh: @escaping WPEOriginRefreshHandler
    ) -> (url: URL, didStart: Bool)? {
        guard let origin,
              let resolved = refreshingWPEOrigin(
                origin,
                onOriginBookmarkRefresh: onOriginBookmarkRefresh
              ) else { return nil }
        return (resolved.url, resolved.url.startAccessingSecurityScopedResource())
    }

    /// Resolves the persistent WPE source owner and carries refreshed Data both
    /// to the current build and back to its MainActor persistence owner. Kept
    /// internal so the runtime path is testable without creating a Metal device.
    func refreshingWPEOrigin(
        _ origin: WPEOrigin,
        onOriginBookmarkRefresh: WPEOriginRefreshHandler = { _, _ in }
    ) -> (origin: WPEOrigin, url: URL)? {
        guard case .success(let resolved) = bookmarkResolver.resolve(
            origin.sourceFolderBookmark,
            target: .transient
        ) else { return nil }
        guard resolved.didRefresh,
              let refreshedOrigin = origin.replacingSourceFolderBookmark(
                matching: origin.sourceFolderBookmark,
                with: resolved.bookmarkData
              ) else {
            return (origin, resolved.url)
        }
        onOriginBookmarkRefresh(origin, resolved.bookmarkData)
        return (refreshedOrigin, resolved.url)
    }

    /// Lazy migration backstop for a legacy `.cache` descriptor whose extracted
    /// directory is gone: builds an in-place provider from the still-resolvable
    /// import source — `.packageSource` when a `scene.pkg` sits at the source
    /// root, otherwise a directory provider. Returns `nil` when the source can't
    /// be opened, leaving the caller to report the missing cache. The returned
    /// provider owns the source's security scope for its lifetime.
    private func cacheFallbackSourceProvider(
        origin: WPEOrigin?,
        fileManager: FileManager,
        onOriginBookmarkRefresh: @escaping WPEOriginRefreshHandler
    ) -> (provider: (any WPESceneAssetProvider)?, projectRoot: URL)? {
        guard let source = resolveSourceFolder(
            origin: origin,
            onOriginBookmarkRefresh: onOriginBookmarkRefresh
        ) else { return nil }
        let packageURL = source.url.appendingPathComponent("scene.pkg", isDirectory: false)
        if fileManager.fileExists(atPath: packageURL.path),
           let pkg = try? WPEPackageSceneAssetProvider(packageURL: packageURL) {
            let provider = WPESecurityScopedSceneAssetProvider(
                wrapped: pkg, scopedURL: source.url, didStartAccessing: source.didStart
            )
            return (provider, source.url)
        }
        let provider = WPESecurityScopedSceneAssetProvider(
            wrapped: WPEDirectorySceneAssetProvider(rootURL: source.url),
            scopedURL: source.url,
            didStartAccessing: source.didStart
        )
        return (provider, source.url)
    }
    #endif

}
