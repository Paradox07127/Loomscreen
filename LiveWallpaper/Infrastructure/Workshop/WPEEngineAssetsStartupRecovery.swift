#if !LITE_BUILD
    import Foundation

    /// Launch barrier for managed engine assets. It waits only for the utility-lane
    /// rename that selects `assets/`; recursive orphan cleanup is retained as a
    /// separate leased task and never delays ScreenManager construction.
    actor WPEEngineAssetsStartupRecovery {
        static let shared = WPEEngineAssetsStartupRecovery()

        private let operationCoordinator: SteamCMDDoctorOperationCoordinator
        private let filesystemOwner: WPEEngineAssetsFilesystemOwner
        private let managedRoot: URL
        private var deferredCleanupTask: Task<Void, Never>?

        init(
            operationCoordinator: SteamCMDDoctorOperationCoordinator = .shared,
            filesystemOwner: WPEEngineAssetsFilesystemOwner = WPEEngineAssetsFilesystemOwner(),
            managedRoot: URL = WPEEngineAssetsLibrary.managedContainerRoot()
        ) {
            self.operationCoordinator = operationCoordinator
            self.filesystemOwner = filesystemOwner
            self.managedRoot = managedRoot
        }

        @discardableResult
        func prepareForFirstRead() async -> WPEEngineAssetsTransaction.RecoveryAction? {
            let coordinator = operationCoordinator
            let owner = filesystemOwner
            let root = managedRoot
            let result: WPEEngineAssetsTransaction.RecoveryResult
            do {
                result = try await coordinator.withOperation(.assetsMutation) { lease in
                    try await Task.detached(priority: .utility) {
                        try owner.recoverAuthoritativeSlot(
                            managedRoot: root,
                            authorization: lease.filesystemMutation
                        )
                    }.value
                }
            } catch {
                Logger.error(
                    "Managed Wallpaper Engine asset recovery failed: \(error.localizedDescription)",
                    category: .startup
                )
                await MainActor.run {
                    SettingsManager.shared.wpeEngineAssetsManagedBuildID = nil
                }
                return nil
            }

            // Reconcile both crash cuts before ScreenManager or the assets
            // library can read a split disk/marker state: publish -> marker and
            // delete -> marker clear.
            await MainActor.run {
                switch result.action {
                case .empty:
                    if SettingsManager.shared.wpeEngineAssetsManagedBuildID != nil {
                        SettingsManager.shared.wpeEngineAssetsManagedBuildID = nil
                    }
                case .keptCurrent, .publishedIncoming, .restoredPrevious:
                    let recoveredBuildID = result.buildID
                        ?? WPEEngineAssetsLibrary.unknownManagedBuildMarker
                    if SettingsManager.shared.wpeEngineAssetsManagedBuildID != recoveredBuildID {
                        SettingsManager.shared.wpeEngineAssetsManagedBuildID = recoveredBuildID
                    }
                }
            }
            guard !result.deferredCleanup.isEmpty else { return result.action }
            let candidates = result.deferredCleanup
            deferredCleanupTask = Task(priority: .utility) {
                await Task.yield()
                do {
                    try await coordinator.withOperation(.assetsMutation) { lease in
                        await Task.detached(priority: .utility) {
                            owner.removeDeferredRecoveryItems(
                                candidates,
                                managedRoot: root,
                                authorization: lease.filesystemMutation
                            )
                        }.value
                    }
                } catch {
                    // The authoritative slot is already selected. Orphans are safe
                    // to retry on the next launch rather than blocking startup.
                }
            }
            return result.action
        }

        func waitForDeferredCleanup() async {
            await deferredCleanupTask?.value
        }
    }
#endif
