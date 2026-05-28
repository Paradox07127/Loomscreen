#if !LITE_BUILD && DIRECT_DISTRIBUTION
import Foundation
import Observation
import os

/// Drives "Download" from the Workshop browse UI: runs the SteamCMD download
/// through the configured Doctor, imports the result into the local library,
/// and exposes per-item progress for the detail sheet. App-lifetime singleton
/// (mirrors `GIFPlaybackCoordinator.shared`) so a download survives the sheet
/// being dismissed; `init` stays internal for test isolation.
@MainActor
@Observable
final class WorkshopDownloadCoordinator {
    enum DownloadPhase: Equatable, Sendable {
        case idle
        case downloading
        case importing
        case succeeded
        case failed(String)
    }

    static let shared = WorkshopDownloadCoordinator()

    private(set) var phases: [UInt64: DownloadPhase] = [:]

    @ObservationIgnored private let importService: WallpaperEngineImportService
    @ObservationIgnored private var tasks: [UInt64: Task<Void, Never>] = [:]
    @ObservationIgnored private let logger = os.Logger(subsystem: "com.loomscreen.livewallpaper", category: "WorkshopDownload")

    init(importService: WallpaperEngineImportService = WallpaperEngineImportService()) {
        self.importService = importService
    }

    func phase(for itemID: UInt64) -> DownloadPhase { phases[itemID] ?? .idle }

    func isBusy(_ itemID: UInt64) -> Bool {
        switch phases[itemID] {
        case .downloading, .importing: return true
        default: return false
        }
    }

    func download(_ item: WorkshopQueryItem, using doctor: SteamCMDDoctorService) {
        let itemID = item.id
        guard !isBusy(itemID) else { return }
        phases[itemID] = .downloading
        tasks[itemID] = Task { [weak self] in
            await self?.run(itemID: itemID, doctor: doctor)
        }
    }

    func cancel(_ itemID: UInt64) {
        tasks[itemID]?.cancel()
        tasks[itemID] = nil
        phases[itemID] = .idle
    }

    private func run(itemID: UInt64, doctor: SteamCMDDoctorService) async {
        let result = await doctor.downloadWorkshopItem(itemID) { [weak self] folderURL -> WallpaperEngineImportService.ImportResult? in
            guard let self else { return nil }
            self.phases[itemID] = .importing
            return try? await self.importService.importProject(folder: folderURL)
        }
        tasks[itemID] = nil
        guard !Task.isCancelled else {
            phases[itemID] = .idle
            return
        }

        switch result {
        case .imported(let importResult):
            recordOrFail(importResult, itemID: itemID)
        case .notConfigured(let reason):
            phases[itemID] = .failed(reason)
        case .loginRequired:
            phases[itemID] = .failed(String(localized: "Sign in to SteamCMD in the Doctor (Settings → Workshop) first.", comment: "Workshop download blocked: no cached SteamCMD login."))
        case .notEntitled:
            phases[itemID] = .failed(String(localized: "This Steam account can't download Wallpaper Engine items — it may not own Wallpaper Engine, or downloads are region-restricted.", comment: "Workshop download blocked: account not entitled."))
        case .removedFromSteam:
            phases[itemID] = .failed(String(localized: "This item is no longer available on Steam.", comment: "Workshop download failed: item removed from Steam."))
        case .temporarilyUnavailable:
            phases[itemID] = .failed(String(localized: "Steam is temporarily unreachable. Try again in a moment.", comment: "Workshop download failed: Steam unreachable."))
        case .timedOut:
            phases[itemID] = .failed(String(localized: "The download timed out. Try again.", comment: "Workshop download timed out."))
        case .failed(let reason):
            phases[itemID] = .failed(reason)
        }
    }

    private func recordOrFail(_ result: WallpaperEngineImportService.ImportResult?, itemID: UInt64) {
        guard let result else {
            phases[itemID] = .failed(String(localized: "Couldn't read the downloaded files.", comment: "Workshop import failed: unreadable download."))
            return
        }
        switch result {
        case .ready(_, let origin), .unsupported(let origin):
            SettingsManager.shared.recordWPEImport(
                WPEHistoryEntry(origin: origin, importedAt: Date(), lastUsedAt: nil)
            )
            phases[itemID] = .succeeded
            logger.info("Imported downloaded Workshop item into the library")
        case .rejected(let reason):
            phases[itemID] = .failed(reason)
        }
    }
}
#endif
