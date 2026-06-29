#if !LITE_BUILD && DIRECT_DISTRIBUTION
import Foundation
import Observation
import os

/// Drives "Download" from the Workshop browse UI: runs the SteamCMD download
/// through the configured Doctor, imports the result into the local library,
/// and exposes per-item progress for the detail sheet. App-lifetime singleton
/// so a download survives the sheet being dismissed.
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

    struct DownloadProgressBytes: Equatable, Sendable {
        let downloaded: UInt64?
        let total: UInt64?
    }

    static let shared = WorkshopDownloadCoordinator()

    private(set) var phases: [UInt64: DownloadPhase] = [:]
    /// Per-item download fraction (0...1); absent = indeterminate.
    private(set) var progress: [UInt64: Double] = [:]
    private(set) var progressBytes: [UInt64: DownloadProgressBytes] = [:]

    @ObservationIgnored private let importService: WallpaperEngineImportService
    @ObservationIgnored private var tasks: [UInt64: Task<Void, Never>] = [:]
    /// Per-item attempt token. Guards against a cancel-then-retry race where a
    /// superseded run's late callbacks/result would otherwise mutate the newer
    /// download's progress or phase.
    @ObservationIgnored private var attempts: [UInt64: UUID] = [:]
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
        download(itemID: item.id, title: item.title, using: doctor)
    }

    /// Re-download path for the Installed library's "Update" action. The
    /// re-import overwrites the cache in place and records a fresher
    /// `importedAt`, which clears the "update available" badge.
    func download(itemID: UInt64, title: String, using doctor: SteamCMDDoctorService) {
        guard !isBusy(itemID) else { return }
        let attemptID = UUID()
        attempts[itemID] = attemptID
        clearProgress(itemID)
        phases[itemID] = .downloading
        tasks[itemID] = Task { [weak self] in
            await self?.run(itemID: itemID, title: title, doctor: doctor, attemptID: attemptID)
        }
    }

    func cancel(_ itemID: UInt64) {
        tasks[itemID]?.cancel()
        tasks[itemID] = nil
        attempts[itemID] = nil
        phases[itemID] = .idle
        clearProgress(itemID)
    }

    private func run(itemID: UInt64, title: String, doctor: SteamCMDDoctorService, attemptID: UUID) async {
        let result = await doctor.downloadWorkshopItem(
            itemID,
            onProgress: { [weak self] percent, downloadedBytes, totalBytes in
                Task { [weak self] in
                    await self?.recordProgress(
                        itemID: itemID,
                        attemptID: attemptID,
                        percent: percent,
                        downloadedBytes: downloadedBytes,
                        totalBytes: totalBytes
                    )
                }
            },
            onContentReady: { [weak self] folderURL -> WallpaperEngineImportService.ImportResult? in
                guard let self, self.attempts[itemID] == attemptID, !Task.isCancelled else { return nil }
                self.phases[itemID] = .importing
                self.clearProgress(itemID)
                return try? await self.importService.importProject(folder: folderURL)
            }
        )
        // A newer attempt may have superseded this one mid-flight; only the
        // current attempt may mutate shared state.
        guard attempts[itemID] == attemptID else { return }
        tasks[itemID] = nil
        guard !Task.isCancelled else {
            attempts[itemID] = nil
            phases[itemID] = .idle
            clearProgress(itemID)
            return
        }

        switch result {
        case .imported(let importResult):
            finishImport(importResult, itemID: itemID, title: title)
        case .notConfigured(let reason):
            finish(itemID: itemID, title: title, phase: .failed(reason))
        case .loginRequired:
            finish(itemID: itemID, title: title, phase: .failed(String(localized: "Sign in to SteamCMD in the Doctor (Settings → Workshop) first.", comment: "Workshop download blocked: no cached SteamCMD login.")))
        case .untrustedBinary:
            finish(itemID: itemID, title: title, phase: .failed(String(localized: "SteamCMD isn't a verified Valve build, so the download was blocked. Re-select the official SteamCMD in the Doctor.", comment: "Workshop download blocked: unverified SteamCMD binary.")))
        case .notEntitled:
            finish(itemID: itemID, title: title, phase: .failed(String(localized: "This Steam account can't download Wallpaper Engine items — it may not own Wallpaper Engine, or downloads are region-restricted.", comment: "Workshop download blocked: account not entitled.")))
        case .removedFromSteam:
            finish(itemID: itemID, title: title, phase: .failed(String(localized: "This item is no longer available on Steam.", comment: "Workshop download failed: item removed from Steam.")))
        case .temporarilyUnavailable:
            finish(itemID: itemID, title: title, phase: .failed(String(localized: "Steam is temporarily unreachable. Try again in a moment.", comment: "Workshop download failed: Steam unreachable.")))
        case .timedOut:
            finish(itemID: itemID, title: title, phase: .failed(String(localized: "The download timed out. Try again.", comment: "Workshop download timed out.")))
        case .failed(let reason):
            finish(itemID: itemID, title: title, phase: .failed(reason))
        }
    }

    /// Ignored unless the item is still in the `.downloading` phase
    /// (import/terminal phases clear it).
    private func recordProgress(
        itemID: UInt64,
        attemptID: UUID,
        percent: Double,
        downloadedBytes: UInt64?,
        totalBytes: UInt64?
    ) {
        guard attempts[itemID] == attemptID, case .downloading? = phases[itemID], percent.isFinite else { return }
        progress[itemID] = min(max(percent / 100, 0), 1)
        progressBytes[itemID] = DownloadProgressBytes(
            downloaded: downloadedBytes,
            total: (totalBytes ?? 0) > 0 ? totalBytes : nil
        )
    }

    private func clearProgress(_ itemID: UInt64) {
        progress[itemID] = nil
        progressBytes[itemID] = nil
    }

    private func finishImport(_ result: WallpaperEngineImportService.ImportResult?, itemID: UInt64, title: String) {
        guard let result else {
            finish(itemID: itemID, title: title, phase: .failed(String(localized: "Couldn't read the downloaded files.", comment: "Workshop import failed: unreadable download.")))
            return
        }
        switch result {
        case .ready(_, let origin), .unsupported(let origin):
            // Browse re-download / the Installed "Update" button is an explicit
            // re-acquire, so it lifts any prior delete tombstone for this id.
            SettingsManager.shared.recordWPEImport(
                WPEHistoryEntry(origin: origin, importedAt: Date(), lastUsedAt: nil),
                clearsDeleteTombstone: true
            )
            logger.info("Imported downloaded Workshop item into the library")
            finish(itemID: itemID, title: title, phase: .succeeded)
        case .rejected(let reason):
            finish(itemID: itemID, title: title, phase: .failed(reason))
        }
    }

    private func finish(itemID: UInt64, title: String, phase: DownloadPhase) {
        attempts[itemID] = nil
        clearProgress(itemID)
        phases[itemID] = phase
        switch phase {
        case .succeeded:
            WorkshopToastCenter.shared.post(
                headline: String(localized: "Downloaded", comment: "Workshop download success toast headline."),
                title: title,
                message: String(localized: "Added to your library.", comment: "Workshop download success toast subtitle."),
                isSuccess: true
            )
        case .failed(let message):
            WorkshopToastCenter.shared.post(
                headline: String(localized: "Download failed", comment: "Workshop download failure toast headline."),
                title: title,
                message: message,
                isSuccess: false
            )
        default:
            break
        }
    }
}
#endif
