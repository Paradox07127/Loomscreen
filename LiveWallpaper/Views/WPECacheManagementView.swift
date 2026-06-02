#if !LITE_BUILD
import SwiftUI
import AppKit

/// Settings panel section for browsing and pruning the Wallpaper Engine
/// extracted-package cache. Stats are computed off the actor so the UI never
/// blocks on filesystem walks; destructive operations always confirm first.
@MainActor
struct WPECacheManagementView: View {
    @State private var stats: WPECacheStats?
    @State private var isLoading: Bool = true
    @State private var lastFreedBytes: UInt64?
    @State private var errorMessage: String?
    @State private var pendingDestructive: PendingDestructive?
    @State private var videoStats: WPEVideoCacheStats?
    @State private var isLoadingVideo: Bool = true
    @State private var showingVideoClearConfirmation: Bool = false
    @State private var lastVideoFreedBytes: UInt64?

    private let cache: WallpaperEngineCache

    init(cache: WallpaperEngineCache = WallpaperEngineCache()) {
        self.cache = cache
    }

    var body: some View {
        Form {
            Section {
                summaryRow
            } header: {
                HStack {
                    Text("Imported Project Cache")
                    Spacer()
                    if let stats {
                        Text(verbatim: "\(byteFormatter.string(fromByteCount: Int64(stats.totalBytes))) · \(stats.entries.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(Text("Cache totals \(byteFormatter.string(fromByteCount: Int64(stats.totalBytes))) across \(stats.entries.count) projects"))
                    }
                }
            } footer: {
                if let last = lastFreedBytes, last > 0 {
                    Text("Freed \(Int64(last), format: .byteCount(style: .file)).", comment: "WPE cache management footer shown after a purge. Placeholder is the freed byte total, rendered through SwiftUI's byteCount format style.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let stats, !stats.entries.isEmpty {
                Section {
                    ForEach(stats.entries) { entry in
                        cacheRow(for: entry)
                    }
                } header: {
                    Text("Cached Projects (\(stats.entries.count))")
                }

                Section {
                    HStack(spacing: 12) {
                        Button(role: .destructive) {
                            confirmClearAll()
                        } label: {
                            Label("Clear All", systemImage: "trash")
                        }
                        .destructiveControlTint()
                        .controlSize(.regular)

                        Button {
                            confirmPurgeOlderThan(days: 30)
                        } label: {
                            Label("Clear Unused > 30 days", systemImage: "calendar.badge.minus")
                        }
                        .destructiveControlTint()
                        .controlSize(.regular)
                        .disabled(stats.entries.allSatisfy { ($0.lastUsed ?? .distantPast) > Date().addingTimeInterval(-30 * 86_400) })

                        Spacer()
                    }
                } footer: {
                    if isOversized {
                        Label("Cache is using more than 1 GB. Consider clearing unused projects.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            videoCacheSection
        }
        .settingsFormChrome()
        .onAppear { Task { await refreshStats() } }
        .onReceive(NotificationCenter.default.publisher(for: .wpeHistoryDidChange)) { _ in
            Task { await refreshStats() }
        }
        .confirmDestructive($pendingDestructive)
        .confirmationDialog(
            "Clear scene video texture cache?",
            isPresented: $showingVideoClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) {
                Task { await purgeVideoCache() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes every extracted video file. Each scene re-extracts its video the next time it renders.")
        }
        .errorAlert("Cache Error", message: $errorMessage)
    }

    /// Surfaces the `wpe-tex-video` folder's *actual* on-disk footprint (the
    /// `du`-equivalent), which previously went uncounted in Settings.
    @ViewBuilder
    private var videoCacheSection: some View {
        Section {
            if isLoadingVideo {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Calculating cache size…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(byteFormatter.string(fromByteCount: Int64(videoStats?.totalBytes ?? 0)))
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text("Across \(videoStats?.fileCount ?? 0) extracted video file\((videoStats?.fileCount ?? 0) == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button(role: .destructive) {
                    showingVideoClearConfirmation = true
                } label: {
                    Label("Clear video cache", systemImage: "trash")
                }
                .destructiveControlTint()
                .controlSize(.regular)
                .disabled((videoStats?.totalBytes ?? 0) == 0)
            }
        } header: {
            HStack {
                Text("Scene Video Texture Cache")
                Spacer()
                if let videoStats {
                    Text(verbatim: "\(byteFormatter.string(fromByteCount: Int64(videoStats.totalBytes))) · \(videoStats.fileCount)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            if let last = lastVideoFreedBytes, last > 0 {
                Text("Freed \(Int64(last), format: .byteCount(style: .file)).", comment: "WPE video texture cache footer shown after a purge. Placeholder is the freed byte total.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("MP4 frames extracted from scene video layers, reused across launches. Orphaned scenes are reclaimed automatically at startup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Header / rows

    @ViewBuilder
    private var summaryRow: some View {
        if isLoading {
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Calculating cache size…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else if let stats {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(byteFormatter.string(fromByteCount: Int64(stats.totalBytes)))
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                    Spacer()
                    if isOversized {
                        Label("Over 1 GB", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Text("Across \(stats.entries.count) project\(stats.entries.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("No cache entries yet.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func cacheRow(for entry: WPECacheStats.Entry) -> some View {
        let title = displayTitle(for: entry.workshopID)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                // Workshop names can be 60+ chars; without explicit
                // truncation a single long entry forces every row in the
                // list to expand to the longest title's width and wraps,
                // breaking the dense table feel.
                Text(verbatim: title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(Text(verbatim: title))
                Text(rowSubtitle(for: entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            Button(role: .destructive) {
                confirmPurge(entry: entry)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .destructiveControlTint()
            .help(Text("Remove cached files for \(entry.workshopID)"))
            .accessibilityLabel(Text("Remove cache for \(entry.workshopID)"))
        }
        .padding(.vertical, 2)
    }

    // MARK: - Actions

    private func refreshStats() async {
        isLoading = true
        let snapshot = await cache.stats()
        stats = snapshot
        isLoading = false
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
        let freed = await cache.purgeOlderThan(cutoff)
        lastFreedBytes = freed
        await refreshStats()
        NotificationCenter.default.post(name: .wpeHistoryDidChange, object: nil)
    }

    /// Surface the unified Liquid Glass confirmation so users see exactly which entries (count + total size) are about to be removed before bulk purging.
    private func confirmPurgeOlderThan(days: Int) {
        let cutoff = Date().addingTimeInterval(TimeInterval(-days * 86_400))
        let candidates = (stats?.entries ?? []).filter { ($0.lastUsed ?? .distantPast) <= cutoff }
        let totalBytes = candidates.reduce(UInt64(0)) { $0 + $1.sizeBytes }
        let size = byteFormatter.string(fromByteCount: Int64(totalBytes))
        pendingDestructive = PendingDestructive(
            .clearUnusedWallpapers(itemCount: candidates.count, byteSize: size)
        ) {
            Task { await purgeOlderThan(days: days) }
        }
    }

    /// Bulk-clear confirmation showing the current cache footprint so users can see what they're freeing.
    private func confirmClearAll() {
        let entries = stats?.entries ?? []
        let totalBytes = entries.reduce(UInt64(0)) { $0 + $1.sizeBytes }
        let size = byteFormatter.string(fromByteCount: Int64(totalBytes))
        pendingDestructive = PendingDestructive(
            .clearAllWPECache(projectCount: entries.count, byteSize: size)
        ) {
            Task { await purgeAll() }
        }
    }

    /// Single-entry purge confirmation that resolves the workshop ID to its display title so the destructive sheet matches what's visible in the list.
    private func confirmPurge(entry: WPECacheStats.Entry) {
        let workshopID = entry.workshopID
        pendingDestructive = PendingDestructive(
            .removeWPECacheEntry(displayName: displayTitle(for: workshopID))
        ) {
            Task { await purgeOne(workshopID) }
        }
    }

    // MARK: - Helpers

    private var isOversized: Bool {
        (stats?.totalBytes ?? 0) > 1_073_741_824
    }

    private func displayTitle(for workshopID: String) -> String {
        let history = SettingsManager.shared.loadGlobalSettings().recentWPEImports
        return history.first(where: { $0.origin.workshopID == workshopID })?.origin.title ?? workshopID
    }

    private func rowSubtitle(for entry: WPECacheStats.Entry) -> String {
        let size = byteFormatter.string(fromByteCount: Int64(entry.sizeBytes))
        guard let lastUsed = entry.lastUsed else { return size }
        let relative = relativeFormatter.localizedString(for: lastUsed, relativeTo: Date())
        return "\(size) · used \(relative)"
    }

    private var byteFormatter: ByteCountFormatter {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        f.includesUnit = true
        return f
    }

    private var relativeFormatter: RelativeDateTimeFormatter {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }
}
#endif
