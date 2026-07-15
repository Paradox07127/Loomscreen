#if !LITE_BUILD
import SwiftUI

extension WPECacheManagementView {
    /// Only legacy imports reach this section — ones an older build unpacked into
    /// `wpe-cache` and whose runtime renders from that copy, leaving the source
    /// `.pkg` redundant. Reclaiming moves it to the Trash (recoverable); an
    /// import that reads its archive in place is filtered out upstream.
    /// Pro/direct-distribution only (Lite has no SteamCMD).
    @ViewBuilder
    var reclaimArchivesSection: some View {
        #if DIRECT_DISTRIBUTION
        if reclaimableArchiveBytes > 0 {
            Section {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(byteFormatter.string(fromByteCount: reclaimableArchiveBytes))
                            .font(DesignTokens.Typography.pageTitle)
                        Text("Source archives from older imports that were unpacked into your cache.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button {
                        Task { await reclaimArchives() }
                    } label: {
                        Label("Reclaim download archives", systemImage: "internaldrive")
                    }
                    .controlSize(.small)
                    StorageInfoButton {
                        infoNote("Moves the source .pkg of legacy imports (already unpacked into the cache) to the Trash (recoverable). Wallpapers that read in place from their source are left untouched.")
                    }
                }
            } header: {
                Text("Reclaimable Download Archives")
            } footer: {
                if let last = lastReclaimedBytes, last > 0 {
                    Text("Freed \(Int64(last), format: .byteCount(style: .file)).", comment: "WPE download-archive reclaim footer after freeing space. Placeholder is the freed byte total.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        #endif
    }

    #if DIRECT_DISTRIBUTION
    private func reclaimArchives() async {
        let cachedIDs = await cache.listCompletedWorkshopIDs()
            .subtracting(WPESceneReachability.packageBackedWorkshopIDs())
        let result = await Task.detached {
            WPEDownloadArchiveReclaimer().reclaim(cachedIDs: cachedIDs)
        }.value
        lastReclaimedBytes = UInt64(max(0, result.bytes))
        reclaimableArchiveBytes = 0
        await refreshStats()
    }

    #endif
}
#endif
