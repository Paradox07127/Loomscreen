#if !LITE_BUILD
import SwiftUI
import AppKit

/// Unified "Storage" tab. The dashboard separates user-owned downloads from
/// reclaimable caches, while migration-only cache details stay conditional so
/// the page remains short. Stats are computed off the actor so filesystem walks
/// never block the UI.
@MainActor
struct WPECacheManagementView: View {
    @State private var stats: WPECacheStats?
    @State private var isLoading: Bool = true
    @State private var lastFreedBytes: UInt64?
    @State private var errorMessage: String?
    @State private var pendingDestructive: PendingDestructive?
    @State private var videoStats: WPEVideoCacheStats?
    @State private var isLoadingVideo: Bool = true
    @State private var lastVideoFreedBytes: UInt64?
    /// Bytes of redundant SteamCMD source archives (`.pkg`) whose payload is
    /// already unpacked into the cache — reclaimable without losing wallpapers.
    @State private var reclaimableArchiveBytes: Int64 = 0
    @State private var lastReclaimedBytes: UInt64?
    /// Reachable scene ids (applied / bookmarked / recent / deps). Single keep-set
    /// shared by the "Clear Unused" button state, confirmation count, and action,
    /// computed once per refresh rather than per render.
    @State private var reachableIDs: Set<String> = []
    /// Downloaded content (projects + engine assets) — the actual wallpapers on
    /// disk, kept strictly apart from the reclaimable caches below.
    @State private var inventory: WPEStorageInventory?
    @State private var isLoadingInventory: Bool = true
    /// Built once per refresh (NOT in the body path — resolving titles/types
    /// reads settings) and fed straight to the compact table.
    @State private var projectItems: [WPEStorageRowItem] = []
    /// workshopID → import title, snapshotted per refresh so each legacy-cache
    /// row resolves its display name in O(1) instead of re-scanning history.
    @State private var cacheEntryTitles: [String: String] = [:]
    @State private var showingProjectsSheet = false
    @Binding private var pendingSearchAnchor: SettingsSearchAnchor?

    #if DIRECT_DISTRIBUTION
    /// The Workshop online-browse JSON cache (self-capped at 5-min TTL + 100 MB),
    /// folded into the Storage total + Clear All so it lives in one place.
    @Environment(WorkshopServices.self) private var workshopServices
    @State private var workshopCacheBytes: Int64 = 0
    #endif

    private let cache: WallpaperEngineCache
    private let dashboardColumns = [
        GridItem(.flexible(minimum: 220), spacing: DesignTokens.Spacing.md),
        GridItem(.flexible(minimum: 220), spacing: DesignTokens.Spacing.md)
    ]

    init(
        cache: WallpaperEngineCache = .shared,
        pendingSearchAnchor: Binding<SettingsSearchAnchor?> = .constant(nil)
    ) {
        self.cache = cache
        _pendingSearchAnchor = pendingSearchAnchor
    }

    var body: some View {
        Form {
            storageDashboardSection

            legacyCacheSection

            reclaimArchivesSection
        }
        .settingsFormChrome()
        .settingsSearchAnchorScroller(
            pendingSearchAnchor: $pendingSearchAnchor,
            anchors: [
                .storageDashboard,
                .storageCaches
            ]
        )
        .onAppear { Task { await refreshStats() } }
        .onReceive(NotificationCenter.default.publisher(for: .wpeHistoryDidChange)) { _ in
            Task { await refreshStats() }
        }
        .confirmDestructive($pendingDestructive)
        .errorAlert("Cache Error", message: $errorMessage)
    }

    // MARK: - Summary (total + clear-all)

    // Excludes `reclaimableArchiveBytes`: "Clear All Caches" must NOT trash the
    // source archives (a legacy cache-backed item's archive can be its only
    // re-extractable copy). Archives have their own dedicated reclaim section.
    private var totalBytes: UInt64 {
        var total = UInt64(stats?.totalBytes ?? 0)
        total += videoStats?.totalBytes ?? 0
        #if DIRECT_DISTRIBUTION
        total += UInt64(max(0, workshopCacheBytes))
        #endif
        return total
    }

    private var downloadedProjectBytes: UInt64 {
        inventory?.projectsTotalBytes ?? 0
    }

    private var engineAssetBytes: UInt64 {
        inventory?.engineAssetsBytes ?? 0
    }

    private var storageFootprintBytes: UInt64 {
        downloadedProjectBytes + engineAssetBytes + totalBytes
    }

    private var isStorageOverviewLoading: Bool {
        isAnyLoading || (isLoadingInventory && inventory == nil)
    }

    private var storageOverviewSegments: [StorageOverviewSegment] {
        [
            StorageOverviewSegment(
                id: "projects",
                title: "Projects",
                color: DesignTokens.Colors.Gauge.low,
                bytes: downloadedProjectBytes,
                valueText: byteFormatter.string(fromByteCount: Int64(downloadedProjectBytes))
            ),
            StorageOverviewSegment(
                id: "engine",
                title: "Engine",
                color: DesignTokens.Colors.accent,
                bytes: engineAssetBytes,
                valueText: byteFormatter.string(fromByteCount: Int64(engineAssetBytes))
            ),
            StorageOverviewSegment(
                id: "caches",
                title: "Caches",
                color: DesignTokens.Colors.Gauge.medium,
                bytes: totalBytes,
                valueText: byteFormatter.string(fromByteCount: Int64(totalBytes))
            )
        ].filter { $0.bytes > 0 }
    }

    private var isAnyLoading: Bool {
        isLoading || isLoadingVideo
    }

    @ViewBuilder
    private var storageDashboardSection: some View {
        Section {
            StorageOverviewPanel(
                totalText: byteFormatter.string(fromByteCount: Int64(storageFootprintBytes)),
                isLoading: isStorageOverviewLoading,
                segments: storageOverviewSegments
            )

            LazyVGrid(columns: dashboardColumns, alignment: .leading, spacing: DesignTokens.Spacing.md) {
                StorageDashboardTile(
                    title: "Downloaded Projects",
                    systemImage: "photo.on.rectangle.angled",
                    accent: DesignTokens.Colors.Gauge.low,
                    subtitle: Text("Your installed wallpapers, largest first")
                ) {
                    storageValue(
                        bytes: inventory?.projectsTotalBytes,
                        isLoading: isLoadingInventory && inventory == nil
                    )
                } actions: {
                    if let root = WPEStoragePaths.containerWorkshopContentRoot() {
                        openFolderIconButton(root)
                    }
                    if !projectItems.isEmpty {
                        Button { showingProjectsSheet = true } label: {
                            Image(systemName: "list.bullet.rectangle")
                        }
                        .buttonStyle(.borderless)
                        .help(Text("View files"))
                        .accessibilityLabel(Text("View files"))
                    }
                    StorageInfoButton {
                        infoNote("These are the Wallpaper Engine projects you downloaded — not caches. Removing a project's folder deletes that wallpaper.")
                    }
                }

                StorageDashboardTile(
                    title: "Engine Assets",
                    systemImage: "shippingbox",
                    accent: DesignTokens.Colors.accent,
                    subtitle: Text("Shared Wallpaper Engine runtime assets")
                ) {
                    storageValue(
                        bytes: inventory?.engineAssetsBytes,
                        isLoading: isLoadingInventory && inventory == nil
                    )
                } actions: {
                    if let url = inventory?.engineAssetsURL {
                        openFolderIconButton(url)
                    }
                    StorageInfoButton {
                        infoNote("Materials, models, and shaders shared by every scene — downloaded once and required by scenes that reference built-in files. Not a cache.")
                    }
                }

                StorageDashboardTile(
                    title: "Caches",
                    systemImage: "internaldrive",
                    accent: DesignTokens.Colors.Gauge.medium,
                    subtitle: Text("Reclaimable files rebuilt automatically when needed")
                ) {
                    storageValue(bytes: totalBytes, isLoading: isAnyLoading)
                } actions: {
                    Button(role: .destructive) {
                        confirmClearAllCaches()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .storageDestructiveIconStyle()
                    .controlSize(.small)
                    .disabled(totalBytes == 0)
                    .help(Text("Clear All Caches"))
                    .accessibilityLabel(Text("Clear All Caches"))
                    StorageInfoButton {
                        infoNote("Caches are bounded and cleared automatically — use these only to reclaim space now.")
                    }
                }
                .settingsSearchAnchorTarget(.storageCaches)

                StorageDashboardTile(
                    title: "Scene Video Texture Cache",
                    systemImage: "film",
                    accent: DesignTokens.Colors.Gauge.high,
                    subtitle: videoCacheSubtitle
                ) {
                    storageValue(
                        bytes: videoStats?.totalBytes,
                        isLoading: isLoadingVideo
                    )
                } actions: {
                    Button(role: .destructive) {
                        confirmPurgeVideoCache()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .storageDestructiveIconStyle()
                    .controlSize(.small)
                    .disabled((videoStats?.totalBytes ?? 0) == 0)
                    .help(Text("Clear Video Cache"))
                    .accessibilityLabel(Text("Clear Video Cache"))
                    StorageInfoButton {
                        infoNote("Frames extracted from scene videos, reused across launches. Capped at 2 GB — the least-recently-used files are removed first, and orphaned scenes are reclaimed at startup.")
                    }
                }
            }
            .sheet(isPresented: $showingProjectsSheet) { projectsSheet }
        } header: {
            SettingsSearchSectionHeader("Storage", anchor: .storageDashboard)
        }
    }

    @ViewBuilder
    private func storageValue(bytes: UInt64?, isLoading: Bool) -> some View {
        if isLoading {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(Text("Calculating cache size…"))
        } else {
            Text(byteFormatter.string(fromByteCount: Int64(bytes ?? 0)))
                .font(DesignTokens.Typography.pageTitle)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private var videoCacheSubtitle: Text {
        if let last = lastVideoFreedBytes, last > 0 {
            return Text("Freed \(Int64(last), format: .byteCount(style: .file)).", comment: "WPE video texture cache footer shown after a purge. Placeholder is the freed byte total.")
        }
        return Text("Across \(videoStats?.fileCount ?? 0) extracted video file\((videoStats?.fileCount ?? 0) == 1 ? "" : "s")")
    }

    // MARK: - Downloaded projects (actual wallpapers — NOT caches)

    /// macOS Storage-style detail window for the downloaded projects: full file
    /// table with room to scroll, plus reveal-in-Finder and Done actions.
    private var projectsSheet: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 26))
                    .foregroundStyle(.tint)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Downloaded Projects").font(.headline)
                        Text(verbatim: "— \(byteFormatter.string(fromByteCount: Int64(inventory?.projectsTotalBytes ?? 0)))")
                            .foregroundStyle(.secondary)
                    }
                    Text("These are the Wallpaper Engine projects you downloaded — not caches. Removing a project's folder deletes that wallpaper.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            WPEStorageCompactTable(items: projectItems, fill: true) { openFolder($0) }
                .padding(16)

            Divider()

            HStack {
                if let root = WPEStoragePaths.containerWorkshopContentRoot() {
                    Button { openFolder(root) } label: {
                        Label("Open Folder", systemImage: "folder")
                    }
                }
                Spacer()
                Button("Done") { showingProjectsSheet = false }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 560, height: 480)
    }

    /// Maps the size-sorted inventory into table rows, resolving each project's
    /// title + WPE type from import history in a single pass (one settings load).
    private func projectRowItems(_ projects: [WPEStorageInventory.ProjectEntry]) -> [WPEStorageRowItem] {
        let originByID = Dictionary(
            SettingsManager.shared.loadGlobalSettings().recentWPEImports.map { ($0.origin.workshopID, $0.origin) },
            uniquingKeysWith: { first, _ in first }
        )
        return projects.map { project in
            let origin = originByID[project.workshopID]
            return WPEStorageRowItem(
                id: project.workshopID,
                icon: Self.icon(for: origin?.originalType),
                title: origin?.title ?? project.workshopID,
                kind: origin?.originalType.localizedDisplayName ?? "",
                sizeText: byteFormatter.string(fromByteCount: Int64(project.sizeBytes)),
                folderURL: project.folderURL
            )
        }
    }

    private static func icon(for type: WPEType?) -> String {
        switch type {
        case .scene:       return "cube.transparent"
        case .video:       return "film"
        case .web:         return "globe"
        case .application: return "app.dashed"
        case .unknown, .none: return "questionmark.square.dashed"
        }
    }

    private func openFolder(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    private func openFolderIconButton(_ url: URL) -> some View {
        Button { openFolder(url) } label: {
            Image(systemName: "folder")
        }
        .buttonStyle(.borderless)
        .help(Text("Open Folder"))
        .accessibilityLabel(Text("Open Folder"))
    }

    @ViewBuilder
    private func infoNote(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 300, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Imported-project migration cache

    @ViewBuilder
    private var legacyCacheSection: some View {
        if let stats, !stats.entries.isEmpty {
            Section {
                HStack(alignment: .center) {
                    summaryRow
                    StorageInfoButton {
                        infoNote("New scenes read their assets in place from the source, so this cache only holds older imports. Unreferenced leftovers are reclaimed automatically at startup.")
                    }
                }
            } header: {
                Text("Imported Project Cache")
            } footer: {
                if let last = lastFreedBytes, last > 0 {
                    Text("Freed \(Int64(last), format: .byteCount(style: .file)).", comment: "WPE cache management footer shown after a purge. Placeholder is the freed byte total, rendered through SwiftUI's byteCount format style.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach(stats.entries) { entry in
                    cacheRow(for: entry)
                }
            } header: {
                Text(verbatim: "Cached Projects (\(stats.entries.count))")
            }

            Section {
                HStack(spacing: 12) {
                    Button(role: .destructive) {
                        confirmClearAll()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .storageDestructiveIconStyle()
                    .controlSize(.regular)
                    .help(Text("Clear All"))
                    .accessibilityLabel(Text("Clear All"))

                    Button(role: .destructive) {
                        confirmPurgeOlderThan(days: 30)
                    } label: {
                        Label("Clear Unused > 30 days", systemImage: "calendar.badge.minus")
                    }
                    .destructiveControlTint()
                    .controlSize(.regular)
                    .disabled(unusedCandidates(olderThanDays: 30).isEmpty)

                    Spacer()
                }
            } footer: {
                if isOversized {
                    Label("Cache is using more than 1 GB. Consider clearing unused projects.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(DesignTokens.Colors.Status.warning)
                }
            }
        }
    }

    /// Reclaiming the redundant `.pkg` moves it to the Trash (recoverable) without
    /// touching any wallpaper — the runtime renders from the unpacked cache copy.
    /// Pro/direct-distribution only (Lite has no SteamCMD).
    @ViewBuilder
    private var reclaimArchivesSection: some View {
        #if DIRECT_DISTRIBUTION
        if reclaimableArchiveBytes > 0 {
            Section {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(byteFormatter.string(fromByteCount: reclaimableArchiveBytes))
                            .font(DesignTokens.Typography.pageTitle)
                        Text("Source download archives already unpacked into your cache.")
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
                        .font(DesignTokens.Typography.pageTitle)
                    Spacer()
                    if isOversized {
                        Label("Over 1 GB", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(DesignTokens.Colors.Status.warning)
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
                // Workshop names can be 60+ chars; without explicit truncation one
                // long entry forces every row to the longest title's width and wraps.
                Text(verbatim: title)
                    .font(DesignTokens.Typography.body)
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
            .foregroundStyle(DesignTokens.Colors.Status.danger)
            .help(Text("Remove cached files for \(entry.workshopID)"))
            .accessibilityLabel(Text("Remove cache for \(entry.workshopID)"))
        }
        .padding(.vertical, 2)
    }

    // MARK: - Actions

    private func refreshStats() async {
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

    /// Entries old enough to count as "unused" that are also unreachable. Single
    /// definition shared by the button's disabled state, confirmation count, and purge.
    private func unusedCandidates(olderThanDays days: Int) -> [WPECacheStats.Entry] {
        let cutoff = Date().addingTimeInterval(TimeInterval(-days * 86_400))
        return (stats?.entries ?? []).filter {
            !reachableIDs.contains($0.workshopID) && ($0.lastUsed ?? .distantPast) <= cutoff
        }
    }

    private func purgeOlderThan(days: Int) async {
        let cutoff = Date().addingTimeInterval(TimeInterval(-days * 86_400))
        let freed = await cache.purgeOlderThan(cutoff, keepingIDs: reachableIDs)
        lastFreedBytes = freed
        await refreshStats()
        NotificationCenter.default.post(name: .wpeHistoryDidChange, object: nil)
    }

    private func confirmPurgeOlderThan(days: Int) {
        let candidates = unusedCandidates(olderThanDays: days)
        let totalBytes = candidates.reduce(UInt64(0)) { $0 + $1.sizeBytes }
        let size = byteFormatter.string(fromByteCount: Int64(totalBytes))
        pendingDestructive = PendingDestructive(
            .clearUnusedWallpapers(itemCount: candidates.count, byteSize: size)
        ) {
            Task { await purgeOlderThan(days: days) }
        }
    }

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

    private func confirmClearAllCaches() {
        let size = byteFormatter.string(fromByteCount: Int64(totalBytes))
        pendingDestructive = PendingDestructive(.clearAllStorageCaches(byteSize: size)) {
            Task { await clearAllCaches() }
        }
    }

    private func confirmPurgeVideoCache() {
        let bytes = videoStats?.totalBytes ?? 0
        let size = byteFormatter.string(fromByteCount: Int64(bytes))
        pendingDestructive = PendingDestructive(.clearSceneVideoCache(byteSize: size)) {
            Task { await purgeVideoCache() }
        }
    }

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
        cacheEntryTitles[workshopID] ?? workshopID
    }

    private func rowSubtitle(for entry: WPECacheStats.Entry) -> String {
        let size = byteFormatter.string(fromByteCount: Int64(entry.sizeBytes))
        guard let lastUsed = entry.lastUsed else { return size }
        let relative = relativeFormatter.localizedString(for: lastUsed, relativeTo: Date())
        return "\(size) · used \(relative)"
    }

    // Shared instances: otherwise rebuilt per cache row / per refresh, a measurable
    // allocation cost in a list that updates often.
    private var byteFormatter: ByteCountFormatter { Self.sharedByteFormatter }
    private var relativeFormatter: RelativeDateTimeFormatter { Self.sharedRelativeFormatter }

    private static let sharedByteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        f.includesUnit = true
        return f
    }()

    private static let sharedRelativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()
}

private struct StorageOverviewSegment: Identifiable {
    let id: String
    let title: LocalizedStringKey
    let color: Color
    let bytes: UInt64
    let valueText: String
}

private struct StorageOverviewPanel: View {
    let totalText: String
    let isLoading: Bool
    let segments: [StorageOverviewSegment]

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Label("Storage Footprint", systemImage: "chart.bar.xaxis")
                    .font(DesignTokens.Typography.bodyEmphasized)
                    .foregroundStyle(.primary)

                Spacer(minLength: DesignTokens.Spacing.md)

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(Text("Calculating storage footprint…"))
                } else {
                    Text(verbatim: totalText)
                        .font(DesignTokens.Typography.pageTitle)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }

            StorageSegmentedBar(segments: segments)

            if segments.isEmpty {
                Text("No downloaded content or cache files yet.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 118), spacing: DesignTokens.Spacing.md)],
                    alignment: .leading,
                    spacing: DesignTokens.Spacing.xs
                ) {
                    ForEach(segments) { segment in
                        HStack(spacing: DesignTokens.Spacing.xs) {
                            Circle()
                                .fill(segment.color)
                                .frame(width: 7, height: 7)
                                .accessibilityHidden(true)

                            Text(segment.title)
                                .font(DesignTokens.Typography.caption)
                                .foregroundStyle(.secondary)

                            Text(verbatim: segment.valueText)
                                .font(DesignTokens.Typography.metric)
                                .foregroundStyle(.primary)
                        }
                        .fixedSize()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous)
                .fill(DesignTokens.Colors.surfaceRaised.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous)
                .stroke(DesignTokens.Colors.separator.opacity(0.55), lineWidth: 0.5)
        )
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
    }
}

private struct StorageSegmentedBar: View {
    let segments: [StorageOverviewSegment]

    private var totalBytes: UInt64 {
        segments.reduce(UInt64(0)) { $0 + $1.bytes }
    }

    var body: some View {
        GeometryReader { proxy in
            let nonZeroSegments = segments.filter { $0.bytes > 0 }
            let spacing: CGFloat = 2
            let usableWidth = max(0, proxy.size.width - spacing * CGFloat(max(nonZeroSegments.count - 1, 0)))

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))

                if totalBytes > 0 {
                    HStack(spacing: spacing) {
                        ForEach(nonZeroSegments) { segment in
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(segment.color)
                                .frame(width: max(3, usableWidth * CGFloat(Double(segment.bytes) / Double(totalBytes))))
                        }
                    }
                }
            }
        }
        .frame(height: 9)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// Compact metric card for the Storage dashboard.
private struct StorageDashboardTile<Value: View, Actions: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    let accent: Color
    let subtitle: Text
    @ViewBuilder var value: () -> Value
    @ViewBuilder var actions: () -> Actions

    init(
        title: LocalizedStringKey,
        systemImage: String,
        accent: Color,
        subtitle: Text,
        @ViewBuilder value: @escaping () -> Value,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.title = title
        self.systemImage = systemImage
        self.accent = accent
        self.subtitle = subtitle
        self.value = value
        self.actions = actions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous)
                        .fill(accent.opacity(0.16))
                        .frame(width: 30, height: 30)
                    Image(systemName: systemImage)
                        .font(.body.weight(.medium))
                        .foregroundStyle(accent)
                }
                .accessibilityHidden(true)

                Spacer(minLength: DesignTokens.Spacing.sm)

                HStack(spacing: DesignTokens.Spacing.xs) {
                    actions()
                }
            }

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                value()
                    .frame(minHeight: 30, alignment: .leading)

                Text(title)
                    .font(DesignTokens.Typography.bodyEmphasized)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                subtitle
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .padding(DesignTokens.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous)
                .fill(DesignTokens.Colors.surfaceRaised.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous)
                .stroke(DesignTokens.Colors.separator.opacity(0.55), lineWidth: 0.5)
        )
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
    }
}

/// Trailing ⓘ that reveals a section's detail in a popover, so the dashboard
/// stays uncluttered with extra explanation hidden by default.
private struct StorageInfoButton<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(Text("Details"))
        .accessibilityLabel(Text("Details"))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            content().padding(14)
        }
    }
}

private extension View {
    func storageDestructiveIconStyle() -> some View {
        buttonStyle(.borderless)
            .foregroundStyle(DesignTokens.Colors.Status.danger)
    }
}
#endif
