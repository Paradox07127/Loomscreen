#if !LITE_BUILD
import AppKit
import Foundation
import Metal

#if DEBUG

/// JSON-serialisable summary of one corpus playback run. The artifact maintainers
/// share when triaging which subset of the workshop corpus fails to load.
struct WPECorpusPlaybackReport: Codable, Sendable {
    let generatedAt: Date
    let perSceneTimeoutSeconds: Double
    let total: Int
    let summary: Summary
    let entries: [Entry]

    init(
        generatedAt: Date,
        perSceneTimeoutSeconds: Double,
        total: Int,
        summary: Summary,
        entries: [Entry]
    ) {
        self.generatedAt = generatedAt
        self.perSceneTimeoutSeconds = perSceneTimeoutSeconds
        self.total = total
        self.summary = summary
        self.entries = entries
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        perSceneTimeoutSeconds = try container.decode(Double.self, forKey: .perSceneTimeoutSeconds)
        total = try container.decode(Int.self, forKey: .total)
        summary = try container.decode(Summary.self, forKey: .summary)
        entries = try container.decode([Entry].self, forKey: .entries)
    }

    struct Summary: Codable, Sendable {
        let passCount: Int
        let failCount: Int
        let timeoutCount: Int
        let skippedCount: Int
    }

    struct Entry: Codable, Sendable, Identifiable {
        let workshopID: String
        let title: String
        let capabilityTier: SceneCapabilityTier?
        let preflightTier: WPEScenePreflightTier?
        let result: Outcome
        let elapsedSeconds: Double
        let failureMessage: String?
        let resolution: ResolutionSummary
        /// First-frame readback summary. Nil for skipped scenes and archives
        /// produced before the visual gate was added.
        let visual: VisualSummary?

        var id: String { workshopID }

        enum Outcome: String, Codable, Sendable {
            case pass
            case fail
            case timeout
            case skipped
        }

        struct ResolutionSummary: Codable, Sendable {
            let events: Int
            let resolved: Int
            let missing: Int
            let firstMisses: [String]

            static let empty = Self(events: 0, resolved: 0, missing: 0, firstMisses: [])
        }

        struct VisualSummary: Codable, Sendable {
            let width: Int
            let height: Int
            let nonBlackPixelCount: Int
            let nonTransparentPixelCount: Int
            let nonBlackBounds: WPEMetalTextureVisualBounds?
            let nonBlackCoversFullFrame: Bool

            init(stats: WPEMetalTextureVisualStats) {
                self.width = stats.width
                self.height = stats.height
                self.nonBlackPixelCount = stats.nonBlackPixelCount
                self.nonTransparentPixelCount = stats.nonTransparentPixelCount
                self.nonBlackBounds = stats.nonBlackBounds
                self.nonBlackCoversFullFrame = stats.nonBlackCoversFullFrame
            }
        }
    }
}

/// Headless driver that runs `WPEMetalSceneRenderer.load()` against every
/// imported scene workshop project and aggregates the outcome.
///
/// The harness owns the renderer lifetime per scene — it builds the same
/// `VideoWallpaperWindow` + renderer combo `AmbientWallpaperSessionBuilder`
/// uses, but the window is held at `alphaValue = 0` and ordered to the
/// wallpaper level so nothing flashes on the user's desktop while the loop
/// runs.
@MainActor
final class WPECorpusPlaybackHarness {
    struct Configuration: Sendable {
        var perSceneTimeoutSeconds: Double = 8
        var rendererFrame: CGSize = CGSize(width: 1920, height: 1080)
        /// When non-nil, only workshop IDs in this set are exercised. Used
        /// by the Developer Tools single-scene debug button so a maintainer
        /// can iterate on one failing scene without burning through the
        /// whole corpus run.
        var workshopIDFilter: Set<String>? = nil
    }

    enum Progress: Sendable {
        case scanning
        case running(index: Int, total: Int, workshopID: String, title: String)
        case sceneComplete(WPECorpusPlaybackReport.Entry)
        case finished(WPECorpusPlaybackReport)
        case cancelled(WPECorpusPlaybackReport)
        case failedToStart(String)
    }

    private struct HeadlessSession {
        let renderer: WPEMetalSceneRenderer
        let window: NSWindow
    }

    private struct TimeoutError: Error, LocalizedError, Sendable {
        let seconds: Double

        var errorDescription: String? {
            "Timed out after \(String(format: "%.1f", seconds))s waiting for renderer.load()."
        }
    }

    private enum HarnessError: Error, LocalizedError, Sendable {
        case metalUnavailable

        var errorDescription: String? {
            switch self {
            case .metalUnavailable:
                return "Metal is unavailable on this Mac."
            }
        }
    }

    private let configuration: Configuration
    private let cache: WallpaperEngineCache

    init(
        configuration: Configuration = .init(),
        cache: WallpaperEngineCache = .init()
    ) {
        self.configuration = configuration
        self.cache = cache
    }

    func run(
        progress: @escaping @MainActor (Progress) -> Void,
        isCancelled: @escaping @MainActor () -> Bool
    ) async {
        progress(.scanning)
        Logger.info("WPE corpus playback: scanning Workshop library", category: .screenManager)

        // Two scene sources, merged + deduped by workshop ID:
        //   1. the user's Workshop library bookmark — a real Steam install OUTSIDE
        //      the container, which needs a held security scope during runScene; and
        //   2. steamcmd's sandbox-redirected download tree INSIDE the container
        //      (Application Support/Steam/…/431960), where in-app "download" items
        //      actually land — full access, no bookmark.
        // Either may be empty; we only fail if BOTH are.
        var libraryScope: URL?
        var projects: [WallpaperEngineLibraryScanner.DiscoveredProject] = []
        var seenIDs = Set<String>()

        func ingest(_ scanned: [WallpaperEngineLibraryScanner.DiscoveredProject]) {
            for project in scanned where project.type == .scene && project.hasScenePackage {
                if let allow = configuration.workshopIDFilter, !allow.contains(project.workshopID) { continue }
                guard seenIDs.insert(project.workshopID).inserted else { continue }
                projects.append(project)
            }
        }

        if let rootBookmarkData = SettingsManager.shared.loadWorkshopLibraryRootBookmark(),
           case .success(let resolved) = SecurityScopedBookmarkResolver.shared.resolve(
               rootBookmarkData, target: .workshopLibraryRoot
           ),
           resolved.url.startAccessingSecurityScopedResource() {
            // Only ingest the out-of-container bookmarked scenes while we actually
            // HOLD the root scope — runScene reads each project's folderURL directly,
            // which fails without it. If the scope didn't open, fall through to the
            // in-container steamcmd source (which needs no scope) instead.
            libraryScope = resolved.url
            if let scanned = try? await WallpaperEngineLibraryScanner()
                .scan(rootBookmarkData: rootBookmarkData, alreadyImportedWorkshopIDs: []) {
                ingest(scanned)
            }
        }
        defer { libraryScope?.stopAccessingSecurityScopedResource() }

        if let steamContentRoot = Self.steamcmdContentRoot,
           let scanned = try? await WallpaperEngineLibraryScanner()
            .scan(rootURL: steamContentRoot, alreadyImportedWorkshopIDs: []) {
            ingest(scanned)
        }

        guard !projects.isEmpty else {
            let message = "No scenes found — neither the Workshop library bookmark nor the steamcmd download folder (\(Self.steamcmdContentRoot?.path ?? "n/a")) has any scene.pkg projects."
            Logger.error("WPE corpus playback could not start: \(message)", category: .screenManager)
            progress(.failedToStart(message))
            return
        }

        Logger.info("WPE corpus playback: running \(projects.count) scene projects", category: .screenManager)

        var entries: [WPECorpusPlaybackReport.Entry] = []
        entries.reserveCapacity(projects.count)
        let engineAssetsRoot = WPEEngineAssetsLibrary.shared.resolveAuthorizedRoot()

        for (offset, project) in projects.enumerated() {
            if isCancelled() || Task.isCancelled {
                let report = makeReport(total: projects.count, entries: entries)
                Logger.info("WPE corpus playback cancelled with \(entries.count)/\(projects.count) entries", category: .screenManager)
                progress(.cancelled(report))
                return
            }

            progress(.running(
                index: offset + 1,
                total: projects.count,
                workshopID: project.workshopID,
                title: project.title
            ))

            let entry = await runScene(project: project, engineAssetsRoot: engineAssetsRoot)
            entries.append(entry)
            progress(.sceneComplete(entry))

            switch entry.result {
            case .pass:
                Logger.info("WPE corpus playback passed \(entry.workshopID)", category: .screenManager)
            case .fail, .timeout, .skipped:
                Logger.warning(
                    "WPE corpus playback \(entry.result.rawValue) \(entry.workshopID): \(entry.failureMessage ?? "(no message)")",
                    category: .screenManager
                )
            }

            await Task.yield()
        }

        let report = makeReport(total: projects.count, entries: entries)
        Logger.info(
            "WPE corpus playback finished: pass=\(report.summary.passCount) fail=\(report.summary.failCount) timeout=\(report.summary.timeoutCount) skipped=\(report.summary.skippedCount)",
            category: .screenManager
        )
        progress(.finished(report))
    }

    private func runScene(
        project discovered: WallpaperEngineLibraryScanner.DiscoveredProject,
        engineAssetsRoot: URL?
    ) async -> WPECorpusPlaybackReport.Entry {
        let startedAt = Date()
        var capabilityTier: SceneCapabilityTier?
        var preflightTier: WPEScenePreflightTier?

        do {
            let project = try await Self.readProject(from: discovered.folderURL)
            let sourcePkgURL = discovered.folderURL.appendingPathComponent("scene.pkg")
            let cacheURL = try await cache.ensureExtracted(
                workshopID: project.workshopID,
                sourcePkgURL: sourcePkgURL
            )
            let entryURL = try SceneResourceResolver(cacheRootURL: cacheURL)
                .resolveExistingFileURL(relativePath: project.entryFile)
            let document = try await Self.readSceneDocument(from: entryURL)
            let scenePackageEntries = await Self.scenePackageEntryNames(in: cacheURL)
            let preflight = WPEScenePreflight.classify(
                document: document,
                project: project,
                scenePackageEntries: scenePackageEntries
            )
            preflightTier = preflight.tier

            let dependencyMounts = WPEDependencyMountResolver().mounts(
                dependencyWorkshopIDs: project.dependencyWorkshopIDs,
                origin: nil
            )
            capabilityTier = await Self.capabilityTier(
                document: document,
                cacheURL: cacheURL,
                dependencyMounts: dependencyMounts,
                engineAssetsRoot: engineAssetsRoot
            )

            let descriptor = SceneDescriptor(
                workshopID: project.workshopID,
                cacheRelativePath: Self.cacheRelativePath(for: project.workshopID),
                entryFile: project.entryFile,
                capabilityTier: capabilityTier ?? .unsupported,
                dependencyWorkshopIDs: project.dependencyWorkshopIDs,
                preflightTier: preflight.tier,
                preflightFeatureFlags: preflight.featureFlags.sorted { $0.rawValue < $1.rawValue }
            )
            let headless = try makeHeadlessSession(
                descriptor: descriptor,
                dependencyMounts: dependencyMounts,
                engineAssetsRoot: engineAssetsRoot
            )
            defer { tearDown(headless) }

            do {
                try await loadWithTimeout(
                    renderer: headless.renderer,
                    seconds: configuration.perSceneTimeoutSeconds
                )
                return makeEntry(
                    workshopID: project.workshopID,
                    title: discovered.title.isEmpty ? project.title : discovered.title,
                    capabilityTier: capabilityTier,
                    preflightTier: preflightTier,
                    result: .pass,
                    startedAt: startedAt,
                    failureMessage: nil,
                    resolution: Self.resolutionSummary(from: headless.renderer.resolutionDiagnostics),
                    visual: Self.visualSummary(from: headless.renderer)
                )
            } catch let error as TimeoutError {
                return makeEntry(
                    workshopID: project.workshopID,
                    title: discovered.title.isEmpty ? project.title : discovered.title,
                    capabilityTier: capabilityTier,
                    preflightTier: preflightTier,
                    result: .timeout,
                    startedAt: startedAt,
                    failureMessage: error.errorDescription,
                    resolution: Self.resolutionSummary(from: headless.renderer.resolutionDiagnostics),
                    visual: Self.visualSummary(from: headless.renderer)
                )
            } catch {
                let diagnosticMessage = headless.renderer.loadDiagnostics?.errorDescription
                return makeEntry(
                    workshopID: project.workshopID,
                    title: discovered.title.isEmpty ? project.title : discovered.title,
                    capabilityTier: capabilityTier,
                    preflightTier: preflightTier,
                    result: .fail,
                    startedAt: startedAt,
                    failureMessage: diagnosticMessage ?? Self.describe(error),
                    resolution: Self.resolutionSummary(from: headless.renderer.resolutionDiagnostics),
                    visual: Self.visualSummary(from: headless.renderer)
                )
            }
        } catch HarnessError.metalUnavailable {
            return makeFallbackEntry(
                discovered: discovered,
                capabilityTier: capabilityTier,
                preflightTier: preflightTier,
                result: .skipped,
                startedAt: startedAt,
                failureMessage: HarnessError.metalUnavailable.errorDescription
            )
        } catch {
            return makeFallbackEntry(
                discovered: discovered,
                capabilityTier: capabilityTier,
                preflightTier: preflightTier,
                result: .fail,
                startedAt: startedAt,
                failureMessage: Self.describe(error)
            )
        }
    }

    private func makeHeadlessSession(
        descriptor: SceneDescriptor,
        dependencyMounts: [WPEAssetMount],
        engineAssetsRoot: URL?
    ) throws -> HeadlessSession {
        let frame = CGRect(origin: .zero, size: configuration.rendererFrame)
        let cacheURL = applicationSupportCacheURL(for: descriptor)
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw HarnessError.metalUnavailable
        }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: descriptor,
            cacheRootURL: cacheURL,
            dependencyMounts: dependencyMounts,
            engineAssetsRootURL: engineAssetsRoot,
            frame: frame,
            device: device
        )

        let window = VideoWallpaperWindow(frame: frame)
        window.contentView = renderer.nsView
        window.alphaValue = 0
        window.orderBack(nil)
        return HeadlessSession(renderer: renderer, window: window)
    }

    /// steamcmd's sandbox-redirected Workshop download tree inside the app container
    /// (`Application Support/Steam/steamapps/workshop/content/431960`). A steamcmd
    /// spawned by this sandboxed app writes to its own STEAMROOT, which the sandbox
    /// redirects here — so this is where in-app "download" items actually land,
    /// regardless of any bound workdir. Mirrors `SteamCMDDoctorService`'s layout.
    /// 431960 = Wallpaper Engine's Steam app ID.
    private static var steamcmdContentRoot: URL? {
        guard let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return nil }
        return appSupport
            .appendingPathComponent("Steam", isDirectory: true)
            .appendingPathComponent("steamapps", isDirectory: true)
            .appendingPathComponent("workshop", isDirectory: true)
            .appendingPathComponent("content", isDirectory: true)
            .appendingPathComponent("431960", isDirectory: true)
    }

    /// Must match the cache-URL contract `AmbientWallpaperSessionBuilder` enforces.
    private func applicationSupportCacheURL(for descriptor: SceneDescriptor) -> URL {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support
            .appendingPathComponent("LiveWallpaper", isDirectory: true)
            .appendingPathComponent(descriptor.cacheRelativePath, isDirectory: true)
    }

    private func tearDown(_ headless: HeadlessSession) {
        headless.renderer.cleanup()
        headless.window.orderOut(nil)
        headless.window.contentView = nil
        headless.window.close()
    }

    private func loadWithTimeout(renderer: WPEMetalSceneRenderer, seconds: Double) async throws {
        let nanoseconds = Self.timeoutNanoseconds(for: seconds)
        let state = TimeoutRaceState()
        let loadTask = Task { @MainActor in
            try await renderer.load()
        }

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    Task {
                        do {
                            try await loadTask.value
                            if state.markComplete() {
                                continuation.resume()
                            }
                        } catch {
                            if state.markComplete() {
                                continuation.resume(throwing: error)
                            }
                        }
                    }
                    Task {
                        try? await Task.sleep(nanoseconds: nanoseconds)
                        if state.markComplete() {
                            loadTask.cancel()
                            continuation.resume(throwing: TimeoutError(seconds: seconds))
                        }
                    }
                }
            } onCancel: {
                loadTask.cancel()
            }
        } catch {
            _ = await loadTask.result
            throw error
        }
    }

    private func makeReport(
        total: Int,
        entries: [WPECorpusPlaybackReport.Entry]
    ) -> WPECorpusPlaybackReport {
        WPECorpusPlaybackReport(
            generatedAt: Date(),
            perSceneTimeoutSeconds: configuration.perSceneTimeoutSeconds,
            total: total,
            summary: Self.summary(for: entries),
            entries: entries
        )
    }

    private func makeEntry(
        workshopID: String,
        title: String,
        capabilityTier: SceneCapabilityTier?,
        preflightTier: WPEScenePreflightTier?,
        result: WPECorpusPlaybackReport.Entry.Outcome,
        startedAt: Date,
        failureMessage: String?,
        resolution: WPECorpusPlaybackReport.Entry.ResolutionSummary,
        visual: WPECorpusPlaybackReport.Entry.VisualSummary?
    ) -> WPECorpusPlaybackReport.Entry {
        WPECorpusPlaybackReport.Entry(
            workshopID: workshopID,
            title: title,
            capabilityTier: capabilityTier,
            preflightTier: preflightTier,
            result: result,
            elapsedSeconds: Date().timeIntervalSince(startedAt),
            failureMessage: failureMessage,
            resolution: resolution,
            visual: visual
        )
    }

    private func makeFallbackEntry(
        discovered: WallpaperEngineLibraryScanner.DiscoveredProject,
        capabilityTier: SceneCapabilityTier?,
        preflightTier: WPEScenePreflightTier?,
        result: WPECorpusPlaybackReport.Entry.Outcome,
        startedAt: Date,
        failureMessage: String?
    ) -> WPECorpusPlaybackReport.Entry {
        WPECorpusPlaybackReport.Entry(
            workshopID: discovered.workshopID,
            title: discovered.title,
            capabilityTier: capabilityTier,
            preflightTier: preflightTier,
            result: result,
            elapsedSeconds: Date().timeIntervalSince(startedAt),
            failureMessage: failureMessage,
            resolution: .empty,
            visual: nil
        )
    }

    private static func visualSummary(
        from renderer: WPEMetalSceneRenderer
    ) -> WPECorpusPlaybackReport.Entry.VisualSummary? {
        guard let texture = renderer.renderedTexture,
              let stats = WPEMetalTextureVisualStats.analyze(texture: texture) else {
            return nil
        }
        return WPECorpusPlaybackReport.Entry.VisualSummary(stats: stats)
    }

    private static func readProject(from folderURL: URL) async throws -> WallpaperEngineProject {
        try await Task.detached(priority: .userInitiated) {
            try WallpaperEngineProject.read(from: folderURL)
        }.value
    }

    private static func readSceneDocument(from entryURL: URL) async throws -> WPESceneDocument {
        try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: entryURL)
            return try WPESceneDocumentParser.parse(data: data)
        }.value
    }

    private static func capabilityTier(
        document: WPESceneDocument,
        cacheURL: URL,
        dependencyMounts: [WPEAssetMount],
        engineAssetsRoot: URL?
    ) async -> SceneCapabilityTier {
        await Task.detached(priority: .userInitiated) {
            WPESceneCapabilityClassifier().capabilityTier(
                for: document,
                cacheURL: cacheURL,
                dependencyMounts: dependencyMounts,
                engineAssetsRootURL: engineAssetsRoot
            )
        }.value
    }

    private static func scenePackageEntryNames(in rootURL: URL, limit: Int = 10_000) async -> [String] {
        await Task.detached(priority: .utility) {
            enumerateSceneEntries(in: rootURL, limit: limit)
        }.value
    }

    /// Sync helper: Swift 6 marks `FileManager.DirectoryEnumerator`'s iterator
    /// unavailable from async contexts. Running the enumeration in this
    /// nonisolated nonasync function side-steps the diagnostic while the
    /// caller stays on a detached cooperative task.
    private nonisolated static func enumerateSceneEntries(
        in rootURL: URL,
        limit: Int
    ) -> [String] {
        guard limit > 0,
              let enumerator = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else {
            return []
        }

        let rootPath = rootURL.standardizedFileURL.resolvingSymlinksInPath().path
        var entries: [String] = []
        entries.reserveCapacity(min(limit, 256))

        for case let url as URL in enumerator {
            guard entries.count < limit else { break }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            if path.hasPrefix(rootPath + "/") {
                entries.append(String(path.dropFirst(rootPath.count + 1)))
            } else {
                entries.append(url.lastPathComponent)
            }
        }
        return entries
    }

    private static func resolutionSummary(
        from snapshot: WPEResolutionDiagnosticsSnapshot
    ) -> WPECorpusPlaybackReport.Entry.ResolutionSummary {
        let misses = snapshot.events.filter { $0.finalOutcome == .fileMissing }
        return WPECorpusPlaybackReport.Entry.ResolutionSummary(
            events: snapshot.events.count,
            resolved: snapshot.resolvedCount,
            missing: misses.count,
            firstMisses: misses.prefix(5).map(\.ref)
        )
    }

    private static func summary(
        for entries: [WPECorpusPlaybackReport.Entry]
    ) -> WPECorpusPlaybackReport.Summary {
        var passCount = 0
        var failCount = 0
        var timeoutCount = 0
        var skippedCount = 0

        for entry in entries {
            switch entry.result {
            case .pass: passCount += 1
            case .fail: failCount += 1
            case .timeout: timeoutCount += 1
            case .skipped: skippedCount += 1
            }
        }

        return WPECorpusPlaybackReport.Summary(
            passCount: passCount,
            failCount: failCount,
            timeoutCount: timeoutCount,
            skippedCount: skippedCount
        )
    }

    private static func cacheRelativePath(for workshopID: String) -> String {
        "wpe-cache/\(workshopID)"
    }

    private static func timeoutNanoseconds(for seconds: Double) -> UInt64 {
        let clamped = min(max(seconds, 0.001), 86_400)
        return UInt64(clamped * 1_000_000_000)
    }

    /// Single-shot latch for the timeout race in `loadWithTimeout` — whichever
    /// branch (load completion or wall-clock timeout) calls `markComplete()`
    /// first wins and resumes the continuation; the other call is a no-op.
    private final class TimeoutRaceState: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false

        func markComplete() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !done else { return false }
            done = true
            return true
        }
    }

    private static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description
        }
        return error.localizedDescription
    }
}
#endif
#endif
