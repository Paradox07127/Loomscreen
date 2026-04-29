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
        case .scene, .application, .unknown:
            return .unsupported(origin: makeOrigin(project: project, sourceBookmark: sourceBookmark, cacheRelativePath: nil))
        }
    }

    private func importVideo(
        project: WallpaperEngineProject,
        folderURL: URL,
        sourceBookmark: Data
    ) async -> ImportResult {
        let pkgURL = folderURL.appendingPathComponent("scene.pkg")
        guard fileManager.fileExists(atPath: pkgURL.path) else {
            return .rejected(reason: "Missing scene.pkg")
        }

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
            cacheRelativePath: cacheRelativePath(for: project)
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

        // Unpacked web wallpapers stay in the user's Steam folder; cacheRelativePath
        // is nil because the runtime references the source bookmark directly.
        let origin = makeOrigin(project: project, sourceBookmark: sourceBookmark, cacheRelativePath: nil)
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
            cacheRelativePath: cacheRelativePath(for: project)
        )
        let content = WallpaperContent.html(
            source: .folder(bookmarkData: folderBookmark, indexFileName: project.entryFile),
            config: HTMLConfig(physicalPixelLayout: true)
        )
        return .ready(content, origin: origin)
    }

    private func ensureExtracted(project: WallpaperEngineProject, pkgURL: URL) async -> Result<URL, ExtractionFailure> {
        do {
            let url = try await cache.ensureExtracted(workshopID: project.workshopID, sourcePkgURL: pkgURL)
            return .success(url)
        } catch {
            return .failure(ExtractionFailure(reason: describe(error)))
        }
    }

    private func makeOrigin(project: WallpaperEngineProject, sourceBookmark: Data, cacheRelativePath: String?) -> WPEOrigin {
        WPEOrigin(
            workshopID: project.workshopID,
            title: project.title,
            originalType: project.type,
            sourceFolderBookmark: sourceBookmark,
            cacheRelativePath: cacheRelativePath,
            previewFileName: project.previewFileName
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
