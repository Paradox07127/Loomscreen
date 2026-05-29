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
        var skipped = 0
        for projectFolder in projectFolders {
            do {
                switch try await importService.importProject(folder: projectFolder) {
                case .ready(_, let origin), .unsupported(let origin):
                    SettingsManager.shared.recordWPEImport(
                        WPEHistoryEntry(origin: origin, importedAt: Date(), lastUsedAt: nil)
                    )
                    imported += 1
                case .rejected(let reason):
                    skipped += 1
                    logger.info("Skipped a project during folder import: \(reason, privacy: .public)")
                }
            } catch {
                skipped += 1
                logger.info("Failed to read a project during folder import: \(error.localizedDescription, privacy: .public)")
            }
        }

        emitSummary(folder: folder, imported: imported, skipped: skipped)
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
