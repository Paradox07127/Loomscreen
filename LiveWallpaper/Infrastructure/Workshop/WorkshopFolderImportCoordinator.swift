#if !LITE_BUILD && DIRECT_DISTRIBUTION
import AppKit
import Foundation
import Observation
import os

/// Drives "Import from folder…" on the Installed tab. Picks a folder, discovers
/// every Wallpaper Engine project inside it (a single project folder, or a
/// library root full of numbered project folders), mirrors each into the
/// app-managed library via `WallpaperEngineImportService`, and records a
/// `WPEHistoryEntry` so it appears in Installed — the same managed-library path
/// a SteamCMD download takes, minus applying to a screen. App-lifetime singleton
/// so a long import survives view churn.
@MainActor
@Observable
final class WorkshopFolderImportCoordinator {
    static let shared = WorkshopFolderImportCoordinator()

    private(set) var isImporting = false

    @ObservationIgnored private var isIngesting = false
    @ObservationIgnored private let importService: WallpaperEngineImportService
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let logger = os.Logger(subsystem: "com.loomscreen.livewallpaper", category: "WorkshopFolderImport")

    init(
        importService: WallpaperEngineImportService = WallpaperEngineImportService(),
        fileManager: FileManager = .default
    ) {
        self.importService = importService
        self.fileManager = fileManager
    }

    /// Presents the folder picker, then imports asynchronously. No-op while a
    /// previous import is still running.
    func presentImportPanel() {
        guard !isImporting else { return }
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Import", comment: "Folder picker confirm button for importing Wallpaper Engine projects.")
        panel.message = String(localized: "Choose a Wallpaper Engine project folder, or a folder that contains numbered project folders.", comment: "Folder picker message for the Workshop library import.")

        guard panel.runModal() == .OK, let folder = panel.url else { return }
        isImporting = true
        Task { [weak self] in
            await self?.importAll(from: folder)
        }
    }

    private func importAll(from folder: URL) async {
        defer { isImporting = false }

        let didStart = folder.startAccessingSecurityScopedResource()
        defer { if didStart { folder.stopAccessingSecurityScopedResource() } }

        let projectFolders = discoverProjectFolders(in: folder)
        guard !projectFolders.isEmpty else {
            WorkshopToastCenter.shared.post(
                headline: String(localized: "Import failed", comment: "Folder import failure toast headline."),
                title: folder.lastPathComponent,
                message: String(localized: "No Wallpaper Engine projects were found in that folder.", comment: "Folder import failure: the chosen folder had no project.json."),
                isSuccess: false
            )
            return
        }

        var imported = 0
        for projectFolder in projectFolders {
            if await importOne(projectFolder) { imported += 1 }
        }

        emitSummary(folder: folder, imported: imported, skipped: projectFolders.count - imported)
    }

    /// Reconciles the managed library with what is already on disk: imports
    /// every project that isn't already recorded, from BOTH the app-managed
    /// SteamCMD download tree AND the user-configured "Workshop library folder"
    /// — so the Installed tab reflects existing downloads by default, including
    /// items the user downloaded with their own SteamCMD / the Steam client to a
    /// folder they granted access to. Silent unless it actually adds something;
    /// re-runs are cheap (a directory scan + a set check).
    func ingestExistingDownloads(using doctor: SteamCMDDoctorService) async {
        guard !isIngesting, !isImporting else { return }
        isIngesting = true
        defer { isIngesting = false }

        var known = Set(SettingsManager.shared.loadGlobalSettings().recentWPEImports.map(\.origin.workshopID))
        var added = 0

        // 1. App-managed SteamCMD download tree (container-local).
        await doctor.enumerateDownloadedItemFolders { [weak self] folder in
            guard let self else { return }
            guard !known.contains(folder.lastPathComponent) else { return }
            if await self.importOne(folder) {
                added += 1
                known.insert(folder.lastPathComponent)
            }
        }

        // 2. The user-configured "Workshop library folder" — reuses the bookmark
        //    that setting persists. Previously only a debug harness read it, so
        //    pointing it at a real download folder did nothing for Installed.
        if let libraryRoot = SettingsManager.shared.loadWorkshopLibraryRootBookmark() {
            added += await importNewProjects(fromWorkshopLibrary: libraryRoot, known: known)
        }

        guard added > 0 else { return }
        WorkshopToastCenter.shared.post(
            headline: String(localized: "Library synced", comment: "Toast headline after auto-importing existing SteamCMD downloads."),
            title: String(localized: "SteamCMD downloads", comment: "Toast subject for the SteamCMD download sync."),
            message: String(localized: "Added \(added) downloaded wallpaper(s) to your library.", comment: "Sync summary. Placeholder is the number of newly imported downloads."),
            isSuccess: true
        )
    }

    /// Imports every not-yet-recorded WPE project discovered under the user's
    /// configured Workshop library folder. Returns the number newly added.
    private func importNewProjects(fromWorkshopLibrary rootBookmark: Data, known: Set<String>) async -> Int {
        guard case .success(let initialRoot) = SecurityScopedBookmarkResolver.shared.resolve(
            rootBookmark,
            target: .workshopLibraryRoot
        ) else { return 0 }

        // Refuse the misconfiguration where the library root IS the app's own
        // WPE cache: importing from it would feed cache folders back into the
        // mirror path. (The cache self-protects too, but skip the scan entirely.)
        let libraryRoot = initialRoot.url.standardizedFileURL.resolvingSymlinksInPath()
        let appCacheRoot = WallpaperEngineCache.defaultRootURL.standardizedFileURL.resolvingSymlinksInPath()
        guard libraryRoot != appCacheRoot else {
            logger.info("Workshop library scan skipped: root points at the app-managed WPE cache")
            return 0
        }

        let discovered: [WallpaperEngineLibraryScanner.DiscoveredProject]
        do {
            discovered = try await WallpaperEngineLibraryScanner().scan(
                rootBookmarkData: initialRoot.bookmarkData,
                alreadyImportedWorkshopIDs: known
            )
        } catch {
            logger.info("Workshop library scan failed: \(error.localizedDescription, privacy: .public)")
            return 0
        }

        let fresh = discovered.filter { !$0.importedAlready }
        guard !fresh.isEmpty else { return 0 }

        // `scan()` releases its own security scope when it returns; re-acquire it
        // using the bookmark the scan resolved (it may have been refreshed) so the
        // per-project import reads (and source bookmarks) work.
        guard case .success(let resolved) = SecurityScopedBookmarkResolver.shared.resolve(
            fresh[0].libraryRootBookmarkData,
            target: .workshopLibraryRoot
        ) else { return 0 }
        let didStart = resolved.url.startAccessingSecurityScopedResource()
        defer { if didStart { resolved.url.stopAccessingSecurityScopedResource() } }

        var added = 0
        for project in fresh where await importOne(project.folderURL) {
            added += 1
        }
        return added
    }

    /// Imports one project folder into the managed library and records it.
    /// Returns true when a `WPEHistoryEntry` was recorded.
    private func importOne(_ projectFolder: URL) async -> Bool {
        do {
            switch try await importService.importProject(folder: projectFolder) {
            case .ready(_, let origin), .unsupported(let origin):
                SettingsManager.shared.recordWPEImport(
                    WPEHistoryEntry(origin: origin, importedAt: Date(), lastUsedAt: nil)
                )
                return true
            case .rejected(let reason):
                logger.info("Skipped a project during import: \(reason, privacy: .public)")
                return false
            }
        } catch {
            logger.info("Failed to read a project during import: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func emitSummary(folder: URL, imported: Int, skipped: Int) {
        guard imported > 0 else {
            WorkshopToastCenter.shared.post(
                headline: String(localized: "Import failed", comment: "Folder import failure toast headline."),
                title: folder.lastPathComponent,
                message: String(localized: "None of the projects in that folder could be imported.", comment: "Folder import failure: every discovered project was rejected."),
                isSuccess: false
            )
            return
        }

        let message: String
        if skipped > 0 {
            message = String(localized: "Imported \(imported), skipped \(skipped) unsupported.", comment: "Folder import success summary with skipped count. Placeholders are imported and skipped counts.")
        } else {
            message = String(localized: "Imported \(imported) into your library.", comment: "Folder import success summary. Placeholder is the imported count.")
        }
        WorkshopToastCenter.shared.post(
            headline: String(localized: "Imported", comment: "Folder import success toast headline."),
            title: folder.lastPathComponent,
            message: message,
            isSuccess: true
        )
    }

    /// A single project folder (has `project.json`) imports as itself; otherwise
    /// the chosen folder is treated as a library root and its immediate
    /// subfolders that contain a `project.json` are imported.
    private func discoverProjectFolders(in root: URL) -> [URL] {
        if fileManager.fileExists(atPath: root.appendingPathComponent("project.json").path) {
            return [root]
        }

        guard let children = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        return children.filter { child in
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return isDir && fileManager.fileExists(atPath: child.appendingPathComponent("project.json").path)
        }
    }
}
#endif
