#if !LITE_BUILD
import CoreGraphics
import Foundation

/// Owns the Wallpaper Engine import flow: folder prepare → outcome decision
/// → apply / unsupported / rejected branches → history-cache fallback. Sits
/// on top of the existing `WPEImportTracker` (per-screen error + generation
/// dicts) and the `WallpaperEngineImportService` / `WPECachedContentResolver`
/// service pair, so the heavy orchestration doesn't have to live in
/// `ScreenManager`.
///
/// The two side effects that touch broader `ScreenManager` state —
/// persisting a configuration and restoring the runtime wallpaper session
/// for a screen — come in as callbacks so the coordinator can stay focused
/// on the import semantics without reaching into Combine / notification
/// lifetimes owned by the manager.
@MainActor
final class WPEImportCoordinator {
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

    private let importService: WallpaperEngineImportService
    private let cachedContentResolver: WPECachedContentResolver
    private let tracker: WPEImportTracker
    private let configurationStore: WallpaperConfigurationStore
    private let saveConfiguration: @MainActor (ScreenConfiguration) -> Void
    private let restoreWallpaperSession: @MainActor (Screen, ScreenConfiguration, Bool) -> Void

    init(
        importService: WallpaperEngineImportService = WallpaperEngineImportService(),
        cachedContentResolver: WPECachedContentResolver = WPECachedContentResolver(),
        tracker: WPEImportTracker,
        configurationStore: WallpaperConfigurationStore,
        saveConfiguration: @MainActor @escaping (ScreenConfiguration) -> Void,
        restoreWallpaperSession: @MainActor @escaping (Screen, ScreenConfiguration, Bool) -> Void
    ) {
        self.importService = importService
        self.cachedContentResolver = cachedContentResolver
        self.tracker = tracker
        self.configurationStore = configurationStore
        self.saveConfiguration = saveConfiguration
        self.restoreWallpaperSession = restoreWallpaperSession
    }

    // MARK: - Public orchestration

    func prepareProject(at folderURL: URL) async -> PreparationOutcome {
        do {
            let result = try await importService.importProject(folder: folderURL)
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
        let generation = tracker.bumpGeneration(for: screen.id)
        let outcome = await prepareProject(at: folderURL)
        guard tracker.isCurrentGeneration(generation, for: screen.id) else {
            return .rejected(reason: "Action superseded")
        }

        switch outcome {
        case .ready(let content, let origin):
            let now = Date()
            applyReady(content, origin: origin, importedAt: now, lastUsedAt: now, for: screen)
            return .applied(origin: origin)

        case .unsupported(let origin):
            SettingsManager.shared.recordWPEImport(
                WPEHistoryEntry(origin: origin, importedAt: Date(), lastUsedAt: nil)
            )
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
        do {
            var isStale = false
            let folderURL = try URL(
                resolvingBookmarkData: entry.origin.sourceFolderBookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            let didStartScope = folderURL.startAccessingSecurityScopedResource()
            defer {
                if didStartScope {
                    folderURL.stopAccessingSecurityScopedResource()
                }
            }

            guard didStartScope || FileManager.default.fileExists(atPath: folderURL.path) else {
                if applyCachedHistoryEntry(entry, for: screen) {
                    return
                }
                tracker.recordError(.fileAccessDenied(entry.origin.title), for: screen.id)
                return
            }

            tracker.clearError(for: screen.id)
            await importProject(at: folderURL, for: screen)
            if tracker.error(for: screen.id) != nil {
                _ = applyCachedHistoryEntry(entry, for: screen)
            }
        } catch {
            if applyCachedHistoryEntry(entry, for: screen) {
                return
            }
            tracker.recordError(.wpeImportFailed(error.localizedDescription), for: screen.id)
        }
    }

    func removeWorkshop(workshopID: String) {
        SettingsManager.shared.removeWPEImport(workshopID: workshopID)

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

    private func applyReady(
        _ content: WallpaperContent,
        origin: WPEOrigin,
        importedAt: Date,
        lastUsedAt: Date?,
        for screen: Screen
    ) {
        SettingsManager.shared.recordWPEImport(
            WPEHistoryEntry(origin: origin, importedAt: importedAt, lastUsedAt: lastUsedAt)
        )

        var config = configurationStore.get(for: screen.id) ?? ScreenConfiguration(
            screenID: screen.id,
            wallpaper: content
        )
        config.activeWallpaper = content
        if case .html(let source, let htmlConfig) = content {
            config.savedHTMLSource = source
            config.savedHTMLConfig = htmlConfig
        } else if case .video(let bookmarkData) = content {
            config.savedVideoBookmarkData = bookmarkData
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
