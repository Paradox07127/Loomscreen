import SwiftUI
import AppKit

/// MenuBarExtra `.window` 风格的状态栏面板：
/// dashboard + per-screen card + quick toggles + footer。
struct MenuBarContent: View {
    let openSettings: () -> Void
    let openSettingsForScreen: (CGDirectDisplayID) -> Void

    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.dismiss) private var dismiss

    @State private var globalPauseOnBattery: Bool = SettingsManager.shared.loadGlobalSettings().globalPauseOnBattery
    @State private var globalPauseOnFullScreen: Bool = SettingsManager.shared.loadGlobalSettings().pauseOnFullScreen
    /// "system" = 整机 RAM 占用（默认）；"app" = 仅本进程。与 sidebar dashboard 同步。
    @AppStorage("Dashboard.RAMScope") private var ramScopeRaw: String = "system"

    private var monitor: SystemMonitor { .shared }
    private var ramPercent: Double {
        ramScopeRaw == "app" ? monitor.memoryPercentage() : monitor.systemMemoryUsage * 100
    }
    /// CPU 同样跟随 scope：All = 整机 CPU，App = 仅本进程。
    private var cpuPercent: Double {
        ramScopeRaw == "app" ? monitor.cpuUsage : monitor.systemCpuUsage
    }

    @ViewBuilder
    private func ramScopeButton(label: String, value: String) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) { ramScopeRaw = value }
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
        .accessibilityLabel(value == "system" ? "Show whole-system memory usage" : "Show this app's memory usage")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            miniDashboard
            Divider()
            screenSection
            Divider()
            quickToggles
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 340)
        .onAppear {
            monitor.startMonitoring()
            refreshGlobalToggles()
        }
        .onDisappear { monitor.stopMonitoring() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 16))
                .foregroundStyle(Color.accentColor)
            Text("LiveWallpaper")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Text(versionString)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Mini Dashboard

    private var miniDashboard: some View {
        VStack(spacing: 6) {
            // RAM scope picker — explicit segmented capsule shared with sidebar.
            HStack(spacing: 0) {
                ramScopeButton(label: "All", value: "system")
                ramScopeButton(label: "App", value: "app")
            }
            .padding(2)
            .background(Capsule().fill(Color.gray.opacity(0.18)))
            .frame(maxWidth: 180)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("RAM scope")

            chipRow
        }
    }

    private var chipRow: some View {
        HStack(spacing: 8) {
            DashboardChip(label: "CPU", value: cpuPercent, color: dashboardColor(for: cpuPercent), icon: "cpu")
            DashboardChip(label: "GPU", value: monitor.gpuUsage, color: dashboardColor(for: monitor.gpuUsage), icon: "square.stack.3d.up.fill")
            DashboardChip(label: "RAM", value: ramPercent, color: dashboardColor(for: ramPercent), icon: "memorychip")
            DashboardChip(
                label: monitor.videoFPS > 0 ? "FPS" : "—",
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
                        videoName: resolveCurrentVideoName(for: screen),
                        onOpen: { openSettingsForScreen(screen.id) },
                        onPlayPause: { togglePlayback(for: screen) },
                        onPrev: { screenManager.regressPlaylist(for: screen) },
                        onNext: { screenManager.advancePlaylist(for: screen) }
                    )
                }
            }
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
        if playback.isPlaying { playback.pause() } else { playback.play() }
    }

    private func resolveCurrentVideoName(for screen: Screen) -> String? {
        guard let config = screenManager.getConfiguration(for: screen) else { return nil }
        let cursor = config.playlistCursorIndex ?? 0
        let combined = [config.savedVideoBookmarkData].compactMap { $0 } + (config.playlistBookmarks ?? [])
        guard cursor < combined.count else {
            return config.savedVideoBookmarkData.flatMap { ResourceUtilities.resolveBookmarkName($0) }
        }
        return ResourceUtilities.resolveBookmarkName(combined[cursor])
    }

    private func refreshGlobalToggles() {
        let s = SettingsManager.shared.loadGlobalSettings()
        globalPauseOnBattery = s.globalPauseOnBattery
        globalPauseOnFullScreen = s.pauseOnFullScreen
    }

    private func commitGlobalToggles() {
        let current = SettingsManager.shared.loadGlobalSettings()
        let updated = GlobalSettings(
            globalPauseOnBattery: globalPauseOnBattery,
            preservePlaybackOnLock: current.preservePlaybackOnLock,
            startOnLogin: current.startOnLogin,
            minimumBatteryLevel: current.minimumBatteryLevel,
            pauseOnFullScreen: globalPauseOnFullScreen
        )
        SettingsManager.shared.saveGlobalSettings(updated)
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
                Text(label)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Text(displayValue ?? "\(Int(value))%")
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
        .accessibilityLabel("\(label): \(displayValue ?? "\(Int(value))%")")
    }
}

// MARK: - Per-Screen Card

private struct MenuBarScreenCard: View {
    let screen: Screen
    let videoName: String?
    let onOpen: () -> Void
    let onPlayPause: () -> Void
    let onPrev: () -> Void
    let onNext: () -> Void

    @State private var isHovering = false

    private var isPlaying: Bool {
        screen.playbackController?.isPlaying ?? false
    }

    private var summary: WallpaperSessionSummary {
        screen.wallpaperSessionSummary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 13))
                    .foregroundStyle(iconColor)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(screen.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(subtitle)
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
                .help("Configure this display")
            }

            if summary.supportsPlaybackControl {
                HStack(spacing: 12) {
                    Button(action: onPrev) {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help("Previous video")

                    Button(action: onPlayPause) {
                        Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .contentTransition(.symbolEffect(.replace))
                    .help(isPlaying ? "Pause" : "Play")

                    Button(action: onNext) {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help("Next video")

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

    private var subtitle: String {
        if let videoName, summary.wallpaperType == .video { return videoName }
        switch summary.wallpaperType {
        case .html: return "HTML wallpaper"
        case .metalShader: return "Shader wallpaper"
        case .video: return "Not configured"
        case nil: return "Not configured"
        }
    }
}
