import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// MenuBarExtra window content.
struct MenuBarContent: View {
    let openSettings: () -> Void
    let openSettingsForScreen: (CGDirectDisplayID) -> Void
    let promptAddWallpaper: (String) -> Void

    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.dismiss) private var dismiss

    @State private var globalPauseOnBattery: Bool = SettingsManager.shared.loadGlobalSettings().globalPauseOnBattery
    @State private var globalPauseOnFullScreen: Bool = SettingsManager.shared.loadGlobalSettings().pauseOnFullScreen
    @AppStorage("Dashboard.RAMScope") private var ramScopeRaw: String = "system"
    /// Persisted across launches so power users keep the live readout visible
    /// while casual users see a one-line summary by default. The 280pt status
    /// bar overlay was the noisiest surface in the audit.
    @AppStorage("MenuBar.DashboardExpanded") private var dashboardExpanded: Bool = false

    @State private var isWebURLEntryExpanded: Bool = false
    @State private var webURLDraft: String = ""
    @State private var showBookmarksPopover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var monitor: SystemMonitor { .shared }
    private var ramPercent: Double {
        ramScopeRaw == "app" ? monitor.memoryPercentage() : monitor.systemMemoryUsage * 100
    }
    private var cpuPercent: Double {
        ramScopeRaw == "app" ? monitor.cpuUsage : monitor.systemCpuUsage
    }

    @ViewBuilder
    private func ramScopeButton(label: LocalizedStringKey, value: String) -> some View {
        Button {
            withAnimation(DesignTokens.motion(reduceMotion, .snappy(duration: 0.18))) { ramScopeRaw = value }
        } label: {
            Text(label)
                .font(.system(size: 10, weight: ramScopeRaw == value ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(ramScopeRaw == value ? Color.accentColor.opacity(0.35) : Color.clear)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(value == "system"
            ? Text("Show whole-system memory usage")
            : Text("Show this app's memory usage"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            miniDashboard
            Divider()
            screenSection
            Divider()
            quickActions
            Divider()
            quickToggles
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 280)
        .onAppear { refreshGlobalToggles() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 16))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text("LiveWallpaper")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Text(verbatim: versionString)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text("Version \(versionString)", comment: "A11y label for the app version. The placeholder is the version string."))
        }
    }

    // MARK: - Mini Dashboard

    private var miniDashboard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(DesignTokens.motion(reduceMotion, .snappy(duration: 0.18))) { dashboardExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(dashboardExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                    Text(verbatim: dashboardSummary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("System Monitor"))
            .accessibilityValue(dashboardAccessibilityValue)
            .accessibilityHint(dashboardExpanded
                ? Text("Double tap to collapse")
                : Text("Double tap to expand"))

            if dashboardExpanded {
                // RAM scope picker — explicit segmented capsule shared with sidebar.
                HStack(spacing: 0) {
                    ramScopeButton(label: "All", value: "system")
                    ramScopeButton(label: "App", value: "app")
                }
                .padding(2)
                .background(Capsule().fill(Color.gray.opacity(0.18)))
                .frame(maxWidth: 180)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text("RAM scope"))

                chipRow
            }
        }
    }

    private var dashboardSummary: String {
        let cpu = FormatUtils.formatPercent(cpuPercent.rounded())
        let ram = FormatUtils.formatPercent(ramPercent.rounded())
        let gpu = FormatUtils.formatPercent(monitor.gpuUsage.rounded())
        return "CPU \(cpu) · GPU \(gpu) · RAM \(ram)"
    }

    private var dashboardAccessibilityValue: Text {
        dashboardExpanded
            ? Text("Expanded, \(dashboardSummary)", comment: "A11y value for the expanded system monitor dashboard. The placeholder is the CPU/GPU/RAM summary.")
            : Text("Collapsed, \(dashboardSummary)", comment: "A11y value for the collapsed system monitor dashboard. The placeholder is the CPU/GPU/RAM summary.")
    }

    private var chipRow: some View {
        HStack(spacing: 8) {
            DashboardChip(label: "CPU", value: cpuPercent, color: dashboardColor(for: cpuPercent), icon: "cpu")
            DashboardChip(label: "GPU", value: monitor.gpuUsage, color: dashboardColor(for: monitor.gpuUsage), icon: "square.stack.3d.up.fill")
            DashboardChip(label: "RAM", value: ramPercent, color: dashboardColor(for: ramPercent), icon: "memorychip")
            DashboardChip(
                label: monitor.videoFPS > 0 ? "EST" : "—",
                value: min(monitor.videoFPS, 120) / 120 * 100,
                color: monitor.videoFPS >= 30 ? .green : (monitor.videoFPS > 0 ? .orange : .secondary),
                icon: "speedometer",
                displayValue: monitor.videoFPS > 0 ? "\(Int(monitor.videoFPS))" : "—"
            )
        }
    }

    // MARK: - Per-Screen Cards

    private var screenSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DISPLAYS")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)

            if screenManager.screens.isEmpty {
                Text("No displays detected")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(screenManager.screens, id: \.id) { screen in
                    MenuBarScreenCard(
                        screen: screen,
                        videoName: screenManager.currentVideoDisplayName(for: screen),
                        htmlName: resolveCurrentHTMLName(for: screen),
                        onOpen: { openSettingsForScreen(screen.id) },
                        onPlayPause: { togglePlayback(for: screen) },
                        onPrev: { screenManager.regressPlaylist(for: screen) },
                        onNext: { screenManager.advancePlaylist(for: screen) }
                    )
                }
            }
        }
    }

    // MARK: - Quick Actions

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ADD WALLPAPER")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)

            HStack(spacing: 6) {
                QuickActionButton(label: "Web Page", systemImage: "globe") {
                    withAnimation(DesignTokens.motion(reduceMotion, .snappy(duration: 0.18))) { isWebURLEntryExpanded.toggle() }
                }
                QuickActionButton(label: "HTML File", systemImage: "doc.richtext") {
                    requestAddWallpaper(kind: "html-file")
                }
                QuickActionButton(label: "Folder", systemImage: "folder") {
                    requestAddWallpaper(kind: "html-folder")
                }
                QuickActionButton(label: "Bookmarks", systemImage: "bookmark.fill") {
                    showBookmarksPopover = true
                }
                .popover(isPresented: $showBookmarksPopover, arrowEdge: .bottom) {
                    if let target = screenManager.screens.first {
                        BookmarksPopover(screen: target)
                            .environment(screenManager)
                    } else {
                        Text("No display detected").padding(20)
                    }
                }
            }

            if isWebURLEntryExpanded {
                webURLEntryRow
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var webURLEntryRow: some View {
        HStack(spacing: 6) {
            TextField("example.com or https://…", text: $webURLDraft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .onSubmit { commitWebURLEntry() }

            Button {
                commitWebURLEntry()
            } label: {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .disabled(webURLDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help(Text("Use as wallpaper for the first display"))
            .accessibilityLabel(Text("Apply web URL"))
            .accessibilityHint(Text("Use the URL above as wallpaper for the first display"))
        }
    }

    // MARK: - Quick Toggles

    private var quickToggles: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("QUICK TOGGLES")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)

            Toggle(isOn: $globalPauseOnBattery) {
                Label("Pause on Battery", systemImage: "bolt.slash")
                    .font(.system(size: 12))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .onChange(of: globalPauseOnBattery) { _, _ in commitGlobalToggles() }

            Toggle(isOn: $globalPauseOnFullScreen) {
                Label("Pause on Full-Screen Apps", systemImage: "macwindow")
                    .font(.system(size: 12))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .onChange(of: globalPauseOnFullScreen) { _, _ in commitGlobalToggles() }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button(action: invokeOpenSettings) {
                Label("Settings", systemImage: "gearshape")
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut(",", modifiers: .command)

            Button(action: { screenManager.reloadAllScreens() }) {
                Label("Reload", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut("r", modifiers: .command)

            Button(role: .destructive, action: { NSApp.terminate(nil) }) {
                Label("Quit", systemImage: "power")
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .controlSize(.small)
    }

    // MARK: - Helpers

    private func invokeOpenSettings() {
        dismiss()
        openSettings()
    }

    private func togglePlayback(for screen: Screen) {
        guard let playback = screen.playbackController else { return }
        PlaybackToggle.toggle(playback)
    }

    private func resolveCurrentHTMLName(for screen: Screen) -> String? {
        screenManager.getConfiguration(for: screen)?.htmlSource?.displayName
    }

    // MARK: - Quick Action Handlers

    private func commitWebURLEntry() {
        let trimmed = webURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let source = HTMLSource(userInput: trimmed),
              let target = screenManager.screens.first else { return }
        screenManager.setHTMLWallpaperPreservingConfig(source: source, for: target)
        webURLDraft = ""
        withAnimation(DesignTokens.motion(reduceMotion, .snappy(duration: 0.18))) { isWebURLEntryExpanded = false }
    }

    /// Hands the picker off to the main window via a synchronous closure
    /// that calls `AppDelegate.showSettings(initialAddWallpaperPromptKind:)`
    /// — this guarantees `ContentView` receives the request at init time
    /// (or via post when the window already exists) instead of racing against
    /// SwiftUI mounting the new scene.
    private func requestAddWallpaper(kind: String) {
        dismiss()
        promptAddWallpaper(kind)
    }

    private func refreshGlobalToggles() {
        let s = SettingsManager.shared.loadGlobalSettings()
        globalPauseOnBattery = s.globalPauseOnBattery
        globalPauseOnFullScreen = s.pauseOnFullScreen
    }

    /// Mutate-then-save preserves any GlobalSettings field this surface
    /// doesn't bind. The previous full-constructor approach silently reset
    /// every field outside the two booleans (defaultFrameRateLimit, showInDock,
    /// weatherLocation, globalShortcuts, recentWPEImports) on every toggle.
    private func commitGlobalToggles() {
        var settings = SettingsManager.shared.loadGlobalSettings()
        settings.globalPauseOnBattery = globalPauseOnBattery
        settings.pauseOnFullScreen = globalPauseOnFullScreen
        SettingsManager.shared.saveGlobalSettings(settings)
        screenManager.handleGlobalSettingsChanged()
    }

    private func dashboardColor(for percent: Double) -> Color {
        if percent >= 80 { return .red }
        if percent >= 50 { return .orange }
        return .green
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        return "v\(version)"
    }
}

@MainActor
enum PlaybackToggle {
    static func toggle(_ playback: any WallpaperPlaybackControllable) {
        if playback.isPlaying {
            playback.pause()
        } else {
            playback.play()
        }
    }
}

// MARK: - Dashboard Chip

private struct DashboardChip: View {
    let label: String
    let value: Double
    let color: Color
    let icon: String
    var displayValue: String?

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(color)
                Text(verbatim: label)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: displayValue ?? FormatUtils.formatPercent(value))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
            Capsule()
                .fill(Color.gray.opacity(0.18))
                .frame(height: 3)
                .overlay(
                    GeometryReader { geo in
                        Capsule()
                            .fill(color)
                            .frame(width: geo.size.width * CGFloat(min(max(value, 0), 100) / 100))
                    }
                )
                .frame(height: 3)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(label): \(displayValue ?? FormatUtils.formatPercent(value))", comment: "A11y label for a dashboard metric chip. The first placeholder is the metric label, the second is its value."))
    }
}

// MARK: - Per-Screen Card

private struct MenuBarScreenCard: View {
    let screen: Screen
    let videoName: String?
    let htmlName: String?
    let onOpen: () -> Void
    let onPlayPause: () -> Void
    let onPrev: () -> Void
    let onNext: () -> Void

    @Environment(ScreenManager.self) private var screenManager
    @State private var isHovering = false

    private var isPlaying: Bool {
        summary.activity == .active
    }

    private var summary: WallpaperSessionSummary {
        screenManager.wallpaperSummary(for: screen)
    }

    var body: some View {
        let summary = screenManager.wallpaperSummary(for: screen)
        let isPlaying = summary.activity == .active

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 13))
                    .foregroundStyle(iconColor)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: screen.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    subtitleText
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Button(action: onOpen) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .opacity(isHovering ? 1 : 0.5)
                .help(Text("Configure this display"))
            }

            if summary.supportsPlaybackControl {
                HStack(spacing: 12) {
                    Button(action: onPrev) {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help(Text("Previous video"))

                    Button(action: onPlayPause) {
                        Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .contentTransition(.symbolEffect(.replace))
                    .help(isPlaying
                        ? Text("Pause", comment: "Tooltip for the play/pause button when playback is active.")
                        : Text("Play", comment: "Tooltip for the play/pause button when playback is paused."))

                    Button(action: onNext) {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help(Text("Next video"))

                    Spacer()
                }
                .padding(.leading, 26)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovering ? Color.primary.opacity(0.06) : Color.clear)
        )
        .onHover { isHovering = $0 }
    }

    private var iconName: String {
        switch summary.wallpaperType {
        case .html: return "globe"
        case .metalShader: return "sparkles.rectangle.stack"
        case .video: return summary.activity == .active ? "play.rectangle.fill" : "pause.rectangle.fill"
        case .scene: return "cube.transparent"
        case nil: return "display"
        }
    }

    private var iconColor: Color {
        switch summary.activity {
        case .active: return .green
        case .paused: return .orange
        case .inactive: return .secondary
        }
    }

    private var subtitleText: Text {
        if let videoName, summary.wallpaperType == .video { return Text(verbatim: videoName) }
        if let htmlName, summary.wallpaperType == .html { return Text(verbatim: htmlName) }
        switch summary.wallpaperType {
        case .html: return Text("HTML wallpaper")
        case .metalShader: return Text("Shader wallpaper")
        case .video: return Text("Not configured")
        case .scene: return Text("Scene wallpaper")
        case nil: return Text("Not configured")
        }
    }
}

// MARK: - Quick Action Button

private struct QuickActionButton: View {
    let label: LocalizedStringKey
    let systemImage: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .medium))
                Text(label)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 38)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovering ? Color.accentColor.opacity(0.20) : Color.gray.opacity(0.12))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable()
        .onHover { isHovering = $0 }
        .accessibilityLabel(Text(label))
    }
}
