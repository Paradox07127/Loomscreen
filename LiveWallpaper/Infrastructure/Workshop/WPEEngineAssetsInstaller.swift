#if !LITE_BUILD
import Foundation
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

    /// Marker stored when an install exists but its buildid couldn't be parsed —
    /// keeps `hasManagedInstall` true while signalling "version unknown".
    private static let unknownBuildMarker = "0"

    /// Stored (not computed-from-`SettingsManager`) so SwiftUI re-renders the
    /// engine-assets row the instant a download finishes — a computed read of
    /// UserDefaults isn't observation-tracked, which left the row stuck on the
    /// pre-download state until some other change nudged it.
    private(set) var hasManagedInstall: Bool

    init() {
        let state = Self.managedStateFromDefaults()
        hasManagedInstall = state.hasManagedInstall
        installedBuildID = state.installedBuildID
    }

    var isBusy: Bool {
        switch phase {
        case .downloading, .pruning, .checking: return true
        default: return false
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
        if isBusy { phase = .idle }
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
        let result = await doctor.updateWallpaperEngineApp(onProgress: { [weak self] percent, downloaded, total in
            Task { @MainActor [weak self] in
                guard let self, self.currentAttempt == attempt,
                      case .downloading = self.phase, percent.isFinite else { return }
                self.progress = min(max(percent / 100, 0), 1)
                self.progressBytes = ProgressBytes(downloaded: downloaded, total: (total ?? 0) > 0 ? total : nil)
            }
        })
        // A newer attempt (cancel-then-retry) may have superseded this one while it
        // awaited; only the current attempt may mutate shared state.
        guard currentAttempt == attempt else { return }
        task = nil
        guard !Task.isCancelled else { phase = .idle; progress = nil; currentAttempt = nil; return }

        switch result {
        case .updated(let installRoot, let buildID):
            await finishUpdate(installRoot: installRoot, buildID: buildID)
        case .notConfigured(let reason):
            fail(reason)
        case .loginRequired:
            fail(String(localized: "Sign in to SteamCMD in the Doctor (Settings → Workshop) first.", comment: "Engine-assets download blocked: no cached SteamCMD login."))
        case .untrustedBinary:
            fail(String(localized: "SteamCMD isn't a verified Valve build, so the download was blocked. Re-select the official SteamCMD in the Doctor.", comment: "Engine-assets download blocked: unverified SteamCMD binary."))
        case .notEntitled:
            fail(String(localized: "This Steam account doesn't own Wallpaper Engine, so its assets can't be downloaded.", comment: "Engine-assets download blocked: account doesn't own Wallpaper Engine."))
        case .timedOut:
            fail(String(localized: "The download timed out. Try again.", comment: "Engine-assets download timed out."))
        case .failed(let reason):
            fail(reason)
        }
    }

    private func finishUpdate(installRoot: URL, buildID: String?) async {
        phase = .pruning
        progress = nil
        progressBytes = nil
        do {
            try await Task.detached(priority: .utility) {
                try WPEEngineAssetsInstaller.commitAndPrune(installRoot: installRoot)
            }.value
        } catch {
            fail(String(localized: "Downloaded Wallpaper Engine, but trimming it to the assets folder failed.", comment: "Engine-assets download succeeded but pruning failed."))
            return
        }

        SettingsManager.shared.wpeEngineAssetsManagedBuildID = buildID ?? Self.unknownBuildMarker
        hasManagedInstall = true
        installedBuildID = buildID
        latestBuildID = buildID
        updateAvailable = false
        updateCheckOutcome = .upToDate(buildID: buildID)
        currentAttempt = nil
        WPEEngineAssetsLibrary.shared.refresh()
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
            guard let self, self.currentAttempt == attempt else { return }
            self.task = nil
            self.currentAttempt = nil
            self.phase = .idle
            self.latestBuildID = latest
            let outcome = UpdateCheckOutcome.resolve(
                installedBuildID: self.installedBuildID,
                latestBuildID: latest
            )
            self.updateCheckOutcome = outcome
            self.updateAvailable = {
                if case .available = outcome { return true }
                return false
            }()
            self.postUpdateCheckToast(outcome)
        }
    }

    // MARK: - Removal

    func remove() {
        guard !isBusy else { return }
        SettingsManager.shared.wpeEngineAssetsManagedBuildID = nil
        Self.deleteManagedInstall()
        hasManagedInstall = false
        installedBuildID = nil
        latestBuildID = nil
        updateAvailable = false
        updateCheckOutcome = .notChecked
        WPEEngineAssetsLibrary.shared.refresh()
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
        return (true, stored == Self.unknownBuildMarker ? nil : stored)
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

// MARK: - Safe filesystem operations

extension WPEEngineAssetsInstaller {
    enum PruneError: Error, Equatable, Sendable {
        case notContainerInternal
        case unexpectedLayout
        case missingAssets
    }

    nonisolated static let wpeAppID = 431960

    /// Cross-platform `app_update` leaves the engine content in steamcmd's staging
    /// dir (`downloading/431960/`) and never commits it to `common/`. So we do the
    /// "commit" ourselves: move `assets/` into the managed location, prune, then
    /// clear steamcmd's 431960 bookkeeping so its lingering pending-update state
    /// stops derailing the Doctor's ownership probe (which shares app id 431960).
    nonisolated static func commitAndPrune(installRoot: URL, fileManager: FileManager = .default) throws {
        let managed = WPEEngineAssetsLibrary.managedContainerRoot()
        if WPEEngineAssetsLibrary.canonicalPath(installRoot) != WPEEngineAssetsLibrary.canonicalPath(managed) {
            try relocateAssets(from: installRoot, to: managed, fileManager: fileManager)
        }
        try pruneToAssets(installRoot: managed, fileManager: fileManager)
        cleanupSteamcmdAppState(fileManager: fileManager)
    }

    /// Moves `sourceRoot/assets` into the managed `common/wallpaper_engine/assets`
    /// (a same-volume rename). Guards that the destination is the expected
    /// container path and the source assets exist.
    private nonisolated static func relocateAssets(from sourceRoot: URL, to managedRoot: URL, fileManager: FileManager) throws {
        let managed = managedRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard WPEEngineAssetsLibrary.isContainerInternal(managed),
              managed.lastPathComponent == "wallpaper_engine",
              managed.deletingLastPathComponent().lastPathComponent == "common" else {
            throw PruneError.unexpectedLayout
        }
        let srcAssets = sourceRoot.appendingPathComponent("assets", isDirectory: true)
        guard isNonEmptyDirectory(srcAssets, fileManager: fileManager) else { throw PruneError.missingAssets }
        try fileManager.createDirectory(at: managed, withIntermediateDirectories: true)

        // Stage-then-swap so a failed move (e.g. cross-volume copy) can't leave us
        // with the old assets deleted and the new ones not in place. The first move
        // (possibly cross-volume) happens BEFORE the old assets are touched; the
        // two swap moves are same-directory renames.
        let dest = managed.appendingPathComponent("assets", isDirectory: true)
        let incoming = managed.appendingPathComponent("assets.incoming", isDirectory: true)
        let previous = managed.appendingPathComponent("assets.previous", isDirectory: true)
        try? fileManager.removeItem(at: incoming)
        try? fileManager.removeItem(at: previous)
        try fileManager.moveItem(at: srcAssets, to: incoming)
        if fileManager.fileExists(atPath: dest.path(percentEncoded: false)) {
            try fileManager.moveItem(at: dest, to: previous)
        }
        do {
            try fileManager.moveItem(at: incoming, to: dest)
        } catch {
            if fileManager.fileExists(atPath: previous.path(percentEncoded: false)),
               !fileManager.fileExists(atPath: dest.path(percentEncoded: false)) {
                try? fileManager.moveItem(at: previous, to: dest)
            }
            throw error
        }
        try? fileManager.removeItem(at: previous)
    }

    /// Deletes ONLY steamcmd's 431960 app-install bookkeeping — the `appmanifest`,
    /// the `downloading/431960` staging tree, and its `state_*` patch files. Never
    /// touches `common/`, workshop content, or the login session. This is what
    /// stops a half-finished cross-platform update from poisoning the ownership
    /// probe (which runs `workshop_download_item 431960` and otherwise gets pulled
    /// into resuming the pending update).
    nonisolated static func cleanupSteamcmdAppState(fileManager: FileManager = .default) {
        guard let steamApps = containerSteamApps(fileManager: fileManager) else { return }
        cleanupSteamcmdAppState(steamApps: steamApps, fileManager: fileManager)
    }

    nonisolated static func cleanupSteamcmdAppState(steamApps: URL, fileManager: FileManager = .default) {
        var targets = [
            steamApps.appendingPathComponent("appmanifest_\(wpeAppID).acf", isDirectory: false),
            steamApps.appendingPathComponent("downloading/\(wpeAppID)", isDirectory: true),
        ]
        let downloadingRoot = steamApps.appendingPathComponent("downloading", isDirectory: true)
        if let children = try? fileManager.contentsOfDirectory(at: downloadingRoot, includingPropertiesForKeys: nil) {
            targets += children.filter { $0.lastPathComponent.hasPrefix("state_\(wpeAppID)_") }
        }
        for target in targets {
            // Containment check uses the fully-resolved path (catches a symlinked
            // intermediate that escapes the container); the delete operates on the
            // LITERAL path so a final-component symlink is unlinked, not followed to
            // its target (which could be `common/`, the login session, etc.).
            let resolved = target.standardizedFileURL.resolvingSymlinksInPath()
            guard WPEEngineAssetsLibrary.isContainerInternal(resolved) else { continue }
            try? fileManager.removeItem(at: target)
        }
    }

    private nonisolated static func containerSteamApps(fileManager: FileManager) -> URL? {
        guard let appSupport = try? fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) else { return nil }
        return appSupport.appendingPathComponent("Steam/steamapps", isDirectory: true)
    }

    /// Deletes everything under the WPE install dir EXCEPT `assets/`. Hard guards
    /// against ever touching files elsewhere:
    ///  1. the target must be inside our own sandbox container,
    ///  2. it must be the expected `…/common/wallpaper_engine` path,
    ///  3. `assets/` must be a non-empty directory (never prune a partial download),
    ///  4. only immediate children that resolve back inside the dir are removed —
    ///     a symlink escaping the install dir is skipped, not followed.
    nonisolated static func pruneToAssets(installRoot: URL, fileManager: FileManager = .default) throws {
        let root = installRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard WPEEngineAssetsLibrary.isContainerInternal(root) else { throw PruneError.notContainerInternal }
        guard root.lastPathComponent == "wallpaper_engine",
              root.deletingLastPathComponent().lastPathComponent == "common" else {
            throw PruneError.unexpectedLayout
        }
        let assets = root.appendingPathComponent("assets", isDirectory: true)
        guard isNonEmptyDirectory(assets, fileManager: fileManager) else { throw PruneError.missingAssets }

        let children = try fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [])
        for child in children where child.lastPathComponent != "assets" {
            guard isContained(child, in: root) else { continue }
            try? fileManager.removeItem(at: child)
        }
    }

    /// Removes the whole managed `wallpaper_engine` directory, guarded the same
    /// way as the prune so a corrupt path can never escape the container.
    nonisolated static func deleteManagedInstall(fileManager: FileManager = .default) {
        let root = WPEEngineAssetsLibrary.managedContainerRoot().standardizedFileURL.resolvingSymlinksInPath()
        guard WPEEngineAssetsLibrary.isContainerInternal(root),
              root.lastPathComponent == "wallpaper_engine",
              root.deletingLastPathComponent().lastPathComponent == "common" else { return }
        try? fileManager.removeItem(at: root)
    }

    private nonisolated static func isContained(_ child: URL, in parent: URL) -> Bool {
        let c = WPEEngineAssetsLibrary.canonicalPath(child)
        let p = WPEEngineAssetsLibrary.canonicalPath(parent)
        return c == p || c.hasPrefix(p + "/")
    }

    private nonisolated static func isNonEmptyDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDir = ObjCBool(false)
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        let contents = (try? fileManager.contentsOfDirectory(atPath: url.path(percentEncoded: false))) ?? []
        return !contents.isEmpty
    }
}
#endif
