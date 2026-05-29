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

    /// Reconciles the managed library with what SteamCMD has on disk: imports
    /// every downloaded project that isn't already recorded, so the Installed
    /// tab reflects the SteamCMD download folder by default — including items
    /// downloaded manually or before this ran. Silent unless it actually adds
    /// something; re-runs are cheap (a directory scan + a set check).
    func ingestSteamCMDDownloads(using doctor: SteamCMDDoctorService) async {
        guard !isIngesting, !isImporting else { return }
        isIngesting = true
        defer { isIngesting = false }

        let known = Set(SettingsManager.shared.loadGlobalSettings().recentWPEImports.map(\.origin.workshopID))
        var added = 0
        await doctor.enumerateDownloadedItemFolders { [weak self] folder in
            guard let self else { return }
            guard !known.contains(folder.lastPathComponent) else { return }
            if await self.importOne(folder) { added += 1 }
        }

        guard added > 0 else { return }
        WorkshopToastCenter.shared.post(
            headline: String(localized: "Library synced", comment: "Toast headline after auto-importing existing SteamCMD downloads."),
            title: String(localized: "SteamCMD downloads", comment: "Toast subject for the SteamCMD download sync."),
            message: String(localized: "Added \(added) downloaded wallpaper(s) to your library.", comment: "Sync summary. Placeholder is the number of newly imported downloads."),
            isSuccess: true
        )
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
