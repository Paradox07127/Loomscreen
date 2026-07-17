#if !LITE_BUILD
    import Foundation

    /// Same-volume slot selection for the managed Wallpaper Engine assets tree.
    /// Authority changes are rename-only; recursive orphan deletion belongs to
    /// `WPEEngineAssetsFilesystemOwner` and runs later on its utility lane.
    // @unchecked: FileManager isn't Sendable, but an instance with no delegate set is
    // documented safe across threads, and this type exists to run off MainActor.
    struct WPEEngineAssetsTransaction: @unchecked Sendable {
        enum RecoveryAction: Equatable, Sendable {
            case keptCurrent
            case publishedIncoming
            case restoredPrevious
            case empty
        }

        struct RecoveryResult: Equatable, Sendable {
            let action: RecoveryAction
            let deferredCleanup: [URL]
            let buildID: String?
        }

        struct ReplacementResult: Equatable, Sendable {
            let deferredCleanup: [URL]
            let buildID: String
        }

        enum TransactionError: Error, Equatable, Sendable {
            case unauthorizedMutation
            case untrustedRoot
            case untrustedSourceRoot
            case invalidCurrentWithoutRecovery
            case missingIncomingAssets
            case unsafeBuildIDSidecar
        }

        static let buildIDSidecarName = ".loomscreen-build-id"

        private let fileManager: FileManager
        private let trustsRoot: @Sendable (URL) -> Bool

        init(
            fileManager: FileManager = .default,
            trustsRoot: @escaping @Sendable (URL) -> Bool = { WPEEngineAssetsLibrary.isContainerInternal($0) }
        ) {
            self.fileManager = fileManager
            self.trustsRoot = trustsRoot
        }

        /// Establishes exactly one authoritative `assets/` directory using only
        /// same-volume renames. Large stale trees are renamed to unique orphan
        /// slots and returned to the caller for deferred off-main deletion.
        func recover(
            managedRoot: URL,
            authoritativeBuildID: String? = nil,
            authorization: SteamCMDDoctorFilesystemMutationLease
        ) throws -> RecoveryResult {
            try validate(authorization)
            let slots = try validatedSlots(managedRoot: managedRoot)
            let currentExists = existsWithoutFollowing(slots.current)
            let currentValid = isTrustedAssetsDirectory(slots.current)
            let incomingValid = isTrustedAssetsDirectory(slots.incoming)
            let previousValid = isTrustedAssetsDirectory(slots.previous)
            var cleanup = existingDeferredItems(in: slots.root)

            if currentValid {
                try deferRemovalIfPresent(slots.incoming, root: slots.root, into: &cleanup)
                try deferRemovalIfPresent(slots.previous, root: slots.root, into: &cleanup)
                return try recoveryResult(
                    action: .keptCurrent,
                    cleanup: cleanup,
                    current: slots.current,
                    authoritativeBuildID: authoritativeBuildID
                )
            }

            if currentExists {
                guard incomingValid || previousValid else {
                    throw TransactionError.invalidCurrentWithoutRecovery
                }
                try deferRemovalIfPresent(slots.current, root: slots.root, into: &cleanup)
            }

            if incomingValid {
                try fileManager.moveItem(at: slots.incoming, to: slots.current)
                try deferRemovalIfPresent(slots.previous, root: slots.root, into: &cleanup)
                return try recoveryResult(
                    action: .publishedIncoming,
                    cleanup: cleanup,
                    current: slots.current,
                    authoritativeBuildID: authoritativeBuildID
                )
            }
            if previousValid {
                try fileManager.moveItem(at: slots.previous, to: slots.current)
                try deferRemovalIfPresent(slots.incoming, root: slots.root, into: &cleanup)
                return try recoveryResult(
                    action: .restoredPrevious,
                    cleanup: cleanup,
                    current: slots.current,
                    authoritativeBuildID: authoritativeBuildID
                )
            }

            try deferRemovalIfPresent(slots.incoming, root: slots.root, into: &cleanup)
            try deferRemovalIfPresent(slots.previous, root: slots.root, into: &cleanup)
            return RecoveryResult(action: .empty, deferredCleanup: cleanup, buildID: nil)
        }

        /// Stages a downloaded `assets/`, swaps it into authority, and returns the
        /// previous/stale slots for later cleanup. No recursive deletion occurs in
        /// the publication critical section.
        func replaceAssets(
            from sourceRoot: URL,
            managedRoot: URL,
            buildID: String?,
            authorization: SteamCMDDoctorFilesystemMutationLease
        ) throws -> ReplacementResult {
            try validate(authorization)
            guard authorization.kind == .appUpdate,
                  authorization.approvesSourceRoot(sourceRoot) else {
                throw TransactionError.untrustedSourceRoot
            }
            let sourceRoot = try validatedSourceRoot(sourceRoot)
            let slots = try validatedSlots(managedRoot: managedRoot)
            var cleanup = try recover(
                managedRoot: managedRoot,
                authorization: authorization
            ).deferredCleanup

            let source = sourceRoot.appendingPathComponent("assets", isDirectory: true)
            guard isTrustedAssetsDirectory(source) else {
                throw TransactionError.missingIncomingAssets
            }
            let committedBuildID = Self.normalizedBuildID(buildID)
            try writeBuildID(committedBuildID, to: source)
            try fileManager.createDirectory(at: slots.root, withIntermediateDirectories: true)
            try fileManager.moveItem(at: source, to: slots.incoming)
            if existsWithoutFollowing(slots.current) {
                try fileManager.moveItem(at: slots.current, to: slots.previous)
            }
            do {
                try fileManager.moveItem(at: slots.incoming, to: slots.current)
            } catch {
                if !existsWithoutFollowing(slots.current),
                   isTrustedAssetsDirectory(slots.previous) {
                    try? fileManager.moveItem(at: slots.previous, to: slots.current)
                }
                throw error
            }
            try deferRemovalIfPresent(slots.previous, root: slots.root, into: &cleanup)
            return ReplacementResult(
                deferredCleanup: cleanup,
                buildID: committedBuildID
            )
        }

        static func normalizedBuildID(_ buildID: String?) -> String {
            guard let buildID,
                  !buildID.isEmpty,
                  buildID.count <= 64,
                  buildID.utf8.allSatisfy({ (48 ... 57).contains($0) }) else {
                return WPEEngineAssetsLibrary.unknownManagedBuildMarker
            }
            return buildID
        }

        func removeDeferredItems(
            _ candidates: [URL],
            managedRoot: URL,
            authorization: SteamCMDDoctorFilesystemMutationLease
        ) {
            guard (try? validate(authorization)) != nil,
                  let slots = try? validatedSlots(managedRoot: managedRoot) else { return }
            let rootPath = slots.root.standardizedFileURL.path(percentEncoded: false)
            for candidate in candidates {
                let literal = candidate.standardizedFileURL
                guard literal.deletingLastPathComponent().path(percentEncoded: false) == rootPath,
                      deferredOrphanID(for: literal) != nil,
                      let values = try? literal.resourceValues(forKeys: [.isSymbolicLinkKey]),
                      values.isSymbolicLink != true else { continue }
                try? fileManager.removeItem(at: literal)
            }
        }

        private func validate(
            _ authorization: SteamCMDDoctorFilesystemMutationLease
        ) throws {
            guard authorization.isActive,
                  authorization.kind == .appUpdate || authorization.kind == .assetsMutation else {
                throw TransactionError.unauthorizedMutation
            }
        }

        private func recoveryResult(
            action: RecoveryAction,
            cleanup: [URL],
            current: URL,
            authoritativeBuildID: String?
        ) throws -> RecoveryResult {
            let buildID: String
            if let authoritativeBuildID {
                buildID = Self.normalizedBuildID(authoritativeBuildID)
                try writeBuildID(buildID, to: current)
            } else if let stored = readBuildID(from: current) {
                buildID = stored
            } else {
                buildID = WPEEngineAssetsLibrary.unknownManagedBuildMarker
                try writeBuildID(buildID, to: current)
            }
            return RecoveryResult(
                action: action,
                deferredCleanup: cleanup,
                buildID: buildID
            )
        }

        private func readBuildID(from assets: URL) -> String? {
            let sidecar = assets.appendingPathComponent(Self.buildIDSidecarName)
            guard let values = try? sidecar.resourceValues(forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ]),
                values.isRegularFile == true,
                values.isSymbolicLink != true,
                let size = values.fileSize,
                size > 0,
                size <= 64,
                let value = try? String(contentsOf: sidecar, encoding: .utf8) else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return Self.normalizedBuildID(trimmed) == trimmed ? trimmed : nil
        }

        private func writeBuildID(_ buildID: String, to assets: URL) throws {
            let sidecar = assets.appendingPathComponent(Self.buildIDSidecarName)
            if existsWithoutFollowing(sidecar) {
                guard let values = try? sidecar.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ]),
                    values.isRegularFile == true,
                    values.isSymbolicLink != true else {
                    throw TransactionError.unsafeBuildIDSidecar
                }
            }
            do {
                try Data(buildID.utf8).write(to: sidecar, options: .atomic)
            } catch {
                throw TransactionError.unsafeBuildIDSidecar
            }
        }

        /// Finds only direct, non-symlink orphan slots produced by this
        /// transaction. A later launch can resume cleanup without traversing a
        /// link or accepting a merely similar filename.
        private func existingDeferredItems(in root: URL) -> [URL] {
            guard let children = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isSymbolicLinkKey],
                options: []
            ) else { return [] }
            return children.filter { child in
                guard deferredOrphanID(for: child) != nil,
                      let values = try? child.resourceValues(forKeys: [.isSymbolicLinkKey]) else {
                    return false
                }
                return values.isSymbolicLink != true
            }
        }

        private func deferredOrphanID(for url: URL) -> UUID? {
            let prefix = "assets.orphan."
            let name = url.lastPathComponent
            guard name.hasPrefix(prefix) else { return nil }
            return UUID(uuidString: String(name.dropFirst(prefix.count)))
        }

        private func deferRemovalIfPresent(
            _ url: URL,
            root: URL,
            into cleanup: inout [URL]
        ) throws {
            guard existsWithoutFollowing(url) else { return }
            let orphan = root.appendingPathComponent(
                "assets.orphan.\(UUID().uuidString)",
                isDirectory: true
            )
            try fileManager.moveItem(at: url, to: orphan)
            cleanup.append(orphan)
        }

        private func validatedSlots(managedRoot: URL) throws -> (
            root: URL,
            current: URL,
            incoming: URL,
            previous: URL
        ) {
            let literal = managedRoot.standardizedFileURL
            let root = literal.resolvingSymlinksInPath()
            guard literalPath(literal) == literalPath(root),
                  trustsRoot(literal),
                  root.lastPathComponent == "wallpaper_engine",
                  root.deletingLastPathComponent().lastPathComponent == "common" else {
                throw TransactionError.untrustedRoot
            }
            return (
                root,
                // Do not attach a directory resource hint here. Recovery must
                // also see a corrupt regular file occupying one of these slot
                // names so it can move that entry aside without following it.
                root.appendingPathComponent("assets"),
                root.appendingPathComponent("assets.incoming"),
                root.appendingPathComponent("assets.previous")
            )
        }

        private func validatedSourceRoot(_ sourceRoot: URL) throws -> URL {
            let literal = sourceRoot.standardizedFileURL
            let resolved = literal.resolvingSymlinksInPath()
            guard literalPath(literal) == literalPath(resolved),
                  let values = try? literal.resourceValues(forKeys: [
                      .isDirectoryKey,
                      .isSymbolicLinkKey,
                  ]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true else {
                throw TransactionError.untrustedSourceRoot
            }
            return literal
        }

        private func isTrustedAssetsDirectory(_ url: URL) -> Bool {
            guard let values = try? url.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ]),
                values.isDirectory == true,
                values.isRegularFile != true,
                values.isSymbolicLink != true,
                let contents = try? fileManager.contentsOfDirectory(atPath: url.path(percentEncoded: false)),
                contents.contains(where: { $0 != Self.buildIDSidecarName }) else { return false }
            return true
        }

        private func literalPath(_ url: URL) -> String {
            var path = url.standardizedFileURL.path(percentEncoded: false)
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            return path
        }

        private func existsWithoutFollowing(_ url: URL) -> Bool {
            let path = url.path(percentEncoded: false)
            return fileManager.fileExists(atPath: path)
                || (try? fileManager.destinationOfSymbolicLink(atPath: path)) != nil
        }
    }
#endif
