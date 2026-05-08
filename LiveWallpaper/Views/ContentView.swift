import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(ScreenManager.self) private var screenManager
    @State private var selectedNavigation: Navigation?
    @State private var didConsumeInitialAddWallpaperPrompt = false
    private let initialAddWallpaperPromptKind: String?

    init(initialNavigation: Navigation? = nil, initialAddWallpaperPromptKind: String? = nil) {
        _selectedNavigation = State(initialValue: initialNavigation)
        self.initialAddWallpaperPromptKind = initialAddWallpaperPromptKind
    }

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $selectedNavigation)
                .onReceive(NotificationCenter.default.publisher(for: .selectScreenInSettings)) { notification in
                    guard let screenID = notification.userInfo?["screenID"] as? CGDirectDisplayID else { return }
                    selectedNavigation = .screen(screenID)
                }
                .onReceive(NotificationCenter.default.publisher(for: .openAppleAerials)) { _ in
                    selectedNavigation = .appleAerials
                }
                .onReceive(NotificationCenter.default.publisher(for: .promptAddWallpaper)) { notification in
                    handleAddWallpaperPrompt(notification: notification)
                }
        } detail: {
            DetailContent(selection: $selectedNavigation)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button(action: {
                            selectedNavigation = .general
                        }) {
                            Image(systemName: "gearshape")
                        }
                        .help(Text("Preferences"))
                        .accessibilityLabel(Text("Preferences"))
                        .accessibilityHint(Text("Open application preferences"))
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(
            minWidth: SettingsWindowMetrics.minimumContentSize.width,
            minHeight: SettingsWindowMetrics.minimumContentSize.height
        )
        .onAppear { consumeInitialAddWallpaperPromptIfNeeded() }
    }

    /// Receives `.promptAddWallpaper` notifications from a re-used settings
    /// window (one already mounted). The fresh-window path uses
    /// `initialAddWallpaperPromptKind` consumed in `onAppear`.
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

    /// Routes a menu-bar quick-add request to the appropriate picker. Targets
    /// the currently-selected screen if the user has one open; otherwise the
    /// first registered display. Selection is also redirected so the user
    /// sees the result land.
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
        panel.allowedContentTypes = [.movie, .video, .quickTimeMovie, .mpeg4Movie, .avi]
        panel.directoryURL = SettingsManager.shared.getLastUsedDirectory()
        panel.prompt = L10n.Panel.useAsWallpaper
        guard panel.runModal() == .OK, let url = panel.url,
              let bookmark = ResourceUtilities.createBookmark(for: url) else { return }
        SettingsManager.shared.saveLastUsedDirectory(url.deletingLastPathComponent())
        screenManager.setVideo(url: url, bookmarkData: bookmark, for: screen)
    }

    private func promptHTMLFile(for screen: Screen) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType.html]
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
}

// MARK: - Sidebar View
struct Sidebar: View {
    @Binding var selection: Navigation?
    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isReloading = false

    var body: some View {
        List(selection: $selection) {
            Section(header: HStack(spacing: 4) {
                Text("Displays").font(.caption).bold().foregroundStyle(.secondary)
                Button(action: reloadWallpapers) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .symbolEffect(.rotate, options: .repeat(.continuous), isActive: isReloading)
                }
                .buttonStyle(.plain)
                .help(Text("Reload all wallpapers"))
                .accessibilityLabel(Text("Reload all wallpapers"))
                .accessibilityHint(Text("Reapplies the active wallpaper on every display"))
            }) {
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
            }
            
            Section(header: VStack(alignment: .leading, spacing: 6) {
                Divider()
                Text("Library").font(.caption).bold().foregroundStyle(.secondary)
            }) {
                NavigationLink(value: Navigation.bookmarks) {
                    Label("My Wallpapers", systemImage: "bookmark.fill")
                }
                NavigationLink(value: Navigation.appleAerials) {
                    Label("Apple Aerials", systemImage: "sparkles.tv")
                }
                NavigationLink(value: Navigation.workshop) {
                    Label("Workshop Library", systemImage: "cube.transparent")
                }
                .accessibilityHint(Text("Browse Wallpaper Engine workshop projects"))
            }

            Section(header: VStack(alignment: .leading, spacing: 6) {
                Divider()
                Text("Dashboard").font(.caption).bold().foregroundStyle(.secondary)
            }) {
                SystemMonitorView()
                    .padding(.vertical, 2)
                    // Tight 4pt horizontal inset. Default List inset on macOS 26 drifts
                    // with sidebar width, causing dashboard cards to misalign on resize.
                    .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4))
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.sidebar)
        // Reserve the standard ~28pt titlebar height as a top safe area so
        // the first sidebar row never renders under the window's
        // traffic-light controls. `.fullSizeContentView` lets content
        // bleed under the transparent titlebar otherwise.
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: 28)
        }
        .navigationSplitViewColumnWidth(
            min: SettingsWindowMetrics.sidebarColumnWidth,
            ideal: SettingsWindowMetrics.sidebarColumnWidth,
            max: SettingsWindowMetrics.sidebarColumnMaxWidth
        )
    }

    private func reloadWallpapers() {
        withAnimation(DesignTokens.motion(reduceMotion, .snappy(duration: 0.2))) {
            isReloading = true
        }

        screenManager.reloadAllScreens()

        Task {
            try? await Task.sleep(for: .milliseconds(500))
            withAnimation(DesignTokens.motion(reduceMotion, .snappy(duration: 0.2))) {
                isReloading = false
            }
        }
    }

    private func handleVideoDrop(urls: [URL], for screen: Screen) -> Bool {
        guard let videoURL = urls.first else { return false }
        guard let bookmarkData = ResourceUtilities.createBookmark(for: videoURL) else {
            return false
        }
        screenManager.setVideo(url: videoURL, bookmarkData: bookmarkData, for: screen)
        return true
    }
}

// MARK: - Screen Row
struct ScreenRow: View {
    var screen: Screen
    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var hasEffectBadge: Bool = false

    var body: some View {
        let summary = screenManager.wallpaperSummary(for: screen)

        HStack(spacing: 4) {
            Image(systemName: iconName(for: summary))
                .foregroundStyle(iconColor(for: summary))
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 4) {
                Text(screen.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(screen.name)

                HStack(spacing: 6) {
                    Text("\(Int(screen.frame.width))×\(Int(screen.frame.height))")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if summary.isConfigured {
                        HStack(spacing: 2) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 6))
                                .foregroundStyle(statusColor(for: summary))
                                .symbolEffect(.pulse, options: .repeat(.continuous), isActive: summary.activity == .active)

                            Text(statusText(for: summary))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if hasEffectBadge {
                            Image(systemName: "sparkles")
                                .font(.caption2)
                                .foregroundStyle(Color.accentColor)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .onAppear { refreshEffectBadge() }
        .onChange(of: screen.id) { refreshEffectBadge() }
        .onReceive(NotificationCenter.default.publisher(for: .wallpaperConfigurationDidChange)) { notification in
            if let changedID = notification.userInfo?["screenID"] as? CGDirectDisplayID,
               changedID == screen.id {
                withAnimation(DesignTokens.motion(reduceMotion, .snappy(duration: 0.2))) { refreshEffectBadge() }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(screen.name), \(Int(screen.frame.width)) by \(Int(screen.frame.height)) pixels"))
        .accessibilityValue(accessibilityValue(for: summary))
        .accessibilityHint(Text("Double-tap to configure this display"))
    }

    private func refreshEffectBadge() {
        guard let config = screenManager.getConfiguration(for: screen) else {
            hasEffectBadge = false
            return
        }
        hasEffectBadge = config.effectConfig.hasActiveEffect || config.particleEffect != .none
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

    private func statusColor(for summary: WallpaperSessionSummary) -> Color {
        switch summary.activity {
        case .active:
            return .green
        case .paused:
            return .orange
        case .inactive:
            return .secondary
        }
    }

    private func statusText(for summary: WallpaperSessionSummary) -> String {
        switch summary.wallpaperType {
        case .html:
            return "HTML"
        case .metalShader:
            return "Shader"
        case .video:
            return summary.activity == .active ? "Playing" : "Paused"
        case .scene:
            return "Scene"
        case nil:
            return "Not configured"
        }
    }

    private func accessibilityValue(for summary: WallpaperSessionSummary) -> String {
        switch summary.wallpaperType {
        case .html:
            return "HTML wallpaper active"
        case .metalShader:
            return "Shader wallpaper active"
        case .video:
            return summary.activity == .active ? "Playing video" : "Video paused"
        case .scene:
            return "Scene wallpaper"
        case nil:
            return "No wallpaper configured"
        }
    }
}

// MARK: - Detail Content
struct DetailContent: View {
    @Binding var selection: Navigation?
    @Environment(ScreenManager.self) private var screenManager

    var body: some View {
        Group {
            switch selection {
            case .general:
                GeneralSettingsView()
                    .transition(.opacity)
                
            case .screen(let screenId):
                if let screen = screenManager.screens.first(where: { $0.id == screenId }) {
                    ScreenDetailView(screen: screen)
                        .transition(.opacity)
                } else {
                    EmptyStateView(
                        icon: "display.trianglebadge.exclamationmark",
                        title: "Display Not Found",
                        message: "The selected display is no longer available."
                    )
                }

            case .appleAerials:
                AppleAerialsLibraryView()
                    .transition(.opacity)

            case .bookmarks:
                BookmarksLibraryView()
                    .transition(.opacity)

            case .workshop:
                WorkshopGalleryView()
                    .transition(.opacity)

            case .none:
                EmptyStateView(
                    icon: "arrow.left.circle",
                    title: "Select a Display",
                    message: "Choose a display from the sidebar to configure your live wallpaper."
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.underPageBackgroundColor))
        .animation(.snappy(duration: 0.3), value: selection)
    }
}

// MARK: - Empty State View
struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(spacing: 20) {
                Image(systemName: icon)
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary.opacity(0.7))
                    .frame(width: 80, height: 80)
                    .glassEffect(.regular, in: .circle)
                    .contentTransition(.symbolEffect(.replace))

                Text(title)
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }
            .padding(32)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
