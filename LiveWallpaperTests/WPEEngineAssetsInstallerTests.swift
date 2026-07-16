#if !LITE_BUILD
import Foundation
import Testing
@testable import LiveWallpaper

@Suite("WPE engine-assets install: scripts, version parsing, safe prune")
struct WPEEngineAssetsInstallerTests {

    // MARK: - SteamCMD scripts

    @Test("app_update script forces the Windows depot and validates")
    func appUpdateScriptShape() throws {
        let script = try SteamCMDScriptWriter.appUpdateScript(username: "alice_01")
        #expect(script.contains("@NoPromptForPassword 1"))
        #expect(script.contains("@sSteamCmdForcePlatformType windows"))
        #expect(script.contains("login alice_01"))
        #expect(script.contains("app_update 431960 validate"))
    }

    @Test("app_info script forces a fresh metadata pull then prints app 431960")
    func appInfoScriptShape() throws {
        let script = try SteamCMDScriptWriter.appInfoScript(username: "alice_01")
        #expect(script.contains("app_info_update 1"))
        #expect(script.contains("app_info_print 431960"))
    }

    @Test("Invalid usernames are rejected for both new scripts")
    func scriptsRejectBadUsernames() {
        #expect(throws: SteamCMDScriptError.self) { try SteamCMDScriptWriter.appUpdateScript(username: "bad name") }
        #expect(throws: SteamCMDScriptError.self) { try SteamCMDScriptWriter.appInfoScript(username: "a;b") }
    }

    @Test("logout script logs in (cached) then logs out the named account")
    func logoutScriptShape() throws {
        let script = try SteamCMDScriptWriter.logoutScript(username: "alice_01")
        #expect(script.contains("@NoPromptForPassword 1"))
        #expect(script.contains("login alice_01"))
        #expect(script.contains("logout"))
        #expect(script.contains("quit"))
        #expect(throws: SteamCMDScriptError.self) { try SteamCMDScriptWriter.logoutScript(username: "a b") }
    }

    // MARK: - Build-id parsing

    @Test("ACF buildid is parsed from an appmanifest")
    func parseACFBuildID() {
        let acf = """
        "AppState"
        {
        \t"appid"\t\t"431960"
        \t"installdir"\t\t"wallpaper_engine"
        \t"buildid"\t\t"17654321"
        }
        """
        #expect(SteamCMDDoctorService.parseACFBuildID(acf) == "17654321")
        #expect(SteamCMDDoctorService.parseACFBuildID("no build id here") == nil)
    }

    @Test("Public-branch buildid is parsed, ignoring the beta branch")
    func parsePublicBuildID() {
        let appInfo = """
        "431960"
        {
        \t"depots"
        \t{
        \t\t"branches"
        \t\t{
        \t\t\t"public"
        \t\t\t{
        \t\t\t\t"buildid"\t\t"17654321"
        \t\t\t\t"timeupdated"\t\t"1700000000"
        \t\t\t}
        \t\t\t"beta"
        \t\t\t{
        \t\t\t\t"buildid"\t\t"99999999"
        \t\t\t}
        \t\t}
        \t}
        }
        """
        #expect(SteamCMDDoctorService.parsePublicBuildID(fromAppInfo: appInfo) == "17654321")
        #expect(SteamCMDDoctorService.parsePublicBuildID(fromAppInfo: "garbage") == nil)
    }

    // MARK: - Cross-platform staging (app_update never commits on macOS)

    @Test("Staging dir outranks the committed dir so an update can't keep stale assets")
    func stagingCandidateOutranksCommitted() {
        let workdir = URL(fileURLWithPath: "/tmp/lw-workdir", isDirectory: true)
        let paths = SteamCMDDoctorService.wpeInstallRootCandidates(workdir: workdir, fileManager: .default)
            .map { $0.path }
        let firstStaging = paths.firstIndex { $0.hasSuffix("steamapps/downloading/431960") }
        let firstCommitted = paths.firstIndex { $0.hasSuffix("steamapps/common/wallpaper_engine") }
        #expect(firstStaging != nil)
        #expect(firstCommitted != nil)
        if let s = firstStaging, let c = firstCommitted { #expect(s < c) }
    }

    @Test("Staging completeness needs a committed buildid or fully-written staging")
    func stagingCompleteRequiresManifestEvidence() throws {
        let fm = FileManager.default
        let steamApps = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Caches/lw-staging-test-\(UUID().uuidString)/steamapps", isDirectory: true)
        defer { try? fm.removeItem(at: steamApps.deletingLastPathComponent()) }
        let installRoot = steamApps.appendingPathComponent("downloading/431960", isDirectory: true)
        try fm.createDirectory(at: installRoot, withIntermediateDirectories: true)
        let manifestURL = steamApps.appendingPathComponent("appmanifest_431960.acf")

        func write(_ body: String) throws { try "\"AppState\"\n{\n\(body)\n}".write(to: manifestURL, atomically: true, encoding: .utf8) }

        // Missing manifest → not complete.
        #expect(SteamCMDDoctorService.isWPEStagingComplete(installRoot: installRoot, fileManager: fm) == false)
        // Staged partially → not complete.
        try write("\t\"buildid\"\t\t\"0\"\n\t\"BytesToStage\"\t\t\"829\"\n\t\"BytesStaged\"\t\t\"400\"")
        #expect(SteamCMDDoctorService.isWPEStagingComplete(installRoot: installRoot, fileManager: fm) == false)
        // Staging fully written → complete.
        try write("\t\"buildid\"\t\t\"0\"\n\t\"BytesToStage\"\t\t\"829\"\n\t\"BytesStaged\"\t\t\"829\"")
        #expect(SteamCMDDoctorService.isWPEStagingComplete(installRoot: installRoot, fileManager: fm) == true)
        // Committed (buildid set) → complete regardless of bytes.
        try write("\t\"buildid\"\t\t\"23570248\"")
        #expect(SteamCMDDoctorService.isWPEStagingComplete(installRoot: installRoot, fileManager: fm) == true)
    }

    @Test("Public buildid parse doesn't fall through to a sibling branch")
    func publicBuildIDDoesNotLeakFromSibling() {
        let appInfo = """
        "431960"
        {
        \t"depots"
        \t{
        \t\t"branches"
        \t\t{
        \t\t\t"public"
        \t\t\t{
        \t\t\t\t"description"\t\t"stable"
        \t\t\t}
        \t\t\t"beta"
        \t\t\t{
        \t\t\t\t"buildid"\t\t"99999999"
        \t\t\t}
        \t\t}
        \t}
        }
        """
        #expect(SteamCMDDoctorService.parsePublicBuildID(fromAppInfo: appInfo) == nil)
    }

    @Test("Update check outcome distinguishes available, up-to-date, and failed checks")
    func updateCheckOutcomeHasStableSettingsStates() {
        #expect(WPEEngineAssetsInstaller.UpdateCheckOutcome.resolve(
            installedBuildID: "10",
            latestBuildID: "11"
        ) == .available(latestBuildID: "11"))
        #expect(WPEEngineAssetsInstaller.UpdateCheckOutcome.resolve(
            installedBuildID: "10",
            latestBuildID: "10"
        ) == .upToDate(buildID: "10"))
        #expect(WPEEngineAssetsInstaller.UpdateCheckOutcome.resolve(
            installedBuildID: nil,
            latestBuildID: "11"
        ) == .unableToCompare)
        #expect(WPEEngineAssetsInstaller.UpdateCheckOutcome.resolve(
            installedBuildID: "10",
            latestBuildID: nil
        ) == .checkFailed)
    }

    @Test("Ownership preflight cleanup removes app-update state without deleting linked assets")
    func ownershipPreflightCleanupPreservesLinkedAssets() async throws {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Caches/lw-ownership-cleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let steamApps = base.appendingPathComponent("steamapps", isDirectory: true)
        let downloading = steamApps.appendingPathComponent("downloading", isDirectory: true)
        let stagedApp = downloading.appendingPathComponent("431960", isDirectory: true)
        let managedAssets = steamApps
            .appendingPathComponent("common/wallpaper_engine/assets/materials/util", isDirectory: true)
        try fm.createDirectory(at: stagedApp, withIntermediateDirectories: true)
        try fm.createDirectory(at: managedAssets, withIntermediateDirectories: true)
        try "staged".write(to: stagedApp.appendingPathComponent("chunk.bin"), atomically: true, encoding: .utf8)
        try "state".write(to: downloading.appendingPathComponent("state_431960_123.patch"), atomically: true, encoding: .utf8)
        try "manifest".write(to: steamApps.appendingPathComponent("appmanifest_431960.acf"), atomically: true, encoding: .utf8)
        try "asset".write(to: managedAssets.appendingPathComponent("noise.png"), atomically: true, encoding: .utf8)

        let owner = WPEEngineAssetsFilesystemOwner(fileManager: fm)
        try await SteamCMDDoctorOperationCoordinator().withOperation(.ownershipValidation) { lease in
            owner.cleanupSteamCMDAppState(
                steamApps: steamApps,
                authorization: lease.filesystemMutation
            )
        }

        #expect(!fm.fileExists(atPath: stagedApp.path(percentEncoded: false)))
        #expect(!fm.fileExists(atPath: downloading.appendingPathComponent("state_431960_123.patch").path(percentEncoded: false)))
        #expect(!fm.fileExists(atPath: steamApps.appendingPathComponent("appmanifest_431960.acf").path(percentEncoded: false)))
        #expect(fm.fileExists(atPath: managedAssets.appendingPathComponent("noise.png").path(percentEncoded: false)))
    }

    @Test("Content is complete only when materials/models/shaders are all present")
    func contentCompletenessRequiresFrameworkDirs() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Caches/lw-complete-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let assets = root.appendingPathComponent("assets", isDirectory: true)
        for sub in ["materials", "models"] {
            try fm.createDirectory(at: assets.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        #expect(SteamCMDDoctorService.isWPEContentComplete(installRoot: root, fileManager: fm) == false)
        try fm.createDirectory(at: assets.appendingPathComponent("shaders"), withIntermediateDirectories: true)
        #expect(SteamCMDDoctorService.isWPEContentComplete(installRoot: root, fileManager: fm) == true)
    }

    @Test("Staged-not-committed buildid=0 falls back to TargetBuildID")
    func buildIDFallsBackToTargetBuildID() throws {
        let fm = FileManager.default
        let steamApps = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Caches/lw-buildid-test-\(UUID().uuidString)/steamapps", isDirectory: true)
        defer { try? fm.removeItem(at: steamApps.deletingLastPathComponent()) }
        let installRoot = steamApps.appendingPathComponent("downloading/431960", isDirectory: true)
        try fm.createDirectory(at: installRoot, withIntermediateDirectories: true)
        let acf = """
        "AppState"
        {
        \t"appid"\t\t"431960"
        \t"buildid"\t\t"0"
        \t"TargetBuildID"\t\t"23570248"
        }
        """
        try acf.write(to: steamApps.appendingPathComponent("appmanifest_431960.acf"), atomically: true, encoding: .utf8)
        #expect(SteamCMDDoctorService.readInstalledBuildID(installRoot: installRoot, fileManager: fm) == "23570248")
    }

    // MARK: - Safe prune

    /// Builds a throwaway install tree under the container home so it passes the
    /// `isContainerInternal` guard, then deletes it.
    private func makeInstallTree(leaf: String, withAssets: Bool) throws -> (base: URL, installRoot: URL) {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Caches/lw-engine-assets-test-\(UUID().uuidString)", isDirectory: true)
        let installRoot = base
            .appendingPathComponent("common", isDirectory: true)
            .appendingPathComponent(leaf, isDirectory: true)
        try fm.createDirectory(at: installRoot, withIntermediateDirectories: true)
        // Junk we expect pruned.
        try fm.createDirectory(at: installRoot.appendingPathComponent("bin", isDirectory: true), withIntermediateDirectories: true)
        try "x".write(to: installRoot.appendingPathComponent("wallpaper64.exe"), atomically: true, encoding: .utf8)
        if withAssets {
            let assets = installRoot.appendingPathComponent("assets/materials/util", isDirectory: true)
            try fm.createDirectory(at: assets, withIntermediateDirectories: true)
            try "noise".write(to: assets.appendingPathComponent("noise.png"), atomically: true, encoding: .utf8)
        }
        return (base, installRoot)
    }

    @Test("Prune keeps assets/ and removes everything else")
    func pruneKeepsAssets() async throws {
        let fm = FileManager.default
        let tree = try makeInstallTree(leaf: "wallpaper_engine", withAssets: true)
        defer { try? fm.removeItem(at: tree.base) }

        let owner = WPEEngineAssetsFilesystemOwner(fileManager: fm)
        try await SteamCMDDoctorOperationCoordinator().withOperation(.appUpdate) { lease in
            try owner.pruneToAssets(
                installRoot: tree.installRoot,
                authorization: lease.filesystemMutation
            )
        }

        #expect(fm.fileExists(atPath: tree.installRoot.appendingPathComponent("assets/materials/util/noise.png").path))
        #expect(!fm.fileExists(atPath: tree.installRoot.appendingPathComponent("bin").path))
        #expect(!fm.fileExists(atPath: tree.installRoot.appendingPathComponent("wallpaper64.exe").path))
    }

    @Test("Prune refuses a target outside the sandbox container")
    func pruneRejectsNonContainerPath() async throws {
        let outside = URL(fileURLWithPath: "/tmp/lw-not-container/common/wallpaper_engine", isDirectory: true)
        try await SteamCMDDoctorOperationCoordinator().withOperation(.appUpdate) { lease in
            #expect(throws: WPEEngineAssetsFilesystemOwner.Error.notContainerInternal) {
                try WPEEngineAssetsFilesystemOwner().pruneToAssets(
                    installRoot: outside,
                    authorization: lease.filesystemMutation
                )
            }
        }
    }

    @Test("Prune refuses an unexpected directory name")
    func pruneRejectsWrongLeaf() async throws {
        let fm = FileManager.default
        let tree = try makeInstallTree(leaf: "something_else", withAssets: true)
        defer { try? fm.removeItem(at: tree.base) }
        let owner = WPEEngineAssetsFilesystemOwner(fileManager: fm)
        try await SteamCMDDoctorOperationCoordinator().withOperation(.appUpdate) { lease in
            #expect(throws: WPEEngineAssetsFilesystemOwner.Error.unexpectedLayout) {
                try owner.pruneToAssets(
                    installRoot: tree.installRoot,
                    authorization: lease.filesystemMutation
                )
            }
        }
        // Nothing was touched.
        #expect(fm.fileExists(atPath: tree.installRoot.appendingPathComponent("bin").path))
    }

    @Test("Prune refuses (and touches nothing) when assets/ is absent")
    func pruneRefusesWithoutAssets() async throws {
        let fm = FileManager.default
        let tree = try makeInstallTree(leaf: "wallpaper_engine", withAssets: false)
        defer { try? fm.removeItem(at: tree.base) }
        let owner = WPEEngineAssetsFilesystemOwner(fileManager: fm)
        try await SteamCMDDoctorOperationCoordinator().withOperation(.appUpdate) { lease in
            #expect(throws: WPEEngineAssetsFilesystemOwner.Error.missingAssets) {
                try owner.pruneToAssets(
                    installRoot: tree.installRoot,
                    authorization: lease.filesystemMutation
                )
            }
        }
        // The download was partial — siblings must survive so a re-run can finish.
        #expect(fm.fileExists(atPath: tree.installRoot.appendingPathComponent("bin").path))
        #expect(fm.fileExists(atPath: tree.installRoot.appendingPathComponent("wallpaper64.exe").path))
    }
}
#endif
