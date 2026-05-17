import LiveWallpaperCore
import SwiftUI
import AppKit
import os

/// MenuBarExtra window content.
struct MenuBarContent: View {
    private static let signposter = OSSignposter(
        subsystem: "com.taijia.LiveWallpaper",
        category: "MenuBar"
    )

    let openSettings: () -> Void
    let openSettingsForScreen: (CGDirectDisplayID) -> Void

    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.dismiss) private var dismiss

    @State private var density: MenuBarDensity = SettingsManager.shared.loadGlobalSettings().menuBarDensity

    private var metrics: MenuBarControlCenterMetrics.Resolved {
        MenuBarControlCenterMetrics.resolved(for: density)
    }

    private var monitor: SystemMonitor { .shared }

    private var isWallpaperEnabled: Bool {
        screenManager.wallpaperOverviewStatus == .active
    }

    private var isWallpaperSwitchDisabled: Bool {
        screenManager.wallpaperOverviewStatus == .notConfigured
    }

    var body: some View {
        // Wrap each body evaluation with an OSSignpost interval so the
        // "first few clicks don't respond" symptom can be traced in
        // Instruments → System Trace, filtered by subsystem
        // `com.taijia.LiveWallpaper` + category `MenuBar`.
        let id = Self.signposter.makeSignpostID()
        let interval = Self.signposter.beginInterval("MenuBarBody", id: id)
        defer { Self.signposter.endInterval("MenuBarBody", interval) }
        return content
    }

    private var content: some View {
        AdaptiveGlassContainer(spacing: metrics.componentSpacing) {
            VStack(alignment: .leading, spacing: metrics.componentSpacing) {
                header
                sectionLabel("DISPLAYS")
                displays
                usageStrip
                footer
            }
            .padding(metrics.outerPadding)
            .frame(width: metrics.popoverWidth)
        }
        .modifier(MenuBarOuterShell())
        .onAppear {
            Logger.debug("MenuBar popover appeared", category: .startup)
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuBarDensityDidChange)) { _ in
            // Defer the @State write so a density-change notification
            // arriving during the popover's reconcile doesn't cause
            // "Modifying state during view update".
            Task { @MainActor in
                density = SettingsManager.shared.loadGlobalSettings().menuBarDensity
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            AppTile()

            Text("LiveWallpaper")
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                Logger.debug("MenuBar action: reload tapped", category: .startup)
                screenManager.reloadAllScreens()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
            }
            .adaptiveGlassButton(.regular)
            .controlSize(.small)
            .help(Text("Reload all wallpapers"))
            .accessibilityLabel(Text("Reload all wallpapers"))

            Toggle("", isOn: Binding(
                get: { isWallpaperEnabled },
                set: { enabled in
                    // Equality guard (CLAUDE.md §8): the custom ZStack toggle
                    // can replay the current value during animation; an
                    // unconditional setter would re-enter `setWallpapersEnabled`
                    // and the persistence chain it triggers.
                    guard enabled != isWallpaperEnabled else { return }
                    Logger.debug("MenuBar action: master switch \(enabled ? "on" : "off")", category: .startup)
                    screenManager.setWallpapersEnabled(enabled)
                }
            ))
            .toggleStyle(InlineLabelSwitchStyle())
            .labelsHidden()
            .disabled(isWallpaperSwitchDisabled)
            // The custom toggle style draws "On"/"Off" inside the track as
            // a visual cue, not a label — collapse the children so VoiceOver
            // reads it as a single switch element with the value we set
            // explicitly below, not a button containing the literal text.
            .accessibilityElement(children: .ignore)
            .help(Text("LiveWallpaper system on/off — keeps the app running in the background"))
            .accessibilityLabel(Text("LiveWallpaper system"))
            .accessibilityValue(isWallpaperEnabled ? Text("On") : Text("Off"))
            .accessibilityAddTraits(.isButton)
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
        VStack(spacing: metrics.rowSpacing) {
            if screenManager.screens.isEmpty {
                Text("No displays detected")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .center)
                    .adaptiveGlassSurface(.roundedRectangle(10))
            } else {
                ForEach(screenManager.screens, id: \.id) { screen in
                    let summary = screenManager.wallpaperSummary(for: screen)
                    let visualState = displayVisualState(for: summary.activity)

                    MenuBarDisplayRow(
                        title: screen.name,
                        subtitle: displaySubtitleAttributed(for: screen, summary: summary),
                        subtitleAccessibilityText: displaySubtitleText(for: screen, summary: summary),
                        iconName: displayIconName(for: summary.wallpaperType),
                        visualState: visualState,
                        isPlaying: summary.activity == .active,
                        supportsPlayback: summary.supportsPlaybackControl,
                        canStepPlaylist: canStepPlaylist(for: screen),
                        videoVolume: videoVolumeBinding(for: screen),
                        density: density,
                        openAction: { invokeOpenScreenSettings(screen.id) },
                        previousAction: {
                            Logger.debug("MenuBar action: previous wallpaper tapped", category: .startup)
                            screenManager.regressPlaylist(for: screen)
                        },
                        playbackAction: { togglePlayback(for: screen) },
                        nextAction: {
                            Logger.debug("MenuBar action: next wallpaper tapped", category: .startup)
                            screenManager.advancePlaylist(for: screen)
                        }
                    )
                }
            }
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
        HStack(spacing: metrics.controlSpacing) {
            Button(action: invokeManageWindow) {
                HStack(spacing: 7) {
                    Image(systemName: "slider.horizontal.3")
                    Text("Manage")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, minHeight: 24)
            }
            .adaptiveGlassButton(.prominent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .help(Text("Manage — open the LiveWallpaper settings window"))
            .accessibilityLabel(Text("Manage wallpapers"))

            MenuBarFooterUtility(
                systemImage: "gearshape",
                role: .neutral,
                action: invokeOpenSettings,
                help: "Settings",
                accessibilityLabel: "Open Settings"
            )

            MenuBarFooterUtility(
                systemImage: "power",
                role: .destructiveGlyph,
                action: invokeQuit,
                help: "Quit LiveWallpaper",
                accessibilityLabel: "Quit LiveWallpaper"
            )
        }
        .frame(maxWidth: .infinity)
    }

    private func displaySubtitleAttributed(
        for screen: Screen,
        summary: WallpaperSessionSummary
    ) -> AttributedString {
        let source = displaySource(for: screen, summary: summary)

        guard let typeText = wallpaperTypeText(for: summary.wallpaperType) else {
            return AttributedString(source.isEmpty ? "Not configured" : source)
        }

        var attributed = AttributedString(typeText)
        attributed.font = Font.system(size: 10, weight: .semibold)
        attributed.foregroundColor = Color.primary

        if !source.isEmpty {
            // Separator approximates `.tertiary` foreground style — AttributedString
            // cannot bind to a HierarchicalShapeStyle directly, so reduce opacity
            // on top of `.secondary` to mimic the visual weight.
            var separator = AttributedString(" · ")
            separator.foregroundColor = Color.secondary.opacity(0.65)
            attributed.append(separator)

            var sourceText = AttributedString(source)
            sourceText.font = Font.system(size: 10)
            sourceText.foregroundColor = Color.secondary
            attributed.append(sourceText)
        }

        return attributed
    }

    private func displaySubtitleText(
        for screen: Screen,
        summary: WallpaperSessionSummary
    ) -> String {
        let source = displaySource(for: screen, summary: summary)

        guard let typeText = wallpaperTypeText(for: summary.wallpaperType) else {
            return source.isEmpty ? "Not configured" : source
        }

        guard !source.isEmpty else { return typeText }
        return "\(typeText), \(source)"
    }

    private func displaySource(for screen: Screen, summary: WallpaperSessionSummary) -> String {
        if summary.wallpaperType == .video,
           let name = screenManager.currentVideoDisplayName(for: screen),
           !name.isEmpty {
            return name
        }

        if let name = screenManager.wallpaperDisplayName(for: screen), !name.isEmpty {
            return name
        }

        if let message = summary.subtitle, !message.isEmpty {
            return message
        }

        return ""
    }

    private func wallpaperTypeText(for type: WallpaperType?) -> String? {
        switch type {
        case .video:
            return "Video"
        case .html:
            return "Web"
        case .metalShader:
            return "Shader"
        case .scene:
            return "Scene"
        case nil:
            return nil
        }
    }

    private func displayIconName(for type: WallpaperType?) -> String {
        switch type {
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

    private func displayVisualState(for activity: WallpaperSessionActivity) -> DisplayVisualState {
        switch activity {
        case .active:
            return .active
        case .paused:
            return .paused
        case .inactive:
            return .inactive
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

    private func videoVolumeBinding(for screen: Screen) -> Binding<Double>? {
        guard let config = screenManager.getConfiguration(for: screen),
              config.wallpaperType == .video,
              config.hasConfiguredVideoSource else { return nil }

        return Binding(
            get: {
                screenManager.getConfiguration(for: screen)?.videoVolume ?? config.videoVolume
            },
            set: { newValue in
                let clampedValue = min(max(newValue, 0), 1)
                screenManager.updateVideoVolume(clampedValue, for: screen)
            }
        )
    }

    private func togglePlayback(for screen: Screen) {
        Logger.debug("MenuBar action: row playback tapped", category: .startup)
        guard let playback = screen.playbackController else { return }
        PlaybackToggle.toggle(playback)
    }

    private func invokeManageWindow() {
        Logger.debug("MenuBar action: manage tapped", category: .startup)
        dismiss()
        if let screen = screenManager.screens.first {
            openSettingsForScreen(screen.id)
        } else {
            openSettings()
        }
    }

    private func invokeOpenScreenSettings(_ id: CGDirectDisplayID) {
        Logger.debug("MenuBar action: display settings tapped", category: .startup)
        dismiss()
        openSettingsForScreen(id)
    }

    private func invokeOpenSettings() {
        Logger.debug("MenuBar action: settings tapped", category: .startup)
        dismiss()
        openSettings()
    }

    private func invokeQuit() {
        Logger.debug("MenuBar action: quit tapped", category: .startup)
        NSApp.terminate(nil)
    }

    private func usageColor(for percent: Double) -> Color {
        if percent >= 80 { return .red }
        if percent >= 50 { return .orange }
        // Neutral fill under the warning threshold — warm colors stay reserved
        // for the warning/critical bands so they read as alerts, not decoration.
        return .white.opacity(0.55)
    }
}

/// Metric block driven by the user's `MenuBarDensity` preference. Comfortable
/// keeps the existing defaults; Compact trims padding + row spacing so users
/// on busy multi-display setups see more without scrolling.
private enum MenuBarControlCenterMetrics {
    static let popoverWidth: CGFloat = 320
    static let outerPadding: CGFloat = 12
    static let componentSpacing: CGFloat = 10
    static let rowSpacing: CGFloat = 7
    static let controlSpacing: CGFloat = 7
    static let rowPaddingHorizontal: CGFloat = 10
    static let rowPaddingVertical: CGFloat = 9

    struct Resolved {
        let popoverWidth: CGFloat
        let outerPadding: CGFloat
        let componentSpacing: CGFloat
        let rowSpacing: CGFloat
        let controlSpacing: CGFloat
        let rowPaddingHorizontal: CGFloat
        let rowPaddingVertical: CGFloat
    }

    static func resolved(for density: MenuBarDensity) -> Resolved {
        switch density {
        case .comfortable:
            return Resolved(
                popoverWidth: popoverWidth,
                outerPadding: outerPadding,
                componentSpacing: componentSpacing,
                rowSpacing: rowSpacing,
                controlSpacing: controlSpacing,
                rowPaddingHorizontal: rowPaddingHorizontal,
                rowPaddingVertical: rowPaddingVertical
            )
        case .compact:
            // Trim padding ≈ 35% so 3+ displays + power controls fit on a
            // single 1080p external panel without scrolling. Width unchanged
            // so the header / titles still read cleanly.
            return Resolved(
                popoverWidth: popoverWidth,
                outerPadding: 8,
                componentSpacing: 6,
                rowSpacing: 4,
                controlSpacing: 5,
                rowPaddingHorizontal: 7,
                rowPaddingVertical: 5
            )
        }
    }
}

private enum DisplayVisualState: Equatable {
    case active
    case paused
    case inactive

    var tint: Color {
        switch self {
        case .active:   return .green
        case .paused:   return .orange
        case .inactive: return .secondary
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .active:
            return "active"
        case .paused:
            return "paused"
        case .inactive:
            return "idle"
        }
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

/// Outer "Control-Center-style" glass shell.
///
/// On **macOS 26+** the popover's system NSVisualEffectView would block the
/// desktop wallpaper, defeating the inner Liquid Glass refraction. We strip
/// that chrome (`MenuBarWindowChromeClearer`) and replace it with a native
/// `.glassEffect` so the popover itself becomes one big crystalline capsule
/// the inner row / button glass surfaces can refract over.
///
/// On **macOS 14/15** the popover's NSVisualEffectView *is* the surface —
/// stripping it would leave the popover transparent without a replacement
/// (Liquid Glass doesn't exist there). Layering an `adaptiveGlassSurface`
/// on top would double up `.regularMaterial` for no visual win. So we leave
/// the system chrome alone and skip the outer shell entirely.
private struct MenuBarOuterShell: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .adaptiveGlassSurface(.roundedRectangle(22))
                .background(MenuBarWindowChromeClearer())
        } else {
            content
        }
    }
}

private struct AppTile: View {
    var body: some View {
        Image(systemName: "play.rectangle.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .frame(width: 26, height: 26)
            .adaptiveGlassSurface(.roundedRectangle(8))
            .accessibilityHidden(true)
    }
}

/// Custom toggle whose track carries an "On" / "Off" label inline, so the
/// switch communicates state via three cues at once: knob position, track
/// color, and text. macOS's native `.switch` only gives the first two.
///
/// The label sits *centered in the half of the track the knob does not
/// occupy* — never centered in the whole track, otherwise the knob would
/// overlap it.
private struct InlineLabelSwitchStyle: ToggleStyle {
    private let trackWidth: CGFloat = 54
    private let trackHeight: CGFloat = 24
    private let knobSize: CGFloat = 20
    private let knobPadding: CGFloat = 2

    /// Horizontal slot the knob (plus its padding) occupies. The label is
    /// centered in the *remaining* slot so it always reads centered in its
    /// own half rather than nudged against the track edge.
    private var knobChannelWidth: CGFloat { knobSize + knobPadding * 2 }

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack {
                Capsule()
                    .fill(configuration.isOn ? Color.accentColor : Color.secondary.opacity(0.42))

                HStack(spacing: 0) {
                    if configuration.isOn {
                        Text("On")
                            .frame(maxWidth: .infinity, alignment: .center)
                        Color.clear.frame(width: knobChannelWidth)
                    } else {
                        Color.clear.frame(width: knobChannelWidth)
                        Text("Off")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(configuration.isOn ? 0.95 : 0.70))

                Circle()
                    .fill(.white)
                    .frame(width: knobSize, height: knobSize)
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                    .padding(knobPadding)
                    .frame(
                        maxWidth: .infinity,
                        alignment: configuration.isOn ? .trailing : .leading
                    )
            }
            .frame(width: trackWidth, height: trackHeight)
            .contentShape(Capsule())
        }
        .buttonStyle(MenuBarPressFeedbackStyle())
        .animation(.snappy(duration: 0.18), value: configuration.isOn)
    }
}

private struct MenuBarDisplayRow: View {
    let title: String
    let subtitle: AttributedString
    let subtitleAccessibilityText: String
    let iconName: String
    let visualState: DisplayVisualState
    let isPlaying: Bool
    let supportsPlayback: Bool
    let canStepPlaylist: Bool
    let videoVolume: Binding<Double>?
    let density: MenuBarDensity
    let openAction: () -> Void
    let previousAction: () -> Void
    let playbackAction: () -> Void
    let nextAction: () -> Void

    private var metrics: MenuBarControlCenterMetrics.Resolved {
        MenuBarControlCenterMetrics.resolved(for: density)
    }

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                // Whole-card click target: any tap on the icon, title, subtitle,
                // or the empty space between them jumps to the display's
                // Settings page. The trailing control buttons (and the volume
                // slider below) stay independent gesture targets.
                //
                // State is conveyed entirely by the leading `DisplayIconTile`
                // (color + glyph shape) — the standalone status chip was dropped
                // because the icon tint already carries the same information
                // and a chip duplicates it for every screen.
                Button(action: openAction) {
                    HStack(spacing: 8) {
                        DisplayIconTile(systemImage: iconName, state: visualState)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: title)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(subtitle)
                                .font(.system(size: 10))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(MenuBarPressFeedbackStyle())
                .help(Text("Open display settings"))
                .accessibilityLabel(Text("\(title), \(subtitleAccessibilityText), \(visualState.accessibilityLabel)"))
                .accessibilityElement(children: .combine)

                // Show only the controls the wallpaper can actually drive:
                //   • single video / web → just play-pause
                //   • video playlist → prev / play-pause / next
                //   • non-playable (scene-still, unsupported) → no buttons at all
                // Beats greying out disabled buttons — fewer visible slots,
                // less cognitive noise per row.
                if supportsPlayback {
                    HStack(spacing: 4) {
                        if canStepPlaylist {
                            IconControlButton(
                                systemImage: "chevron.left",
                                isEnabled: true,
                                action: previousAction,
                                accessibilityLabel: "Previous wallpaper"
                            )
                        }

                        IconControlButton(
                            systemImage: isPlaying ? "pause.fill" : "play.fill",
                            isEnabled: true,
                            action: playbackAction,
                            accessibilityLabel: isPlaying ? "Pause wallpaper" : "Play wallpaper",
                            isProminent: true
                        )

                        if canStepPlaylist {
                            IconControlButton(
                                systemImage: "chevron.right",
                                isEnabled: true,
                                action: nextAction,
                                accessibilityLabel: "Next wallpaper"
                            )
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)

            if let videoVolume {
                VolumeControlRow(videoVolume: videoVolume)
            }
        }
        .padding(.horizontal, metrics.rowPaddingHorizontal)
        .padding(.vertical, metrics.rowPaddingVertical)
        .frame(maxWidth: .infinity)
        // No tint — let the system render its native edge highlight + interior
        // refraction. Tinting forced opaque gray bands that read as flat cards.
        .adaptiveGlassSurface(.roundedRectangle(12), interactive: true)
    }
}

private struct DisplayIconTile: View {
    let systemImage: String
    let state: DisplayVisualState

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 11, weight: .semibold))
            // State color rides on the glyph only — the surrounding glass tile
            // stays neutral so we don't bring back the color-block surfaces.
            .foregroundStyle(state.tint)
            .frame(width: 26, height: 26)
            .adaptiveGlassSurface(.roundedRectangle(8))
            .accessibilityHidden(true)
    }
}

private struct VolumeControlRow: View {
    let videoVolume: Binding<Double>

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: volumeIcon(for: videoVolume.wrappedValue))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)

            Slider(value: videoVolume, in: 0...1)
                .controlSize(.mini)
                .tint(.secondary)
                .accessibilityLabel(Text("Video volume"))
                .accessibilityValue(Text("\(volumePercent(videoVolume.wrappedValue)) percent"))

            Text(verbatim: "\(volumePercent(videoVolume.wrappedValue))%")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
    }

    private func volumePercent(_ value: Double) -> Int {
        Int((min(max(value, 0), 1) * 100).rounded())
    }

    private func volumeIcon(for value: Double) -> String {
        switch value {
        case ..<0.01:
            return "speaker.slash.fill"
        case ..<0.5:
            return "speaker.wave.1.fill"
        default:
            return "speaker.wave.2.fill"
        }
    }
}

private struct IconControlButton: View {
    let systemImage: String
    let isEnabled: Bool
    let action: () -> Void
    let accessibilityLabel: String
    var isProminent: Bool = false

    var body: some View {
        // The prominent / regular branch is decided once per row (play vs
        // prev/next). On macOS 26 each gets Apple's polished Liquid Glass
        // edge highlight + press squish; on 14/15 it falls back to
        // `.bordered` / `.borderedProminent` capsule via the adaptive layer.
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .bold))
        }
        .adaptiveGlassButton(isProminent ? .prominent : .regular)
        .controlSize(.small)
        .disabled(!isEnabled)
        .accessibilityLabel(Text(accessibilityLabel))
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
        HStack(spacing: 9) {
            ForEach(metrics, id: \.label) { metric in
                MenuBarUsageMetricView(metric: metric)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .adaptiveGlassSurface(.roundedRectangle(11))
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

private enum FooterUtilityRole {
    case neutral
    case destructiveGlyph
}

private struct MenuBarFooterUtility: View {
    let systemImage: String
    let role: FooterUtilityRole
    let action: () -> Void
    let help: LocalizedStringKey
    let accessibilityLabel: LocalizedStringKey

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                // Glyph still carries the role (red = destructive). The
                // glass surface itself stays neutral — Apple's destructive
                // intent should come from the icon, not a colored surface.
                .foregroundStyle(role == .destructiveGlyph ? Color.red : Color.primary)
        }
        .adaptiveGlassButton(.regular)
        .controlSize(.large)
        .help(Text(help))
        .accessibilityLabel(Text(accessibilityLabel))
    }
}

/// Adds a subtle press cue (scale + dim) to every menu-bar button that
/// doesn't already go through `.adaptiveGlassButton` (which delivers its
/// own native press feedback). Currently used only by the master toggle's
/// custom Capsule track and the whole-row display card.
private struct MenuBarPressFeedbackStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}

/// Bridges into AppKit at view-appear time to strip the menubar popover's
/// chrome so the desktop wallpaper bleeds through the outer Liquid Glass
/// shell. Two layers have to be cleared, not one:
///
/// 1. **NSWindow itself** — `isOpaque = false`, `backgroundColor = .clear`.
///    The window stops painting its own backdrop.
/// 2. **NSVisualEffectView descendants** — `MenuBarExtra(.window)` plants a
///    dark-vibrancy `NSVisualEffectView` as the popover's default backdrop.
///    It is a sibling/child of the SwiftUI host view, NOT the window's
///    `backgroundColor`, so step 1 alone leaves a uniform dark layer
///    behind everything. Hiding it lets the Liquid Glass shell sit
///    directly over the desktop wallpaper.
///
/// Gated to macOS 26+ by the call site (`MenuBarOuterShell`). On macOS
/// 14/15 we keep the system chrome — there is no Liquid Glass to take its
/// place, and stripping vibrancy without a replacement leaves an empty
/// transparent popover.
///
/// Idempotent: AppKit re-uses the same NSWindow across popover open/close
/// cycles, and these setters are no-ops once already cleared.
private struct MenuBarWindowChromeClearer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { Self.stripChrome(anchoredAt: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // The accessor view may attach to its NSWindow late — the first
        // `makeNSView` callback can fire before `view.window` is set.
        // Re-apply on every update so the cleared chrome survives a
        // popover that opens fresh after a density change or a relaunch.
        DispatchQueue.main.async { Self.stripChrome(anchoredAt: nsView) }
    }

    private static func stripChrome(anchoredAt anchor: NSView) {
        guard let window = anchor.window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear

        if let contentView = window.contentView {
            hideVisualEffectViews(in: contentView)
        }
    }

    private static func hideVisualEffectViews(in view: NSView) {
        if let vfx = view as? NSVisualEffectView {
            // `isHidden` removes the view from rendering without unhooking
            // it from the view hierarchy, so AppKit's popover bookkeeping
            // (focus, dismissal on click-outside) stays intact.
            vfx.isHidden = true
        }
        for subview in view.subviews {
            hideVisualEffectViews(in: subview)
        }
    }
}
