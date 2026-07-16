#if !LITE_BUILD
import CoreGraphics
import Foundation

/// Owns the Wallpaper Engine import flow on top of `WPEImportTracker` and the
/// `WallpaperEngineImportService` / `WPECachedContentResolver` pair.
///
/// `saveConfiguration` / `restoreWallpaperSession` come in as callbacks so the
/// coordinator stays out of the Combine / notification lifetimes owned by
/// `ScreenManager`.
@MainActor
final class WPEImportCoordinator {
    typealias ImportOperation = @MainActor (URL) async throws -> WallpaperEngineImportService.ImportResult

    enum PreparationOutcome: Sendable, Equatable {
        case ready(content: WallpaperContent, origin: WPEOrigin)
        case unsupported(origin: WPEOrigin)
        case rejected(reason: String)
    }

    enum ApplyOutcome: Sendable, Equatable {
        case applied(origin: WPEOrigin)
        case unsupported(origin: WPEOrigin)
        case rejected(reason: String)
    }

    private let importOperation: ImportOperation
    private let cachedContentResolver: WPECachedContentResolver
    private let tracker: WPEImportTracker
    private let configurationStore: WallpaperConfigurationStore
    private let bookmarkResolver: SecurityScopedBookmarkResolver
    private let saveConfiguration: @MainActor (ScreenConfiguration) -> Void
    private let restoreWallpaperSession: @MainActor (Screen, ScreenConfiguration, Bool) -> Void
    private let recordImport: @MainActor (WPEHistoryEntry) -> Void
    private let persistOriginBookmarkRefresh: @MainActor (WPEOrigin, Data) -> Void
    private let isLifecycleActive: @MainActor () -> Bool
    private let notifyImportCompleted: @MainActor (CGDirectDisplayID, WPEType, String) -> Void

    init(
        importService: WallpaperEngineImportService = WallpaperEngineImportService(),
        cachedContentResolver: WPECachedContentResolver = WPECachedContentResolver(),
        tracker: WPEImportTracker,
        configurationStore: WallpaperConfigurationStore,
        bookmarkResolver: SecurityScopedBookmarkResolver = .shared,
        saveConfiguration: @MainActor @escaping (ScreenConfiguration) -> Void,
        restoreWallpaperSession: @MainActor @escaping (Screen, ScreenConfiguration, Bool) -> Void,
        importOperation: ImportOperation? = nil,
        recordImport: @MainActor @escaping (WPEHistoryEntry) -> Void = {
            SettingsManager.shared.recordWPEImport($0)
        },
        persistOriginBookmarkRefresh: @MainActor @escaping (WPEOrigin, Data) -> Void = {
            origin, refreshed in
            _ = SettingsManager.shared.replaceWPEHistorySourceBookmark(
                workshopID: origin.workshopID,
                matching: origin.sourceFolderBookmark,
                with: refreshed
            )
        },
        isLifecycleActive: @MainActor @escaping () -> Bool = { true },
        notifyImportCompleted: @MainActor @escaping (CGDirectDisplayID, WPEType, String) -> Void = {
            screenID, type, workshopID in
            NotificationCenter.default.post(
                name: .wpeImportDidComplete,
                object: nil,
                userInfo: [
                    "screenID": screenID,
                    "type": type.rawValue,
                    "workshopID": workshopID,
                ]
            )
        }
    ) {
        self.importOperation = importOperation ?? { [importService] folderURL in
            try await importService.importProject(folder: folderURL)
        }
        self.cachedContentResolver = cachedContentResolver
        self.tracker = tracker
        self.configurationStore = configurationStore
        self.bookmarkResolver = bookmarkResolver
        self.saveConfiguration = saveConfiguration
        self.restoreWallpaperSession = restoreWallpaperSession
        self.recordImport = recordImport
        self.persistOriginBookmarkRefresh = persistOriginBookmarkRefresh
        self.isLifecycleActive = isLifecycleActive
        self.notifyImportCompleted = notifyImportCompleted
    }

    // MARK: - Public orchestration

    func prepareProject(at folderURL: URL) async -> PreparationOutcome {
        do {
            let result = try await importOperation(folderURL)
            switch result {
            case .ready(let content, let origin):
                return .ready(content: content, origin: origin)
            case .unsupported(let origin):
                return .unsupported(origin: origin)
            case .rejected(let reason):
                return .rejected(reason: reason)
            }
        } catch {
            return .rejected(reason: error.localizedDescription)
        }
    }

    @discardableResult
    func importProject(at folderURL: URL, for screen: Screen) async -> ApplyOutcome {
        guard isLifecycleActive(), !tracker.isTerminated else {
            return .rejected(reason: "Application terminating")
        }
        let generation = tracker.bumpGeneration(for: screen.id)
        let outcome = await prepareProject(at: folderURL)
        guard isLifecycleActive(), tracker.isCurrentGeneration(generation, for: screen.id) else {
            return .rejected(reason: "Action superseded")
        }

        switch outcome {
        case .ready(let content, let origin):
            let now = Date()
            applyReady(content, origin: origin, importedAt: now, lastUsedAt: now, for: screen)
            return .applied(origin: origin)

        case .unsupported(let origin):
            recordImport(WPEHistoryEntry(origin: origin, importedAt: Date(), lastUsedAt: nil))
            postDidComplete(
                screenID: screen.id,
                type: origin.originalType,
                workshopID: origin.workshopID
            )
            tracker.clearError(for: screen.id)
            return .unsupported(origin: origin)

        case .rejected(let reason):
            tracker.recordError(.wpePackageInvalid(reason), for: screen.id)
            return .rejected(reason: reason)
        }
    }

    func activateHistoryEntry(_ entry: WPEHistoryEntry, for screen: Screen) async {
        guard isLifecycleActive(), !tracker.isTerminated else { return }
        do {
            let resolved = try bookmarkResolver
                .resolve(entry.origin.sourceFolderBookmark, target: .transient).get()
            let effectiveEntry: WPEHistoryEntry
            if resolved.didRefresh,
               let refreshed = entry.replacingSourceFolderBookmark(
                workshopID: entry.origin.workshopID,
                matching: entry.origin.sourceFolderBookmark,
                with: resolved.bookmarkData
               ) {
                persistOriginBookmarkRefresh(entry.origin, resolved.bookmarkData)
                effectiveEntry = refreshed
            } else {
                effectiveEntry = entry
            }
            let folderURL = resolved.url
            let didStartScope = folderURL.startAccessingSecurityScopedResource()
            defer {
                if didStartScope {
                    folderURL.stopAccessingSecurityScopedResource()
                }
            }

            guard didStartScope || FileManager.default.fileExists(atPath: folderURL.path) else {
                if applyCachedHistoryEntry(effectiveEntry, for: screen) {
                    return
                }
                tracker.recordError(.fileAccessDenied(entry.origin.title), for: screen.id)
                return
            }

            tracker.clearError(for: screen.id)
            await importProject(at: folderURL, for: screen)
            guard isLifecycleActive(), !tracker.isTerminated else { return }
            if tracker.error(for: screen.id) != nil {
                _ = applyCachedHistoryEntry(effectiveEntry, for: screen)
            }
        } catch {
            guard isLifecycleActive(), !tracker.isTerminated else { return }
            if applyCachedHistoryEntry(entry, for: screen) {
                return
            }
            tracker.recordError(.wpeImportFailed(error.localizedDescription), for: screen.id)
        }
    }

    func removeWorkshop(workshopID: String) {
        guard isLifecycleActive(), !tracker.isTerminated else { return }
        SettingsManager.shared.removeWPEImport(workshopID: workshopID)
        // Tombstone the delete so the auto-import scan can't resurrect the item
        // from a still-present SteamCMD download or library-folder copy. Applies
        // to every delete path (Installed + Scene tab) since they all funnel here.
        SettingsManager.shared.recordWPEDeleteTombstone(workshopID: workshopID)

        clearRemovedWorkshopReferences(workshopID: workshopID)
    }

    func clearRemovedWorkshopReferences(workshopID: String) {
        guard isLifecycleActive(), !tracker.isTerminated else { return }
        for var config in configurationStore.loadAll() where config.wpeOrigin?.workshopID == workshopID {
            config.wpeOrigin = nil
            saveConfiguration(config)
        }
    }

    // MARK: - Private helpers

    private func postDidComplete(
        screenID: CGDirectDisplayID,
        type: WPEType,
        workshopID: String
    ) {
        guard isLifecycleActive(), !tracker.isTerminated else { return }
        notifyImportCompleted(screenID, type, workshopID)
    }

    private func applyReady(
        _ content: WallpaperContent,
        origin: WPEOrigin,
        importedAt: Date,
        lastUsedAt: Date?,
        for screen: Screen
    ) {
        guard isLifecycleActive(), !tracker.isTerminated else { return }
        recordImport(WPEHistoryEntry(origin: origin, importedAt: importedAt, lastUsedAt: lastUsedAt))

        var config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) ?? ScreenConfiguration(
            screenID: screen.id,
            wallpaper: content
        ).applyingDisplayDefaults(SettingsManager.shared.loadDisplayDefaults())
        config.activeWallpaper = content
        if case .html(let source, let htmlConfig) = content {
            config.savedHTMLSource = source
            config.savedHTMLConfig = htmlConfig
        } else if case .video(let bookmarkData, let packageEntryName) = content {
            config.savedVideoBookmarkData = bookmarkData
            config.savedVideoPackageEntryName = packageEntryName
        }
        config.wpeOrigin = origin
        saveConfiguration(config)
        restoreWallpaperSession(screen, config, false)
        postDidComplete(
            screenID: screen.id,
            type: origin.originalType,
            workshopID: origin.workshopID
        )
        tracker.clearError(for: screen.id)
    }

    @discardableResult
    private func applyCachedHistoryEntry(_ entry: WPEHistoryEntry, for screen: Screen) -> Bool {
        guard isLifecycleActive(), !tracker.isTerminated else { return false }
        guard let content = cachedContentResolver.content(for: entry.origin) else {
            return false
        }
        applyReady(
            content,
            origin: entry.origin,
            importedAt: entry.importedAt,
            lastUsedAt: Date(),
            for: screen
        )
        return true
    }
}
#endif
