import Foundation

/// End-to-end Wallpaper Engine workshop import. Reads `project.json`, routes
/// by `WPEType`, extracts `scene.pkg` via `WallpaperEngineCache` when present,
/// and produces a `WallpaperContent` (.video / .html(.folder)) ready to apply.
@MainActor
final class WallpaperEngineImportService {
    enum ImportResult: Equatable, Sendable {
        case ready(WallpaperContent, origin: WPEOrigin)
        case unsupported(origin: WPEOrigin)
        case rejected(reason: String)
    }

    private let cache: WallpaperEngineCache
    private let fileManager: FileManager
    private let validateVideo: @Sendable (URL) async throws -> Void
    private let makeBookmark: @MainActor @Sendable (URL) -> Data?

    init(
        cache: WallpaperEngineCache = WallpaperEngineCache(),
        fileManager: FileManager = .default,
        validateVideo: @escaping @Sendable (URL) async throws -> Void = { url in
            try await PlayableVideoLoader.validatePlayableVideo(at: url)
        },
        makeBookmark: @escaping @MainActor @Sendable (URL) -> Data? = { url in
            ResourceUtilities.createBookmark(for: url)
        }
    ) {
        self.cache = cache
        self.fileManager = fileManager
        self.validateVideo = validateVideo
        self.makeBookmark = makeBookmark
    }

    func importProject(folder folderURL: URL) async throws -> ImportResult {
        let project = try WallpaperEngineProject.read(from: folderURL)
        guard let sourceBookmark = makeBookmark(folderURL) else {
            return .rejected(reason: "Cannot create source folder bookmark")
        }

        switch project.type {
        case .video:
            return await importVideo(project: project, folderURL: folderURL, sourceBookmark: sourceBookmark)
        case .web:
            return await importWeb(project: project, folderURL: folderURL, sourceBookmark: sourceBookmark)
        case .scene:
            return await importScene(project: project, folderURL: folderURL, sourceBookmark: sourceBookmark)
        case .application, .unknown:
            return .unsupported(origin: makeOrigin(
                project: project,
                sourceBookmark: sourceBookmark,
                cacheRelativePath: nil,
                resourceLocation: .unsupported
            ))
        }
    }

    private func importVideo(
        project: WallpaperEngineProject,
        folderURL: URL,
        sourceBookmark: Data
    ) async -> ImportResult {
        // WPE distributes video wallpapers in two shapes (per
        // help.wallpaperengine.io and linux-wallpaperengine docs):
        //   1) packaged: `scene.pkg` archive containing the video file,
        //   2) unpackaged: `<entryFile>` directly inside the project folder.
        // Both are valid; rejecting unpackaged videos cuts off the majority
        // of community video wallpapers.
        let pkgURL = folderURL.appendingPathComponent("scene.pkg")
        if fileManager.fileExists(atPath: pkgURL.path) {
            return await importPackagedVideo(project: project, pkgURL: pkgURL, sourceBookmark: sourceBookmark)
        }
        return await importUnpackagedVideo(project: project, folderURL: folderURL, sourceBookmark: sourceBookmark)
    }

    private func importPackagedVideo(
        project: WallpaperEngineProject,
        pkgURL: URL,
        sourceBookmark: Data
    ) async -> ImportResult {
        let cacheResult = await ensureExtracted(project: project, pkgURL: pkgURL)
        guard case .success(let cacheURL) = cacheResult else {
            if case .failure(let failure) = cacheResult { return .rejected(reason: failure.reason) }
            return .rejected(reason: "Extraction failed")
        }

        guard let videoURL = resourceURL(root: cacheURL, relativePath: project.entryFile),
              fileManager.fileExists(atPath: videoURL.path) else {
            return .rejected(reason: "Missing video entry \(project.entryFile)")
        }

        do {
            try await validateVideo(videoURL)
        } catch {
            return .rejected(reason: describe(error))
        }

        guard let videoBookmark = makeBookmark(videoURL) else {
            return .rejected(reason: "Cannot create video bookmark")
        }

        let origin = makeOrigin(
            project: project,
            sourceBookmark: sourceBookmark,
            cacheRelativePath: cacheRelativePath(for: project),
            resourceLocation: .cache
        )
        return .ready(.video(bookmarkData: videoBookmark), origin: origin)
    }

    private func importUnpackagedVideo(
        project: WallpaperEngineProject,
        folderURL: URL,
        sourceBookmark: Data
    ) async -> ImportResult {
        guard let videoURL = resourceURL(root: folderURL, relativePath: project.entryFile),
              fileManager.fileExists(atPath: videoURL.path) else {
            return .rejected(reason: "Missing video entry \(project.entryFile)")
        }

        do {
            try await validateVideo(videoURL)
        } catch {
            return .rejected(reason: describe(error))
        }

        guard let videoBookmark = makeBookmark(videoURL) else {
            return .rejected(reason: "Cannot create video bookmark")
        }

        // Source-folder backed: cacheRelativePath is nil; reconcile uses
        // the source-folder bookmark's prefix-path match to keep the badge.
        let origin = makeOrigin(
            project: project,
            sourceBookmark: sourceBookmark,
            cacheRelativePath: nil,
            resourceLocation: .sourceFolder
        )
        return .ready(.video(bookmarkData: videoBookmark), origin: origin)
    }

    private func importWeb(
        project: WallpaperEngineProject,
        folderURL: URL,
        sourceBookmark: Data
    ) async -> ImportResult {
        let pkgURL = folderURL.appendingPathComponent("scene.pkg")
        if fileManager.fileExists(atPath: pkgURL.path) {
            return await importPackagedWeb(project: project, pkgURL: pkgURL, sourceBookmark: sourceBookmark)
        }

        guard let indexURL = resourceURL(root: folderURL, relativePath: project.entryFile),
              fileManager.fileExists(atPath: indexURL.path) else {
            return .rejected(reason: "Missing web entry \(project.entryFile)")
        }

        guard let folderBookmark = makeBookmark(folderURL) else {
            return .rejected(reason: "Cannot create web folder bookmark")
        }

        // Unpacked web wallpapers stay in the user's Steam folder. They are
        // supported source-folder-backed imports, not unsupported nil-cache entries.
        let origin = makeOrigin(
            project: project,
            sourceBookmark: sourceBookmark,
            cacheRelativePath: nil,
            resourceLocation: .sourceFolder
        )
        let content = WallpaperContent.html(
            source: .folder(bookmarkData: folderBookmark, indexFileName: project.entryFile),
            config: HTMLConfig(physicalPixelLayout: true)
        )
        return .ready(content, origin: origin)
    }

    private func importPackagedWeb(
        project: WallpaperEngineProject,
        pkgURL: URL,
        sourceBookmark: Data
    ) async -> ImportResult {
        let cacheResult = await ensureExtracted(project: project, pkgURL: pkgURL)
        guard case .success(let cacheURL) = cacheResult else {
            if case .failure(let failure) = cacheResult { return .rejected(reason: failure.reason) }
            return .rejected(reason: "Extraction failed")
        }

        guard let indexURL = resourceURL(root: cacheURL, relativePath: project.entryFile),
              fileManager.fileExists(atPath: indexURL.path) else {
            return .rejected(reason: "Missing web entry \(project.entryFile)")
        }

        guard let folderBookmark = makeBookmark(cacheURL) else {
            return .rejected(reason: "Cannot create cached web folder bookmark")
        }

        let origin = makeOrigin(
            project: project,
            sourceBookmark: sourceBookmark,
            cacheRelativePath: cacheRelativePath(for: project),
            resourceLocation: .cache
        )
        let content = WallpaperContent.html(
            source: .folder(bookmarkData: folderBookmark, indexFileName: project.entryFile),
            config: HTMLConfig(physicalPixelLayout: true)
        )
        return .ready(content, origin: origin)
    }

    private func importScene(
        project: WallpaperEngineProject,
        folderURL: URL,
        sourceBookmark: Data
    ) async -> ImportResult {
        // Phase 2.0 contract: scene wallpapers must ship a `scene.pkg` (the
        // unpacked-folder shape rarely lands in workshop downloads). If the
        // pkg is missing we still surface as unsupported with a clear reason
        // so the UI can show the fallback card instead of a generic error.
        let pkgURL = folderURL.appendingPathComponent("scene.pkg")
        guard fileManager.fileExists(atPath: pkgURL.path) else {
            return .unsupported(origin: makeOrigin(
                project: project,
                sourceBookmark: sourceBookmark,
                cacheRelativePath: nil,
                resourceLocation: .unsupported
            ))
        }

        let cacheResult = await ensureExtracted(project: project, pkgURL: pkgURL)
        guard case .success(let cacheURL) = cacheResult else {
            if case .failure(let failure) = cacheResult { return .rejected(reason: failure.reason) }
            return .rejected(reason: "Extraction failed")
        }

        guard let entryURL = resourceURL(root: cacheURL, relativePath: project.entryFile),
              fileManager.fileExists(atPath: entryURL.path) else {
            return .rejected(reason: "Missing scene entry \(project.entryFile)")
        }

        // Parse `scene.json` to classify capability tier. Failures here are
        // user-actionable (file shipped malformed) so we reject rather than
        // mark unsupported — the UI surfaces the parse error to help the
        // user nudge the wallpaper author.
        let sceneData: Data
        do {
            sceneData = try Data(contentsOf: entryURL)
        } catch {
            return .rejected(reason: "Cannot read \(project.entryFile): \(describe(error))")
        }

        let document: WPESceneDocument
        do {
            document = try WPESceneDocumentParser.parse(data: sceneData)
        } catch {
            return .rejected(reason: describe(error))
        }

        let tier = capabilityTier(for: document, cacheURL: cacheURL)
        let descriptor = SceneDescriptor(
            workshopID: project.workshopID,
            cacheRelativePath: cacheRelativePath(for: project),
            entryFile: project.entryFile,
            capabilityTier: tier
        )
        let origin = makeOrigin(
            project: project,
            sourceBookmark: sourceBookmark,
            cacheRelativePath: cacheRelativePath(for: project),
            resourceLocation: .cache
        )

        if tier == .unsupported {
            return .unsupported(origin: origin)
        }
        return .ready(.scene(descriptor), origin: origin)
    }

    /// Walk `imageObjects` against the cache root: if every layer's asset is
    /// present the scene is `.imageOnly`; if some are present and others are
    /// missing we tag it `.degraded` so the UI shows a "missing assets"
    /// notice; if none are renderable we surface as `.unsupported` and let
    /// the import flow fall back to the placeholder card.
    private func capabilityTier(for document: WPESceneDocument, cacheURL: URL) -> SceneCapabilityTier {
        guard !document.imageObjects.isEmpty else {
            return .unsupported
        }
        let resolver = SceneResourceResolver(cacheRootURL: cacheURL)
        var resolvable = 0
        var unresolvable = 0
        for object in document.imageObjects {
            let path = object.imageRelativePath
            // Treat .tex as unresolvable for tier purposes — the resolver
            // throws unsupportedTexture, the runtime will skip the layer.
            if path.lowercased().hasSuffix(".tex") {
                unresolvable += 1
                continue
            }
            if resolver.exists(relativePath: path) {
                resolvable += 1
            } else {
                unresolvable += 1
            }
        }

        if resolvable == 0 { return .unsupported }
        // Pure imageOnly only when EVERY layer resolves AND the parser saw no
        // diagnostics at all. Info-level diagnostics include unsupported
        // particle/text/sound objects — a scene that mixes a PNG layer with
        // a particle emitter is degraded (the PNG renders, the particles
        // don't), not fully imageOnly.
        if unresolvable == 0 && document.diagnostics.isEmpty {
            return .imageOnly
        }
        return .degraded
    }

    private func ensureExtracted(project: WallpaperEngineProject, pkgURL: URL) async -> Result<URL, ExtractionFailure> {
        do {
            let url = try await cache.ensureExtracted(workshopID: project.workshopID, sourcePkgURL: pkgURL)
            return .success(url)
        } catch {
            return .failure(ExtractionFailure(reason: describe(error)))
        }
    }

    private func makeOrigin(
        project: WallpaperEngineProject,
        sourceBookmark: Data,
        cacheRelativePath: String?,
        resourceLocation: WPEResourceLocation
    ) -> WPEOrigin {
        WPEOrigin(
            workshopID: project.workshopID,
            title: project.title,
            originalType: project.type,
            sourceFolderBookmark: sourceBookmark,
            cacheRelativePath: cacheRelativePath,
            previewFileName: project.previewFileName,
            entryFile: project.entryFile,
            resourceLocation: resourceLocation
        )
    }

    private func cacheRelativePath(for project: WallpaperEngineProject) -> String {
        "wpe-cache/\(project.workshopID)"
    }

    private func resourceURL(root: URL, relativePath: String) -> URL? {
        // Resolve symlinks so an unpacked web fixture can't smuggle an entry
        // file pointing outside the user-selected folder.
        let rootURL = root.standardizedFileURL.resolvingSymlinksInPath()
        let url = root.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(rootURL.path + "/") else { return nil }
        return url
    }

    private func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}

private struct ExtractionFailure: Error, Sendable {
    let reason: String
}

@MainActor
struct WPECachedContentResolver {
    private let applicationSupportRootURL: URL
    private let fileManager: FileManager
    private let makeBookmark: @MainActor @Sendable (URL) -> Data?

    init(
        applicationSupportRootURL: URL? = nil,
        fileManager: FileManager = .default,
        makeBookmark: @escaping @MainActor @Sendable (URL) -> Data? = { url in
            ResourceUtilities.createBookmark(for: url)
        }
    ) {
        self.fileManager = fileManager
        if let applicationSupportRootURL {
            self.applicationSupportRootURL = applicationSupportRootURL
        } else if let applicationSupport = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            self.applicationSupportRootURL = applicationSupport.appendingPathComponent("LiveWallpaper", isDirectory: true)
        } else {
            self.applicationSupportRootURL = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support/LiveWallpaper", isDirectory: true)
        }
        self.makeBookmark = makeBookmark
    }

    func content(for origin: WPEOrigin) -> WallpaperContent? {
        guard origin.resourceLocation == .cache,
              let cacheRelativePath = origin.cacheRelativePath,
              Self.isSafeCacheRelativePath(cacheRelativePath),
              let entryFile = origin.entryFile,
              !entryFile.isEmpty else {
            return nil
        }

        // Resolve symlinks before containment check — otherwise an
        // attacker-controlled symlink at `Application Support/LiveWallpaper`
        // could point at a sibling directory and still pass the prefix test.
        let safeSupportRoot = applicationSupportRootURL.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = safeSupportRoot.path
        let cacheURL = safeSupportRoot
            .appendingPathComponent(cacheRelativePath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard cacheURL.path == rootPath || cacheURL.path.hasPrefix(rootPath + "/") else {
            return nil
        }
        guard let entryURL = resourceURL(root: cacheURL, relativePath: entryFile),
              fileManager.fileExists(atPath: entryURL.path) else {
            return nil
        }

        switch origin.originalType {
        case .video:
            guard let bookmark = makeBookmark(entryURL) else { return nil }
            return .video(bookmarkData: bookmark)
        case .web:
            guard let bookmark = makeBookmark(cacheURL) else { return nil }
            return .html(
                source: .folder(bookmarkData: bookmark, indexFileName: entryFile),
                config: HTMLConfig(physicalPixelLayout: true)
            )
        case .scene:
            // Phase 2.0 cache rebuild: do NOT re-parse `scene.json` here —
            // the runtime layer already validates the descriptor on mount.
            // We only need to confirm the cache entry exists, then hand back
            // a `.scene(SceneDescriptor)` so ScreenManager can restore it
            // without help from the import service.
            return .scene(SceneDescriptor(
                workshopID: origin.workshopID,
                cacheRelativePath: cacheRelativePath,
                entryFile: entryFile,
                // Optimistic — runtime downgrades on first parse if needed.
                capabilityTier: .imageOnly
            ))
        case .application, .unknown:
            return nil
        }
    }

    private func resourceURL(root: URL, relativePath: String) -> URL? {
        let rootURL = root.standardizedFileURL.resolvingSymlinksInPath()
        let url = root
            .appendingPathComponent(relativePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard url.path.hasPrefix(rootURL.path + "/") else { return nil }
        return url
    }

    /// Rejects malformed persisted cache paths before they get appended to the
    /// application-support root. Mirrors the rules enforced when writing.
    /// Requires the `wpe-cache/` prefix so persisted state can never resolve
    /// to a sibling subtree under `Application Support/LiveWallpaper/`.
    fileprivate static func isSafeCacheRelativePath(_ path: String) -> Bool {
        path.hasPrefix("wpe-cache/")
            && !path.contains("\\")
            && !path.contains("..")
            && !path.contains("//")
    }
}
