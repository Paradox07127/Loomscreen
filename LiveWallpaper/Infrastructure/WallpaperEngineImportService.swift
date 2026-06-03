#if !LITE_BUILD
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

        let originKind = WallpaperEngineImportService.originKind(forSourceFolder: folderURL)
        let origin = makeOrigin(
            project: project,
            sourceBookmark: sourceBookmark,
            cacheRelativePath: nil,
            resourceLocation: .sourceFolder,
            originKind: originKind
        )
        let content = WallpaperContent.html(
            source: .folder(bookmarkData: folderBookmark, indexFileName: project.entryFile),
            config: HTMLConfig(
                physicalPixelLayout: true,
                originKind: originKind
            )
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

        let originKind = WallpaperEngineImportService.originKind(forSourceFolder: pkgURL.deletingLastPathComponent())
        let origin = makeOrigin(
            project: project,
            sourceBookmark: sourceBookmark,
            cacheRelativePath: cacheRelativePath(for: project),
            resourceLocation: .cache,
            originKind: originKind
        )
        let content = WallpaperContent.html(
            source: .folder(bookmarkData: folderBookmark, indexFileName: project.entryFile),
            config: HTMLConfig(
                physicalPixelLayout: true,
                originKind: originKind
            )
        )
        return .ready(content, origin: origin)
    }

    /// Marks an HTML wallpaper's `HTMLConfig` as Workshop-sourced when the
    /// source folder lives under a SteamCMD-managed
    /// `steamapps/workshop/content/431960/<id>/` tree.
    ///
    /// Path-based detection is deliberately conservative: it relies on the
    /// canonical SteamCMD layout and Wallpaper Engine app ID (`431960`).
    /// Any folder whose canonical path does NOT match the suffix
    /// `/steamapps/workshop/content/431960/<numeric>/` (with the optional
    /// trailing slash) is treated as `userLocal` — including projects copied
    /// out to a user-managed library directory.
    static func originKind(forSourceFolder folderURL: URL) -> HTMLOriginKind {
        let canonical = folderURL.standardizedFileURL.resolvingSymlinksInPath().path
        let components = canonical.split(separator: "/", omittingEmptySubsequences: true)
        guard let id = components.last,
              UInt64(id) != nil,
              components.count >= 5 else {
            return .userLocal
        }
        let tail = components.suffix(5)
        let tailArray = Array(tail)
        // Layout: steamapps / workshop / content / 431960 / <pubfileid>
        guard tailArray[0] == "steamapps",
              tailArray[1] == "workshop",
              tailArray[2] == "content",
              tailArray[3] == "431960" else {
            return .userLocal
        }
        return .workshopImport
    }

    private func importScene(
        project: WallpaperEngineProject,
        folderURL: URL,
        sourceBookmark: Data
    ) async -> ImportResult {
        if project.requiresWindowsPlugin {
            return .unsupported(origin: makeOrigin(
                project: project,
                sourceBookmark: sourceBookmark,
                cacheRelativePath: nil,
                resourceLocation: .unsupported
            ))
        }

        let missingDeps = await missingDependencies(
            declared: project.dependencyWorkshopIDs,
            sourceFolderURL: folderURL
        )
        if !missingDeps.isEmpty {
            return .unsupported(origin: makeOrigin(
                project: project,
                sourceBookmark: sourceBookmark,
                cacheRelativePath: nil,
                resourceLocation: .unsupported,
                missingDependencyIDs: missingDeps
            ))
        }

        let pkgURL = folderURL.appendingPathComponent("scene.pkg")
        if fileManager.fileExists(atPath: pkgURL.path) {
            // Default: read the packaged scene in place from scene.pkg — no
            // extraction, so no second multi-GB copy in wpe-cache. Falls back to
            // extracting into the cache only when the package can't be opened or
            // parsed for in-place use.
            if let packageResult = await finishScenePackageBackedImport(
                project: project,
                pkgURL: pkgURL,
                sourceFolderURL: folderURL,
                sourceBookmark: sourceBookmark
            ) {
                return packageResult
            }

            let cacheResult = await ensureExtracted(project: project, pkgURL: pkgURL)
            guard case .success(let cacheURL) = cacheResult else {
                if case .failure(let failure) = cacheResult { return .rejected(reason: failure.reason) }
                return .rejected(reason: "Extraction failed")
            }

            return finishSceneImport(
                project: project,
                cacheURL: cacheURL,
                sourceFolderURL: folderURL,
                sourceBookmark: sourceBookmark
            )
        }

        guard let entryURL = resourceURL(root: folderURL, relativePath: project.entryFile),
              fileManager.fileExists(atPath: entryURL.path) else {
            return .unsupported(origin: makeOrigin(
                project: project,
                sourceBookmark: sourceBookmark,
                cacheRelativePath: nil,
                resourceLocation: .unsupported
            ))
        }

        let cacheResult = await ensureMirrored(project: project, folderURL: folderURL)
        guard case .success(let cacheURL) = cacheResult else {
            if case .failure(let failure) = cacheResult { return .rejected(reason: failure.reason) }
            return .rejected(reason: "Directory mirror failed")
        }

        return finishSceneImport(
            project: project,
            cacheURL: cacheURL,
            sourceFolderURL: folderURL,
            sourceBookmark: sourceBookmark
        )
    }

    private func finishSceneImport(
        project: WallpaperEngineProject,
        cacheURL: URL,
        sourceFolderURL: URL,
        sourceBookmark: Data
    ) -> ImportResult {
        // `scene.pkg` archives never carry `project.json` (it lives next to
        // them in the workshop folder), so the .pkg extraction path leaves
        // the cache without authoring metadata. Top it up here so the
        // inspector schema loader and downstream readers find it without
        // re-opening the source bookmark on every cold start.
        copyProjectManifestIfNeeded(from: sourceFolderURL, to: cacheURL)


        guard let entryURL = resourceURL(root: cacheURL, relativePath: project.entryFile),
              fileManager.fileExists(atPath: entryURL.path) else {
            return .rejected(reason: "Missing scene entry \(project.entryFile)")
        }

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

        let dependencyMounts = WPEDependencyMountResolver().mounts(
            dependencyWorkshopIDs: project.dependencyWorkshopIDs,
            origin: nil
        )
        let engineRoot = WPEEngineAssetsLibrary.shared.resolveAuthorizedRoot()
        let tier = WPESceneCapabilityClassifier().capabilityTier(
            for: document,
            cacheURL: cacheURL,
            dependencyMounts: dependencyMounts,
            engineAssetsRootURL: engineRoot
        )
        let preflight = WPEScenePreflight.classify(
            document: document,
            project: project,
            scenePackageEntries: scenePackageEntryNames(in: cacheURL, fileManager: fileManager)
        )
        let descriptor = SceneDescriptor(
            workshopID: project.workshopID,
            cacheRelativePath: cacheRelativePath(for: project),
            entryFile: project.entryFile,
            capabilityTier: tier,
            dependencyWorkshopIDs: project.dependencyWorkshopIDs,
            preflightTier: preflight.tier,
            preflightFeatureFlags: sortedPreflightFeatureFlags(preflight.featureFlags)
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

    /// Imports a packaged scene to read in place from `scene.pkg` (no
    /// extraction). Returns `nil` when the package can't be opened/parsed for
    /// in-place use, so the caller falls back to extracting into the cache.
    private func finishScenePackageBackedImport(
        project: WallpaperEngineProject,
        pkgURL: URL,
        sourceFolderURL: URL,
        sourceBookmark: Data
    ) async -> ImportResult? {
        guard let provider = try? WPEPackageSceneAssetProvider(packageURL: pkgURL),
              let sceneData = try? provider.data(atRelativePath: project.entryFile) else {
            return nil
        }
        let document: WPESceneDocument
        do {
            document = try WPESceneDocumentParser.parse(data: sceneData)
        } catch {
            return nil
        }

        // Zero-cache: assets and project.json are read in place from the source,
        // so nothing is kept in wpe-cache. Remove any stale prior extraction for
        // this id — frees its disk and ensures the source `.pkg` is never treated
        // as a redundant, reclaimable copy (no completion manifest survives).
        try? await cache.purge(workshopID: project.workshopID)

        let dependencyMounts = WPEDependencyMountResolver().mounts(
            dependencyWorkshopIDs: project.dependencyWorkshopIDs,
            origin: nil
        )
        let engineRoot = WPEEngineAssetsLibrary.shared.resolveAuthorizedRoot()
        let tier = WPESceneCapabilityClassifier().capabilityTier(
            for: document,
            primaryProvider: provider,
            dependencyMounts: dependencyMounts,
            engineAssetsRootURL: engineRoot
        )
        let preflight = WPEScenePreflight.classify(
            document: document,
            project: project,
            scenePackageEntries: provider.entryNames
        )
        let descriptor = SceneDescriptor(
            workshopID: project.workshopID,
            cacheRelativePath: cacheRelativePath(for: project),
            entryFile: project.entryFile,
            capabilityTier: tier,
            assetStorage: .packageSource(fileName: pkgURL.lastPathComponent),
            dependencyWorkshopIDs: project.dependencyWorkshopIDs,
            preflightTier: preflight.tier,
            preflightFeatureFlags: sortedPreflightFeatureFlags(preflight.featureFlags)
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

    private func ensureExtracted(project: WallpaperEngineProject, pkgURL: URL) async -> Result<URL, ExtractionFailure> {
        do {
            let url = try await cache.ensureExtracted(workshopID: project.workshopID, sourcePkgURL: pkgURL)
            return .success(url)
        } catch {
            return .failure(ExtractionFailure(reason: describe(error)))
        }
    }

    private func ensureMirrored(project: WallpaperEngineProject, folderURL: URL) async -> Result<URL, ExtractionFailure> {
        do {
            let url = try await cache.ensureMirroredDirectory(
                workshopID: project.workshopID,
                sourceFolderURL: folderURL
            )
            return .success(url)
        } catch {
            return .failure(ExtractionFailure(reason: describe(error)))
        }
    }

    private func makeOrigin(
        project: WallpaperEngineProject,
        sourceBookmark: Data,
        cacheRelativePath: String?,
        resourceLocation: WPEResourceLocation,
        missingDependencyIDs: [String] = [],
        originKind: HTMLOriginKind = .userLocal
    ) -> WPEOrigin {
        WPEOrigin(
            workshopID: project.workshopID,
            title: project.title,
            originalType: project.type,
            sourceFolderBookmark: sourceBookmark,
            cacheRelativePath: cacheRelativePath,
            previewFileName: project.previewFileName,
            entryFile: project.entryFile,
            resourceLocation: resourceLocation,
            dependencyWorkshopIDs: project.dependencyWorkshopIDs,
            missingDependencyIDs: missingDependencyIDs,
            requiresWindowsPlugin: project.requiresWindowsPlugin,
            originKind: originKind
        )
    }

    /// Returns the subset of `declared` workshop IDs whose extracted payload is NOT currently available either in our cache OR as a sibling `~/Documents/Live Wallpapers/<appid>/<wid>/` folder.
    private func missingDependencies(declared: [String], sourceFolderURL: URL) async -> [String] {
        guard !declared.isEmpty else { return [] }
        let cached = await cache.listAvailableWorkshopIDs()
        let subscribed = subscribedWorkshopIDs(declared: declared, sourceFolderURL: sourceFolderURL)
        let available = cached.union(subscribed)
        return declared.filter { !available.contains($0) }
    }

    /// Inspects the parent of `sourceFolderURL` (the Steam Workshop content directory) for sibling folders matching declared dependency IDs.
    private func subscribedWorkshopIDs(declared: [String], sourceFolderURL: URL) -> Set<String> {
        let workshopRoot = sourceFolderURL.deletingLastPathComponent()
        var hits: Set<String> = []
        for id in declared {
            guard WPEPathSafety.isSafeWorkshopID(id) else { continue }
            let dependencyURL = workshopRoot.appendingPathComponent(id, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: dependencyURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }
            let manifest = dependencyURL.appendingPathComponent("project.json")
            if fileManager.fileExists(atPath: manifest.path) {
                hits.insert(id)
            }
        }
        return hits
    }

    private func cacheRelativePath(for project: WallpaperEngineProject) -> String {
        "wpe-cache/\(project.workshopID)"
    }

    private func copyProjectManifestIfNeeded(from sourceFolder: URL, to cacheURL: URL) {
        let destination = cacheURL.appendingPathComponent("project.json")
        if fileManager.fileExists(atPath: destination.path) { return }
        let source = sourceFolder.appendingPathComponent("project.json")
        guard fileManager.fileExists(atPath: source.path) else { return }
        do {
            try fileManager.copyItem(at: source, to: destination)
        } catch {
            Logger.warning(
                "WPE cache: failed to copy project.json into cache (\(error.localizedDescription))",
                category: .screenManager
            )
        }
    }

    private func resourceURL(root: URL, relativePath: String) -> URL? {
        WPEPathSafety.resourceURL(root: root, relativePath: relativePath)
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
        switch origin.resourceLocation {
        case .cache:
            return cacheContent(for: origin)
        case .sourceFolder:
            return sourceFolderContent(for: origin)
        default:
            return nil
        }
    }

    /// Rebuilds content for `.sourceFolder` items — unpackaged video/web
    /// downloads that reference their files in place (e.g. inside the SteamCMD
    /// workdir) rather than our managed cache. Without this, freshly-downloaded
    /// unpackaged wallpapers couldn't be bookmarked. Scene needs the cache.
    private func sourceFolderContent(for origin: WPEOrigin) -> WallpaperContent? {
        guard let entryFile = origin.entryFile, !entryFile.isEmpty else { return nil }
        var isStale = false
        guard let folderURL = try? URL(
            resolvingBookmarkData: origin.sourceFolderBookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        let didStart = folderURL.startAccessingSecurityScopedResource()
        defer { if didStart { folderURL.stopAccessingSecurityScopedResource() } }

        guard let entryURL = resourceURL(root: folderURL, relativePath: entryFile),
              fileManager.fileExists(atPath: entryURL.path) else { return nil }

        switch origin.originalType {
        case .video:
            guard let bookmark = makeBookmark(entryURL) else { return nil }
            return .video(bookmarkData: bookmark)
        case .web:
            guard let bookmark = makeBookmark(folderURL) else { return nil }
            return .html(
                source: .folder(bookmarkData: bookmark, indexFileName: entryFile),
                config: HTMLConfig(physicalPixelLayout: true, originKind: origin.originKind)
            )
        case .scene, .application, .unknown:
            return nil
        }
    }

    private func cacheContent(for origin: WPEOrigin) -> WallpaperContent? {
        guard origin.resourceLocation == .cache,
              let cacheRelativePath = origin.cacheRelativePath,
              WPEPathSafety.isSafeCacheRelativePath(cacheRelativePath),
              let entryFile = origin.entryFile,
              !entryFile.isEmpty else {
            return nil
        }

        let safeSupportRoot = applicationSupportRootURL.standardizedFileURL.resolvingSymlinksInPath()
        let cacheURL = safeSupportRoot
            .appendingPathComponent(cacheRelativePath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard WPEPathSafety.contains(cacheURL, in: safeSupportRoot) else {
            return nil
        }
        let entryURLCandidate = resourceURL(root: cacheURL, relativePath: entryFile)
        let entryExistsInCache = entryURLCandidate.map { fileManager.fileExists(atPath: $0.path) } ?? false

        // Package-backed scene: scene.json lives in the source `scene.pkg`, not
        // the metadata-only cache. Rebuild the in-place descriptor from source.
        if origin.originalType == .scene, !entryExistsInCache {
            return packageBackedSceneContent(
                for: origin,
                cacheRelativePath: cacheRelativePath,
                entryFile: entryFile
            )
        }

        guard let entryURL = entryURLCandidate, entryExistsInCache else {
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
                config: HTMLConfig(
                    physicalPixelLayout: true,
                    originKind: origin.originKind
                )
            )
        case .scene:
            var tier: SceneCapabilityTier = .unsupported
            var preflightTier: WPEScenePreflightTier?
            var preflightFeatureFlags: [WPESceneFeatureFlag] = []
            do {
                let data = try Data(contentsOf: entryURL)
                let document = try WPESceneDocumentParser.parse(data: data)
                let dependencyMounts = WPEDependencyMountResolver().mounts(
                    dependencyWorkshopIDs: origin.dependencyWorkshopIDs,
                    origin: origin
                )
                let engineRoot = WPEEngineAssetsLibrary.shared.resolveAuthorizedRoot()
                tier = WPESceneCapabilityClassifier().capabilityTier(
                    for: document,
                    cacheURL: cacheURL,
                    dependencyMounts: dependencyMounts,
                    engineAssetsRootURL: engineRoot
                )
                let synthesizedProject = WallpaperEngineProject(
                    workshopID: origin.workshopID,
                    title: origin.title,
                    entryFile: entryFile,
                    type: origin.originalType,
                    previewFileName: origin.previewFileName,
                    propertyCount: 0,
                    dependencyWorkshopIDs: origin.dependencyWorkshopIDs,
                    requiresWindowsPlugin: origin.requiresWindowsPlugin
                )
                let preflight = WPEScenePreflight.classify(
                    document: document,
                    project: synthesizedProject,
                    scenePackageEntries: scenePackageEntryNames(in: cacheURL, fileManager: fileManager)
                )
                preflightTier = preflight.tier
                preflightFeatureFlags = sortedPreflightFeatureFlags(preflight.featureFlags)
            } catch {
            }
            return .scene(SceneDescriptor(
                workshopID: origin.workshopID,
                cacheRelativePath: cacheRelativePath,
                entryFile: entryFile,
                capabilityTier: tier,
                dependencyWorkshopIDs: origin.dependencyWorkshopIDs,
                preflightTier: preflightTier,
                preflightFeatureFlags: preflightFeatureFlags
            ))
        case .application, .unknown:
            return nil
        }
    }

    /// Rebuilds a package-backed scene descriptor from its source `scene.pkg`
    /// (favorites/history reconstruction for in-place scenes whose cache holds
    /// only `project.json`). Returns `nil` if the source can't be opened.
    private func packageBackedSceneContent(
        for origin: WPEOrigin,
        cacheRelativePath: String,
        entryFile: String
    ) -> WallpaperContent? {
        var isStale = false
        guard let folderURL = try? URL(
            resolvingBookmarkData: origin.sourceFolderBookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        let didStart = folderURL.startAccessingSecurityScopedResource()
        defer { if didStart { folderURL.stopAccessingSecurityScopedResource() } }

        let packageURL = folderURL.appendingPathComponent("scene.pkg", isDirectory: false)
        guard fileManager.fileExists(atPath: packageURL.path),
              let provider = try? WPEPackageSceneAssetProvider(packageURL: packageURL),
              let sceneData = try? provider.data(atRelativePath: entryFile),
              let document = try? WPESceneDocumentParser.parse(data: sceneData) else {
            return nil
        }

        let dependencyMounts = WPEDependencyMountResolver().mounts(
            dependencyWorkshopIDs: origin.dependencyWorkshopIDs,
            origin: origin
        )
        let engineRoot = WPEEngineAssetsLibrary.shared.resolveAuthorizedRoot()
        let tier = WPESceneCapabilityClassifier().capabilityTier(
            for: document,
            primaryProvider: provider,
            dependencyMounts: dependencyMounts,
            engineAssetsRootURL: engineRoot
        )
        let synthesizedProject = WallpaperEngineProject(
            workshopID: origin.workshopID,
            title: origin.title,
            entryFile: entryFile,
            type: origin.originalType,
            previewFileName: origin.previewFileName,
            propertyCount: 0,
            dependencyWorkshopIDs: origin.dependencyWorkshopIDs,
            requiresWindowsPlugin: origin.requiresWindowsPlugin
        )
        let preflight = WPEScenePreflight.classify(
            document: document,
            project: synthesizedProject,
            scenePackageEntries: provider.entryNames
        )
        return .scene(SceneDescriptor(
            workshopID: origin.workshopID,
            cacheRelativePath: cacheRelativePath,
            entryFile: entryFile,
            capabilityTier: tier,
            assetStorage: .packageSource(fileName: packageURL.lastPathComponent),
            dependencyWorkshopIDs: origin.dependencyWorkshopIDs,
            preflightTier: preflight.tier,
            preflightFeatureFlags: sortedPreflightFeatureFlags(preflight.featureFlags)
        ))
    }

    private func resourceURL(root: URL, relativePath: String) -> URL? {
        WPEPathSafety.resourceURL(root: root, relativePath: relativePath)
    }
}

/// Enumerates regular-file entries under a scene cache root so `WPEScenePreflight` can probe for custom shader payloads (`.vert`, `.frag`) without having to walk the directory itself.
private func scenePackageEntryNames(
    in rootURL: URL,
    fileManager: FileManager,
    limit: Int = 10_000
) -> [String] {
    guard limit > 0,
          let enumerator = fileManager.enumerator(
              at: rootURL,
              includingPropertiesForKeys: [.isRegularFileKey],
              options: [.skipsHiddenFiles, .skipsPackageDescendants]
          ) else {
        return []
    }

    var entries: [String] = []
    entries.reserveCapacity(min(limit, 256))
    for case let url as URL in enumerator {
        guard entries.count < limit else { break }
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            continue
        }
        entries.append(url.lastPathComponent)
    }
    return entries
}

/// `WPEScenePreflight` emits an unordered `Set` so descriptor persistence matches the historical ordering convention (alphabetical by raw value).
private func sortedPreflightFeatureFlags(_ flags: Set<WPESceneFeatureFlag>) -> [WPESceneFeatureFlag] {
    flags.sorted { $0.rawValue < $1.rawValue }
}
#endif
