import SwiftUI
import AppKit
import LiveWallpaperCore
import LiveWallpaperSharedUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.featureCatalog) private var featureCatalog
    @State private var selectedNavigation: Navigation?
    @State private var didConsumeInitialAddWallpaperPrompt = false
    /// Sidebar visibility binding. Exists so the view can drive a one-shot
    /// prewarm cycle that emulates the user-discovered "drag the sidebar
    /// closed, then drag it open" gesture, which warms up the underlying
    /// NSSplitView state so the first user-driven sidebar toggle no longer
    /// stalls mid-animation.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var didPrewarmSidebar = false
    @State private var isReloading = false
    /// Cached `GlobalSettings.developerModeEnabled` mirror. Lifted to
    /// `ContentView` so both `Sidebar` and `DetailContent` see the same
    /// value — without this, a stale `.developerTools` selection could
    /// mount the detail view even with the toggle off.
    @State private var developerModeEnabled: Bool = ContentView.loadDeveloperModeEnabled()
    private let initialAddWallpaperPromptKind: String?

    init(initialNavigation: Navigation? = nil, initialAddWallpaperPromptKind: String? = nil) {
        _selectedNavigation = State(initialValue: initialNavigation)
        self.initialAddWallpaperPromptKind = initialAddWallpaperPromptKind
    }

    /// Reads the persisted Developer Mode flag in Pro. Pinned to `false`
    /// in Lite so a settings import can never auto-light the Developer
    /// Tools surface inside the lightweight runtime.
    private static func loadDeveloperModeEnabled() -> Bool {
        #if !LITE_BUILD
        return SettingsManager.shared.loadGlobalSettings().developerModeEnabled
        #else
        return false
        #endif
    }

    private var canShowDeveloperTools: Bool {
        #if !LITE_BUILD
        return developerModeEnabled && featureCatalog.isEnabled(.developerTools)
        #else
        return false
        #endif
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            DetailContent(selection: $selectedNavigation, canShowDeveloperTools: canShowDeveloperTools)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar { toolbarContent }
        .frame(
            minWidth: SettingsWindowMetrics.minimumContentSize.width,
            minHeight: SettingsWindowMetrics.minimumContentSize.height
        )
        .onReceive(NotificationCenter.default.publisher(for: .openGeneralSettings)) { _ in
            scheduleNavigationChange { selectedNavigation = .general }
        }
        .onReceive(NotificationCenter.default.publisher(for: .screensRefreshed)) { _ in
            scheduleDefaultDisplaySelection()
        }
        .onReceive(NotificationCenter.default.publisher(for: .developerModeDidChange)) { _ in
            refreshDeveloperModeStateAndSelection()
        }
        .onAppear {
            refreshDeveloperModeStateAndSelection()
            scheduleDefaultDisplaySelection()
            consumeInitialAddWallpaperPromptIfNeeded()
            prewarmSidebarIfNeeded()
        }
    }

    /// Sidebar wrapper that captures the listeners shared between the
    /// `selectScreenInSettings` / `promptAddWallpaper` notifications and,
    /// in direct-distribution Pro, the Workshop entry button.
    @ViewBuilder
    private var sidebar: some View {
        Sidebar(
            selection: $selectedNavigation,
            developerModeEnabled: developerModeEnabled
        )
        .onReceive(NotificationCenter.default.publisher(for: .selectScreenInSettings)) { notification in
            guard let screenID = notification.userInfo?["screenID"] as? CGDirectDisplayID else { return }
            scheduleNavigationChange { selectedNavigation = .screen(screenID) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .promptAddWallpaper)) { notification in
            handleAddWallpaperPrompt(notification: notification)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                scheduleNavigationChange { selectedNavigation = .general }
            } label: {
                Image(systemName: "gearshape")
            }
            .help(Text(L10n.Toolbar.preferences))
            .accessibilityLabel(Text(L10n.Toolbar.preferences))
            .accessibilityHint(Text("Open application preferences"))
        }
        ToolbarItem(placement: .primaryAction) {
            Button(action: invokeAddWallpaper) {
                Image(systemName: "plus")
            }
            .help(Text(L10n.Toolbar.addWallpaper))
            .accessibilityLabel(Text(L10n.Toolbar.addWallpaper))
            .accessibilityHint(Text("Pick a video for the selected display"))
            .disabled(screenManager.screens.isEmpty)
        }
        ToolbarItem(placement: .primaryAction) {
            Button(action: invokeReload) {
                if #available(macOS 15.0, *) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .symbolEffect(.rotate, options: .continuouslyRepeating, isActive: isReloading)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .symbolEffect(.pulse, options: .continuouslyRepeating, isActive: isReloading)
                }
            }
            .help(Text("Reload all wallpapers"))
            .accessibilityLabel(Text("Reload all wallpapers"))
            .accessibilityHint(Text("Reapplies the active wallpaper on every display"))
            .disabled(screenManager.screens.isEmpty)
        }
    }

    /// Mimics the user-discovered "drag the sidebar closed then drag it open"
    /// warmup, but programmatically and animation-suppressed so there is no
    /// visible flash. Fires once per ContentView lifetime; the cached
    /// NSWindowController preserves the warmed state across window close.
    private func prewarmSidebarIfNeeded() {
        guard !didPrewarmSidebar else { return }
        didPrewarmSidebar = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                columnVisibility = .detailOnly
            }
            try? await Task.sleep(for: .milliseconds(30))
            withTransaction(transaction) {
                columnVisibility = .all
            }
        }
    }

    private func scheduleDefaultDisplaySelection() {
        DispatchQueue.main.async {
            Task { @MainActor in
                selectDefaultDisplayIfNeeded()
            }
        }
    }

    /// W4 fix — schedule navigation mutations outside the current view-update
    /// pass so a synchronous poster (now or in the future) cannot trigger
    /// "Modifying state during view update" warnings.
    private func scheduleNavigationChange(_ apply: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            apply()
        }
    }

    /// Re-reads Developer Mode from disk and falls the selection back to
    /// `.general` if the user just disabled the toggle while sitting on
    /// the Developer Tools page. Centralised so the notification handler
    /// and any startup re-entry use the same logic.
    private func refreshDeveloperModeStateAndSelection() {
        developerModeEnabled = ContentView.loadDeveloperModeEnabled()
        #if !LITE_BUILD
        if !canShowDeveloperTools, selectedNavigation == .developerTools {
            scheduleNavigationChange { selectedNavigation = .general }
        }
        #endif
    }

    private func selectDefaultDisplayIfNeeded() {
        guard screenManager.screens.count == 1, let screen = screenManager.screens.first else { return }

        switch selectedNavigation {
        case nil:
            selectedNavigation = .screen(screen.id)
        case .screen(let selectedID) where selectedID != screen.id:
            selectedNavigation = .screen(screen.id)
        default:
            break
        }
    }

    /// Receives `.promptAddWallpaper` notifications from a re-used settings window (one already mounted).
    private func handleAddWallpaperPrompt(notification: Notification) {
        guard let kind = notification.userInfo?["kind"] as? String else { return }
        handleAddWallpaperPrompt(kind: kind)
    }

    private func consumeInitialAddWallpaperPromptIfNeeded() {
        guard !didConsumeInitialAddWallpaperPrompt,
              let kind = initialAddWallpaperPromptKind else { return }
        didConsumeInitialAddWallpaperPrompt = true
        handleAddWallpaperPrompt(kind: kind)
    }

    /// Routes a menu-bar quick-add request to the appropriate picker.
    private func handleAddWallpaperPrompt(kind: String) {
        guard let target = preferredAddWallpaperTarget() else { return }
        selectedNavigation = .screen(target.id)

        switch kind {
        case "video":
            promptVideoFile(for: target)
        case "html-file":
            promptHTMLFile(for: target)
        case "html-folder":
            promptHTMLFolder(for: target)
        default:
            break
        }
    }

    private func invokeAddWallpaper() {
        handleAddWallpaperPrompt(kind: "video")
    }

    /// Click feedback for the toolbar reload button. The underlying
    /// `reloadAllScreens()` is fire-and-forget; the symbol effect is a
    /// click-affordance only, not a real progress signal.
    private func invokeReload() {
        guard !isReloading else { return }
        withAnimation(DesignTokens.motion(reduceMotion, .snappy(duration: 0.2))) {
            isReloading = true
        }
        screenManager.reloadAllScreens()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            withAnimation(DesignTokens.motion(reduceMotion, .snappy(duration: 0.2))) {
                isReloading = false
            }
        }
    }

    private func preferredAddWallpaperTarget() -> Screen? {
        if case .screen(let id) = selectedNavigation,
           let match = screenManager.screens.first(where: { $0.id == id }) {
            return match
        }
        return screenManager.screens.first
    }

    private func promptVideoFile(for screen: Screen) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ResourceUtilities.supportedVideoContentTypes
        panel.directoryURL = SettingsManager.shared.getLastUsedDirectory()
        panel.prompt = L10n.Panel.useAsWallpaper
        guard panel.runModal() == .OK, let url = panel.url,
              let bookmark = ResourceUtilities.createVideoBookmark(for: url) else { return }
        SettingsManager.shared.saveLastUsedDirectory(url.deletingLastPathComponent())
        screenManager.setVideo(url: url, bookmarkData: bookmark, for: screen)
    }

    private func promptHTMLFile(for screen: Screen) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ResourceUtilities.supportedHTMLContentTypes
        panel.prompt = L10n.Panel.useAsWallpaper
        guard panel.runModal() == .OK, let url = panel.url,
              let source = ResourceUtilities.htmlSourceFromPickedFile(url) else { return }
        screenManager.setHTMLWallpaperPreservingConfig(source: source, for: screen)
    }

    private func promptHTMLFolder(for screen: Screen) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.Panel.useAsWallpaper
        guard panel.runModal() == .OK, let folderURL = panel.url,
              let bookmark = ResourceUtilities.createBookmark(for: folderURL) else { return }
        let didStart = folderURL.startAccessingSecurityScopedResource()
        defer { if didStart { folderURL.stopAccessingSecurityScopedResource() } }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: folderURL.path)) ?? []
        let indexFileName = ResourceUtilities.inferHTMLIndexFileName(from: entries)
        screenManager.setHTMLWallpaperPreservingConfig(
            source: .folder(bookmarkData: bookmark, indexFileName: indexFileName),
            for: screen
        )
    }
}

// MARK: - Navigation

enum Navigation: Hashable {
    case general
    case screen(CGDirectDisplayID)
    case appleAerials
    case bookmarks
    case workshop
    #if !LITE_BUILD
    case developerTools
    #endif
}

// MARK: - Sidebar View
struct Sidebar: View {
    @Binding var selection: Navigation?
    /// Owned by `ContentView` so the sidebar entry stays in lock-step
    /// with `DetailContent`'s runtime gate.
    let developerModeEnabled: Bool
    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.featureCatalog) private var featureCatalog

    var body: some View {
        List(selection: $selection) {
            Section {
                if screenManager.screens.isEmpty {
                    HStack {
                        Image(systemName: "display.slash")
                            .foregroundStyle(.secondary)
                        Text("No displays detected")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
                } else {
                    ForEach(screenManager.screens, id: \.id) { screen in
                        NavigationLink(value: Navigation.screen(screen.id)) {
                            ScreenRow(screen: screen)
                        }
                        .dropDestination(for: URL.self) { urls, _ in
                            return handleVideoDrop(urls: urls, for: screen)
                        }
                    }
                }
            } header: {
                SidebarSectionHeader(title: "Displays")
            }

            Section {
                NavigationLink(value: Navigation.bookmarks) {
                    Label("My Wallpapers", systemImage: "bookmark.fill")
                }
                NavigationLink(value: Navigation.appleAerials) {
                    Label("Apple Aerials", systemImage: "sparkles.tv")
                }
                // The Workshop pane (Installed + Browse Online) manages every
                // imported project and is the single Workshop surface. It only
                // exists in the direct-distribution Pro build.
                #if !LITE_BUILD && DIRECT_DISTRIBUTION
                if featureCatalog.isEnabled(.wpeImport) {
                    NavigationLink(value: Navigation.workshop) {
                        Label("Steam Workshop", systemImage: "cube.transparent.fill")
                    }
                    .accessibilityLabel(Text("Steam Workshop"))
                    .accessibilityHint(Text("Browse installed and online Workshop wallpapers"))
                }
                #endif

                #if !LITE_BUILD
                if featureCatalog.isEnabled(.developerTools), developerModeEnabled {
                    NavigationLink(value: Navigation.developerTools) {
                        HStack {
                            Label("Developer Tools", systemImage: "wrench.and.screwdriver")
                            Spacer()
                            DevPill()
                        }
                    }
                    .accessibilityHint(Text("Diagnostic harness. Only visible while Developer Mode is on."))
                }
                #endif
            } header: {
                SidebarSectionHeader(title: "Library")
            }

            if featureCatalog.isEnabled(.systemMonitor) {
                Section {
                    SystemMonitorView(
                        activeDisplayCount: activeWallpaperDisplayCount,
                        totalDisplayCount: screenManager.screens.count
                    )
                        .padding(.vertical, 2)
                        .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4))
                        .listRowBackground(Color.clear)
                } header: {
                    SidebarSectionHeader(title: "Usage")
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(
            min: SettingsWindowMetrics.sidebarColumnWidth,
            ideal: SettingsWindowMetrics.sidebarColumnWidth,
            max: SettingsWindowMetrics.sidebarColumnMaxWidth
        )
    }

    /// Snapshot of how many displays are currently in `.active` activity.
    /// Reads via `wallpaperSummary(_:)` so the read tracks the same
    /// `wallpaperSessionState` observation channel as `ScreenRow`, keeping
    /// the Usage chip in lock-step with the sidebar dots.
    private var activeWallpaperDisplayCount: Int {
        screenManager.screens.reduce(0) { acc, screen in
            acc + (screenManager.wallpaperSummary(for: screen).activity == .active ? 1 : 0)
        }
    }

    /// Accepts the first supported video URL in the drop payload — Finder
    /// occasionally sends sidecar files first when dragging a media bundle.
    private func handleVideoDrop(urls: [URL], for screen: Screen) -> Bool {
        guard let videoURL = urls.first(where: ResourceUtilities.isSupportedVideoURL) else { return false }
        guard let bookmarkData = ResourceUtilities.createVideoBookmark(for: videoURL) else { return false }
        screenManager.setVideo(url: videoURL, bookmarkData: bookmarkData, for: screen)
        return true
    }
}

private struct SidebarSectionHeader: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(.caption)
            .bold()
            .foregroundStyle(.secondary)
            .padding(.bottom, DesignTokens.Sidebar.sectionHeaderBottomPadding)
    }
}

// MARK: - Screen Row
struct ScreenRow: View {
    var screen: Screen
    @Environment(ScreenManager.self) private var screenManager

    var body: some View {
        let summary = screenManager.wallpaperSummary(for: screen)

        HStack(spacing: 8) {
            Image(systemName: iconName(for: summary))
                .foregroundStyle(iconColor(for: summary))
                .frame(width: 22, height: 22)

            Text(verbatim: screen.name)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(Text(verbatim: screen.name))
                .frame(maxWidth: .infinity, alignment: .leading)

            if let dotColor = dotColor(for: summary) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(displayAccessibilityLabel)
        .accessibilityValue(accessibilityValue(for: summary))
        .accessibilityHint(Text("Select to configure this display"))
    }

    /// Tri-state status dot — `.green` playing, `.orange` paused, `nil`
    /// (no dot) for unconfigured/inactive displays. We deliberately use raw
    /// system colors here instead of `.tint` / `.accentColor` because the
    /// "is this screen alive right now" signal needs the same universal
    /// red-amber-green semantics users already learned from the menu-bar
    /// usage strip — accent on a selected-row accent background would be
    /// invisible, and `.primary` would lose the playing/paused distinction.
    private func dotColor(for summary: WallpaperSessionSummary) -> Color? {
        switch summary.activity {
        case .active:   return .green
        case .paused:   return .orange
        case .off:      return .secondary
        case .error:    return .red
        case .inactive: return nil
        }
    }

    private var displayAccessibilityLabel: Text {
        Text(
            "\(screen.name), \(Int(screen.frame.width)) by \(Int(screen.frame.height)) pixels",
            comment: "Sidebar row VoiceOver label combining display name and resolution. First placeholder is the display name, second and third are width and height in pixels."
        )
    }

    private func iconName(for summary: WallpaperSessionSummary) -> String {
        switch summary.wallpaperType {
        case .video:
            return summary.isConfigured ? "display.and.arrow.down" : "display"
        case .html:
            return "globe"
        case .metalShader:
            return "sparkles.rectangle.stack"
        case .scene:
            return "cube.transparent"
        case nil:
            return "display"
        }
    }

    private func iconColor(for summary: WallpaperSessionSummary) -> Color {
        summary.isConfigured ? Color.accentColor : Color.secondary
    }

    private func accessibilityValue(for summary: WallpaperSessionSummary) -> Text {
        switch summary.wallpaperType {
        case .html:
            return Text("HTML wallpaper active")
        case .metalShader:
            return Text("Shader wallpaper active")
        case .video:
            return summary.activity == .active ? Text("Wallpaper playing") : Text("Wallpaper paused")
        case .scene:
            return Text("Scene wallpaper")
        case nil:
            return Text("No wallpaper configured")
        }
    }
}

// MARK: - Detail Content
struct DetailContent: View {
    @Binding var selection: Navigation?
    /// Runtime gate for Developer Tools detail mount. Owned by
    /// `ContentView` so a stale or restored `.developerTools` selection
    /// can't bring the diagnostic surface back without the toggle.
    let canShowDeveloperTools: Bool
    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.featureCatalog) private var featureCatalog

    var body: some View {
        Group {
            switch selection {
            case .general:
                GeneralSettingsView()

            case .screen(let screenId):
                if let screen = screenManager.screens.first(where: { $0.id == screenId }) {
                    ScreenDetailView(screen: screen)
                } else {
                    EmptyStateView(
                        icon: "display.trianglebadge.exclamationmark",
                        message: "The selected display is no longer available."
                    )
                }

            case .appleAerials:
                AppleAerialsLibraryView()

            case .bookmarks:
                BookmarksLibraryView()

            case .workshop:
                #if !LITE_BUILD && DIRECT_DISTRIBUTION
                WorkshopPaneView()
                #else
                EmptyView()
                #endif

            #if !LITE_BUILD
            case .developerTools:
                if canShowDeveloperTools {
                    DeveloperToolsView()
                } else {
                    EmptyStateView(
                        icon: "wrench.and.screwdriver",
                        message: "Developer Mode is off. Enable it in Settings → General → Advanced."
                    )
                }
            #endif

            case .none:
                EmptyStateView(
                    icon: "display",
                    message: "Choose a display from the sidebar to configure your live wallpaper."
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.Colors.pageBackground)
    }
}

// MARK: - Empty State View
struct EmptyStateView: View {
    let icon: String
    let message: LocalizedStringKey

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 42, weight: .regular))
                .foregroundStyle(.tertiary)
                .symbolRenderingMode(.hierarchical)

            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
