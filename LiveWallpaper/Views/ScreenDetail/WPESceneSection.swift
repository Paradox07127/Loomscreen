#if !LITE_BUILD
import SwiftUI

/// Top-level Scene tab content. Drives the Wallpaper Engine project flow:
/// folder picker → prepare/apply service → history grid → unsupported placeholder.
@MainActor
struct WPESceneSection: View {
    let screen: Screen
    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var recentImports: [WPEHistoryEntry] = []
    @State private var selectedHistoryEntry: WPEHistoryEntry?
    @State private var showWorkshopGallery: Bool = false
    @State private var pendingDestructive: PendingDestructive?

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
        .animation(reduceMotion ? nil : .default, value: recentImports.isEmpty)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            Task { @MainActor in reloadHistory() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .wpeImportDidComplete)) { notification in
            Task { @MainActor in
                reloadHistory()
                selectUnsupportedImportIfNeeded(from: notification)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .wpeHistoryDidChange)) { _ in
            Task { @MainActor in reloadHistory() }
        }
        .sheet(isPresented: $showWorkshopGallery) {
            WorkshopGalleryView(screen: screen)
                .environment(screenManager)
        }
        .confirmDestructive($pendingDestructive)
        .errorAlert(
            "Apply Failed",
            error: Binding<AppError?>(
                get: { screenManager.wpeImportError(for: screen) },
                set: { if $0 == nil { screenManager.clearWPEImportError(for: screen) } }
            )
        )
    }

    // MARK: - States

    private var emptyState: some View {
        VStack(spacing: 24) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: 8) {
                Text("Apply Local Project")
                    .font(.title2.bold())
                Text("Choose a copied project folder to apply")
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                Button {
                    presentFolderPicker()
                } label: {
                    Label("Apply Project Folder…", systemImage: "folder.badge.plus")
                }
                .adaptiveGlassButton(.prominent)
                .controlSize(.large)
                .accessibilityHint(Text("Opens a folder chooser to apply a copied local project"))

                Button {
                    showWorkshopGallery = true
                } label: {
                    Label("Browse Workshop Library…", systemImage: "books.vertical")
                }
                .adaptiveGlassButton(.regular)
                .controlSize(.regular)
                .accessibilityHint(Text("Browse copied local projects"))
            }
            .padding(.top, 4)

            Text("Supports Video / Web · Scene support varies")
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
                    Text("Recent Imported Projects")
                        .font(.headline)
                    Spacer()
                    Button {
                        showWorkshopGallery = true
                    } label: {
                        Label("Browse Library…", systemImage: "books.vertical")
                    }
                    .adaptiveGlassButton(.regular)
                    .controlSize(.regular)
                    .accessibilityHint(Text("Browse copied local projects"))

                    Button {
                        presentFolderPicker()
                    } label: {
                        Label("Apply Project…", systemImage: "plus")
                    }
                    .adaptiveGlassButton(.regular)
                    .controlSize(.regular)
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 16)],
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
                    Image(systemName: "chevron.left")
                }
                .adaptiveGlassButton(.regular)
                .controlSize(.regular)
                .help(Text("Back to library"))
                .accessibilityLabel(Text("Back to library"))
                .accessibilityHint(Text("Return to the recent imported projects grid"))
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
            // Single, focused "preview + diagnostics" column. Custom settings
            // live in the app's right inspector sidebar (alongside HTML's), so
            // they're always to the side and never stacked under the preview.
            VStack(spacing: 16) {
                sceneToolbar
                WPESceneDetailView(
                    origin: origin,
                    descriptor: descriptor,
                    session: session,
                    onClearWallpaper: {
                        pendingDestructive = PendingDestructive(
                            .clearScene(sceneName: origin.title, displayName: screen.name)
                        ) {
                            screenManager.clearWallpaperForScreen(screen)
                        }
                    }
                )
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .top)
        } else {
            EmptyView()
        }
    }

    private var sceneToolbar: some View {
        HStack {
            Button {
                showWorkshopGallery = true
            } label: {
                Label("Browse Library…", systemImage: "books.vertical")
            }
            .adaptiveGlassButton(.regular)
            .controlSize(.regular)
            Spacer()
            Button {
                presentFolderPicker()
            } label: {
                Label("Apply Project…", systemImage: "plus")
            }
            .adaptiveGlassButton(.regular)
            .controlSize(.regular)
        }
    }

    // MARK: - Actions

    private var activeWorkshopID: String? {
        screenManager.getConfiguration(for: screen)?.wpeOrigin?.workshopID
    }

    private func reloadHistory() {
        recentImports = SettingsManager.shared.loadGlobalSettings().recentWPEImports
    }

    /// Plan §A4/A5: when a `scene` / `application` / `unknown` check lands for THIS screen, auto-promote the user into the unsupported placeholder card so they see the preview + tip without having to dig through the grid.
    private func selectUnsupportedImportIfNeeded(from notification: Notification) {
        guard let screenID = notification.userInfo?["screenID"] as? CGDirectDisplayID,
              screenID == screen.id,
              let rawType = notification.userInfo?["type"] as? String,
              let type = WPEType(rawValue: rawType) else { return }

        let workshopID = notification.userInfo?["workshopID"] as? String

        DispatchQueue.main.async {
            let entry: WPEHistoryEntry?
            if let workshopID {
                entry = recentImports.first { $0.origin.workshopID == workshopID }
            } else {
                entry = recentImports.first { $0.origin.originalType == type }
            }
            guard let entry else { return }

            switch type {
            case .application, .unknown:
                selectedHistoryEntry = entry
            case .scene where entry.origin.resourceLocation == .unsupported:
                selectedHistoryEntry = entry
            case .scene, .video, .web:
                selectedHistoryEntry = nil
            }
        }
    }

    private func handleTap(entry: WPEHistoryEntry) {
        switch entry.origin.originalType {
        case .application, .unknown:
            selectedHistoryEntry = entry
        case .scene where entry.origin.resourceLocation == .unsupported:
            selectedHistoryEntry = entry
        case .scene, .video, .web:
            Task { @MainActor in
                await screenManager.activateWPEHistoryEntry(entry, for: screen)
                reloadHistory()
            }
        }
    }

    private func handleRemove(entry: WPEHistoryEntry) {
        pendingDestructive = PendingDestructive(
            .removeSceneHistory(sceneName: entry.origin.title)
        ) {
            screenManager.removeWPEImport(workshopID: entry.id)
            if selectedHistoryEntry?.id == entry.id {
                selectedHistoryEntry = nil
            }
            reloadHistory()
        }
    }

    private func presentFolderPicker() {
        guard let url = WPEFolderPicker.chooseImportFolder() else { return }
        Task { @MainActor in
            await screenManager.importWallpaperEngineProject(at: url, for: screen)
            reloadHistory()
        }
    }
}
#endif
