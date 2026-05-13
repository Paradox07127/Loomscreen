import SwiftUI
import AppKit

/// MenuBarExtra window content.
struct MenuBarContent: View {
    let openSettings: () -> Void
    let openSettingsForScreen: (CGDirectDisplayID) -> Void
    let promptAddWallpaper: (String) -> Void

    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.dismiss) private var dismiss

    @State private var globalPauseOnBattery: Bool = SettingsManager.shared.loadGlobalSettings().globalPauseOnBattery
    @State private var globalPauseOnFullScreen: Bool = SettingsManager.shared.loadGlobalSettings().pauseOnFullScreen
    @State private var isMorePopoverPresented = false

    private var monitor: SystemMonitor { .shared }

    private var isWallpaperEnabled: Bool {
        screenManager.wallpaperOverviewStatus == .active
    }

    private var isWallpaperSwitchDisabled: Bool {
        screenManager.wallpaperOverviewStatus == .notConfigured
    }

    private var overviewSubtitle: String {
        switch screenManager.wallpaperOverviewStatus {
        case .notConfigured:
            return "No wallpaper configured"
        case .active:
            return "\(screenManager.screens.count) displays active"
        case .paused:
            return "\(screenManager.screens.count) displays paused"
        }
    }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                header
                sectionLabel("DISPLAYS")
                displays
                sectionLabel("SETTINGS")
                allDisplayActions
                usageStrip
                footer
            }
            .padding(MenuBarControlCenterMetrics.outerPadding)
            .frame(width: MenuBarControlCenterMetrics.popoverWidth)
        }
        .onAppear { refreshGlobalToggles() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22, height: 22)
                .readableGlass(radius: 7, tint: Color.accentColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("LiveWallpaper")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(verbatim: overviewSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 6)

            Button {
                screenManager.setWallpapersEnabled(!isWallpaperEnabled)
            } label: {
                PowerTogglePill(isOn: isWallpaperEnabled)
            }
            .buttonStyle(.plain)
            .disabled(isWallpaperSwitchDisabled)
            .help(isWallpaperEnabled ? Text("Turn off wallpapers") : Text("Turn on wallpapers"))
            .accessibilityLabel(Text("Wallpapers"))
            .accessibilityValue(isWallpaperEnabled ? Text("On") : Text("Off"))
        }
        .frame(maxWidth: .infinity)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(verbatim: title)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .tracking(0.8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var displays: some View {
        VStack(spacing: 5) {
            if screenManager.screens.isEmpty {
                Text("No displays detected")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .center)
                    .readableGlass(radius: 10, tint: .secondary)
            } else {
                ForEach(screenManager.screens, id: \.id) { screen in
                    MenuBarDisplayRow(
                        title: screen.name,
                        subtitle: displaySubtitle(for: screen),
                        iconName: displayIconName(for: screen),
                        iconTint: displayIconColor(for: screen),
                        isPlaying: screenManager.wallpaperSummary(for: screen).activity == .active,
                        showsStatusDot: screenManager.wallpaperSummary(for: screen).activity != .inactive,
                        supportsPlayback: screenManager.wallpaperSummary(for: screen).supportsPlaybackControl,
                        canStepPlaylist: canStepPlaylist(for: screen),
                        openAction: { openSettingsForScreen(screen.id) },
                        previousAction: { screenManager.regressPlaylist(for: screen) },
                        playbackAction: { togglePlayback(for: screen) },
                        nextAction: { screenManager.advancePlaylist(for: screen) }
                    )
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var allDisplayActions: some View {
        HStack(spacing: 5) {
            MenuBarControlButton(
                title: screenManager.wallpaperOverviewStatus == .active ? "Pause All" : "Play All",
                systemImage: screenManager.wallpaperOverviewStatus == .active ? "pause.fill" : "play.fill",
                tint: .accentColor,
                isProminent: true,
                isEnabled: screenManager.hasControllableWallpaperSessions,
                action: { screenManager.togglePlayback() }
            )

            MenuBarControlButton(
                title: "Battery",
                systemImage: globalPauseOnBattery ? "battery.50" : "battery.100",
                tint: globalPauseOnBattery ? .orange : .secondary,
                isProminent: globalPauseOnBattery,
                action: {
                    globalPauseOnBattery.toggle()
                    commitGlobalToggles()
                }
            )

            MenuBarControlButton(
                title: "Mute",
                systemImage: isGlobalMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                tint: isGlobalMuted ? .orange : .secondary,
                isProminent: isGlobalMuted,
                action: { toggleGlobalMute() }
            )
        }
        .frame(maxWidth: .infinity)
    }

    private var usageStrip: some View {
        MenuBarUsageStrip(metrics: [
            MenuBarUsageMetric(
                label: "CPU",
                valueText: FormatUtils.formatPercent(monitor.systemCpuUsage.rounded()),
                progress: monitor.systemCpuUsage / 100,
                color: usageColor(for: monitor.systemCpuUsage)
            ),
            MenuBarUsageMetric(
                label: "GPU",
                valueText: FormatUtils.formatPercent(monitor.gpuUsage.rounded()),
                progress: monitor.gpuUsage / 100,
                color: usageColor(for: monitor.gpuUsage)
            ),
            MenuBarUsageMetric(
                label: "RAM",
                valueText: FormatUtils.formatPercent((monitor.systemMemoryUsage * 100).rounded()),
                progress: monitor.systemMemoryUsage,
                color: usageColor(for: monitor.systemMemoryUsage * 100)
            )
        ])
    }

    private var footer: some View {
        HStack(spacing: 5) {
            Menu {
                Button {
                    dismiss()
                    promptAddWallpaper("video")
                } label: {
                    Label("Video File", systemImage: "film")
                }

                Button {
                    requestAddWallpaper(kind: "html-file")
                } label: {
                    Label("HTML File", systemImage: "doc.richtext")
                }

                Button {
                    requestAddWallpaper(kind: "html-folder")
                } label: {
                    Label("Folder", systemImage: "folder")
                }
            } label: {
                MenuBarFooterLabel(title: "Add Wallpaper", systemImage: "plus")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)

            Button(action: invokeOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 32, height: 30)
                    .readableGlass(radius: 10, tint: .secondary, interactive: true)
            }
            .buttonStyle(.plain)
            .help(Text("Settings"))
            .accessibilityLabel(Text("Settings"))

            Button {
                isMorePopoverPresented.toggle()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 32, height: 30)
                    .readableGlass(radius: 10, tint: .secondary, interactive: true)
            }
            .buttonStyle(.plain)
            .help(Text("More"))
            .accessibilityLabel(Text("More"))
            .popover(isPresented: $isMorePopoverPresented, arrowEdge: .bottom) {
                MenuBarMorePopover(
                    globalPauseOnFullScreen: globalPauseOnFullScreen,
                    reloadAction: {
                        isMorePopoverPresented = false
                        screenManager.reloadAllScreens()
                    },
                    toggleFullScreenPauseAction: {
                        globalPauseOnFullScreen.toggle()
                        commitGlobalToggles()
                    },
                    aboutAction: {
                        isMorePopoverPresented = false
                        NSApp.orderFrontStandardAboutPanel(nil)
                    }
                )
            }

            Button(action: invokeQuit) {
                MenuBarQuitButton()
            }
            .buttonStyle(.plain)
            .help(Text("Quit LiveWallpaper"))
            .accessibilityLabel(Text("Quit LiveWallpaper"))
        }
        .frame(maxWidth: .infinity)
    }

    private var isGlobalMuted: Bool {
        let configurations = SettingsManager.shared.loadConfigurations()
        guard !configurations.isEmpty else { return false }
        return configurations.allSatisfy(\.muted)
    }

    private func displaySubtitle(for screen: Screen) -> String {
        let summary = screenManager.wallpaperSummary(for: screen)
        if let message = summary.subtitle, !message.isEmpty {
            return message
        }

        if summary.wallpaperType == .video,
           let name = screenManager.currentVideoDisplayName(for: screen) {
            return name
        }

        if let name = screenManager.wallpaperDisplayName(for: screen) {
            return name
        }

        switch summary.wallpaperType {
        case .html:
            return "HTML wallpaper"
        case .metalShader:
            return "Shader wallpaper"
        case .scene:
            return "Scene wallpaper"
        case .video:
            return "Video wallpaper"
        case nil:
            return "Not configured"
        }
    }

    private func displayIconName(for screen: Screen) -> String {
        switch screenManager.wallpaperSummary(for: screen).wallpaperType {
        case .html:
            return "globe"
        case .metalShader:
            return "wand.and.stars"
        case .scene:
            return "cube.transparent"
        case .video:
            return "play.rectangle"
        case nil:
            return "display"
        }
    }

    private func displayIconColor(for screen: Screen) -> Color {
        switch screenManager.wallpaperSummary(for: screen).activity {
        case .active:
            return .green
        case .paused:
            return .orange
        case .inactive:
            return .secondary
        }
    }

    private func canStepPlaylist(for screen: Screen) -> Bool {
        guard let config = screenManager.getConfiguration(for: screen),
              config.wallpaperMode == .playlist,
              config.savedVideoBookmarkData != nil
        else {
            return false
        }

        return 1 + (config.playlistBookmarks ?? []).count > 1
    }

    private func togglePlayback(for screen: Screen) {
        guard let playback = screen.playbackController else { return }
        PlaybackToggle.toggle(playback)
    }

    private func requestAddWallpaper(kind: String) {
        dismiss()
        promptAddWallpaper(kind)
    }

    private func invokeOpenSettings() {
        dismiss()
        openSettings()
    }

    private func invokeQuit() {
        NSApp.terminate(nil)
    }

    private func refreshGlobalToggles() {
        let settings = SettingsManager.shared.loadGlobalSettings()
        globalPauseOnBattery = settings.globalPauseOnBattery
        globalPauseOnFullScreen = settings.pauseOnFullScreen
    }

    private func commitGlobalToggles() {
        var settings = SettingsManager.shared.loadGlobalSettings()
        settings.globalPauseOnBattery = globalPauseOnBattery
        settings.pauseOnFullScreen = globalPauseOnFullScreen
        SettingsManager.shared.saveGlobalSettings(settings)
        screenManager.handleGlobalSettingsChanged()
    }

    private func toggleGlobalMute() {
        let configurations = SettingsManager.shared.loadConfigurations()
        let shouldMute = configurations.contains { !$0.muted }

        for screen in screenManager.screens {
            screenManager.updateMuted(shouldMute, for: screen)
        }
    }

    private func usageColor(for percent: Double) -> Color {
        if percent >= 80 { return .red }
        if percent >= 50 { return .orange }
        return .green
    }
}

private enum MenuBarControlCenterMetrics {
    static let popoverWidth: CGFloat = 267
    static let outerPadding: CGFloat = 9
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

private struct PowerTogglePill: View {
    let isOn: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isOn ? Color.green : Color.secondary)
                .frame(width: 6, height: 6)
            Text(isOn ? "On" : "Off")
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(isOn ? Color.green : Color.secondary)
        .padding(.horizontal, 8)
        .frame(height: 27)
        .readableGlass(radius: 14, tint: isOn ? Color.green : Color.secondary, interactive: true)
    }
}

private struct MenuBarDisplayRow: View {
    let title: String
    let subtitle: String
    let iconName: String
    let iconTint: Color
    let isPlaying: Bool
    let showsStatusDot: Bool
    let supportsPlayback: Bool
    let canStepPlaylist: Bool
    let openAction: () -> Void
    let previousAction: () -> Void
    let playbackAction: () -> Void
    let nextAction: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: openAction) {
                HStack(spacing: 6) {
                    Image(systemName: iconName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(iconTint)
                        .frame(width: 20, height: 20)
                        .readableGlass(radius: 7, tint: iconTint)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: title)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                        Text(verbatim: subtitle)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Circle()
                        .fill(iconTint)
                        .frame(width: 5, height: 5)
                        .opacity(showsStatusDot ? 1 : 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text("Open display settings"))

            HStack(spacing: 3) {
                IconControlButton(
                    systemImage: "chevron.left",
                    isEnabled: supportsPlayback && canStepPlaylist,
                    action: previousAction,
                    accessibilityLabel: "Previous wallpaper"
                )

                IconControlButton(
                    systemImage: isPlaying ? "pause.fill" : "play.fill",
                    isEnabled: supportsPlayback,
                    action: playbackAction,
                    accessibilityLabel: isPlaying ? "Pause wallpaper" : "Play wallpaper",
                    isProminent: true
                )

                IconControlButton(
                    systemImage: "chevron.right",
                    isEnabled: supportsPlayback && canStepPlaylist,
                    action: nextAction,
                    accessibilityLabel: "Next wallpaper"
                )
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .readableGlass(radius: 11, tint: iconTint, interactive: true)
    }
}

private struct IconControlButton: View {
    let systemImage: String
    let isEnabled: Bool
    let action: () -> Void
    let accessibilityLabel: String
    var isProminent: Bool = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(isProminent ? Color.accentColor : Color.primary.opacity(0.72))
                .frame(width: 21, height: 21)
                .readableGlass(
                    radius: 7,
                    tint: isProminent ? Color.accentColor : Color.secondary,
                    interactive: isEnabled
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.38)
        .accessibilityLabel(Text(accessibilityLabel))
    }
}

private struct MenuBarControlButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    var isProminent: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                Text(verbatim: title)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, minHeight: 31)
            .readableGlass(radius: 10, tint: tint, interactive: true)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.42)
    }
}

private struct MenuBarUsageMetric {
    let label: String
    let valueText: String
    let progress: Double
    let color: Color
}

private struct MenuBarUsageStrip: View {
    let metrics: [MenuBarUsageMetric]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(metrics, id: \.label) { metric in
                MenuBarUsageMetricView(metric: metric)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .readableGlass(radius: 10, tint: .secondary)
    }
}

private struct MenuBarUsageMetricView: View {
    let metric: MenuBarUsageMetric

    private var clampedProgress: Double {
        min(max(metric.progress, 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Text(verbatim: metric.label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 2)
                Text(verbatim: metric.valueText)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
            }

            GeometryReader { proxy in
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(metric.color)
                            .frame(width: proxy.size.width * clampedProgress)
                    }
            }
            .frame(height: 3)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(metric.label) \(metric.valueText)"))
    }
}

private struct MenuBarMorePopover: View {
    let globalPauseOnFullScreen: Bool
    let reloadAction: () -> Void
    let toggleFullScreenPauseAction: () -> Void
    let aboutAction: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            MenuBarMoreButton(
                title: "Reload Wallpapers",
                systemImage: "arrow.clockwise",
                action: reloadAction
            )

            MenuBarMoreButton(
                title: globalPauseOnFullScreen ? "Disable Full-Screen Pause" : "Enable Full-Screen Pause",
                systemImage: "macwindow",
                action: toggleFullScreenPauseAction
            )

            Divider()

            MenuBarMoreButton(
                title: "About LiveWallpaper",
                systemImage: "info.circle",
                action: aboutAction
            )
        }
        .padding(8)
        .frame(width: 198)
        .readableGlass(radius: 14, tint: .secondary)
    }
}

private struct MenuBarMoreButton: View {
    let title: String
    let systemImage: String
    var tint: Color = .primary
    var surfaceTint: Color = .secondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 16)
                Text(verbatim: title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 30)
            .readableGlass(radius: 9, tint: surfaceTint, interactive: true)
        }
        .buttonStyle(.plain)
    }
}

private struct MenuBarFooterLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
            Text(verbatim: title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 30)
        .readableGlass(radius: 10, tint: .accentColor, interactive: true)
    }
}

private struct MenuBarQuitButton: View {
    var body: some View {
        Image(systemName: "power")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.red)
            .frame(width: 32, height: 30)
            .readableGlass(radius: 10, tint: .red, interactive: true)
    }
}

private extension View {
    func readableGlass(radius: CGFloat, tint: Color, interactive: Bool = false) -> some View {
        modifier(ReadableGlassSurface(radius: radius, tint: tint, interactive: interactive))
    }
}

private struct ReadableGlassSurface: ViewModifier {
    let radius: CGFloat
    let tint: Color
    let interactive: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var tintOpacity: Double {
        colorScheme == .dark ? 0.20 : 0.11
    }

    private var edgeOpacity: Double {
        colorScheme == .dark ? 0.18 : 0.13
    }

    private var shadowOpacity: Double {
        colorScheme == .dark ? 0.22 : 0.08
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if interactive {
            decorated(
                content.glassEffect(
                    .regular.tint(tint.opacity(tintOpacity)).interactive(),
                    in: .rect(cornerRadius: radius)
                )
            )
        } else {
            decorated(
                content.glassEffect(
                    .regular.tint(tint.opacity(tintOpacity)),
                    in: .rect(cornerRadius: radius)
                )
            )
        }
    }

    private func decorated<V: View>(_ view: V) -> some View {
        view
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(edgeOpacity), lineWidth: 0.6)
            }
            .shadow(color: Color.black.opacity(shadowOpacity), radius: 5, y: 1)
    }
}
