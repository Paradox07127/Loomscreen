import SwiftUI
import AppKit

/// Top-level Scene tab content. Drives the Wallpaper Engine import flow:
/// folder picker → import service → history grid → unsupported placeholder.
@MainActor
struct WPESceneSection: View {
    let screen: Screen
    @Environment(ScreenManager.self) private var screenManager

    @State private var recentImports: [WPEHistoryEntry] = []
    @State private var selectedHistoryEntry: WPEHistoryEntry?
    @State private var showImportErrorAlert = false
    @State private var showWorkshopGallery: Bool = false

    var body: some View {
        Group {
            if hasActiveSceneWallpaper {
                activeSceneCard
            } else if recentImports.isEmpty {
                emptyState
            } else if let selected = selectedHistoryEntry {
                unsupportedDetail(for: selected)
            } else {
                historyList
            }
        }
        // Animate only the empty↔grid transition (both pure-SwiftUI subtrees).
        // Cross-branch animation into `unsupportedDetail` is deliberately
        // skipped because that branch hosts `WPEPreviewView` (NSViewRepresentable)
        // and animating across NSView boundaries triggers an AppKit Auto-Layout
        // constraint cycle (`needs Update Constraints in Window pass …`).
        .animation(.default, value: recentImports.isEmpty)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { reloadHistory() }
        .onReceive(NotificationCenter.default.publisher(for: .wpeImportDidComplete)) { notification in
            reloadHistory()
            selectUnsupportedImportIfNeeded(from: notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .wpeHistoryDidChange)) { _ in
            reloadHistory()
        }
        .onChange(of: screenManager.wpeImportError(for: screen)) { _, error in
            showImportErrorAlert = (error != nil)
        }
        .sheet(isPresented: $showWorkshopGallery) {
            WorkshopGalleryView()
                .environment(screenManager)
        }
        .alert("Import Failed", isPresented: $showImportErrorAlert, presenting: screenManager.wpeImportError(for: screen)) { _ in
            Button("OK", role: .cancel) {
                screenManager.clearWPEImportError(for: screen)
            }
        } message: { error in
            VStack(alignment: .leading) {
                Text(error.localizedDescription)
                if let suggestion = error.recoverySuggestion {
                    Text(suggestion).font(.caption)
                }
            }
        }
    }

    // MARK: - States

    private var emptyState: some View {
        VStack(spacing: 24) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: 8) {
                Text("Import Wallpaper Engine project")
                    .font(.title2.bold())
                Text("Locate your Wallpaper Engine project folder")
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                Button {
                    presentFolderPicker()
                } label: {
                    Label("Choose Folder…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .accessibilityHint(Text("Opens a folder chooser to import a Wallpaper Engine project"))

                Button {
                    showWorkshopGallery = true
                } label: {
                    Label("Browse Workshop Library…", systemImage: "books.vertical")
                }
                .buttonStyle(.glass)
                .controlSize(.regular)
                .accessibilityHint(Text("Discover every project under your Steam library and import in bulk"))
            }
            .padding(.top, 4)

            Text("Supports Video / Web · Scene preview only")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var historyList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Recently Imported")
                        .font(.headline)
                    Spacer()
                    Button {
                        showWorkshopGallery = true
                    } label: {
                        Label("Browse Library…", systemImage: "books.vertical")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.regular)
                    .accessibilityHint(Text("Bulk-discover and import projects from your Steam Workshop folder"))

                    Button {
                        presentFolderPicker()
                    } label: {
                        Label("Import New…", systemImage: "plus")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.regular)
                }

                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(160), spacing: 16), count: 4),
                    alignment: .leading,
                    spacing: 16
                ) {
                    ForEach(recentImports) { entry in
                        WPEHistoryRow(
                            entry: entry,
                            isActive: activeWorkshopID == entry.id,
                            onTap: { handleTap(entry: entry) },
                            onRemove: { handleRemove(entry: entry) }
                        )
                    }
                }
            }
            .padding(24)
        }
    }

    @ViewBuilder
    private func unsupportedDetail(for entry: WPEHistoryEntry) -> some View {
        VStack(spacing: 16) {
            HStack {
                Button {
                    selectedHistoryEntry = nil
                } label: {
                    Label("Back to library", systemImage: "chevron.left")
                }
                .buttonStyle(.glass)
                .controlSize(.regular)
                .accessibilityHint(Text("Return to the recent imports grid"))
                Spacer()
            }
            WPEFallbackCard(
                origin: entry.origin,
                reason: WPEFallbackCard.reason(for: entry.origin)
            )
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var hasActiveSceneWallpaper: Bool {
        guard let configuration = screenManager.getConfiguration(for: screen),
              case .scene = configuration.activeWallpaper,
              configuration.wpeOrigin != nil else { return false }
        return true
    }

    /// When the active wallpaper for this screen is a scene, render the
    /// detail card directly so the user sees the live preview + state machine
    /// instead of having to dig back to the imports grid.
    @ViewBuilder
    private var activeSceneCard: some View {
        if let configuration = screenManager.getConfiguration(for: screen),
           case .scene(let descriptor) = configuration.activeWallpaper,
           let origin = configuration.wpeOrigin {
            let session = screen.runtimeSession as? SceneWallpaperSession
            VStack(spacing: 16) {
                HStack {
                    Button {
                        showWorkshopGallery = true
                    } label: {
                        Label("Browse Library…", systemImage: "books.vertical")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.regular)
                    Spacer()
                    Button {
                        presentFolderPicker()
                    } label: {
                        Label("Import New…", systemImage: "plus")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.regular)
                }
                WPESceneDetailView(
                    origin: origin,
                    descriptor: descriptor,
                    session: session,
                    onClearWallpaper: {
                        screenManager.clearWallpaperForScreen(screen)
                    }
                )
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .top)
        } else {
            EmptyView()
        }
    }

    // MARK: - Actions

    private var activeWorkshopID: String? {
        screenManager.getConfiguration(for: screen)?.wpeOrigin?.workshopID
    }

    private func reloadHistory() {
        recentImports = SettingsManager.shared.loadGlobalSettings().recentWPEImports
    }

    /// Plan §A4/A5: when a `scene` / `application` / `unknown` import lands for
    /// THIS screen, auto-promote the user into the unsupported placeholder card
    /// so they see the preview + tip without having to dig through the grid.
    /// Defers state mutation to the next runloop tick so we don't ask SwiftUI
    /// to switch branches (and remount `NSViewRepresentable` previews) during
    /// the same body evaluation that just refreshed `recentImports`.
    /// Selects by `workshopID` so two scene imports back-to-back never collide.
    private func selectUnsupportedImportIfNeeded(from notification: Notification) {
        guard let screenID = notification.userInfo?["screenID"] as? CGDirectDisplayID,
              screenID == screen.id,
              let rawType = notification.userInfo?["type"] as? String,
              let type = WPEType(rawValue: rawType) else { return }

        let workshopID = notification.userInfo?["workshopID"] as? String

        DispatchQueue.main.async {
            switch type {
            case .scene, .application, .unknown:
                if let workshopID {
                    selectedHistoryEntry = recentImports.first { $0.origin.workshopID == workshopID }
                } else {
                    selectedHistoryEntry = recentImports.first { $0.origin.originalType == type }
                }
            case .video, .web:
                selectedHistoryEntry = nil
            }
        }
    }

    private func handleTap(entry: WPEHistoryEntry) {
        switch entry.origin.originalType {
        case .scene, .application, .unknown:
            selectedHistoryEntry = entry
        case .video, .web:
            Task { @MainActor in
                await screenManager.activateWPEHistoryEntry(entry, for: screen)
                reloadHistory()
            }
        }
    }

    private func handleRemove(entry: WPEHistoryEntry) {
        screenManager.removeWPEImport(workshopID: entry.id)
        if selectedHistoryEntry?.id == entry.id {
            selectedHistoryEntry = nil
        }
        reloadHistory()
    }

    private func presentFolderPicker() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.Panel.importProject

        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let lwDir = docs.appendingPathComponent("Live Wallpapers")
            if FileManager.default.fileExists(atPath: lwDir.path) {
                panel.directoryURL = lwDir
            }
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            await screenManager.importWallpaperEngineProject(at: url, for: screen)
            reloadHistory()
        }
    }
}
