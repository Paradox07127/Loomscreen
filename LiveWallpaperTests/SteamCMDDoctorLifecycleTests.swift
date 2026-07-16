#if !LITE_BUILD
    import Foundation
    @testable import LiveWallpaper
    import Testing

    @Suite("AF-12: Doctor operation and asset lifecycle", .serialized)
    struct SteamCMDDoctorLifecycleTests {
        @Test("operation owner serializes generations and rejects stale completion")
        func operationGenerationsAreExclusive() async throws {
            let coordinator = SteamCMDDoctorOperationCoordinator()
            let firstStarted = AF12Latch()
            let releaseFirst = AF12Latch()
            let secondStarted = AF12Latch()
            let releaseSecond = AF12Latch()
            let secondLeaseBox = AF12LeaseBox()

            let firstTask = Task {
                try await coordinator.withOperation(.appUpdate) { lease in
                    await firstStarted.signal()
                    await releaseFirst.wait()
                    return lease
                }
            }
            await firstStarted.wait()

            let secondTask = Task {
                try await coordinator.withOperation(.ownershipValidation) { lease in
                    await secondLeaseBox.set(lease)
                    await secondStarted.signal()
                    await releaseSecond.wait()
                    return lease
                }
            }
            for _ in 0 ..< 20 {
                await Task.yield()
            }
            #expect(await !(secondStarted.isSignalled))

            await releaseFirst.signal()
            let firstLease = try await firstTask.value
            await secondStarted.wait()
            let storedSecondLease = await secondLeaseBox.value
            let activeSecondLease = try #require(storedSecondLease)
            #expect(activeSecondLease.generation == firstLease.generation + 1)
            #expect(await coordinator.isCurrent(activeSecondLease))
            #expect(await !(coordinator.isCurrent(firstLease)))
            await releaseSecond.signal()
            let secondLease = try await secondTask.value
            #expect(secondLease.generation == firstLease.generation + 1)
            #expect(await !(coordinator.isCurrent(secondLease)))
        }

        @Test("cancelled waiter consumes no generation and successor can enter")
        func cancelledWaiterDoesNotPublish() async throws {
            let coordinator = SteamCMDDoctorOperationCoordinator()
            let started = AF12Latch()
            let release = AF12Latch()

            let first = Task {
                try await coordinator.withOperation(.appUpdate) { lease in
                    await started.signal()
                    await release.wait()
                    return lease
                }
            }
            await started.wait()
            let cancelled = Task {
                try await coordinator.withOperation(.ownershipValidation) { $0 }
            }
            cancelled.cancel()
            do {
                _ = try await cancelled.value
                Issue.record("cancelled operation unexpectedly entered")
            } catch is CancellationError {
                // Expected.
            }

            await release.signal()
            let firstLease = try await first.value
            let successor = try await coordinator.withOperation(.assetsMutation) { $0 }
            #expect(successor.generation == firstLease.generation + 1)
        }

        @Test("cancelled publisher retains the FIFO until durable state precedes its successor")
        func cancelledPublisherCompletesBeforeSuccessor() async throws {
            let coordinator = SteamCMDDoctorOperationCoordinator()
            let commitStarted = AF12Latch()
            let allowPublication = AF12Latch()
            let successorStarted = AF12Latch()
            let durableState = AF12StringBox()

            let publisher = Task {
                try await coordinator.withOperation(.appUpdate) { _ in
                    await commitStarted.signal()
                    await allowPublication.wait()
                    await durableState.set("published-and-marked")
                }
            }
            await commitStarted.wait()
            publisher.cancel()

            let successor = Task {
                try await coordinator.withOperation(.appUpdate) { _ in
                    await successorStarted.signal()
                    return await durableState.value
                }
            }
            for _ in 0 ..< 20 {
                await Task.yield()
            }
            #expect(await !(successorStarted.isSignalled))

            await allowPublication.signal()
            try await publisher.value
            #expect(try await successor.value == "published-and-marked")
        }

        @Test("same operation inherits its lease while cross-kind nesting fails closed")
        func nestedOperationRules() async throws {
            let coordinator = SteamCMDDoctorOperationCoordinator()
            let inherited = try await coordinator.withOperation(.appUpdate) { outer in
                try await coordinator.withOperation(.appUpdate, inheriting: outer) { inner in
                    #expect(inner == outer)
                    return inner
                }
            }
            #expect(inherited.generation == 1)

            do {
                _ = try await coordinator.withOperation(.appUpdate) { outer in
                    try await coordinator.withOperation(.workshopCleanup, inheriting: outer) { $0 }
                }
                Issue.record("cross-kind nested operation unexpectedly entered")
            } catch let error as SteamCMDDoctorOperationError {
                #expect(error == .nestedConflict(active: .appUpdate, requested: .workshopCleanup))
            }
        }

        @Test("filesystem capability expires when its owning operation returns")
        func escapedFilesystemCapabilityIsRejected() async throws {
            let coordinator = SteamCMDDoctorOperationCoordinator()
            let escaped = try await coordinator.withOperation(.assetsMutation) {
                $0.filesystemMutation
            }
            #expect(!escaped.isActive)

            let root = temporaryRoot("expired-capability")
            defer { try? FileManager.default.removeItem(at: root) }
            let managed = managedRoot(under: root, label: "managed")
            try seedAssets("current", slot: "assets", managed: managed)
            let transaction = transactionForTests(
                fileManager: .default,
                trustedParent: root
            )
            #expect(throws: WPEEngineAssetsTransaction.TransactionError.unauthorizedMutation) {
                try transaction.recover(
                    managedRoot: managed,
                    authorization: escaped
                )
            }
        }

        @Test("crash recovery chooses exactly one trusted asset slot at every cut point")
        func assetCrashRecoveryMatrix() async throws {
            let fm = FileManager.default
            let root = temporaryRoot("recovery")
            defer { try? fm.removeItem(at: root) }
            try fm.createDirectory(at: root, withIntermediateDirectories: true)

            struct Fixture {
                let current: String?
                let incoming: String?
                let previous: String?
                let expected: WPEEngineAssetsTransaction.RecoveryAction
                let marker: String?
            }
            let fixtures: [Fixture] = [
                Fixture(current: nil, incoming: nil, previous: nil, expected: .empty, marker: nil),
                Fixture(current: "old", incoming: nil, previous: nil, expected: .keptCurrent, marker: "old"),
                Fixture(current: "old", incoming: "new", previous: nil, expected: .keptCurrent, marker: "old"),
                Fixture(current: nil, incoming: "new", previous: "old", expected: .publishedIncoming, marker: "new"),
                Fixture(current: "new", incoming: nil, previous: "old", expected: .keptCurrent, marker: "new"),
                Fixture(current: nil, incoming: nil, previous: "old", expected: .restoredPrevious, marker: "old"),
            ]

            for (index, fixture) in fixtures.enumerated() {
                let managed = managedRoot(under: root, label: String(index))
                try seedAssets(fixture.current, slot: "assets", managed: managed)
                try seedAssets(fixture.incoming, slot: "assets.incoming", managed: managed)
                try seedAssets(fixture.previous, slot: "assets.previous", managed: managed)
                let transaction = transactionForTests(fileManager: fm, trustedParent: root)

                try await SteamCMDDoctorOperationCoordinator().withOperation(.assetsMutation) { lease in
                    let result = try transaction.recover(
                        managedRoot: managed,
                        authorization: lease.filesystemMutation
                    )
                    #expect(result.action == fixture.expected)
                }
                #expect(try marker(in: managed.appendingPathComponent("assets")) == fixture.marker)
                #expect(!fm.fileExists(atPath: managed.appendingPathComponent("assets.incoming").path))
                #expect(!fm.fileExists(atPath: managed.appendingPathComponent("assets.previous").path))
            }
        }

        @Test("invalid current restores backup, but no-backup corruption is preserved and refused")
        func invalidCurrentFailsClosed() async throws {
            let fm = FileManager.default
            let root = temporaryRoot("invalid-current")
            defer { try? fm.removeItem(at: root) }
            let transaction = transactionForTests(fileManager: fm, trustedParent: root)

            let recoverable = managedRoot(under: root, label: "recoverable")
            try fm.createDirectory(at: recoverable, withIntermediateDirectories: true)
            try Data("invalid".utf8).write(to: recoverable.appendingPathComponent("assets"))
            try seedAssets("old", slot: "assets.previous", managed: recoverable)
            try await SteamCMDDoctorOperationCoordinator().withOperation(.assetsMutation) { lease in
                let result = try transaction.recover(
                    managedRoot: recoverable,
                    authorization: lease.filesystemMutation
                )
                #expect(result.action == .restoredPrevious)
            }
            #expect(try marker(in: recoverable.appendingPathComponent("assets")) == "old")

            let refused = managedRoot(under: root, label: "refused")
            try fm.createDirectory(at: refused, withIntermediateDirectories: true)
            let invalid = refused.appendingPathComponent("assets")
            try Data("do-not-delete".utf8).write(to: invalid)
            try await SteamCMDDoctorOperationCoordinator().withOperation(.assetsMutation) { lease in
                #expect(throws: WPEEngineAssetsTransaction.TransactionError.invalidCurrentWithoutRecovery) {
                    try transaction.recover(
                        managedRoot: refused,
                        authorization: lease.filesystemMutation
                    )
                }
            }
            #expect(try String(contentsOf: invalid, encoding: .utf8) == "do-not-delete")
        }

        @Test("symlinked recovery slot is never followed or selected")
        func recoveryRejectsSymlinkSlot() async throws {
            let fm = FileManager.default
            let root = temporaryRoot("recovery-symlink")
            let external = temporaryRoot("recovery-external")
            defer { try? fm.removeItem(at: root) }
            defer { try? fm.removeItem(at: external) }
            let managed = managedRoot(under: root, label: "linked")
            try fm.createDirectory(at: managed, withIntermediateDirectories: true)
            try seedAssets("old", slot: "assets.previous", managed: managed)
            try fm.createDirectory(at: external, withIntermediateDirectories: true)
            let sentinel = external.appendingPathComponent("sentinel")
            try Data("external".utf8).write(to: sentinel)
            try fm.createSymbolicLink(
                at: managed.appendingPathComponent("assets.incoming"),
                withDestinationURL: external
            )

            let transaction = transactionForTests(fileManager: fm, trustedParent: root)
            try await SteamCMDDoctorOperationCoordinator().withOperation(.assetsMutation) { lease in
                let result = try transaction.recover(
                    managedRoot: managed,
                    authorization: lease.filesystemMutation
                )
                #expect(result.action == .restoredPrevious)
            }
            #expect(try marker(in: managed.appendingPathComponent("assets")) == "old")
            #expect(fm.fileExists(atPath: sentinel.path))
        }

        @Test("transaction rejects managed and staging ancestry aliases")
        func transactionRejectsLiteralAncestryAliases() async throws {
            let fm = FileManager.default
            let root = temporaryRoot("transaction-aliases")
            defer { try? fm.removeItem(at: root) }
            let transaction = transactionForTests(fileManager: fm, trustedParent: root)

            let realManaged = root.appendingPathComponent(
                "real/common/wallpaper_engine",
                isDirectory: true
            )
            try seedAssets("real", slot: "assets", managed: realManaged)
            let aliasCommon = root.appendingPathComponent("alias/common", isDirectory: true)
            try fm.createDirectory(at: aliasCommon, withIntermediateDirectories: true)
            let managedAlias = aliasCommon.appendingPathComponent(
                "wallpaper_engine",
                isDirectory: true
            )
            try fm.createSymbolicLink(at: managedAlias, withDestinationURL: realManaged)
            try await SteamCMDDoctorOperationCoordinator().withOperation(.assetsMutation) { lease in
                #expect(throws: WPEEngineAssetsTransaction.TransactionError.untrustedRoot) {
                    try transaction.recover(
                        managedRoot: managedAlias,
                        authorization: lease.filesystemMutation
                    )
                }
            }

            let managed = managedRoot(under: root, label: "authoritative")
            try seedAssets("old", slot: "assets", managed: managed)
            let realParent = root.appendingPathComponent("real-staging", isDirectory: true)
            let realSource = realParent.appendingPathComponent("431960", isDirectory: true)
            try seedAssets("new", slot: "assets", managed: realSource)
            let aliasedParent = root.appendingPathComponent("staging-alias", isDirectory: true)
            try fm.createSymbolicLink(at: aliasedParent, withDestinationURL: realParent)
            let aliasedSource = aliasedParent.appendingPathComponent("431960", isDirectory: true)
            try await SteamCMDDoctorOperationCoordinator().withOperation(.appUpdate) { lease in
                #expect(throws: WPEEngineAssetsTransaction.TransactionError.untrustedSourceRoot) {
                    try transaction.replaceAssets(
                        from: aliasedSource,
                        managedRoot: managed,
                        buildID: "555",
                        authorization: lease.filesystemMutation(
                            approvingSourceRoot: aliasedSource
                        )
                    )
                }
            }
            #expect(try marker(in: managed.appendingPathComponent("assets")) == "old")
        }

        @Test("relaunch discovers old exact-name orphans and deletes no symlink target")
        @MainActor
        func startupRecoveryResumesDeferredCleanup() async throws {
            let fm = FileManager.default
            let originalManagedMarker = SettingsManager.shared.wpeEngineAssetsManagedBuildID
            defer {
                SettingsManager.shared.wpeEngineAssetsManagedBuildID = originalManagedMarker
            }
            let root = temporaryRoot("relaunch-orphan")
            let external = temporaryRoot("relaunch-external")
            defer { try? fm.removeItem(at: root) }
            defer { try? fm.removeItem(at: external) }
            let managed = managedRoot(under: root, label: "managed")
            try seedAssets("current", slot: "assets", managed: managed)

            let oldOrphan = managed.appendingPathComponent(
                "assets.orphan.\(UUID().uuidString)",
                isDirectory: true
            )
            try seedAssets("stale", slot: oldOrphan.lastPathComponent, managed: managed)
            let nearMiss = managed.appendingPathComponent("assets.orphan.not-a-uuid", isDirectory: true)
            try fm.createDirectory(at: nearMiss, withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: nearMiss.appendingPathComponent("sentinel"))

            try fm.createDirectory(at: external, withIntermediateDirectories: true)
            let externalSentinel = external.appendingPathComponent("sentinel")
            try Data("external".utf8).write(to: externalSentinel)
            let linkedOrphan = managed.appendingPathComponent(
                "assets.orphan.\(UUID().uuidString)",
                isDirectory: true
            )
            try fm.createSymbolicLink(at: linkedOrphan, withDestinationURL: external)

            let transaction = transactionForTests(fileManager: fm, trustedParent: root)
            let recovery = WPEEngineAssetsStartupRecovery(
                operationCoordinator: SteamCMDDoctorOperationCoordinator(),
                filesystemOwner: WPEEngineAssetsFilesystemOwner(
                    fileManager: fm,
                    transaction: transaction
                ),
                managedRoot: managed
            )
            #expect(await recovery.prepareForFirstRead() == .keptCurrent)
            await recovery.waitForDeferredCleanup()

            #expect(!fm.fileExists(atPath: oldOrphan.path))
            #expect(fm.fileExists(atPath: nearMiss.appendingPathComponent("sentinel").path))
            #expect(fm.fileExists(atPath: linkedOrphan.path))
            #expect(fm.fileExists(atPath: externalSentinel.path))
        }

        @Test("startup repairs the real UserDefaults marker for every authoritative crash cut")
        @MainActor
        func startupRecoveryRepairsManagedMarker() async throws {
            let fm = FileManager.default
            let root = temporaryRoot("marker-crash-cuts")
            defer { try? fm.removeItem(at: root) }
            let originalManagedMarker = SettingsManager.shared.wpeEngineAssetsManagedBuildID
            defer {
                SettingsManager.shared.wpeEngineAssetsManagedBuildID = originalManagedMarker
            }

            struct Fixture {
                let slot: String?
                let expected: WPEEngineAssetsTransaction.RecoveryAction
                let initialMarker: String?
                let sidecarBuildID: String?
                let expectedMarker: String?
            }
            let fixtures = [
                Fixture(
                    slot: "assets",
                    expected: .keptCurrent,
                    initialMarker: "111",
                    sidecarBuildID: "222",
                    expectedMarker: "222"
                ),
                Fixture(
                    slot: "assets.incoming",
                    expected: .publishedIncoming,
                    initialMarker: nil,
                    sidecarBuildID: "333",
                    expectedMarker: "333"
                ),
                Fixture(
                    slot: "assets.previous",
                    expected: .restoredPrevious,
                    initialMarker: "444",
                    sidecarBuildID: nil,
                    expectedMarker: WPEEngineAssetsLibrary.unknownManagedBuildMarker
                ),
                Fixture(
                    slot: nil,
                    expected: .empty,
                    initialMarker: "stale-after-delete",
                    sidecarBuildID: nil,
                    expectedMarker: nil
                ),
            ]
            for (index, fixture) in fixtures.enumerated() {
                SettingsManager.shared.wpeEngineAssetsManagedBuildID = fixture.initialMarker
                let managed = managedRoot(under: root, label: "cut-\(index)")
                if let slot = fixture.slot {
                    try seedAssets("valid", slot: slot, managed: managed)
                    if let sidecarBuildID = fixture.sidecarBuildID {
                        try Data(sidecarBuildID.utf8).write(
                            to: managed.appendingPathComponent(slot, isDirectory: true)
                                .appendingPathComponent(
                                    WPEEngineAssetsTransaction.buildIDSidecarName
                                )
                        )
                    }
                } else {
                    try fm.createDirectory(at: managed, withIntermediateDirectories: true)
                }
                let transaction = transactionForTests(fileManager: fm, trustedParent: root)
                let recovery = WPEEngineAssetsStartupRecovery(
                    operationCoordinator: SteamCMDDoctorOperationCoordinator(),
                    filesystemOwner: WPEEngineAssetsFilesystemOwner(
                        fileManager: fm,
                        transaction: transaction,
                        trustsContainer: { _ in true }
                    ),
                    managedRoot: managed
                )

                #expect(await recovery.prepareForFirstRead() == fixture.expected)
                #expect(SettingsManager.shared.wpeEngineAssetsManagedBuildID == fixture.expectedMarker)
                #expect(UserDefaults.standard.string(
                    forKey: "WPEEngineAssets.ManagedBuildID.v1"
                ) == fixture.expectedMarker)
                if let expectedMarker = fixture.expectedMarker {
                    #expect(try String(
                        contentsOf: managed.appendingPathComponent("assets", isDirectory: true)
                            .appendingPathComponent(
                                WPEEngineAssetsTransaction.buildIDSidecarName
                            ),
                        encoding: .utf8
                    ) == expectedMarker)
                }
            }
        }

        @Test("managed deletion rejects a final symlink and reports failure without clearing marker")
        @MainActor
        func managedRemovalIsExplicitAndMarkerSafe() async throws {
            let fm = FileManager.default
            let root = temporaryRoot("managed-removal")
            defer { try? fm.removeItem(at: root) }
            let originalManagedMarker = SettingsManager.shared.wpeEngineAssetsManagedBuildID
            defer {
                SettingsManager.shared.wpeEngineAssetsManagedBuildID = originalManagedMarker
            }
            SettingsManager.shared.wpeEngineAssetsManagedBuildID = "af12-build"
            let trusted: @Sendable (URL) -> Bool = { candidate in
                let child = candidate.standardizedFileURL.path
                let parent = root.standardizedFileURL.path
                return child == parent || child.hasPrefix(parent + "/")
            }

            let common = root.appendingPathComponent("common", isDirectory: true)
            let sibling = common.appendingPathComponent("real_engine", isDirectory: true)
            let managed = common.appendingPathComponent("wallpaper_engine", isDirectory: true)
            try fm.createDirectory(at: sibling, withIntermediateDirectories: true)
            let sentinel = sibling.appendingPathComponent("sentinel")
            try Data("keep".utf8).write(to: sentinel)
            try fm.createSymbolicLink(at: managed, withDestinationURL: sibling)
            let owner = WPEEngineAssetsFilesystemOwner(
                fileManager: fm,
                trustsContainer: trusted
            )
            do {
                _ = try await SteamCMDDoctorOperationCoordinator().withOperation(.assetsMutation) { lease in
                    try owner.removeManagedInstall(
                        managedRoot: managed,
                        authorization: lease.filesystemMutation
                    )
                }
                Issue.record("symlinked managed root unexpectedly deleted")
            } catch let error as WPEEngineAssetsFilesystemOwner.Error {
                #expect(error == .symbolicLinkRejected)
            }
            #expect(fm.fileExists(atPath: sentinel.path))
            #expect(SettingsManager.shared.wpeEngineAssetsManagedBuildID == "af12-build")

            try fm.removeItem(at: managed)
            try fm.createDirectory(at: managed, withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: managed.appendingPathComponent("sentinel"))
            let failingOwner = WPEEngineAssetsFilesystemOwner(
                fileManager: AF12FailingRemovalFileManager(),
                trustsContainer: trusted
            )
            do {
                _ = try await SteamCMDDoctorOperationCoordinator().withOperation(.assetsMutation) { lease in
                    try failingOwner.removeManagedInstall(
                        managedRoot: managed,
                        authorization: lease.filesystemMutation
                    )
                }
                Issue.record("failed removal unexpectedly reported success")
            } catch let error as WPEEngineAssetsFilesystemOwner.Error {
                #expect(error == .removalFailed)
            }
            #expect(fm.fileExists(atPath: managed.appendingPathComponent("sentinel").path))
            #expect(SettingsManager.shared.wpeEngineAssetsManagedBuildID == "af12-build")

            let absent = root.appendingPathComponent("absent/common/wallpaper_engine", isDirectory: true)
            let result = try await SteamCMDDoctorOperationCoordinator().withOperation(.assetsMutation) { lease in
                try owner.removeManagedInstall(
                    managedRoot: absent,
                    authorization: lease.filesystemMutation
                )
            }
            #expect(result == .alreadyAbsent)
        }

        @Test("session cleanup is off-main and refuses an internal sibling symlink")
        func sessionCleanupRejectsInternalSiblingSymlink() async throws {
            let fm = FileManager.default
            let root = temporaryRoot("session-cleanup")
            defer { try? fm.removeItem(at: root) }
            let steamRoot = root.appendingPathComponent("Steam", isDirectory: true)
            let config = steamRoot.appendingPathComponent("config", isDirectory: true)
            try fm.createDirectory(at: config, withIntermediateDirectories: true)
            let keep = config.appendingPathComponent("keep.vdf")
            try Data("keep".utf8).write(to: keep)
            let linkedConfig = config.appendingPathComponent("config.vdf")
            try fm.createSymbolicLink(at: linkedConfig, withDestinationURL: keep)
            let loginUsers = config.appendingPathComponent("loginusers.vdf")
            try Data("remove".utf8).write(to: loginUsers)
            let owner = WPEEngineAssetsFilesystemOwner(
                fileManager: fm,
                trustsContainer: { candidate in
                    candidate.standardizedFileURL.path.hasPrefix(root.path + "/")
                        || candidate.standardizedFileURL == root
                }
            )

            let outcome = try await SteamCMDDoctorOperationCoordinator()
                .withOperation(.sessionMutation) { lease in
                    await Task.detached(priority: .utility) {
                        let result = owner.clearCachedSessionFiles(
                            steamRoot: steamRoot,
                            authorization: lease.filesystemMutation
                        )
                        return (af12IsMainThread(), result)
                    }.value
                }
            #expect(!outcome.0)
            #expect(outcome.1.removed == 1)
            #expect(outcome.1.refused == 1)
            #expect(!outcome.1.succeeded)
            #expect(fm.fileExists(atPath: keep.path))
            #expect(fm.fileExists(atPath: linkedConfig.path))
            #expect(!fm.fileExists(atPath: loginUsers.path))
        }

        @Test("replacement publishes staged assets and removes recovery slots")
        func replacementTransaction() async throws {
            let fm = FileManager.default
            let root = temporaryRoot("replacement")
            defer { try? fm.removeItem(at: root) }
            let managed = managedRoot(under: root, label: "managed")
            let source = root.appendingPathComponent("source", isDirectory: true)
            try seedAssets("old", slot: "assets", managed: managed)
            try seedAssets("new", slot: "assets", managed: source)

            let transaction = transactionForTests(fileManager: fm, trustedParent: root)
            try await SteamCMDDoctorOperationCoordinator().withOperation(.appUpdate) { lease in
                _ = try transaction.replaceAssets(
                    from: source,
                    managedRoot: managed,
                    buildID: "444",
                    authorization: lease.filesystemMutation(
                        approvingSourceRoot: source
                    )
                )
            }

            #expect(try marker(in: managed.appendingPathComponent("assets")) == "new")
            #expect(!fm.fileExists(atPath: managed.appendingPathComponent("assets.incoming").path))
            #expect(!fm.fileExists(atPath: managed.appendingPathComponent("assets.previous").path))
            #expect(try String(
                contentsOf: managed.appendingPathComponent("assets", isDirectory: true)
                    .appendingPathComponent(WPEEngineAssetsTransaction.buildIDSidecarName),
                encoding: .utf8
            ) == "444")
        }

        @Test("injected identity and codesign verdict control trust without subprocesses")
        @MainActor
        func injectedTrustVerdicts() async {
            let checker = AF12TrustChecker(
                identity: "identity-1",
                result: CodesignResult(
                    teamIdentifier: "MXGJJ98X76",
                    isHardenedRuntime: true,
                    signatureValid: true
                )
            )
            let doctor = SteamCMDDoctorService(binaryTrustChecker: checker)
            let binary = URL(fileURLWithPath: "/nonexistent/injected-steamcmd")
            #expect(await doctor.ensureTrustedBinary(binary))
            #expect(await doctor.ensureTrustedBinary(binary))
            #expect(await checker.codesignCallCount == 1)

            await checker.set(
                identity: "identity-2",
                result: CodesignResult(
                    teamIdentifier: "ATTACKER",
                    isHardenedRuntime: true,
                    signatureValid: true
                )
            )
            #expect(await !(doctor.ensureTrustedBinary(binary)))
            #expect(await checker.codesignCallCount == 2)
        }

        @Test("production codesign seam uses exact argv and parses timeout fail-closed")
        func injectedProcessRunner() async {
            let runner = AF12ProcessRunner(results: [
                SteamCMDRunResult(
                    exitCode: 0,
                    stdout: "",
                    stderr: "",
                    timedOut: false,
                    killed: false
                ),
                SteamCMDRunResult(
                    exitCode: 0,
                    stdout: "",
                    stderr: "TeamIdentifier=MXGJJ98X76\nflags=0x10000(runtime)",
                    timedOut: false,
                    killed: false
                ),
            ])
            let checker = SteamCMDProductionBinaryTrustChecker(runner: runner)
            let result = await checker.codesignResult(for: URL(fileURLWithPath: "/fixture/steamcmd"))
            #expect(result.signatureValid)
            #expect(result.teamIdentifier == "MXGJJ98X76")
            #expect(result.isHardenedRuntime)
            let calls = await runner.calls
            #expect(calls.map(\.arguments) == [
                ["--verify", "--strict", "/fixture/steamcmd"],
                ["-dv", "--verbose=4", "/fixture/steamcmd"],
            ])

            let timeout = SteamCMDCodeSignatureParser.result(
                verify: SteamCMDRunResult(
                    exitCode: 0,
                    stdout: "",
                    stderr: "",
                    timedOut: true,
                    killed: true
                ),
                display: SteamCMDRunResult(
                    exitCode: 0,
                    stdout: "",
                    stderr: "TeamIdentifier=MXGJJ98X76",
                    timedOut: false,
                    killed: false
                )
            )
            #expect(!timeout.signatureValid)
        }

        @Test("runner rejects a binary replaced after Doctor trust")
        func runnerRejectsReplaceAfterCheck() async throws {
            let fm = FileManager.default
            let root = temporaryRoot("binary-replacement")
            defer { try? fm.removeItem(at: root) }
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let binary = root.appendingPathComponent("steamcmd")
            try Data("trusted-version".utf8).write(to: binary)
            let checker = SteamCMDProductionBinaryTrustChecker(
                runner: AF12ProcessRunner(results: [])
            )
            let authorization = SteamCMDBinaryExecutionAuthorization(
                canonicalPath: binary.resolvingSymlinksInPath().path,
                sha256: try await checker.identity(of: binary)
            )
            #expect(SteamCMDProcessRunner.revalidateExecutionAuthorization(
                authorization,
                for: binary
            ))

            try Data("attacker-version".utf8).write(to: binary, options: .atomic)
            #expect(!SteamCMDProcessRunner.revalidateExecutionAuthorization(
                authorization,
                for: binary
            ))
        }

        private func temporaryRoot(_ label: String) -> URL {
            FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("AF12-Lifecycle-\(label)-\(UUID().uuidString)", isDirectory: true)
        }

        private func managedRoot(under parent: URL, label: String) -> URL {
            parent.appendingPathComponent(label, isDirectory: true)
                .appendingPathComponent("common/wallpaper_engine", isDirectory: true)
        }

        private func transactionForTests(
            fileManager: FileManager,
            trustedParent: URL
        ) -> WPEEngineAssetsTransaction {
            WPEEngineAssetsTransaction(fileManager: fileManager) { candidate in
                let child = candidate.standardizedFileURL.path
                let parent = trustedParent.standardizedFileURL.path
                return child == parent || child.hasPrefix(parent + "/")
            }
        }

        private func seedAssets(_ value: String?, slot: String, managed: URL) throws {
            guard let value else { return }
            let directory = managed.appendingPathComponent(slot, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(value.utf8).write(to: directory.appendingPathComponent("marker"))
        }

        private func marker(in directory: URL) throws -> String? {
            guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
            return try String(
                contentsOf: directory.appendingPathComponent("marker"),
                encoding: .utf8
            )
        }
    }

    private actor AF12Latch {
        private var signalled = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        var isSignalled: Bool {
            signalled
        }

        func signal() {
            guard !signalled else { return }
            signalled = true
            let current = waiters
            waiters.removeAll(keepingCapacity: false)
            current.forEach { $0.resume() }
        }

        func wait() async {
            if signalled {
                return
            }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
    }

    private actor AF12LeaseBox {
        private(set) var value: SteamCMDDoctorOperationLease?

        func set(_ lease: SteamCMDDoctorOperationLease) {
            value = lease
        }
    }

    private actor AF12StringBox {
        private(set) var value: String?

        func set(_ value: String) {
            self.value = value
        }
    }

    private final class AF12FailingRemovalFileManager: FileManager, @unchecked Sendable {
        override func removeItem(at _: URL) throws {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func af12IsMainThread() -> Bool {
        Thread.isMainThread
    }

    private actor AF12TrustChecker: SteamCMDBinaryTrustChecking {
        private var storedIdentity: String
        private var storedResult: CodesignResult
        private(set) var codesignCallCount = 0

        init(identity: String, result: CodesignResult) {
            storedIdentity = identity
            storedResult = result
        }

        func identity(of _: URL) async throws -> String {
            storedIdentity
        }

        func codesignResult(for _: URL) async -> CodesignResult {
            codesignCallCount += 1
            return storedResult
        }

        func set(identity: String, result: CodesignResult) {
            storedIdentity = identity
            storedResult = result
        }
    }

    private actor AF12ProcessRunner: SteamCMDProcessRunning {
        struct Call: Sendable {
            let arguments: [String]
        }

        private var results: [SteamCMDRunResult]
        private(set) var calls: [Call] = []

        init(results: [SteamCMDRunResult]) {
            self.results = results
        }

        func run(
            binary _: URL,
            args: [String],
            stdin _: String?,
            timeout _: TimeInterval,
            workingDirectory _: URL?,
            onProgress _: SteamCMDProgressHandler?
        ) async -> SteamCMDRunResult {
            calls.append(Call(arguments: args))
            guard !results.isEmpty else {
                return SteamCMDRunResult(
                    exitCode: nil,
                    stdout: "",
                    stderr: "missing fixture",
                    timedOut: false,
                    killed: false
                )
            }
            return results.removeFirst()
        }
    }
#endif
