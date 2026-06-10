#if !LITE_BUILD && DIRECT_DISTRIBUTION
import LiveWallpaperSharedUI
import SwiftUI

/// Wallpaper-Engine-style unified Workshop pane: one sidebar entry, two tabs.
/// "Installed" embeds the existing local-library gallery (header suppressed —
/// this pane owns the chrome); "Browse Online" embeds the online catalog. A
/// "+" action keeps the paste-by-URL flow one click away.
struct WorkshopPaneView: View {
    @Environment(WorkshopServices.self) private var services
    @Environment(SteamCMDDoctorService.self) private var doctor
    @AppStorage("loomscreen.workshop.pane.selectedTab.v1") private var selectedTab: WorkshopPaneTab = .installed
    @AppStorage("loomscreen.workshop.onboarding.shown.v1") private var onboardingShown: Bool = false

    @State private var folderImport = WorkshopFolderImportCoordinator.shared
    @State private var browseViewModel: WorkshopBrowseViewModel?
    @State private var isShowingPasteSheet = false
    @State private var isShowingOnboarding = false
    @State private var isShowingKeyEntry = false
    /// Installed-library size, for the header's statistics subtext.
    @State private var installedCount = 0

    var body: some View {
        // No scaffold header: each tab hosts the shared `WorkshopPaneHeader`
        // inside its split's main column so the detail panel runs full-height
        // alongside the header (matching the screen-detail inspector). The
        // scaffold still supplies the page background + minimum size.
        DetailPageScaffold(showsHeader: false, header: { EmptyView() }) {
            tabBody
        }
        .overlay(alignment: .bottomTrailing) {
            WorkshopDownloadToastHost()
                .padding(DesignTokens.Spacing.lg)
        }
        // On open: re-confirm SteamCMD readiness so the Download button isn't
        // greyed out just because this launch hasn't re-run the probes, then
        // reconcile the library with what's on disk — both the app-managed
        // SteamCMD download tree and the user-configured Workshop library folder
        // — so existing downloads show in Installed by default. Readiness runs
        // first; it binds the workdir the SteamCMD scan needs.
        .task {
            await doctor.autoConfirmDownloadReadinessIfNeeded()
            await folderImport.ingestExistingDownloads(using: doctor)
        }
        .onAppear {
            refreshInstalledCount()
            consumePendingDeepLink()
        }
        .onReceive(NotificationCenter.default.publisher(for: .wpeHistoryDidChange)) { _ in
            refreshInstalledCount()
        }
        // Fired when the pane is already mounted and a deep link arrives (e.g.
        // the user is sitting on Workshop and clicks "Find in Workshop" on a
        // scene). On a cold switch the `.onAppear` above handles it instead.
        .onReceive(NotificationCenter.default.publisher(for: .openWorkshopPane)) { _ in
            consumePendingDeepLink()
        }
        .sheet(isPresented: $isShowingOnboarding) {
            WorkshopOnboardingSheet { isShowingPasteSheet = true }
        }
        .sheet(isPresented: $isShowingPasteSheet) {
            WorkshopPasteSheet()
        }
        .sheet(isPresented: $isShowingKeyEntry) {
            SteamWebAPIKeyEntrySheet(services: services) {
                Task { await services.refreshAPIKeyStatus() }
            }
        }
    }

    private func refreshInstalledCount() {
        installedCount = SettingsManager.shared.loadGlobalSettings().recentWPEImports.count
    }

    // MARK: - Tab body

    @ViewBuilder
    private var tabBody: some View {
        switch selectedTab {
        case .installed:
            WorkshopInstalledView(
                onBrowseTag: browseByTag,
                paneHeader: makePaneHeader
            )
        case .browseOnline:
            browseTab
        }
    }

    /// Builds the shared pane header for a tab's split main column, injecting
    /// that tab's detail-panel show/hide toggle. Bound to the pane's own state
    /// (tab selection, install count, import status) so both tabs render an
    /// identical header.
    private func makePaneHeader(_ toggle: AnyView) -> AnyView {
        AnyView(
            WorkshopPaneHeader(
                selectedTab: $selectedTab,
                installedCount: installedCount,
                isImporting: folderImport.isImporting,
                onImport: { folderImport.presentImportPanel() },
                onPaste: { presentPasteFlow() },
                inspectorToggle: { toggle }
            )
        )
    }

    @ViewBuilder
    private var browseTab: some View {
        if let viewModel = browseViewModel {
            WorkshopBrowsePane(
                viewModel: viewModel,
                doctor: doctor,
                onRequestKeyEntry: { isShowingKeyEntry = true },
                paneHeader: makePaneHeader
            )
        } else {
            // Lazily build the view-model on first Browse activation so the
            // Installed tab pays no online-browse cost.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { browseViewModel = WorkshopBrowseViewModel(services: services) }
        }
    }

    /// From the Installed inspector: switch to Browse Online and scope the grid
    /// to the tapped tag. Builds the Browse view-model on demand (the Installed
    /// tab may have never opened Browse yet).
    private func browseByTag(_ tag: String) {
        let viewModel: WorkshopBrowseViewModel
        if let existing = browseViewModel {
            viewModel = existing
        } else {
            viewModel = WorkshopBrowseViewModel(services: services)
            browseViewModel = viewModel
        }
        selectedTab = .browseOnline
        Task { await viewModel.browseTag(tag) }
    }

    /// Consumes a one-shot deep link (set by the scene detail's "Find in
    /// Workshop" link): switch to Browse Online and run a search for the target.
    /// Steam's catalog search can't match a raw numeric Workshop ID, so the
    /// caller seeds the item's title as the query — that's what surfaces it.
    private func consumePendingDeepLink() {
        guard let query = WorkshopDeepLink.takePendingSearch() else { return }
        let viewModel: WorkshopBrowseViewModel
        if let existing = browseViewModel {
            viewModel = existing
        } else {
            viewModel = WorkshopBrowseViewModel(services: services)
            browseViewModel = viewModel
        }
        selectedTab = .browseOnline
        Task {
            viewModel.searchInput = query
            await viewModel.submitSearch()
        }
    }

    private func presentPasteFlow() {
        if onboardingShown {
            isShowingPasteSheet = true
        } else {
            isShowingOnboarding = true
        }
    }
}

enum WorkshopPaneTab: String, CaseIterable, Identifiable {
    case installed
    case browseOnline

    var id: String { rawValue }

    var title: String {
        switch self {
        case .installed:
            return String(localized: "Installed", comment: "Workshop pane tab for the locally installed library.")
        case .browseOnline:
            return String(localized: "Workshop", comment: "Workshop pane tab for the online Steam Workshop catalog (zh: 创意工坊).")
        }
    }
}

/// One-shot hand-off for "open Workshop scoped to this item" deep links. The
/// scene detail card lives in the detail column and can't reach the (possibly
/// not-yet-mounted) Workshop pane directly, so it parks a search query here and
/// posts `.openWorkshopPane`; the pane drains it on appear / receipt. Kept tiny
/// and MainActor-isolated — it's a navigation baton, not shared state.
@MainActor
enum WorkshopDeepLink {
    private static var pendingSearch: String?

    /// Park a search target (typically the Workshop item's title).
    static func requestSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingSearch = trimmed.isEmpty ? nil : trimmed
    }

    /// Read-and-clear the pending target (nil if none).
    static func takePendingSearch() -> String? {
        defer { pendingSearch = nil }
        return pendingSearch
    }
}
#endif
