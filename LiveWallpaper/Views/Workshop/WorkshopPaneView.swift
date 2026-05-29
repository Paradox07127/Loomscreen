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

    private var header: some View {
        DetailHeaderBar(
            systemImage: "cube.transparent.fill",
            title: { Text("Steam Workshop") },
            metadata: {
                Picker("Workshop tab", selection: $selectedTab) {
                    ForEach(WorkshopPaneTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 220)
                .accessibilityLabel(Text("Workshop tab"))
            },
            actions: {
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
                        .help(Text("Add from a Steam Workshop URL"))
                        .accessibilityLabel(Text("Add from Workshop URL"))

                        overflowMenu
                    }
                }
            }
        )
    }

    private var overflowMenu: some View {
        Menu {
            Button {
                isShowingKeyEntry = true
            } label: {
                Label("Set Steam Web API Key…", systemImage: "key.fill")
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .adaptiveGlassButton(.regular)
        .controlSize(.regular)
        .help(Text("More Workshop options"))
        .accessibilityLabel(Text("More Workshop options"))
    }

    // MARK: - Tab body

    @ViewBuilder
    private var tabBody: some View {
        switch selectedTab {
        case .installed:
            WorkshopInstalledView()
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
            return String(localized: "Browse Online", comment: "Workshop pane tab for the online Steam Workshop catalog.")
        }
    }
}
#endif
