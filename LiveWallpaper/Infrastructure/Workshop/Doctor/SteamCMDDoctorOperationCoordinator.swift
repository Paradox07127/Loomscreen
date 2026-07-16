#if !LITE_BUILD
    import Foundation

    enum SteamCMDDoctorOperationKind: String, Sendable {
        case ownershipValidation
        case appUpdate
        case assetsMutation
        case workshopDownload
        case workshopCleanup
        case sessionMutation
    }

    enum SteamCMDDoctorOperationError: Error, Equatable, Sendable {
        case nestedConflict(
            active: SteamCMDDoctorOperationKind,
            requested: SteamCMDDoctorOperationKind
        )
    }

    fileprivate final class SteamCMDDoctorOperationValidity: @unchecked Sendable {
        private let lock = NSLock()
        private var active = true

        func invalidate() {
            lock.lock()
            active = false
            lock.unlock()
        }

        func isActive() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return active
        }
    }

    struct SteamCMDDoctorOperationLease: Equatable, Sendable {
        let id: UUID
        let generation: UInt64
        let kind: SteamCMDDoctorOperationKind
        fileprivate let validity: SteamCMDDoctorOperationValidity

        var filesystemMutation: SteamCMDDoctorFilesystemMutationLease {
            SteamCMDDoctorFilesystemMutationLease(
                operationID: id,
                generation: generation,
                kind: kind,
                validity: validity,
                approvedSourceRootLiteralPath: nil
            )
        }

        func filesystemMutation(
            approvingSourceRoot sourceRoot: URL
        ) -> SteamCMDDoctorFilesystemMutationLease {
            SteamCMDDoctorFilesystemMutationLease(
                operationID: id,
                generation: generation,
                kind: kind,
                validity: validity,
                approvedSourceRootLiteralPath: Self.literalPath(sourceRoot)
            )
        }

        private static func literalPath(_ url: URL) -> String {
            var path = url.standardizedFileURL.path(percentEncoded: false)
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            return path
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id == rhs.id
                && lhs.generation == rhs.generation
                && lhs.kind == rhs.kind
        }
    }

    /// Capability handed only to code already executing inside the operation
    /// owner's FIFO. Destructive filesystem APIs require this value so a caller
    /// cannot accidentally bypass the subprocess-to-publication transaction.
    struct SteamCMDDoctorFilesystemMutationLease: Equatable, Sendable {
        fileprivate let operationID: UUID
        fileprivate let generation: UInt64
        let kind: SteamCMDDoctorOperationKind
        fileprivate let validity: SteamCMDDoctorOperationValidity
        fileprivate let approvedSourceRootLiteralPath: String?

        var isActive: Bool { validity.isActive() }

        func approvesSourceRoot(_ sourceRoot: URL) -> Bool {
            guard let approvedSourceRootLiteralPath else { return false }
            var candidate = sourceRoot.standardizedFileURL.path(percentEncoded: false)
            while candidate.count > 1, candidate.hasSuffix("/") { candidate.removeLast() }
            return candidate == approvedSourceRootLiteralPath
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.operationID == rhs.operationID
                && lhs.generation == rhs.generation
                && lhs.kind == rhs.kind
                && lhs.approvedSourceRootLiteralPath == rhs.approvedSourceRootLiteralPath
        }
    }

    /// Owns filesystem-sensitive Doctor work that extends beyond one subprocess.
    /// The process runner's gate prevents simultaneous children, while this owner
    /// keeps preflight cleanup and post-process asset publication in the same FIFO
    /// transaction as the command that produced them.
    actor SteamCMDDoctorOperationCoordinator {
        static let shared = SteamCMDDoctorOperationCoordinator()

        private let gate = AsyncSemaphore(value: 1)
        private var generation: UInt64 = 0
        private var activeLease: SteamCMDDoctorOperationLease?

        func withOperation<T: Sendable>(
            _ kind: SteamCMDDoctorOperationKind,
            inheriting inherited: SteamCMDDoctorOperationLease? = nil,
            _ operation: @Sendable (SteamCMDDoctorOperationLease) async throws -> T
        ) async throws -> T {
            if let inherited {
                guard inherited.kind == kind else {
                    throw SteamCMDDoctorOperationError.nestedConflict(
                        active: inherited.kind,
                        requested: kind
                    )
                }
                guard activeLease == inherited else { throw CancellationError() }
                return try await operation(inherited)
            }

            try await gate.acquire()
            do {
                try Task.checkCancellation()
            } catch {
                gate.release()
                throw error
            }
            generation &+= 1
            let lease = SteamCMDDoctorOperationLease(
                id: UUID(),
                generation: generation,
                kind: kind,
                validity: SteamCMDDoctorOperationValidity()
            )
            activeLease = lease
            defer {
                lease.validity.invalidate()
                if activeLease == lease {
                    activeLease = nil
                    gate.release()
                }
            }
            return try await operation(lease)
        }

        func isCurrent(_ lease: SteamCMDDoctorOperationLease) -> Bool {
            activeLease == lease
        }
    }
#endif
