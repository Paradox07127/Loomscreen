#if !LITE_BUILD
import AppKit
import Foundation
import Metal

#if DEBUG

/// JSON-serialisable summary of one corpus playback run. Phase A.3 output —
/// drives the DEBUG developer-tools view and is the artifact maintainers
/// share when triaging which subset of the workshop corpus fails to load.
struct WPECorpusPlaybackReport: Codable, Sendable {
    let generatedAt: Date
    let perSceneTimeoutSeconds: Double
    let total: Int
    let summary: Summary
    let entries: [Entry]
    /// Which renderer produced this report. Phase 9 prerequisite: the
    /// harness routes through `WPERuntimeSelection.current`, so the same
    /// run that flips the DEBUG flag in DeveloperToolsView produces a
    /// WebGL report instead of a Metal one. Old archives without this
    /// field decode as `"metal"` (the historical default).
    let renderer: String

    init(
        generatedAt: Date,
        perSceneTimeoutSeconds: Double,
        total: Int,
        summary: Summary,
        entries: [Entry],
        renderer: String
    ) {
        self.generatedAt = generatedAt
        self.perSceneTimeoutSeconds = perSceneTimeoutSeconds
        self.total = total
        self.summary = summary
        self.entries = entries
        self.renderer = renderer
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        perSceneTimeoutSeconds = try container.decode(Double.self, forKey: .perSceneTimeoutSeconds)
        total = try container.decode(Int.self, forKey: .total)
        summary = try container.decode(Summary.self, forKey: .summary)
        entries = try container.decode([Entry].self, forKey: .entries)
        renderer = try container.decodeIfPresent(String.self, forKey: .renderer) ?? "metal"
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
    }
}

/// Headless driver that runs `WPESceneRenderer.load()` against every
/// imported scene workshop project and aggregates the outcome. The
/// concrete renderer (Metal or WebGL2) is selected per
/// `WPERuntimeSelection.current`, so flipping the DEBUG flag in
/// DeveloperToolsView changes which pipeline this harness exercises.
/// Phase A.3: turns "57 unknown scenes" into "P pass / F fail / T timeout"
/// with per-scene resolution diagnostics so Phase B has a target list.
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
        let renderer: WPESceneRenderer
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
        case webGLBundleMissing

        var errorDescription: String? {
            switch self {
            case .metalUnavailable:
                return "Metal is unavailable on this Mac."
            case .webGLBundleMissing:
                return "WPE WebGL runtime bundle is missing — run `npm run build` in WPEWebGLRuntime/."
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

        guard let rootBookmarkData = SettingsManager.shared.loadWorkshopLibraryRootBookmark() else {
            let message = "Workshop library root bookmark is missing."
            Logger.error("WPE corpus playback could not start: \(message)", category: .screenManager)
            progress(.failedToStart(message))
            return
        }

        let projects: [WallpaperEngineLibraryScanner.DiscoveredProject]
        do {
            projects = try await WallpaperEngineLibraryScanner()
                .scan(rootBookmarkData: rootBookmarkData, alreadyImportedWorkshopIDs: [])
                .filter { $0.type == .scene && $0.hasScenePackage }
        } catch {
            let message = Self.describe(error)
            Logger.error("WPE corpus playback scan failed: \(message)", category: .screenManager)
            progress(.failedToStart(message))
            return
        }

        let libraryRoot: URL
        switch SecurityScopedBookmarkResolver.shared.resolve(
            rootBookmarkData,
            target: .workshopLibraryRoot
        ) {
        case .success(let resolved):
            libraryRoot = resolved.url
        case .failure(let failure):
            let message = failure.errorDescription ?? "Workshop bookmark resolution failed"
            Logger.error("WPE corpus playback could not resolve library root: \(message)", category: .screenManager)
            progress(.failedToStart(message))
            return
        }
        let didStartScope = libraryRoot.startAccessingSecurityScopedResource()
        defer {
            if didStartScope { libraryRoot.stopAccessingSecurityScopedResource() }
        }

        Logger.info("WPE corpus playback: running \(projects.count) scene projects", category: .screenManager)

        var entries: [WPECorpusPlaybackReport.Entry] = []
        entries.reserveCapacity(projects.count)
        let engineAssetsRoot = WPEEngineAssetsLibrary.shared.resolveAuthorizedRoot()

        for (offset, project) in projects.enumerated() {
            if isCancelled() || Task.isCancelled {
                let report = makeReport(total: projects.count, entries: entries)
                Logger.warning("WPE corpus playback cancelled with \(entries.count)/\(projects.count) entries", category: .screenManager)
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
                    resolution: Self.resolutionSummary(from: headless.renderer.resolutionDiagnostics)
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
                    resolution: Self.resolutionSummary(from: headless.renderer.resolutionDiagnostics)
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
                    resolution: Self.resolutionSummary(from: headless.renderer.resolutionDiagnostics)
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
        } catch HarnessError.webGLBundleMissing {
            return makeFallbackEntry(
                discovered: discovered,
                capabilityTier: capabilityTier,
                preflightTier: preflightTier,
                result: .skipped,
                startedAt: startedAt,
                failureMessage: HarnessError.webGLBundleMissing.errorDescription
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

        let renderer: WPESceneRenderer
        switch WPERuntimeSelection.current {
        case .webGL:
            do {
                renderer = try WPEWebGLSceneRenderer(
                    descriptor: descriptor,
                    cacheRootURL: cacheURL,
                    dependencyMounts: dependencyMounts,
                    engineAssetsRootURL: engineAssetsRoot,
                    frame: frame
                )
            } catch SceneRenderingError.parseFailed {
                throw HarnessError.webGLBundleMissing
            }
        case .metal:
            guard let device = MTLCreateSystemDefaultDevice() else {
                throw HarnessError.metalUnavailable
            }
            renderer = try WPEMetalSceneRenderer(
                descriptor: descriptor,
                cacheRootURL: cacheURL,
                dependencyMounts: dependencyMounts,
                engineAssetsRootURL: engineAssetsRoot,
                frame: frame,
                device: device
            )
        }

        let window = VideoWallpaperWindow(frame: frame)
        window.contentView = renderer.nsView
        window.alphaValue = 0
        window.orderBack(nil)
        return HeadlessSession(renderer: renderer, window: window)
    }

    /// Re-derive the cache URL from the descriptor's `cacheRelativePath`, matching the contract `AmbientWallpaperSessionBuilder` enforces.
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

    /// Races `renderer.load()` against a wall-clock timeout.
    private func loadWithTimeout(renderer: WPESceneRenderer, seconds: Double) async throws {
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
            entries: entries,
            renderer: WPERuntimeSelection.current.rawValue
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
        resolution: WPECorpusPlaybackReport.Entry.ResolutionSummary
    ) -> WPECorpusPlaybackReport.Entry {
        WPECorpusPlaybackReport.Entry(
            workshopID: workshopID,
            title: title,
            capabilityTier: capabilityTier,
            preflightTier: preflightTier,
            result: result,
            elapsedSeconds: Date().timeIntervalSince(startedAt),
            failureMessage: failureMessage,
            resolution: resolution
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
            resolution: .empty
        )
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
