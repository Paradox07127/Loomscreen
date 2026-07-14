#if !LITE_BUILD
import SwiftUI

extension WPECacheManagementView {
    func refreshStats() async {
        isLoading = true
        isLoadingInventory = true
        let snapshot = await cache.stats()
        stats = snapshot
        reachableIDs = WPESceneReachability.referencedWorkshopIDs()
        cacheEntryTitles = Dictionary(
            SettingsManager.shared.loadGlobalSettings().recentWPEImports.map { ($0.origin.workshopID, $0.origin.title) },
            uniquingKeysWith: { first, _ in first }
        )
        isLoading = false
        inventory = await Task.detached { WPEStorageInventory.compute() }.value
        projectItems = projectRowItems(inventory?.projects ?? [])
        isLoadingInventory = false
        #if DIRECT_DISTRIBUTION
        let cachedIDs = await cache.listCompletedWorkshopIDs()
            .subtracting(WPESceneReachability.packageBackedWorkshopIDs())
        reclaimableArchiveBytes = await Task.detached {
            WPEDownloadArchiveReclaimer().reclaimableBytes(cachedIDs: cachedIDs)
        }.value
        workshopCacheBytes = await workshopServices.queryCache.sizeBytes()
        #endif
        await refreshVideoStats()
    }

    private func refreshVideoStats() async {
        isLoadingVideo = true
        videoStats = await WPEVideoTextureDiskCache.shared.stats()
        isLoadingVideo = false
    }

    private func purgeVideoCache() async {
        let freed = await WPEVideoTextureDiskCache.shared.purgeAll()
        lastVideoFreedBytes = freed
        await refreshVideoStats()
    }

    private func clearAllCaches() async {
        lastFreedBytes = await cache.purgeAll()
        lastVideoFreedBytes = await WPEVideoTextureDiskCache.shared.purgeAll()
        #if DIRECT_DISTRIBUTION
        await workshopServices.queryCache.clear()
        #endif
        await refreshStats()
        NotificationCenter.default.post(name: .wpeHistoryDidChange, object: nil)
    }

    private func purgeAll() async {
        let freed = await cache.purgeAll()
        lastFreedBytes = freed
        await refreshStats()
        NotificationCenter.default.post(name: .wpeHistoryDidChange, object: nil)
    }

    private func purgeOne(_ workshopID: String) async {
        do {
            try await cache.purge(workshopID: workshopID)
            await refreshStats()
            NotificationCenter.default.post(name: .wpeHistoryDidChange, object: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func purgeOlderThan(days: Int) async {
        let cutoff = Date().addingTimeInterval(TimeInterval(-days * 86_400))
        let freed = await cache.purgeOlderThan(cutoff, keepingIDs: reachableIDs)
        lastFreedBytes = freed
        await refreshStats()
        NotificationCenter.default.post(name: .wpeHistoryDidChange, object: nil)
    }

    func confirmPurgeOlderThan(days: Int) {
        let candidates = unusedCandidates(olderThanDays: days)
        let totalBytes = candidates.reduce(UInt64(0)) { $0 + $1.sizeBytes }
        let size = byteFormatter.string(fromByteCount: Int64(totalBytes))
        pendingDestructive = PendingDestructive(
            .clearUnusedWallpapers(itemCount: candidates.count, byteSize: size)
        ) {
            Task { await purgeOlderThan(days: days) }
        }
    }

    func confirmClearAll() {
        let entries = stats?.entries ?? []
        let totalBytes = entries.reduce(UInt64(0)) { $0 + $1.sizeBytes }
        let size = byteFormatter.string(fromByteCount: Int64(totalBytes))
        pendingDestructive = PendingDestructive(
            .clearAllWPECache(projectCount: entries.count, byteSize: size)
        ) {
            Task { await purgeAll() }
        }
    }

    func confirmClearAllCaches() {
        let size = byteFormatter.string(fromByteCount: Int64(totalBytes))
        pendingDestructive = PendingDestructive(.clearAllStorageCaches(byteSize: size)) {
            Task { await clearAllCaches() }
        }
    }

    func confirmPurgeVideoCache() {
        let bytes = videoStats?.totalBytes ?? 0
        let size = byteFormatter.string(fromByteCount: Int64(bytes))
        pendingDestructive = PendingDestructive(.clearSceneVideoCache(byteSize: size)) {
            Task { await purgeVideoCache() }
        }
    }

    func confirmPurge(entry: WPECacheStats.Entry) {
        let workshopID = entry.workshopID
        pendingDestructive = PendingDestructive(
            .removeWPECacheEntry(displayName: displayTitle(for: workshopID))
        ) {
            Task { await purgeOne(workshopID) }
        }
    }
}
#endif
