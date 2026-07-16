#if !LITE_BUILD
    import Foundation

    /// The sole entry point for destructive managed-assets and SteamCMD app-state
    /// filesystem work. Every method requires a capability minted by the FIFO
    /// operation owner; callers run these synchronous operations off MainActor.
    // @unchecked: FileManager isn't Sendable, but an instance with no delegate set is
    // documented safe across threads, and this type exists to run off MainActor.
    struct WPEEngineAssetsFilesystemOwner: @unchecked Sendable {
        enum Error: Swift.Error, Equatable, Sendable {
            case unauthorizedMutation
            case notContainerInternal
            case unexpectedLayout
            case missingAssets
            case symbolicLinkRejected
            case identityChanged
            case removalFailed
            case removalPostconditionFailed
        }

        enum RemovalResult: Equatable, Sendable {
            case removed
            case alreadyAbsent
        }

        struct CommitResult: Equatable, Sendable {
            let buildID: String
            let deferredCleanup: [URL]
        }

        struct SessionCleanupResult: Equatable, Sendable {
            let removed: Int
            let refused: Int
            let failed: Int

            var succeeded: Bool { refused == 0 && failed == 0 }
        }

        private enum LiteralRemovalResult {
            case absent
            case removed
            case refused
            case failed
        }

        nonisolated static let wpeAppID = 431_960

        private let fileManager: FileManager
        private let transaction: WPEEngineAssetsTransaction
        private let trustsContainer: @Sendable (URL) -> Bool

        init(
            fileManager: FileManager = .default,
            transaction: WPEEngineAssetsTransaction? = nil,
            trustsContainer: @escaping @Sendable (URL) -> Bool = {
                WPEEngineAssetsLibrary.isContainerInternal($0)
            }
        ) {
            self.fileManager = fileManager
            self.transaction = transaction ?? WPEEngineAssetsTransaction(fileManager: fileManager)
            self.trustsContainer = trustsContainer
        }

        func recoverAuthoritativeSlot(
            managedRoot: URL,
            authorization: SteamCMDDoctorFilesystemMutationLease
        ) throws -> WPEEngineAssetsTransaction.RecoveryResult {
            try transaction.recover(
                managedRoot: managedRoot,
                authorization: authorization
            )
        }

        /// Cancellation is checked by the caller before entering this method. From
        /// the first rename onward publication is a non-cancellable commit: disk,
        /// marker and observable state must be completed as one logical result.
        func commitAndPrune(
            installRoot: URL,
            managedRoot: URL = WPEEngineAssetsLibrary.managedContainerRoot(),
            buildID: String?,
            authorization: SteamCMDDoctorFilesystemMutationLease
        ) throws -> CommitResult {
            guard authorization.isActive,
                  authorization.kind == .appUpdate else { throw Error.unauthorizedMutation }
            try validateManagedRootLiteralIfPresent(managedRoot)
            if WPEEngineAssetsLibrary.canonicalPath(installRoot)
                != WPEEngineAssetsLibrary.canonicalPath(managedRoot) {
                let replacement = try transaction.replaceAssets(
                    from: installRoot,
                    managedRoot: managedRoot,
                    buildID: buildID,
                    authorization: authorization
                )
                return CommitResult(
                    buildID: replacement.buildID,
                    deferredCleanup: replacement.deferredCleanup
                )
            } else {
                let recovery = try transaction.recover(
                    managedRoot: managedRoot,
                    authoritativeBuildID: WPEEngineAssetsTransaction.normalizedBuildID(buildID),
                    authorization: authorization
                )
                guard let recoveredBuildID = recovery.buildID else {
                    throw Error.missingAssets
                }
                return CommitResult(
                    buildID: recoveredBuildID,
                    deferredCleanup: recovery.deferredCleanup
                )
            }
        }

        /// Runs only after the caller has published the durable marker. A crash
        /// before this phase leaves an authoritative sidecar-backed `assets/`
        /// slot and retryable orphan/app-state cleanup, never a split marker.
        func cleanupAfterCommit(
            _ commit: CommitResult,
            managedRoot: URL = WPEEngineAssetsLibrary.managedContainerRoot(),
            authorization: SteamCMDDoctorFilesystemMutationLease
        ) throws {
            guard authorization.isActive,
                  authorization.kind == .appUpdate else { throw Error.unauthorizedMutation }
            transaction.removeDeferredItems(
                commit.deferredCleanup,
                managedRoot: managedRoot,
                authorization: authorization
            )
            try pruneToAssets(installRoot: managedRoot, authorization: authorization)
            cleanupSteamCMDAppState(authorization: authorization)
        }

        func removeManagedInstall(
            managedRoot: URL = WPEEngineAssetsLibrary.managedContainerRoot(),
            authorization: SteamCMDDoctorFilesystemMutationLease
        ) throws -> RemovalResult {
            guard authorization.isActive,
                  authorization.kind == .assetsMutation else { throw Error.unauthorizedMutation }
            let root = managedRoot.standardizedFileURL
            guard trustsContainer(root.deletingLastPathComponent()),
                  root.lastPathComponent == "wallpaper_engine",
                  root.deletingLastPathComponent().lastPathComponent == "common" else {
                throw Error.unexpectedLayout
            }
            guard existsWithoutFollowing(root) else { return .alreadyAbsent }
            guard literalPath(root) == literalPath(root.resolvingSymlinksInPath()) else {
                throw Error.symbolicLinkRejected
            }
            guard let original = literalIdentity(at: root) else {
                throw Error.symbolicLinkRejected
            }
            guard original.isDirectory else { throw Error.unexpectedLayout }
            guard let current = literalIdentity(at: root), original.matches(current) else {
                throw Error.identityChanged
            }
            do {
                try fileManager.removeItem(at: root)
            } catch {
                throw Error.removalFailed
            }
            guard !existsWithoutFollowing(root) else {
                throw Error.removalPostconditionFailed
            }
            return .removed
        }

        func removeDeferredRecoveryItems(
            _ candidates: [URL],
            managedRoot: URL,
            authorization: SteamCMDDoctorFilesystemMutationLease
        ) {
            guard authorization.isActive,
                  authorization.kind == .assetsMutation
                    || authorization.kind == .appUpdate else { return }
            transaction.removeDeferredItems(
                candidates,
                managedRoot: managedRoot,
                authorization: authorization
            )
        }

        /// Deletes only SteamCMD bookkeeping for app 431960. Workshop inventory,
        /// cached login and the authoritative `common/wallpaper_engine/assets`
        /// directory are deliberately outside this target set.
        func cleanupSteamCMDAppState(
            steamApps suppliedSteamApps: URL? = nil,
            authorization: SteamCMDDoctorFilesystemMutationLease
        ) {
            guard authorization.isActive,
                  authorization.kind == .ownershipValidation || authorization.kind == .appUpdate else { return }
            let steamApps = suppliedSteamApps ?? containerSteamApps()
            guard let steamApps else { return }
            var targets = [
                steamApps.appendingPathComponent("appmanifest_\(Self.wpeAppID).acf", isDirectory: false),
                steamApps.appendingPathComponent("downloading/\(Self.wpeAppID)", isDirectory: true),
            ]
            let downloadingRoot = steamApps.appendingPathComponent("downloading", isDirectory: true)
            if let children = try? fileManager.contentsOfDirectory(
                at: downloadingRoot,
                includingPropertiesForKeys: nil
            ) {
                targets += children.filter { $0.lastPathComponent.hasPrefix("state_\(Self.wpeAppID)_") }
            }
            for target in targets {
                _ = removeLiteralItemIfSafe(target, containedIn: steamApps)
            }
        }

        /// Revokes only container-local SteamCMD credentials. Every candidate is
        /// a literal entry below a non-aliased parent, rejects final symlinks, and
        /// is identity-revalidated immediately before deletion.
        func clearCachedSessionFiles(
            steamRoot suppliedSteamRoot: URL? = nil,
            authorization: SteamCMDDoctorFilesystemMutationLease
        ) -> SessionCleanupResult {
            guard authorization.isActive,
                  authorization.kind == .sessionMutation else {
                return SessionCleanupResult(removed: 0, refused: 1, failed: 0)
            }
            guard let steamRoot = suppliedSteamRoot ?? containerSteamRoot() else {
                return SessionCleanupResult(removed: 0, refused: 0, failed: 1)
            }
            let literalRoot = steamRoot.standardizedFileURL
            guard literalPath(literalRoot) == literalPath(literalRoot.resolvingSymlinksInPath()),
                  trustsContainer(literalRoot) else {
                return SessionCleanupResult(removed: 0, refused: 1, failed: 0)
            }
            let config = literalRoot.appendingPathComponent("config", isDirectory: true)
            var targets = [
                config.appendingPathComponent("config.vdf", isDirectory: false),
                config.appendingPathComponent("loginusers.vdf", isDirectory: false),
            ]
            for directory in [literalRoot, config] {
                if let children = try? fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isSymbolicLinkKey]
                ) {
                    targets += children.filter { $0.lastPathComponent.hasPrefix("ssfn") }
                }
            }

            var removed = 0
            var refused = 0
            var failed = 0
            for target in targets {
                switch removeLiteralItemIfSafe(target, containedIn: literalRoot) {
                case .absent: break
                case .removed: removed += 1
                case .refused: refused += 1
                case .failed: failed += 1
                }
            }
            return SessionCleanupResult(
                removed: removed,
                refused: refused,
                failed: failed
            )
        }

        func pruneToAssets(
            installRoot: URL,
            authorization: SteamCMDDoctorFilesystemMutationLease
        ) throws {
            guard authorization.isActive,
                  authorization.kind == .appUpdate else { throw Error.unauthorizedMutation }
            let root = installRoot.standardizedFileURL
            guard trustsContainer(root) else {
                throw Error.notContainerInternal
            }
            guard root.lastPathComponent == "wallpaper_engine",
                  root.deletingLastPathComponent().lastPathComponent == "common" else {
                throw Error.unexpectedLayout
            }
            guard existsWithoutFollowing(root),
                  literalPath(root) == literalPath(root.resolvingSymlinksInPath()),
                  let originalRoot = literalIdentity(at: root),
                  originalRoot.isDirectory else { throw Error.symbolicLinkRejected }
            let assets = root.appendingPathComponent("assets", isDirectory: true)
            guard isNonEmptyDirectory(assets) else { throw Error.missingAssets }
            guard let currentRoot = literalIdentity(at: root),
                  originalRoot.matches(currentRoot) else { throw Error.identityChanged }

            let children = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: []
            )
            for child in children where child.lastPathComponent != "assets" {
                _ = removeLiteralItemIfSafe(child, containedIn: root)
            }
        }

        private struct LiteralIdentity {
            let identifier: NSObject
            let isDirectory: Bool

            func matches(_ other: LiteralIdentity) -> Bool {
                isDirectory == other.isDirectory && identifier.isEqual(other.identifier)
            }
        }

        /// Captures the literal directory entry without accepting a symlink.
        /// The identifier is sampled again immediately before recursive removal
        /// so a replaced entry fails closed rather than deleting its successor.
        private func literalIdentity(at url: URL) -> LiteralIdentity? {
            guard let values = try? url.resourceValues(forKeys: [
                .fileResourceIdentifierKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ]),
                values.isSymbolicLink != true,
                let identifier = values.fileResourceIdentifier as? NSObject else { return nil }
            return LiteralIdentity(
                identifier: identifier,
                isDirectory: values.isDirectory == true
            )
        }

        private func removeLiteralItemIfSafe(
            _ candidate: URL,
            containedIn parent: URL
        ) -> LiteralRemovalResult {
            let literal = candidate.standardizedFileURL
            let safeParent = parent.standardizedFileURL.resolvingSymlinksInPath()
            let literalParent = literal.deletingLastPathComponent().standardizedFileURL
            let resolvedParent = literalParent.resolvingSymlinksInPath()
            let safeParentPath = literalPath(safeParent)
            let resolvedParentPath = literalPath(resolvedParent)
            guard literalPath(literalParent) == resolvedParentPath,
                  resolvedParentPath == safeParentPath
                    || resolvedParentPath.hasPrefix(safeParentPath + "/"),
                  trustsContainer(safeParent) else { return .refused }
            guard existsWithoutFollowing(literal) else { return .absent }
            guard let original = literalIdentity(at: literal) else { return .refused }
            guard let current = literalIdentity(at: literal),
                  original.matches(current) else { return .failed }
            do {
                try fileManager.removeItem(at: literal)
            } catch {
                return .failed
            }
            return existsWithoutFollowing(literal) ? .failed : .removed
        }

        private func validateManagedRootLiteralIfPresent(_ managedRoot: URL) throws {
            let root = managedRoot.standardizedFileURL
            guard root.lastPathComponent == "wallpaper_engine",
                  root.deletingLastPathComponent().lastPathComponent == "common",
                  trustsContainer(root.deletingLastPathComponent()) else {
                throw Error.unexpectedLayout
            }
            guard existsWithoutFollowing(root) else { return }
            guard literalPath(root) == literalPath(root.resolvingSymlinksInPath()),
                  let original = literalIdentity(at: root),
                  original.isDirectory else { throw Error.symbolicLinkRejected }
            guard let current = literalIdentity(at: root), original.matches(current) else {
                throw Error.identityChanged
            }
        }

        private func existsWithoutFollowing(_ url: URL) -> Bool {
            let path = url.path(percentEncoded: false)
            return fileManager.fileExists(atPath: path)
                || (try? fileManager.destinationOfSymbolicLink(atPath: path)) != nil
        }

        private func literalPath(_ url: URL) -> String {
            var path = url.standardizedFileURL.path(percentEncoded: false)
            while path.count > 1, path.hasSuffix("/") {
                path.removeLast()
            }
            return path
        }

        private func containerSteamApps() -> URL? {
            guard let appSupport = try? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            ) else { return nil }
            return appSupport.appendingPathComponent("Steam/steamapps", isDirectory: true)
        }

        private func containerSteamRoot() -> URL? {
            guard let appSupport = try? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            ) else { return nil }
            return appSupport.appendingPathComponent("Steam", isDirectory: true)
        }

        private func isNonEmptyDirectory(_ url: URL) -> Bool {
            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(
                atPath: url.path(percentEncoded: false),
                isDirectory: &isDirectory
            ), isDirectory.boolValue else { return false }
            let contents = (try? fileManager.contentsOfDirectory(
                atPath: url.path(percentEncoded: false)
            )) ?? []
            return !contents.isEmpty
        }
    }
#endif
