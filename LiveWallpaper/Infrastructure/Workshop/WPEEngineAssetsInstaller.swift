#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import Observation

/// Drives the in-app "download Wallpaper Engine assets" flow: runs SteamCMD
/// `app_update 431960` into the sandbox container, prunes the result down to its
/// `assets/` subtree, records the Steam `buildid` for update checks, and flips
/// `WPEEngineAssetsLibrary` to the managed install. App-lifetime singleton so a
/// download survives the settings sheet being dismissed.
@MainActor
@Observable
final class WPEEngineAssetsInstaller {
    enum Phase: Equatable, Sendable {
        case idle
        case downloading
        case pruning
        case checking
        case failed(String)
    }

    struct ProgressBytes: Equatable, Sendable {
        let downloaded: UInt64?
        let total: UInt64?
    }

    enum UpdateCheckOutcome: Equatable, Sendable {
        case notChecked
        case checking
        case available(latestBuildID: String)
        case upToDate(buildID: String?)
        case unableToCompare
        case checkFailed

        static func resolve(installedBuildID: String?, latestBuildID: String?) -> UpdateCheckOutcome {
            guard let latestBuildID else { return .checkFailed }
            guard let installedBuildID else { return .unableToCompare }
            return latestBuildID == installedBuildID
                ? .upToDate(buildID: installedBuildID)
                : .available(latestBuildID: latestBuildID)
        }
    }

    static let shared = WPEEngineAssetsInstaller()

    private(set) var phase: Phase = .idle
    private(set) var progress: Double?
    private(set) var progressBytes: ProgressBytes?
    /// nil when no managed install (or its build couldn't be read).
    private(set) var installedBuildID: String?
    private(set) var latestBuildID: String?
    private(set) var updateAvailable = false
    private(set) var updateCheckOutcome: UpdateCheckOutcome = .notChecked

    @ObservationIgnored private var task: Task<Void, Never>?
    /// Per-run token. Guards a cancel-then-retry race where a superseded run's
    /// late return or progress callback would otherwise mutate the newer run.
    @ObservationIgnored private var currentAttempt: UUID?
    @ObservationIgnored private let operationCoordinator: SteamCMDDoctorOperationCoordinator
    @ObservationIgnored private let filesystemOwner: WPEEngineAssetsFilesystemOwner

    /// Marker stored when an install exists but its buildid couldn't be parsed —
    /// keeps `hasManagedInstall` true while signalling "version unknown".
    /// Stored (not computed-from-`SettingsManager`) so SwiftUI re-renders the
    /// engine-assets row the instant a download finishes — a computed read of
    /// UserDefaults isn't observation-tracked, which left the row stuck on the
    /// pre-download state until some other change nudged it.
    private(set) var hasManagedInstall: Bool

    init(
        operationCoordinator: SteamCMDDoctorOperationCoordinator = .shared,
        assetsTransaction: WPEEngineAssetsTransaction = WPEEngineAssetsTransaction(),
        filesystemOwner: WPEEngineAssetsFilesystemOwner? = nil
    ) {
        self.operationCoordinator = operationCoordinator
        self.filesystemOwner = filesystemOwner ?? WPEEngineAssetsFilesystemOwner(
            transaction: assetsTransaction
        )
        let state = Self.managedStateFromDefaults()
        hasManagedInstall = state.hasManagedInstall
        installedBuildID = state.installedBuildID
    }

    var isBusy: Bool {
        switch phase {
        case .downloading, .pruning, .checking: true
        default: false
        }
    }

    /// Re-derive the linked state from the source of truth (which self-heals a
    /// stale marker when the assets are gone). Call when the settings UI appears
    /// so an external deletion or library self-heal can't leave the row showing
    /// "linked" when it isn't.
    func refreshManagedInstallState() {
        let state = Self.managedStateFromDefaults()
        hasManagedInstall = state.hasManagedInstall
        installedBuildID = state.installedBuildID
        if !hasManagedInstall {
            latestBuildID = nil
            updateAvailable = false
            updateCheckOutcome = .notChecked
        }
    }

    // MARK: - Download / update

    func download(using doctor: SteamCMDDoctorService) {
        guard !isBusy else { return }
        let attempt = UUID()
        currentAttempt = attempt
        phase = .downloading
        progress = nil
        progressBytes = nil
        updateCheckOutcome = .notChecked
        task = Task { [weak self] in await self?.run(using: doctor, attempt: attempt) }
    }

    func cancel() {
        task?.cancel()
        task = nil
        currentAttempt = nil
        progress = nil
        progressBytes = nil
        if isBusy {
            phase = .idle
        }
    }

    func clearTransientStatus() {
        if case .failed = phase {
            phase = .idle
        }
        if !hasManagedInstall {
            latestBuildID = nil
            updateAvailable = false
            updateCheckOutcome = .notChecked
        }
    }

    private func run(using doctor: SteamCMDDoctorService, attempt: UUID) async {
        do {
            try await operationCoordinator.withOperation(.appUpdate) { [weak self] lease in
                guard let self else { return }
                await performRun(using: doctor, attempt: attempt, operationLease: lease)
            }
        } catch {
            guard currentAttempt == attempt else { return }
            task = nil
            if error is CancellationError {
                currentAttempt = nil
                phase = .idle
            } else {
                fail(error.localizedDescription)
            }
        }
    }

    private func performRun(
        using doctor: SteamCMDDoctorService,
        attempt: UUID,
        operationLease: SteamCMDDoctorOperationLease
    ) async {
        let result = await doctor.updateWallpaperEngineApp(onProgress: { [weak self] percent, downloaded, total in
            Task { @MainActor [weak self] in
                guard let self, currentAttempt == attempt,
                      case .downloading = self.phase, percent.isFinite else { return }
                progress = min(max(percent / 100, 0), 1)
                progressBytes = ProgressBytes(downloaded: downloaded, total: (total ?? 0) > 0 ? total : nil)
            }
        }, inheriting: operationLease)
        // A newer attempt (cancel-then-retry) may have superseded this one while it
        // awaited; only the current attempt may mutate shared state.
        guard currentAttempt == attempt else { return }
        task = nil
        guard !Task.isCancelled else { phase = .idle; progress = nil; currentAttempt = nil; return }

        switch result {
        case let .updated(installRoot, buildID):
            await finishUpdate(
                installRoot: installRoot,
                buildID: buildID,
                attempt: attempt,
                operationLease: operationLease
            )
        case let .notConfigured(reason):
            fail(reason)
        case .loginRequired:
            fail(String(localized: "Sign in to SteamCMD in the Doctor (Settings → Workshop) first.", comment: "Engine-assets download blocked: no cached SteamCMD login."))
        case .untrustedBinary:
            fail(String(localized: "SteamCMD isn't a verified Valve build, so the download was blocked. Re-select the official SteamCMD in the Doctor.", comment: "Engine-assets download blocked: unverified SteamCMD binary."))
        case .notEntitled:
            fail(String(localized: "This Steam account doesn't own Wallpaper Engine, so its assets can't be downloaded.", comment: "Engine-assets download blocked: account doesn't own Wallpaper Engine."))
        case .timedOut:
            fail(String(localized: "The download timed out. Try again.", comment: "Engine-assets download timed out."))
        case let .failed(reason):
            fail(reason)
        }
    }

    private func finishUpdate(
        installRoot: URL,
        buildID: String?,
        attempt: UUID,
        operationLease: SteamCMDDoctorOperationLease
    ) async {
        phase = .pruning
        progress = nil
        progressBytes = nil
        // Cancellation is honored until the commit starts. Once the utility task
        // enters publication, disk + marker completion is mandatory; a queued
        // successor remains serialized by the still-held operation lease.
        guard currentAttempt == attempt, !Task.isCancelled else { return }
        let owner = filesystemOwner
        let authorization = operationLease.filesystemMutation(
            approvingSourceRoot: installRoot
        )
        let commit: WPEEngineAssetsFilesystemOwner.CommitResult
        do {
            commit = try await Task.detached(priority: .utility) {
                try owner.commitAndPrune(
                    installRoot: installRoot,
                    buildID: buildID,
                    authorization: authorization
                )
            }.value
        } catch {
            guard currentAttempt == attempt else { return }
            fail(String(localized: "Downloaded Wallpaper Engine, but trimming it to the assets folder failed.", comment: "Engine-assets download succeeded but pruning failed."))
            return
        }
        // Publication is already durable. Always publish its durable marker and
        // library truth even when Cancel created a newer attempt while pruning.
        SettingsManager.shared.wpeEngineAssetsManagedBuildID = commit.buildID
        hasManagedInstall = true
        let exactBuildID = commit.buildID == WPEEngineAssetsLibrary.unknownManagedBuildMarker
            ? nil
            : commit.buildID
        installedBuildID = exactBuildID
        latestBuildID = exactBuildID
        updateAvailable = false
        updateCheckOutcome = .upToDate(buildID: exactBuildID)
        WPEEngineAssetsLibrary.shared.refresh()
        // Large previous slots and SteamCMD staging are cleanup, not commit.
        // Keep them on the same live lease/utility lane, but only after the
        // authority sidecar and UserDefaults marker agree.
        do {
            try await Task.detached(priority: .utility) {
                try owner.cleanupAfterCommit(
                    commit,
                    authorization: authorization
                )
            }.value
        } catch {
            Logger.warning(
                "Wallpaper Engine assets published; deferred cleanup will retry later: \(error.localizedDescription)",
                category: .workshop
            )
        }
        guard currentAttempt == attempt, !Task.isCancelled else { return }
        currentAttempt = nil
        phase = .idle
        WorkshopToastCenter.shared.post(
            headline: String(localized: "Wallpaper Engine assets ready", comment: "Engine-assets download success toast headline."),
            title: "",
            message: String(localized: "Linked for extra scene coverage.", comment: "Engine-assets download success toast subtitle."),
            isSuccess: true
        )
    }

    // MARK: - Update check

    func checkForUpdate(using doctor: SteamCMDDoctorService) {
        guard !isBusy, hasManagedInstall else { return }
        let attempt = UUID()
        currentAttempt = attempt
        phase = .checking
        updateCheckOutcome = .checking
        task = Task { [weak self] in
            let latest = await doctor.latestWallpaperEngineBuildID()
            guard let self, currentAttempt == attempt else { return }
            task = nil
            currentAttempt = nil
            phase = .idle
            latestBuildID = latest
            let outcome = UpdateCheckOutcome.resolve(
                installedBuildID: installedBuildID,
                latestBuildID: latest
            )
            updateCheckOutcome = outcome
            updateAvailable = {
                if case .available = outcome {
                    return true
                }
                return false
            }()
            postUpdateCheckToast(outcome)
        }
    }

    // MARK: - Removal

    func remove() {
        guard !isBusy else { return }
        let attempt = UUID()
        currentAttempt = attempt
        phase = .pruning
        task = Task { [weak self] in await self?.performRemove(attempt: attempt) }
    }

    private func performRemove(attempt: UUID) async {
        do {
            try await operationCoordinator.withOperation(.assetsMutation) { [weak self] lease in
                guard let self else { return }
                try await commitRemove(attempt: attempt, operationLease: lease)
            }
        } catch {
            guard currentAttempt == attempt else { return }
            task = nil
            currentAttempt = nil
            phase = .idle
        }
    }

    // The coordinator's closure is @Sendable and runs off the main actor; hop back in one
    // call instead of touching main-actor state piecemeal, same as performRun.
    private func commitRemove(
        attempt: UUID,
        operationLease lease: SteamCMDDoctorOperationLease
    ) async throws {
        guard currentAttempt == attempt else { return }
        let owner = filesystemOwner
        _ = try await Task.detached(priority: .utility) {
            try owner.removeManagedInstall(
                authorization: lease.filesystemMutation
            )
        }.value
        // Once deletion commits, its durable marker must match disk even
        // if the initiating UI attempt was cancelled meanwhile.
        SettingsManager.shared.wpeEngineAssetsManagedBuildID = nil
        hasManagedInstall = false
        installedBuildID = nil
        latestBuildID = nil
        updateAvailable = false
        updateCheckOutcome = .notChecked
        WPEEngineAssetsLibrary.shared.refresh()
        guard currentAttempt == attempt else { return }
        task = nil
        currentAttempt = nil
        phase = .idle
    }

    private func fail(_ message: String) {
        currentAttempt = nil
        progress = nil
        progressBytes = nil
        phase = .failed(message)
        WorkshopToastCenter.shared.post(
            headline: String(localized: "Download failed", comment: "Engine-assets download failure toast headline."),
            title: "",
            message: message,
            isSuccess: false
        )
    }

    private static func managedStateFromDefaults() -> (hasManagedInstall: Bool, installedBuildID: String?) {
        let hasManagedInstall = WPEEngineAssetsLibrary.hasManagedInstall
        guard hasManagedInstall else { return (false, nil) }
        let stored = SettingsManager.shared.wpeEngineAssetsManagedBuildID
        return (
            true,
            stored == WPEEngineAssetsLibrary.unknownManagedBuildMarker ? nil : stored
        )
    }

    private func postUpdateCheckToast(_ outcome: UpdateCheckOutcome) {
        switch outcome {
        case .available:
            WorkshopToastCenter.shared.post(
                headline: String(localized: "Wallpaper Engine update available", comment: "Engine-assets update check found an update."),
                title: "",
                message: String(localized: "Click Update to download and relink the latest assets.", comment: "Engine-assets update available toast subtitle."),
                isSuccess: true
            )
        case .upToDate:
            WorkshopToastCenter.shared.post(
                headline: String(localized: "Wallpaper Engine assets are up to date", comment: "Engine-assets update check success headline."),
                title: "",
                message: String(localized: "No download is needed.", comment: "Engine-assets update check up-to-date subtitle."),
                isSuccess: true
            )
        case .unableToCompare:
            WorkshopToastCenter.shared.post(
                headline: String(localized: "Couldn't compare versions", comment: "Engine-assets update check version-unknown headline."),
                title: "",
                message: String(localized: "Download again to refresh the managed assets.", comment: "Engine-assets update check version-unknown subtitle."),
                isSuccess: false
            )
        case .checkFailed:
            WorkshopToastCenter.shared.post(
                headline: String(localized: "Couldn't check for updates", comment: "Engine-assets update check failure headline."),
                title: "",
                message: String(localized: "SteamCMD did not return the latest Wallpaper Engine build.", comment: "Engine-assets update check failure subtitle."),
                isSuccess: false
            )
        case .notChecked, .checking:
            break
        }
    }
}

#endif
