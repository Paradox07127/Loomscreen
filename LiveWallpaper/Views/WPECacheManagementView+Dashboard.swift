#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import SwiftUI

extension WPECacheManagementView {
    // MARK: - Summary (total + clear-all)

    // Excludes `reclaimableArchiveBytes`: "Clear All Caches" must NOT trash the source archives (a legacy cache-backed item's archive can be its only re-extractable copy).
    var totalBytes: UInt64 {
        var total = UInt64(stats?.totalBytes ?? 0)
        total += videoStats?.totalBytes ?? 0
        total += UInt64(max(0, workshopCacheBytes))
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
    var storageDashboardSection: some View {
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
    func projectRowItems(_ projects: [WPEStorageInventory.ProjectEntry]) -> [WPEStorageRowItem] {
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
}
#endif
