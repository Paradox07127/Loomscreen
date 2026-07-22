#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

/// Unified Workshop pane: one sidebar entry, two tabs.
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
    @State private var installedCount = 0

    var body: some View {
        DetailPageScaffold(showsHeader: false, header: { EmptyView() }) {
            tabBody
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                tabSwitcher
            }
        }
        .overlay(alignment: .bottomTrailing) {
            WorkshopDownloadToastHost()
                .padding(DesignTokens.Spacing.lg)
        }
        // Re-confirm SteamCMD readiness (so the Download button isn't greyed out just because this launch hasn't re-run the probes), then reconcile the library with what's on disk.
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

    private var tabSwitcher: some View {
        Picker("Workshop tab", selection: $selectedTab) {
            ForEach(WorkshopPaneTab.allCases) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(Text("Workshop tab"))
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

    /// Builds the shared pane header so both tabs render an identical one.
    private func makePaneHeader() -> AnyView {
        AnyView(
            WorkshopPaneHeader(
                selectedTab: selectedTab,
                installedCount: installedCount,
                isImporting: folderImport.isImporting,
                onImport: { folderImport.presentImportPanel() },
                onPaste: { presentPasteFlow() }
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
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { browseViewModel = WorkshopBrowseViewModel(services: services) }
        }
    }

    /// Switch to Browse Online scoped to the tapped tag, building the Browse
    /// view-model on demand (the Installed tab may never have opened Browse).
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

    /// Consumes a one-shot deep link: switch to Browse Online and search for the target.
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

/// One-shot hand-off for "open Workshop scoped to this item" deep links.
@MainActor
enum WorkshopDeepLink {
    private static var pendingSearch: String?

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
