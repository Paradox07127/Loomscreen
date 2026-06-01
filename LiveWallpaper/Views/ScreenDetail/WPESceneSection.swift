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
    /// Parsed custom-property schema for the active scene, loaded off the main
    /// actor and used to drive the dedicated settings column.
    @State private var sceneSchema: WallpaperEngineProjectPropertySchema?
    /// In-progress descriptor edits from the settings column. Held locally so a
    /// slider drag tracks smoothly before the debounced apply persists to the
    /// configuration; reset implicitly when the active scene changes.
    @State private var workingDescriptor: SceneDescriptor?

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
        .task(id: sceneSchemaLoadKey) {
            await loadSceneSchema()
        }
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
            GeometryReader { geo in
                // Go side-by-side only when there's room for the 560 preview
                // card + 360 settings column; otherwise stack and scroll so the
                // layout never cramps on a narrow preview area.
                let twoColumn = hasInteractiveSettings && geo.size.width >= 1000
                VStack(spacing: 16) {
                    sceneToolbar
                    if twoColumn {
                        HStack(alignment: .top, spacing: 20) {
                            Spacer(minLength: 0)
                            detailCard(origin: origin, descriptor: descriptor, session: session)
                            settingsColumn(descriptor: descriptor)
                                .frame(width: 360)
                            Spacer(minLength: 0)
                        }
                    } else {
                        ScrollView(.vertical) {
                            VStack(spacing: 16) {
                                detailCard(origin: origin, descriptor: descriptor, session: session)
                                if hasInteractiveSettings, let schema = sceneSchema {
                                    WPESceneCustomSettingsCard(
                                        screen: screen,
                                        schema: schema,
                                        descriptor: sceneDescriptorBinding(fallback: descriptor)
                                    )
                                }
                            }
                            .frame(maxWidth: 560)
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
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

    private func detailCard(
        origin: WPEOrigin,
        descriptor: SceneDescriptor,
        session: SceneWallpaperSession?
    ) -> some View {
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

    /// Dedicated, independently-scrolling column mirroring Wallpaper Engine's
    /// right-hand property panel — shown only when the scene exposes changeable
    /// options (filtered to interactive controls inside the card).
    @ViewBuilder
    private func settingsColumn(descriptor: SceneDescriptor) -> some View {
        if let schema = sceneSchema {
            ScrollView(.vertical) {
                WPESceneCustomSettingsCard(
                    screen: screen,
                    schema: schema,
                    descriptor: sceneDescriptorBinding(fallback: descriptor)
                )
                .padding(.trailing, 2)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    /// True when the loaded schema exposes at least one interactive control.
    private var hasInteractiveSettings: Bool {
        guard let sceneSchema else { return false }
        return sceneSchema.properties.contains { WPESceneCustomSettingsCard.isInteractive($0.type) }
    }

    /// Binding that surfaces in-progress edits (`workingDescriptor`) while the
    /// settings card persists through `ScreenManager.updateSceneDescriptor`.
    /// Falls back to the configuration's descriptor — and resets implicitly —
    /// whenever the active scene (`workshopID`) changes.
    private func sceneDescriptorBinding(fallback: SceneDescriptor) -> Binding<SceneDescriptor> {
        Binding(
            get: {
                if let working = workingDescriptor, working.workshopID == fallback.workshopID {
                    return working
                }
                return fallback
            },
            set: { workingDescriptor = $0 }
        )
    }

    private var sceneSchemaLoadKey: String {
        guard let configuration = screenManager.getConfiguration(for: screen),
              case .scene(let descriptor) = configuration.activeWallpaper else {
            return "hidden"
        }
        let originFingerprint = configuration.wpeOrigin?.sourceFolderBookmark.count.description ?? "-"
        return "\(screen.id):scene:\(descriptor.workshopID):\(originFingerprint)"
    }

    @MainActor
    private func loadSceneSchema() async {
        guard let configuration = screenManager.getConfiguration(for: screen),
              case .scene(let descriptor) = configuration.activeWallpaper else {
            sceneSchema = nil
            return
        }
        let outcome = await WPESceneProjectSchemaLoader.load(
            descriptor: descriptor,
            wpeOrigin: configuration.wpeOrigin
        )
        guard !Task.isCancelled else { return }
        sceneSchema = outcome.schema
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
