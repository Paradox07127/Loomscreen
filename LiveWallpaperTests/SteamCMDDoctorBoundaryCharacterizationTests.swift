#if !LITE_BUILD
    import Foundation
    @testable import LiveWallpaper
    import os
    import Testing

    /// AF-12 E1: characterize the Doctor's trust/process/filesystem boundaries
    /// without launching SteamCMD, touching a user library, or using the network.
    /// Source contracts are intentionally labelled where execution/codesign and
    /// cleanup still lack dynamic seams; filesystem inventory is exercised here.
    @Suite("AF-12: SteamCMD Doctor boundary characterization", .serialized)
    struct SteamCMDDoctorBoundaryCharacterizationTests {
        @Test("SteamCMD scripts keep user input data-only and non-interactive")
        func scriptsRejectCommandShapedInputs() throws {
            let ownership = try SteamCMDScriptWriter.ownershipProbeScript(
                username: "alice_01", itemID: UInt64.max
            )
            let download = try SteamCMDScriptWriter.downloadItemScript(
                username: "alice_01", itemID: UInt64.max
            )
            for script in [ownership, download] {
                #expect(script.contains("@ShutdownOnFailedCommand 1"))
                #expect(script.contains("@NoPromptForPassword 1"))
                #expect(script.contains("login alice_01"))
                #expect(script.contains("workshop_download_item 431960 \(UInt64.max)"))
                #expect(script.hasSuffix("quit"))
            }

            for hostile in ["a;b", "$(id)", "../alice", "name with space", "用户"] {
                #expect(throws: SteamCMDScriptError.invalidUsername) {
                    try SteamCMDScriptWriter.cachedLoginProbeScript(username: hostile)
                }
                #expect(throws: SteamCMDScriptError.invalidUsername) {
                    try SteamCMDScriptWriter.ownershipProbeScript(username: hostile, itemID: 1)
                }
                #expect(throws: SteamCMDScriptError.invalidUsername) {
                    try SteamCMDScriptWriter.downloadItemScript(username: hostile, itemID: 1)
                }
                #expect(throws: SteamCMDScriptError.invalidUsername) {
                    try SteamCMDScriptWriter.appUpdateScript(username: hostile)
                }
                #expect(throws: SteamCMDScriptError.invalidUsername) {
                    try SteamCMDScriptWriter.appInfoScript(username: hostile)
                }
                #expect(throws: SteamCMDScriptError.invalidUsername) {
                    try SteamCMDScriptWriter.logoutScript(username: hostile)
                }
            }
        }

        @Test("temporary SteamCMD scripts are unique, mode 0600, and narrowly deleted")
        func temporaryScriptScope() throws {
            let fm = FileManager.default
            let root = temporaryRoot("scripts")
            defer { try? fm.removeItem(at: root) }
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let sentinel = root.appendingPathComponent("inventory.keep")
            try Data("inventory".utf8).write(to: sentinel)

            let first = try SteamCMDScriptWriter.writeScript("quit", in: root)
            let second = try SteamCMDScriptWriter.writeScript("quit", in: root)
            #expect(first != second)
            for script in [first, second] {
                let attributes = try fm.attributesOfItem(atPath: script.path)
                let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
                #expect(permissions.map { $0 & 0o777 } == 0o600)
            }

            SteamCMDScriptWriter.deleteScript(first)
            #expect(!fm.fileExists(atPath: first.path))
            #expect(fm.fileExists(atPath: second.path))
            #expect(fm.fileExists(atPath: sentinel.path))
        }

        @Test("process execution is direct argv through posix_spawn, never a shell")
        func noShellProcessSourceContract() throws {
            let runner = try productionSource(
                "LiveWallpaper/Infrastructure/Workshop/Doctor/SteamCMDProcessRunner.swift"
            )
            let spawn = try slice(
                runner,
                from: "private static func spawn(",
                until: "private static func check("
            )
            #expect(spawn.contains("let argvStrings = [binary.path(percentEncoded: false)] + args"))
            #expect(spawn.contains("posix_spawn(&pid, path"))
            #expect(spawn.contains("POSIX_SPAWN_SETPGROUP"))
            #expect(spawn.contains("POSIX_SPAWN_CLOEXEC_DEFAULT"))
            #expect(spawn.contains("sanitizedChildEnvironment()"))
            for forbidden in ["Process(", "executableURL", "/bin/sh", "/bin/bash", "/bin/zsh", "system(", "popen("] {
                #expect(!spawn.contains(forbidden))
            }

            let doctor = try doctorSource()
            let scriptRun = try slice(
                doctor,
                from: "func runSteamCMDScript(",
                until: "func resolveBinaryURL()"
            )
            #expect(scriptRun.contains("args: [\"+runscript\", scriptURL.path(percentEncoded: false)]"))
            #expect(!scriptRun.contains("-c"))
        }

        @Test("selected SteamCMD execution remains behind Valve signature and hash trust")
        func trustGateSourceContract() throws {
            let source = try doctorSource()
            #expect(source.contains("private static let valveTeamIdentifier = \"MXGJJ98X76\""))
            let trust = try slice(
                source,
                from: "func ensureTrustedBinary(_ binary: URL) async -> Bool",
                until: "func runSteamCMDScript("
            )
            #expect(trust.contains("currentSHA != verifiedBinarySHA256"))
            #expect(trust.contains("signature.signatureValid"))
            #expect(trust.contains("signature.teamIdentifier == Self.valveTeamIdentifier"))
            #expect(trust.contains("SteamCMDBinaryExecutionAuthorization("))
            let trustScope = try #require(trust.range(of: "binary.startAccessingSecurityScopedResource()"))
            let identity = try #require(trust.range(of: "binaryTrustChecker.identity(of: binary)"))
            let codesign = try #require(trust.range(of: "binaryTrustChecker.codesignResult(for: binary)"))
            #expect(trustScope.lowerBound < identity.lowerBound)
            #expect(identity.lowerBound < codesign.lowerBound)

            let runScript = try slice(
                source,
                from: "func runSteamCMDScript(",
                until: "func resolveBinaryURL()"
            )
            let trustGate = try #require(runScript.range(
                of: "guard let executionAuthorization = await trustedExecutionAuthorization(for: binary)"
            ))
            let scriptWrite = try #require(runScript.range(of: "SteamCMDScriptWriter.writeScript"))
            let spawn = try #require(runScript.range(of: "return await runner.runVerified"))
            #expect(scriptWrite.lowerBound < trustGate.lowerBound)
            #expect(trustGate.lowerBound < spawn.lowerBound)

            #expect(source.contains("@ObservationIgnored private let runner: any SteamCMDProcessRunning"))
            #expect(source.contains("runner: any SteamCMDProcessRunning = SteamCMDProcessRunner()"))
            #expect(source.contains("binaryTrustChecker: (any SteamCMDBinaryTrustChecking)? = nil"))
            #expect(source.contains("binaryTrustChecker.codesignResult(for: binary)"))

            let runner = try productionSource(
                "LiveWallpaper/Infrastructure/Workshop/Doctor/SteamCMDProcessRunner.swift"
            )
            let execute = try slice(
                runner,
                from: "private nonisolated func execute(",
                until: "/// Re-hashes after the process gate"
            )
            let revalidate = try #require(execute.range(
                of: "Self.revalidateExecutionAuthorization("
            ))
            let posixSpawn = try #require(execute.range(of: "let spawned = try Self.spawn("))
            #expect(revalidate.lowerBound < posixSpawn.lowerBound)
        }

        @Test("ownership preflight removes only app-update state and preserves inventory")
        func ownershipPreflightPreservesInventory() async throws {
            let fm = FileManager.default
            // The production containment guard is anchored to NSHomeDirectory(),
            // so use a UUID-owned cache fixture inside the test host's home. This
            // never aliases a Steam/user inventory directory.
            let root = containerScopedFixtureRoot("ownership")
            defer { try? fm.removeItem(at: root) }
            let steamApps = root.appendingPathComponent("steamapps", isDirectory: true)
            let staged = steamApps.appendingPathComponent("downloading/431960", isDirectory: true)
            try fm.createDirectory(at: staged, withIntermediateDirectories: true)

            let removed = [
                steamApps.appendingPathComponent("appmanifest_431960.acf"),
                staged.appendingPathComponent("chunk.bin"),
                steamApps.appendingPathComponent("downloading/state_431960_7.patch"),
            ]
            let preserved = [
                steamApps.appendingPathComponent("common/wallpaper_engine/assets/materials/keep.bin"),
                steamApps.appendingPathComponent("workshop/content/431960/123/project.json"),
                steamApps.appendingPathComponent("config/loginusers.vdf"),
                steamApps.appendingPathComponent("depotcache/keep.bin"),
                steamApps.appendingPathComponent("appmanifest_999.acf"),
                steamApps.appendingPathComponent("downloading/999/keep.bin"),
            ]
            for file in removed + preserved {
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(file.path.utf8).write(to: file)
            }

            let owner = WPEEngineAssetsFilesystemOwner(fileManager: fm)
            try await SteamCMDDoctorOperationCoordinator().withOperation(.ownershipValidation) { lease in
                owner.cleanupSteamCMDAppState(
                    steamApps: steamApps,
                    authorization: lease.filesystemMutation
                )
            }

            for file in removed {
                #expect(!fm.fileExists(atPath: file.path))
            }
            #expect(!fm.fileExists(atPath: staged.path))
            for file in preserved {
                #expect(fm.fileExists(atPath: file.path))
            }
        }

        @Test("ownership cleanup refuses symlink escapes rather than following them")
        func ownershipCleanupRejectsSymlinkEscape() async throws {
            let fm = FileManager.default
            let root = containerScopedFixtureRoot("ownership-symlink")
            let outside = temporaryRoot("ownership-symlink-target")
            defer { try? fm.removeItem(at: root) }
            defer { try? fm.removeItem(at: outside) }
            let steamApps = root.appendingPathComponent("steamapps", isDirectory: true)
            let downloading = steamApps.appendingPathComponent("downloading", isDirectory: true)
            try fm.createDirectory(at: downloading, withIntermediateDirectories: true)
            try fm.createDirectory(at: outside, withIntermediateDirectories: true)
            #expect(!WPEEngineAssetsLibrary.isContainerInternal(outside))
            let sentinel = outside.appendingPathComponent("keep.bin")
            try Data("keep".utf8).write(to: sentinel)
            let stagedLink = downloading.appendingPathComponent("431960", isDirectory: true)
            try fm.createSymbolicLink(at: stagedLink, withDestinationURL: outside)

            let owner = WPEEngineAssetsFilesystemOwner(fileManager: fm)
            try await SteamCMDDoctorOperationCoordinator().withOperation(.ownershipValidation) { lease in
                owner.cleanupSteamCMDAppState(
                    steamApps: steamApps,
                    authorization: lease.filesystemMutation
                )
            }

            #expect(fm.fileExists(atPath: sentinel.path))
            #expect(fm.fileExists(atPath: stagedLink.path))
        }

        @Test("ownership outcome mapping and cleanup ordering remain explicit")
        func ownershipProbeSourceContract() throws {
            let source = try operationsSource()
            let probe = try slice(
                source,
                from: "func runWallpaperEngineOwnershipProbe() async",
                until: "func updateWallpaperEngineApp("
            )
            #expect(probe.contains("guard isGreen(.cachedLogin) else"))
            #expect(probe.contains("cleanupSteamCMDAppState(authorization: authorization)"))
            #expect(probe.contains("SteamCMDScriptWriter.ownershipProbeScript"))
            #expect(probe.contains("failed (No Connection)"))
            #expect(probe.contains("failed (No match)"))
            #expect(probe.contains("failed (Failure)"))

            #expect(probe.contains("operationCoordinator.withOperation(.ownershipValidation)"))
            let cleanup = try #require(probe.range(of: "cleanupSteamCMDAppState"))
            let execution = try #require(probe.range(of: "runSteamCMDScript"))
            #expect(cleanup.lowerBound < execution.lowerBound)
        }

        @Test("download and app-update candidates remain inside approved roots")
        func installCandidateScope() {
            let root = temporaryRoot("candidates")
            let appSupport = root.appendingPathComponent("Application Support", isDirectory: true)
            let workdir = root.appendingPathComponent("Approved Workdir", isDirectory: true)
            let fm = DoctorFixtureFileManager(applicationSupport: appSupport, home: root)
            let candidates = SteamCMDDoctorService.wpeInstallRootCandidates(
                workdir: workdir,
                fileManager: fm
            )

            #expect(candidates.count == 4)
            #expect(candidates[0].path.hasSuffix("Steam/steamapps/downloading/431960"))
            #expect(candidates[1].path.hasSuffix("Approved Workdir/steamapps/downloading/431960"))
            #expect(candidates[2].path.hasSuffix("Steam/steamapps/common/wallpaper_engine"))
            #expect(candidates[3].path.hasSuffix("Approved Workdir/steamapps/common/wallpaper_engine"))
            #expect(candidates.allSatisfy {
                pathContains($0, in: appSupport) || pathContains($0, in: workdir)
            })
        }

        @Test("downloaded-item deletion is target-only and rejects traversal")
        @MainActor
        func downloadedItemDeleteScope() async throws {
            let fm = FileManager.default
            let root = temporaryRoot("delete")
            defer { try? fm.removeItem(at: root) }
            let appSupport = root.appendingPathComponent("Application Support", isDirectory: true)
            let content = workshopContentRoot(appSupport: appSupport)
            let selected = content.appendingPathComponent("100", isDirectory: true)
            let sibling = content.appendingPathComponent("200", isDirectory: true)
            let external = root.appendingPathComponent("user-library", isDirectory: true)
            for directory in [selected, sibling, external] {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data("keep".utf8).write(to: directory.appendingPathComponent("sentinel"))
            }

            let doctor = makeDoctor(applicationSupport: appSupport, home: root)
            #expect(await doctor.deleteDownloadedItemFolders(workshopID: "../user-library") == 0)
            #expect(await doctor.deleteDownloadedItemFolders(workshopID: "") == 0)
            #expect(await doctor.deleteDownloadedItemFolders(workshopID: "100") == 1)
            #expect(!fm.fileExists(atPath: selected.path))
            #expect(fm.fileExists(atPath: sibling.appendingPathComponent("sentinel").path))
            #expect(fm.fileExists(atPath: external.appendingPathComponent("sentinel").path))
        }

        @Test("delete rejects a rebased Steam root and a symlinked item")
        @MainActor
        func downloadedItemDeleteRejectsSymlinks() async throws {
            let fm = FileManager.default
            let root = temporaryRoot("delete-symlink")
            defer { try? fm.removeItem(at: root) }

            let rebasedSupport = root.appendingPathComponent("RebasedSupport", isDirectory: true)
            let outsideSteam = root.appendingPathComponent("OutsideSteam", isDirectory: true)
            let outsideItem = outsideSteam
                .appendingPathComponent("steamapps/workshop/content/431960/100", isDirectory: true)
            try fm.createDirectory(at: rebasedSupport, withIntermediateDirectories: true)
            try fm.createDirectory(at: outsideItem, withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: outsideItem.appendingPathComponent("sentinel"))
            try fm.createSymbolicLink(
                at: rebasedSupport.appendingPathComponent("Steam", isDirectory: true),
                withDestinationURL: outsideSteam
            )
            let rebasedDoctor = makeDoctor(applicationSupport: rebasedSupport, home: root)
            #expect(await rebasedDoctor.deleteDownloadedItemFolders(workshopID: "100") == 0)
            #expect(fm.fileExists(atPath: outsideItem.appendingPathComponent("sentinel").path))

            let itemSupport = root.appendingPathComponent("ItemSupport", isDirectory: true)
            let content = workshopContentRoot(appSupport: itemSupport)
            let external = root.appendingPathComponent("ExternalItem", isDirectory: true)
            try fm.createDirectory(at: content, withIntermediateDirectories: true)
            try fm.createDirectory(at: external, withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: external.appendingPathComponent("sentinel"))
            try fm.createSymbolicLink(
                at: content.appendingPathComponent("100", isDirectory: true),
                withDestinationURL: external
            )
            let itemDoctor = makeDoctor(applicationSupport: itemSupport, home: root)
            #expect(await itemDoctor.deleteDownloadedItemFolders(workshopID: "100") == 0)
            #expect(fm.fileExists(atPath: external.appendingPathComponent("sentinel").path))

            let siblingSupport = root.appendingPathComponent("SiblingSupport", isDirectory: true)
            let siblingContent = workshopContentRoot(appSupport: siblingSupport)
            let sibling = siblingContent.appendingPathComponent("200", isDirectory: true)
            try fm.createDirectory(at: sibling, withIntermediateDirectories: true)
            let siblingSentinel = sibling.appendingPathComponent("sentinel")
            try Data("sibling".utf8).write(to: siblingSentinel)
            try fm.createSymbolicLink(
                at: siblingContent.appendingPathComponent("100", isDirectory: true),
                withDestinationURL: sibling
            )
            let siblingDoctor = makeDoctor(applicationSupport: siblingSupport, home: root)
            #expect(await siblingDoctor.deleteDownloadedItemFolders(workshopID: "100") == 0)
            #expect(fm.fileExists(atPath: siblingSentinel.path))
            #expect(fm.fileExists(atPath: siblingContent.appendingPathComponent("100").path))
        }

        @Test("downloaded-item destructive helper requires an active cleanup capability")
        func downloadedItemDeleteCapabilitySourceContract() throws {
            let operations = try productionSource(
                "LiveWallpaper/Infrastructure/Workshop/Doctor/SteamCMDDoctorOperations.swift"
            )
            let wrapper = try slice(
                operations,
                from: "func deleteDownloadedItemFolders(workshopID: String)",
                until: "private func performDeleteDownloadedItemFolders("
            )
            #expect(wrapper.contains("withOperation(.workshopCleanup)"))
            #expect(wrapper.contains("authorization: lease.filesystemMutation"))

            let helper = try slice(
                operations,
                from: "private func deleteItemFolder(",
                until: "    }\n#endif"
            )
            let activeGuard = try #require(helper.range(of: "guard authorization.isActive,"))
            let kindGuard = try #require(helper.range(of: "authorization.kind == .workshopCleanup"))
            let identity = try #require(helper.range(of: "let original = literalIdentity(at: item)"))
            let revalidation = try #require(helper.range(of: "let current = literalIdentity(at: item)"))
            let deletion = try #require(helper.range(of: "fileManager.removeItem(at: item)"))
            #expect(activeGuard.lowerBound < kindGuard.lowerBound)
            #expect(kindGuard.lowerBound < identity.lowerBound)
            #expect(identity.lowerBound < revalidation.lowerBound)
            #expect(revalidation.lowerBound < deletion.lowerBound)

            let perform = try slice(
                operations,
                from: "private func performDeleteDownloadedItemFolders(",
                until: "private struct SteamCMDWorkshopCleanupFilesystemOwner"
            )
            #expect(perform.contains("Task.detached(priority: .utility)"))
        }

        @Test("replace is staged before swap and restores previous inventory on same-run failure")
        func replacementSourceContract() throws {
            let transaction = try productionSource(
                "LiveWallpaper/Infrastructure/Workshop/WPEEngineAssetsTransaction.swift"
            )
            let replace = try slice(
                transaction,
                from: "func replaceAssets(",
                until: "func removeDeferredItems("
            )
            let recover = try #require(replace.range(of: "var cleanup = try recover("))
            let sourceCapability = try #require(replace.range(
                of: "authorization.approvesSourceRoot(sourceRoot)"
            ))
            let sidecar = try #require(replace.range(of: "try writeBuildID("))
            let stage = try #require(replace.range(of: "moveItem(at: source, to: slots.incoming)"))
            let preserve = try #require(replace.range(of: "moveItem(at: slots.current, to: slots.previous)"))
            let publish = try #require(replace.range(of: "moveItem(at: slots.incoming, to: slots.current)"))
            #expect(recover.lowerBound < stage.lowerBound)
            #expect(sourceCapability.lowerBound < sidecar.lowerBound)
            #expect(sidecar.lowerBound < stage.lowerBound)
            #expect(stage.lowerBound < preserve.lowerBound)
            #expect(preserve.lowerBound < publish.lowerBound)
            #expect(replace.contains("moveItem(at: slots.previous, to: slots.current)"))

            let slots = try slice(
                transaction,
                from: "private func validatedSlots(",
                until: "private func validatedSourceRoot("
            )
            #expect(slots.contains("literalPath(literal) == literalPath(root)"))
        }

        @Test("startup selects the authoritative assets slot before ScreenManager can restore WPE")
        func startupRecoveryBarrierSourceContract() throws {
            let app = try productionSource("LiveWallpaper/App/LiveWallpaperApp.swift")
            let launch = try slice(
                app,
                from: "func applicationDidFinishLaunching(_ notification: Notification)",
                until: "private func completeApplicationStartup(_ startupPlan: AppStartupPlan)"
            )
            let recovery = try #require(launch.range(
                of: "await WPEEngineAssetsStartupRecovery.shared.prepareForFirstRead()"
            ))
            let continuation = try #require(launch.range(of: "self.completeApplicationStartup(startupPlan)"))
            #expect(recovery.lowerBound < continuation.lowerBound)

            let completion = try slice(
                app,
                from: "private func completeApplicationStartup(_ startupPlan: AppStartupPlan)",
                until: "deinit {"
            )
            #expect(completion.contains("ScreenManager(startupOptions:"))

            let transaction = try productionSource(
                "LiveWallpaper/Infrastructure/Workshop/WPEEngineAssetsTransaction.swift"
            )
            let recover = try slice(
                transaction,
                from: "func recover(",
                until: "func replaceAssets("
            )
            #expect(recover.contains("deferRemovalIfPresent"))
            #expect(recover.contains("moveItem(at: slots.incoming, to: slots.current)"))
            #expect(recover.contains("recoveryResult("))
            #expect(!recover.contains("removeItem"))

            let startupRecovery = try productionSource(
                "LiveWallpaper/Infrastructure/Workshop/WPEEngineAssetsStartupRecovery.swift"
            )
            #expect(startupRecovery.contains("let recoveredBuildID = result.buildID"))
            #expect(startupRecovery.contains("case .empty:"))
        }

        @Test("download callback and sign-out revocation remain inside the operation FIFO")
        func longOperationLeaseSourceContract() throws {
            let doctor = try doctorSource()
            let download = try slice(
                doctor,
                from: "func downloadWorkshopItem<Imported: Sendable>(",
                until: "private func performDownloadWorkshopItem<Imported: Sendable>("
            )
            #expect(download.contains("operationCoordinator.withOperation(.workshopDownload)"))
            #expect(download.contains("return await performDownloadWorkshopItem"))

            let performDownload = try slice(
                doctor,
                from: "private func performDownloadWorkshopItem<Imported: Sendable>(",
                until: "func latestWallpaperEngineBuildID()"
            )
            let revalidation = try #require(performDownload.range(of: "inventory.revalidatedURL"))
            let callback = try #require(performDownload.range(of: "onContentReady(folder)"))
            #expect(revalidation.lowerBound < callback.lowerBound)

            let signOut = try slice(
                doctor,
                from: "func signOut() async",
                until: "func forgetUsername()"
            )
            #expect(signOut.contains("operationCoordinator.withOperation(.sessionMutation)"))
            #expect(signOut.contains("Task.detached(priority: .utility)"))
            #expect(signOut.contains("owner.clearCachedSessionFiles("))
            #expect(signOut.contains("authorization: lease.filesystemMutation"))
        }

        @Test("asset publish has a pre-commit cancellation point and mandatory durable completion")
        func pruneCancellationCommitPointSourceContract() throws {
            let installer = try productionSource(
                "LiveWallpaper/Infrastructure/Workshop/WPEEngineAssetsInstaller.swift"
            )
            let finish = try slice(
                installer,
                from: "private func finishUpdate(",
                until: "// MARK: - Update check"
            )
            let precommit = try #require(finish.range(
                of: "guard currentAttempt == attempt, !Task.isCancelled else { return }"
            ))
            let commit = try #require(finish.range(of: "owner.commitAndPrune("))
            let marker = try #require(finish.range(
                of: "SettingsManager.shared.wpeEngineAssetsManagedBuildID ="
            ))
            let deferredCleanup = try #require(finish.range(of: "owner.cleanupAfterCommit("))
            let postCommit = finish[precommit.upperBound...]
            let oldUIBarrier = try #require(
                postCommit.range(of: "guard currentAttempt == attempt, !Task.isCancelled else { return }")
            )
            let toast = try #require(finish.range(of: "WorkshopToastCenter.shared.post("))
            #expect(precommit.lowerBound < commit.lowerBound)
            #expect(commit.lowerBound < marker.lowerBound)
            #expect(marker.lowerBound < deferredCleanup.lowerBound)
            #expect(marker.lowerBound < oldUIBarrier.lowerBound)
            #expect(oldUIBarrier.lowerBound < toast.lowerBound)

            #expect(!installer.contains("nonisolated static func pruneToAssets"))
            #expect(!installer.contains("nonisolated static func deleteManagedInstall"))
        }

        @Test("managed removal clears its durable marker only after confirmed deletion")
        func managedRemovalMarkerOrderingSourceContract() throws {
            let installer = try productionSource(
                "LiveWallpaper/Infrastructure/Workshop/WPEEngineAssetsInstaller.swift"
            )
            let removal = try slice(
                installer,
                from: "private func performRemove(attempt: UUID) async",
                until: "private func fail("
            )
            let disk = try #require(removal.range(of: "try owner.removeManagedInstall("))
            let marker = try #require(removal.range(
                of: "SettingsManager.shared.wpeEngineAssetsManagedBuildID = nil"
            ))
            let failure = try #require(removal.range(of: "} catch {"))
            #expect(disk.lowerBound < marker.lowerBound)
            #expect(marker.lowerBound < failure.lowerBound)
        }

        @Test("stdout download destination must be the exact approved item target")
        @MainActor
        func downloadPathContainment() throws {
            let fm = FileManager.default
            let root = temporaryRoot("download-containment")
            defer { try? fm.removeItem(at: root) }
            let appSupport = root.appendingPathComponent("Application Support", isDirectory: true)
            let workdir = root.appendingPathComponent("Workdir", isDirectory: true)
            let fixtureManager = DoctorFixtureFileManager(applicationSupport: appSupport, home: root)
            let inventory = SteamCMDWorkshopFileInventory(fileManager: fixtureManager)

            let containerItem = workshopContentRoot(appSupport: appSupport)
                .appendingPathComponent("100", isDirectory: true)
            let workdirItem = workdir
                .appendingPathComponent("steamapps/workshop/content/431960/200", isDirectory: true)
            let outsideItem = root.appendingPathComponent("outside/300", isDirectory: true)
            for item in [containerItem, workdirItem, outsideItem] {
                try fm.createDirectory(at: item, withIntermediateDirectories: true)
            }

            #expect(inventory.resolveDownloadedItemFolder(
                stdout: successLine(itemID: 100, destination: containerItem),
                itemID: 100,
                workdir: workdir
            )?.url.path == containerItem.path)
            #expect(inventory.resolveDownloadedItemFolder(
                stdout: successLine(itemID: 200, destination: workdirItem),
                itemID: 200,
                workdir: workdir
            )?.url.path == workdirItem.path)
            #expect(inventory.resolveDownloadedItemFolder(
                stdout: successLine(itemID: 300, destination: outsideItem),
                itemID: 300,
                workdir: workdir
            ) == nil)
            #expect(inventory.resolveDownloadedItemFolder(
                stdout: successLine(itemID: 100, destination: outsideItem),
                itemID: 100,
                workdir: workdir
            ) == nil)

            let external = root.appendingPathComponent("external-item", isDirectory: true)
            try fm.createDirectory(at: external, withIntermediateDirectories: true)
            let linkedItem = workshopContentRoot(appSupport: appSupport)
                .appendingPathComponent("400", isDirectory: true)
            try fm.createSymbolicLink(at: linkedItem, withDestinationURL: external)
            #expect(inventory.resolveDownloadedItemFolder(
                stdout: successLine(itemID: 400, destination: linkedItem),
                itemID: 400,
                workdir: workdir
            ) == nil)

            let rebasedSupport = root.appendingPathComponent("RebasedSupport", isDirectory: true)
            let outsideSteam = root.appendingPathComponent("OutsideSteam", isDirectory: true)
            let outsideSteamItem = outsideSteam
                .appendingPathComponent("steamapps/workshop/content/431960/500", isDirectory: true)
            try fm.createDirectory(at: rebasedSupport, withIntermediateDirectories: true)
            try fm.createDirectory(at: outsideSteamItem, withIntermediateDirectories: true)
            try fm.createSymbolicLink(
                at: rebasedSupport.appendingPathComponent("Steam", isDirectory: true),
                withDestinationURL: outsideSteam
            )
            let rebasedInventory = SteamCMDWorkshopFileInventory(
                fileManager: DoctorFixtureFileManager(applicationSupport: rebasedSupport, home: root)
            )
            #expect(rebasedInventory.resolveDownloadedItemFolder(
                stdout: successLine(itemID: 500, destination: outsideSteamItem),
                itemID: 500,
                workdir: workdir
            ) == nil)

            let validatedCandidate = try #require(inventory.resolveDownloadedItemFolder(
                stdout: successLine(itemID: 100, destination: containerItem),
                itemID: 100,
                workdir: workdir
            ))
            #expect(inventory.revalidatedURL(
                for: validatedCandidate,
                requiringProjectJSON: false
            )?.path == containerItem.path)
            let parkedItem = containerItem.deletingLastPathComponent()
                .appendingPathComponent("100.original", isDirectory: true)
            try fm.moveItem(at: containerItem, to: parkedItem)
            try fm.createSymbolicLink(at: containerItem, withDestinationURL: outsideItem)
            var callbackInvoked = false
            if inventory.revalidatedURL(for: validatedCandidate, requiringProjectJSON: false) != nil {
                callbackInvoked = true
            }
            #expect(!callbackInvoked)
        }

        @Test("identity selection is branch-stable and fails closed when unavailable")
        @MainActor
        func identitySelectionAndBranchMismatch() throws {
            let primary = SteamCMDWorkshopDirectoryIdentity.resource(
                fileResourceIdentifier: Data("resource".utf8),
                volumeIdentifier: Data("volume".utf8)
            )
            let fallback = SteamCMDWorkshopDirectoryIdentity.deviceAndInode(deviceID: 7, inode: 11)
            #expect(SteamCMDWorkshopFileInventory.selectIdentity(
                fileResourceIdentifier: Data("resource".utf8),
                volumeIdentifier: Data("volume".utf8),
                deviceID: 7,
                inode: 11,
                attributesAreDirectory: true
            ) == primary)
            #expect(SteamCMDWorkshopFileInventory.selectIdentity(
                fileResourceIdentifier: nil,
                volumeIdentifier: nil,
                deviceID: 7,
                inode: 11,
                attributesAreDirectory: true
            ) == fallback)
            #expect(SteamCMDWorkshopFileInventory.selectIdentity(
                fileResourceIdentifier: Data("resource".utf8),
                volumeIdentifier: nil,
                deviceID: 7,
                inode: 11,
                attributesAreDirectory: true
            ) == fallback)
            #expect(SteamCMDWorkshopFileInventory.selectIdentity(
                fileResourceIdentifier: nil,
                volumeIdentifier: nil,
                deviceID: 7,
                inode: 0,
                attributesAreDirectory: true
            ) == nil)
            #expect(SteamCMDWorkshopFileInventory.selectIdentity(
                fileResourceIdentifier: nil,
                volumeIdentifier: nil,
                deviceID: 7,
                inode: 11,
                attributesAreDirectory: false
            ) == nil)

            let fm = FileManager.default
            let root = temporaryRoot("identity-branches")
            defer { try? fm.removeItem(at: root) }
            let appSupport = root.appendingPathComponent("Application Support", isDirectory: true)
            let item = workshopContentRoot(appSupport: appSupport)
                .appendingPathComponent("100", isDirectory: true)
            let workdir = root.appendingPathComponent("Workdir", isDirectory: true)
            try fm.createDirectory(at: item, withIntermediateDirectories: true)
            let fixtureManager = DoctorFixtureFileManager(applicationSupport: appSupport, home: root)

            func candidate(
                using inventory: SteamCMDWorkshopFileInventory
            ) -> SteamCMDValidatedWorkshopItem? {
                inventory.resolveDownloadedItemFolder(
                    stdout: successLine(itemID: 100, destination: item),
                    itemID: 100,
                    workdir: workdir
                )
            }

            let primaryInventory = SteamCMDWorkshopFileInventory(
                fileManager: fixtureManager,
                identityReader: { _, _, _ in primary }
            )
            let primaryCandidate = try #require(candidate(using: primaryInventory))
            #expect(primaryInventory.revalidatedURL(
                for: primaryCandidate,
                requiringProjectJSON: false
            )?.path == item.path)

            let fallbackInventory = SteamCMDWorkshopFileInventory(
                fileManager: fixtureManager,
                identityReader: { _, _, _ in fallback }
            )
            let fallbackCandidate = try #require(candidate(using: fallbackInventory))
            #expect(fallbackInventory.revalidatedURL(
                for: fallbackCandidate,
                requiringProjectJSON: false
            )?.path == item.path)

            let unavailableInventory = SteamCMDWorkshopFileInventory(
                fileManager: fixtureManager,
                identityReader: { _, _, _ in nil }
            )
            #expect(candidate(using: unavailableInventory) == nil)
            let invalidFallbackInventory = SteamCMDWorkshopFileInventory(
                fileManager: fixtureManager,
                identityReader: { _, _, _ in .deviceAndInode(deviceID: 7, inode: 0) }
            )
            #expect(candidate(using: invalidFallbackInventory) == nil)

            let identityReadCount = OSAllocatedUnfairLock(initialState: 0)
            let mismatchInventory = SteamCMDWorkshopFileInventory(
                fileManager: fixtureManager,
                identityReader: { _, _, _ in
                    identityReadCount.withLock { count in
                        count += 1
                        return count == 1 ? primary : fallback
                    }
                }
            )
            let mismatchedCandidate = try #require(candidate(using: mismatchInventory))
            #expect(mismatchInventory.revalidatedURL(
                for: mismatchedCandidate,
                requiringProjectJSON: false
            ) == nil)
        }

        @Test("inventory returns only numeric direct targets and rejects symlinks")
        @MainActor
        func targetOnlyInventoryEnumeration() throws {
            let fm = FileManager.default
            let root = temporaryRoot("inventory-targets")
            defer { try? fm.removeItem(at: root) }
            let steamRoot = root.appendingPathComponent("Steam", isDirectory: true)
            let content = steamRoot.appendingPathComponent(
                "steamapps/workshop/content/431960",
                isDirectory: true
            )
            let external = root.appendingPathComponent("external", isDirectory: true)
            try fm.createDirectory(at: content, withIntermediateDirectories: true)
            try fm.createDirectory(at: external, withIntermediateDirectories: true)
            try Data("external".utf8).write(to: external.appendingPathComponent("project.json"))

            func createProject(id: String) throws -> URL {
                let item = content.appendingPathComponent(id, isDirectory: true)
                try fm.createDirectory(at: item, withIntermediateDirectories: true)
                try Data(id.utf8).write(to: item.appendingPathComponent("project.json"))
                return item
            }

            let first = try createProject(id: "100")
            _ = try createProject(id: "not-an-id")
            let missingProject = content.appendingPathComponent("200", isDirectory: true)
            try fm.createDirectory(at: missingProject, withIntermediateDirectories: true)
            try fm.createSymbolicLink(
                at: content.appendingPathComponent("300", isDirectory: true),
                withDestinationURL: external
            )
            let linkedManifestItem = content.appendingPathComponent("400", isDirectory: true)
            try fm.createDirectory(at: linkedManifestItem, withIntermediateDirectories: true)
            try fm.createSymbolicLink(
                at: linkedManifestItem.appendingPathComponent("project.json"),
                withDestinationURL: external.appendingPathComponent("project.json")
            )

            let inventory = SteamCMDWorkshopFileInventory(fileManager: fm)
            let candidates = inventory.projectFolders(
                under: steamRoot,
                anchoredTo: steamRoot,
                skipping: []
            )
            #expect(candidates.map(\.url.path) == [first.path])
            #expect(inventory.projectFolders(
                under: steamRoot,
                anchoredTo: steamRoot,
                skipping: ["100"]
            ).isEmpty)

            let rebasedRoot = root.appendingPathComponent("RebasedSteam", isDirectory: true)
            try fm.createDirectory(at: rebasedRoot, withIntermediateDirectories: true)
            try fm.createSymbolicLink(
                at: rebasedRoot.appendingPathComponent("steamapps", isDirectory: true),
                withDestinationURL: external
            )
            #expect(inventory.projectFolders(
                under: rebasedRoot,
                anchoredTo: rebasedRoot,
                skipping: []
            ).isEmpty)

            let rebasedSupport = root.appendingPathComponent("RebasedSupport", isDirectory: true)
            let outsideSteam = root.appendingPathComponent("OutsideSteam", isDirectory: true)
            let outsideProject = outsideSteam
                .appendingPathComponent("steamapps/workshop/content/431960/500", isDirectory: true)
            try fm.createDirectory(at: rebasedSupport, withIntermediateDirectories: true)
            try fm.createDirectory(at: outsideProject, withIntermediateDirectories: true)
            try Data("outside".utf8).write(to: outsideProject.appendingPathComponent("project.json"))
            try fm.createSymbolicLink(
                at: rebasedSupport.appendingPathComponent("Steam", isDirectory: true),
                withDestinationURL: outsideSteam
            )
            #expect(inventory.projectFolders(
                under: rebasedSupport.appendingPathComponent("Steam", isDirectory: true),
                anchoredTo: rebasedSupport,
                skipping: []
            ).isEmpty)

            let validatedCandidate = try #require(candidates.first)
            #expect(inventory.revalidatedURL(
                for: validatedCandidate,
                requiringProjectJSON: true
            )?.path == first.path)
            let parkedItem = first.deletingLastPathComponent()
                .appendingPathComponent("100.original", isDirectory: true)
            try fm.moveItem(at: first, to: parkedItem)
            try fm.createSymbolicLink(at: first, withDestinationURL: external)
            var bodyInvoked = false
            if inventory.revalidatedURL(for: validatedCandidate, requiringProjectJSON: true) != nil {
                bodyInvoked = true
            }
            #expect(!bodyInvoked)
        }

        @Test("Doctor delegates download resolution and enumeration to one injectable owner")
        func filesystemOwnerSourceContract() throws {
            let source = try doctorSource()
            #expect(source.contains(
                "@ObservationIgnored private let workshopFileInventory: any SteamCMDWorkshopFileInventoryServing"
            ))
            #expect(source.contains(
                "workshopFileInventory: (any SteamCMDWorkshopFileInventoryServing)? = nil"
            ))
            #expect(source.contains("inventory.resolveDownloadedItemFolder("))
            #expect(source.contains("under: steamRoot,"))
            #expect(source.contains("anchoredTo: appSupport,"))
            #expect(source.contains("under: workdir,"))
            #expect(source.contains("anchoredTo: workdir,"))
            let download = try slice(
                source,
                from: "let folder = await Task.detached(priority: .utility)",
                until: "// Mirror the ownership probe's stdout"
            )
            let revalidation = try #require(download.range(of: "inventory.revalidatedURL("))
            let callback = try #require(download.range(of: "onContentReady(folder)"))
            #expect(revalidation.lowerBound < callback.lowerBound)
            let enumeration = try slice(
                source,
                from: "func enumerateDownloadedItemFolders(",
                until: "/// Extracts the quoted destination"
            )
            #expect(enumeration.components(separatedBy: "requiringProjectJSON: true").count - 1 == 2)
            #expect(enumeration.components(separatedBy: "Task.detached(priority: .utility)").count - 1 >= 4)
            let projectRevalidation = try #require(enumeration.range(of: "inventory.revalidatedURL("))
            let body = try #require(enumeration.range(of: "await body(project)"))
            #expect(projectRevalidation.lowerBound < body.lowerBound)

            let inventorySource = try productionSource(
                "LiveWallpaper/Infrastructure/Workshop/Doctor/SteamCMDWorkshopFileInventory.swift"
            )
            #expect(!inventorySource.contains("@MainActor"))
            #expect(inventorySource.contains("SteamCMDValidatedWorkshopItem: Sendable"))
            #expect(inventorySource.contains("SteamCMDWorkshopDirectoryIdentity: Equatable, Sendable"))
        }

        // MARK: - Test support

        private func temporaryRoot(_ label: String) -> URL {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("AF12-\(label)-\(UUID().uuidString)", isDirectory: true)
        }

        private func containerScopedFixtureRoot(_ label: String) -> URL {
            URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent(
                    "Library/Caches/LiveWallpaper-AF12-\(label)-\(UUID().uuidString)",
                    isDirectory: true
                )
        }

        private func workshopContentRoot(appSupport: URL) -> URL {
            appSupport.appendingPathComponent(
                "Steam/steamapps/workshop/content/431960",
                isDirectory: true
            )
        }

        private func successLine(itemID: UInt64, destination: URL) -> String {
            "Success. Downloaded item \(itemID) to \"\(destination.path(percentEncoded: false))\" (1 bytes after 1 chunks)"
        }

        private func pathContains(_ child: URL, in parent: URL) -> Bool {
            let childPath = child.standardizedFileURL.resolvingSymlinksInPath().path
            let parentPath = parent.standardizedFileURL.resolvingSymlinksInPath().path
            return childPath == parentPath || childPath.hasPrefix(parentPath + "/")
        }

        @MainActor
        private func makeDoctor(applicationSupport: URL, home: URL) -> SteamCMDDoctorService {
            let suiteName = "AF12.Doctor.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            return SteamCMDDoctorService(
                defaults: defaults,
                fileManager: DoctorFixtureFileManager(applicationSupport: applicationSupport, home: home)
            )
        }

        private func doctorSource() throws -> String {
            try productionSource(
                "LiveWallpaper/Infrastructure/Workshop/Doctor/SteamCMDDoctorService.swift"
            )
        }

        private func operationsSource() throws -> String {
            try productionSource(
                "LiveWallpaper/Infrastructure/Workshop/Doctor/SteamCMDDoctorOperations.swift"
            )
        }

        private func productionSource(_ relativePath: String) throws -> String {
            let projectRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            return try String(
                contentsOf: projectRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
        }

        private func slice(_ source: String, from start: String, until end: String) throws -> String {
            let startRange = try #require(source.range(of: start))
            let endRange = try #require(source.range(of: end, range: startRange.upperBound ..< source.endIndex))
            return String(source[startRange.lowerBound ..< endRange.lowerBound])
        }
    }

    private final class DoctorFixtureFileManager: FileManager, @unchecked Sendable {
        private let applicationSupport: URL
        private let home: URL

        init(applicationSupport: URL, home: URL) {
            self.applicationSupport = applicationSupport
            self.home = home
            super.init()
        }

        override func url(
            for directory: FileManager.SearchPathDirectory,
            in domain: FileManager.SearchPathDomainMask,
            appropriateFor url: URL?,
            create shouldCreate: Bool
        ) throws -> URL {
            if directory == .applicationSupportDirectory {
                return applicationSupport
            }
            return try super.url(for: directory, in: domain, appropriateFor: url, create: shouldCreate)
        }

        override var homeDirectoryForCurrentUser: URL {
            home
        }
    }
#endif
