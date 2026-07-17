#if !LITE_BUILD
import LiveWallpaperSharedUI
import SwiftUI
import AppKit

/// Unified "Storage" tab. The dashboard separates user-owned downloads from
/// reclaimable caches, while migration-only cache details stay conditional so
/// the page remains short. Stats are computed off the actor so filesystem walks
/// never block the UI.
@MainActor
struct WPECacheManagementView: View {
    @State var stats: WPECacheStats?
    @State var isLoading: Bool = true
    @State var lastFreedBytes: UInt64?
    @State var errorMessage: String?
    @State var pendingDestructive: PendingDestructive?
    @State var videoStats: WPEVideoCacheStats?
    @State var isLoadingVideo: Bool = true
    @State var lastVideoFreedBytes: UInt64?
    /// Bytes of redundant SteamCMD source archives (`.pkg`) whose payload is
    /// already unpacked into the cache — reclaimable without losing wallpapers.
    @State var reclaimableArchiveBytes: Int64 = 0
    @State var lastReclaimedBytes: UInt64?
    /// Reachable scene ids (applied / bookmarked / recent / deps). Single keep-set
    /// shared by the "Clear Unused" button state, confirmation count, and action,
    /// computed once per refresh rather than per render.
    @State var reachableIDs: Set<String> = []
    /// Downloaded content (projects + engine assets) — the actual wallpapers on
    /// disk, kept strictly apart from the reclaimable caches below.
    @State var inventory: WPEStorageInventory?
    @State var isLoadingInventory: Bool = true
    /// Built once per refresh (NOT in the body path — resolving titles/types
    /// reads settings) and fed straight to the compact table.
    @State var projectItems: [WPEStorageRowItem] = []
    /// workshopID → import title, snapshotted per refresh so each legacy-cache
    /// row resolves its display name in O(1) instead of re-scanning history.
    @State var cacheEntryTitles: [String: String] = [:]
    @State var showingProjectsSheet = false
    @Binding private var pendingSearchAnchor: SettingsSearchAnchor?

    #if DEBUG
    /// Temp dirs left in the container by test runs. DEBUG-only: no shipping
    /// code path creates them, so Release has nothing to report.
    @State var testArtifacts: TestTempArtifacts.Summary = .empty
    @State var lastTestArtifactFreedBytes: UInt64?
    #endif

    /// The Workshop online-browse JSON cache (self-capped at 5-min TTL + 100 MB),
    /// folded into the Storage total + Clear All so it lives in one place.
    @Environment(WorkshopServices.self) var workshopServices
    @State var workshopCacheBytes: Int64 = 0

    let cache: WallpaperEngineCache
    let dashboardColumns = [
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

            testArtifactsSection
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

    @ViewBuilder
    func infoNote(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 300, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    // Shared instances: otherwise rebuilt per cache row / per refresh, a measurable
    // allocation cost in a list that updates often.
    var byteFormatter: ByteCountFormatter { Self.sharedByteFormatter }
    var relativeFormatter: RelativeDateTimeFormatter { Self.sharedRelativeFormatter }

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
#endif
