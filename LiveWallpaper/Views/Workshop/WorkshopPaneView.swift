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
        DetailPageScaffold(
            showsHeader: true,
            header: { header },
            content: { tabBody }
        )
        .overlay(alignment: .bottomTrailing) {
            WorkshopDownloadToastHost()
                .padding(DesignTokens.Spacing.lg)
        }
        // On open: re-confirm SteamCMD readiness so the Download button isn't
        // greyed out just because this launch hasn't re-run the probes, then
        // reconcile the library with SteamCMD's on-disk downloads so they show
        // in Installed by default (covers items downloaded manually or before
        // the in-app button recorded them). Readiness runs first — it binds the
        // workdir the ingest scan needs.
        .task {
            await doctor.autoConfirmDownloadReadinessIfNeeded()
            await folderImport.ingestSteamCMDDownloads(using: doctor)
        }
        .onAppear { refreshInstalledCount() }
        .onReceive(NotificationCenter.default.publisher(for: .wpeHistoryDidChange)) { _ in
            refreshInstalledCount()
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

    // MARK: - Header

    // Three-column header: brand mark on the leading edge, the Installed /
    // Workshop segmented switcher centered (the macOS-native toolbar idiom —
    // the section identity is the tab pair, not a stacked subtitle), and the
    // contextual actions trailing. The two flexible side columns share the
    // leftover width equally, so the switcher stays optically centered and the
    // sides push apart instead of overlapping it when the window narrows.
    private var header: some View {
        HStack(spacing: DesignTokens.DetailHeader.contentSpacing) {
            brandMark
                .frame(maxWidth: .infinity, alignment: .leading)

            tabSwitcher
                .frame(width: 220)
                .layoutPriority(1)

            headerActions
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, DesignTokens.DetailHeader.horizontalPadding)
        .padding(.vertical, DesignTokens.DetailHeader.verticalPadding)
    }

    // Bold title + statistics subtext, matching the Bookmarks / Aerials hero
    // (`DetailHeaderBar`): icon disc, primary semibold title, caption stat line.
    private var brandMark: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(
                        width: DesignTokens.DetailHeader.iconSize,
                        height: DesignTokens.DetailHeader.iconSize
                    )
                Image(systemName: "cube.transparent.fill")
                    .font(.system(size: DesignTokens.DetailHeader.iconSymbolSize))
                    .foregroundStyle(Color.accentColor)
                    .symbolRenderingMode(.hierarchical)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DesignTokens.DetailHeader.textSpacing) {
                Text("Steam Workshop")
                    .font(.system(size: DesignTokens.DetailHeader.titleSize, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                headerStatView
            }
        }
    }

    /// Hero subtitle. On Workshop it prefixes the request count with the API-key
    /// status seal (the ribbon no longer carries a key chip), so key health and
    /// today's honest request count read in one place.
    private var headerStatView: some View {
        HStack(spacing: 4) {
            if selectedTab == .browseOnline, services.hasWebAPIKey {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
            }
            Text(verbatim: headerStat)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .help(selectedTab == .browseOnline && services.hasWebAPIKey
            ? Text("Steam doesn't expose remaining quota; this counts only the requests this Mac has issued today.")
            : Text(""))
    }

    /// Context-aware statistics subtext: library size on Installed, key status +
    /// today's honest request count on Workshop.
    private var headerStat: String {
        switch selectedTab {
        case .installed:
            return String(localized: "\(installedCount) installed", comment: "Workshop header stat: number of installed wallpapers.")
        case .browseOnline:
            if !services.hasWebAPIKey {
                return String(localized: "API key required", comment: "Workshop header stat when no Steam Web API key is set.")
            }
            return String(localized: "\(WorkshopRequestCounter.countForToday()) API requests today", comment: "Workshop header stat: Steam Web API requests issued today.")
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
        .labelsHidden()
        .pickerStyle(.segmented)
        .accessibilityLabel(Text("Workshop tab"))
    }

    private var headerActions: some View {
        AdaptiveGlassContainer(spacing: 8) {
            HStack(spacing: 8) {
                if selectedTab == .installed {
                    Button {
                        folderImport.presentImportPanel()
                    } label: {
                        if folderImport.isImporting {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "folder.badge.plus")
                        }
                    }
                    .adaptiveGlassButton(.regular)
                    .controlSize(.regular)
                    .disabled(folderImport.isImporting)
                    .help(Text("Import Wallpaper Engine projects from a folder"))
                    .accessibilityLabel(Text("Import from folder"))
                }

                Button {
                    presentPasteFlow()
                } label: {
                    Image(systemName: "plus")
                }
                .adaptiveGlassButton(.regular)
                .controlSize(.regular)
                .help(Text("Add a Steam Workshop item by URL or ID"))
                .accessibilityLabel(Text("Add from Workshop URL or ID"))
            }
        }
    }

    // MARK: - Tab body

    @ViewBuilder
    private var tabBody: some View {
        switch selectedTab {
        case .installed:
            WorkshopInstalledView(onBrowseTag: browseByTag)
        case .browseOnline:
            browseTab
        }
    }

    @ViewBuilder
    private var browseTab: some View {
        if let viewModel = browseViewModel {
            WorkshopBrowsePane(viewModel: viewModel, doctor: doctor) { isShowingKeyEntry = true }
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
#endif
