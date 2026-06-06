import LiveWallpaperCore
import SwiftUI
import AppKit
import os

/// MenuBarExtra window content.
struct MenuBarContent: View {
    private static let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "com.taijia.LiveWallpaper",
        category: "MenuBar"
    )

    let openSettings: () -> Void
    let openSettingsForScreen: (CGDirectDisplayID) -> Void
    let openSettingsAndAddWallpaper: () -> Void

    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.dismiss) private var dismiss

    private var monitor: SystemMonitor { .shared }

    private var isWallpaperEnabled: Bool {
        // The master switch reflects the independent render gate — NOT whether a
        // screen is currently playing/paused (that's per-screen state).
        screenManager.wallpapersGloballyEnabled
    }

    private var isWallpaperSwitchDisabled: Bool {
        screenManager.wallpaperOverviewStatus == .notConfigured
    }

    var body: some View {
        let id = Self.signposter.makeSignpostID()
        let interval = Self.signposter.beginInterval("MenuBarBody", id: id)
        defer { Self.signposter.endInterval("MenuBarBody", interval) }
        return content
    }

    private var content: some View {
        AdaptiveGlassContainer(spacing: MenuBarMetrics.componentSpacing) {
            VStack(alignment: .leading, spacing: MenuBarMetrics.componentSpacing) {
                header
                sectionDivider
                displays
                sectionDivider
                footer
            }
            .padding(MenuBarMetrics.outerPadding)
            .frame(width: MenuBarMetrics.popoverWidth)
        }
        .modifier(MenuBarOuterShell())
    }

    /// Subtle horizontal rule used between sections inside the single glass
    /// shell. Slightly more visible than a system `Divider()` because the
    /// shell already adds material contrast around it.
    private var sectionDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(verbatim: BundleIdentity.productDisplayName)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: invokeAddWallpaper) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.primary)
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .adaptiveGlassSurface(.circle, interactive: true)
                .help(Text("Add wallpaper — pick a video for this display", comment: "Quick Add button help"))
                .accessibilityLabel(Text("Add wallpaper", comment: "Quick Add button accessibility label"))

                Toggle("", isOn: Binding(
                    get: { isWallpaperEnabled },
                    set: { enabled in
                        guard enabled != isWallpaperEnabled else { return }
                        screenManager.setWallpapersEnabled(enabled)
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.regular)
                .labelsHidden()
                .disabled(isWallpaperSwitchDisabled)
                .accessibilityElement(children: .ignore)
                .help(Text("LiveWallpaper system on/off — keeps the app running in the background"))
                .accessibilityLabel(Text("LiveWallpaper system"))
                .accessibilityValue(isWallpaperEnabled ? Text("On") : Text("Off"))
                .accessibilityAddTraits(.isButton)
            }

            usageStrip
        }
        .frame(maxWidth: .infinity)
    }

    private var displays: some View {
        VStack(spacing: 0) {
            if screenManager.screens.isEmpty {
                Text("No displays detected")
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .center)
            } else {
                let screens = screenManager.screens
                ForEach(Array(screens.enumerated()), id: \.element.id) { index, screen in
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
                        openAction: { invokeOpenScreenSettings(screen.id) },
                        previousAction: {
                            screenManager.regressPlaylist(for: screen)
                        },
                        playbackAction: { togglePlayback(for: screen) },
                        nextAction: {
                            screenManager.advancePlaylist(for: screen)
                        }
                    )

                    if index < screens.count - 1 {
                        Divider().padding(.horizontal, 4)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var usageStrip: some View {
        let cpuPercent = monitor.systemCpuUsage
        let gpuPercent = monitor.gpuUsage
        let ramPercent = monitor.systemMemoryUsage * 100
        let thermalState = monitor.thermalState

        return HStack(spacing: 8) {
            performanceItem(
                tint: usageColor(for: cpuPercent),
                label: "CPU",
                value: FormatUtils.formatPercent(cpuPercent.rounded())
            )
            performanceItem(
                tint: usageColor(for: gpuPercent),
                label: "GPU",
                value: FormatUtils.formatPercent(gpuPercent.rounded())
            )
            performanceItem(
                tint: usageColor(for: ramPercent),
                label: "RAM",
                value: FormatUtils.formatPercent(ramPercent.rounded())
            )
            performanceItem(
                tint: thermalColor(for: thermalState),
                label: "TEMP",
                value: thermalShortLabel(for: thermalState)
            )
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// Short status label intended for `performanceItem`'s value
    /// column. `ProcessInfo.ThermalState` has no numeric percent, so we
    /// surface a short word — the label + tint do most of the signaling, so
    /// localised values that don't quite fit truncate gracefully.
    private func thermalShortLabel(for state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:  return String(localized: "OK", defaultValue: "OK", comment: "Menu bar TEMP status: thermal state nominal. Keep short — ideally ≤4 Latin characters or equivalent width.")
        case .fair:     return String(localized: "Warm", defaultValue: "Warm", comment: "Menu bar TEMP status: thermal state fair. Keep short — ideally ≤4 Latin characters or equivalent width.")
        case .serious:  return String(localized: "Hot", defaultValue: "Hot", comment: "Menu bar TEMP status: thermal state serious. Keep short — ideally ≤4 Latin characters or equivalent width.")
        case .critical: return String(localized: "Crit", defaultValue: "Crit", comment: "Menu bar TEMP status: thermal state critical. Keep short — ideally ≤4 Latin characters or equivalent width.")
        @unknown default: return "—"
        }
    }

    private func thermalColor(for state: ProcessInfo.ThermalState) -> Color {
        switch state {
        case .nominal:  return .green
        case .fair:     return .yellow
        case .serious:  return .orange
        case .critical: return .red
        @unknown default: return .gray
        }
    }

    /// Three-tier severity gradient for usage gauges:
    /// `< 50%` healthy green, `50-80%` warning orange, `>= 80%` critical red.
    /// Mirrors the standard system-monitor convention (Activity Monitor,
    /// iStat Menus) so the user can read load at a glance without parsing
    /// the number.
    private func usageColor(for percent: Double) -> Color {
        if percent >= 80 { return .red }
        if percent >= 50 { return .orange }
        return .green
    }

    private func performanceItem(tint: Color, label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: label)
                .font(DesignTokens.Typography.captionEmphasized)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(width: 28, alignment: .leading)

            Text(verbatim: value)
                .font(.system(.callout, design: .monospaced).weight(.bold))
                .foregroundStyle(tint)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 36, alignment: .trailing)
        }
        .frame(width: 68)
        .animation(.easeInOut(duration: 0.25), value: tint)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(label) \(value)"))
    }

    private var footer: some View {
        HStack(spacing: MenuBarMetrics.controlSpacing) {
            Button(action: invokeManageWindow) {
                HStack(spacing: 7) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Manage")
                        .font(DesignTokens.Typography.bodyEmphasized)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
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
                help: Text("Open General Settings"),
                accessibilityLabel: Text("Open General Settings")
            )

            MenuBarFooterUtility(
                systemImage: "arrow.clockwise",
                role: .neutral,
                action: invokeReload,
                help: Text("Reload all wallpapers"),
                accessibilityLabel: Text("Reload all wallpapers")
            )

            MenuBarFooterUtility(
                systemImage: "power",
                role: .destructiveGlyph,
                action: invokeQuit,
                help: Text("Quit LiveWallpaper"),
                accessibilityLabel: Text("Quit LiveWallpaper")
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
        attributed.font = Font.system(size: 11, weight: .semibold)
        attributed.foregroundColor = Color.primary

        if !source.isEmpty {
            var separator = AttributedString(" · ")
            separator.foregroundColor = Color.secondary.opacity(0.65)
            attributed.append(separator)

            var sourceText = AttributedString(source)
            sourceText.font = Font.system(size: 11)
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
        case .off:
            return .off
        case .error:
            return .error
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

    /// Effective-audio binding: stays in sync with the inspector's audio row (which keeps `muted` and `videoVolume` as separate states).
    private func videoVolumeBinding(for screen: Screen) -> Binding<Double>? {
        guard let config = screenManager.getConfiguration(for: screen),
              config.wallpaperType == .video,
              config.hasConfiguredVideoSource else { return nil }

        return Binding(
            get: {
                let current = screenManager.getConfiguration(for: screen) ?? config
                return current.muted ? 0 : current.videoVolume
            },
            set: { newValue in
                let clampedValue = min(max(newValue, 0), 1)
                let current = screenManager.getConfiguration(for: screen) ?? config

                if clampedValue <= 0.001 {
                    if !current.muted {
                        screenManager.updateMuted(true, for: screen)
                    }
                    return
                }

                if current.muted {
                    screenManager.updateMuted(false, for: screen)
                }
                screenManager.updateVideoVolume(clampedValue, for: screen)
            }
        )
    }

    private func togglePlayback(for screen: Screen) {
        guard let playback = screen.playbackController else { return }
        PlaybackToggle.toggle(playback)
    }

    private func invokeManageWindow() {
        dismiss()
        if let screen = screenManager.screens.first {
            openSettingsForScreen(screen.id)
        } else {
            openSettings()
        }
    }

    private func invokeOpenScreenSettings(_ id: CGDirectDisplayID) {
        dismiss()
        openSettingsForScreen(id)
    }

    private func invokeOpenSettings() {
        dismiss()
        openSettings()
    }

    private func invokeQuit() {
        NSApp.terminate(nil)
    }

    private func invokeReload() {
        screenManager.reloadAllScreens()
    }

    private func invokeAddWallpaper() {
        dismiss()
        openSettingsAndAddWallpaper()
    }
}

/// Fixed spacing / padding metrics for the menu-bar popover. Tuned for the
/// single-shell layout where the outer Liquid Glass capsule already provides
/// breathing room; values match the previous "comfortable" preset.
private enum MenuBarMetrics {
    static let popoverWidth: CGFloat = 320
    static let outerPadding: CGFloat = 12
    static let componentSpacing: CGFloat = 10
    static let controlSpacing: CGFloat = 7
    static let rowPaddingHorizontal: CGFloat = 10
    static let rowPaddingVertical: CGFloat = 9
}

private enum DisplayVisualState: Equatable {
    case active
    case paused
    case off
    case error
    case inactive

    var tint: Color {
        switch self {
        case .active:   return .green
        case .paused:   return .orange
        case .off:      return .secondary
        case .error:    return .red
        case .inactive: return .secondary
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .active:
            return "active"
        case .paused:
            return "paused"
        case .off:
            return "off"
        case .error:
            return "error"
        case .inactive:
            return "idle"
        }
    }
}

@MainActor
enum PlaybackToggle {
    static func toggle(_ playback: any WallpaperPlaybackControllable) {
        // Toggle the user's intent, not the actual playing state: a
        // policy-suspended video reads `isPlaying == false` even though the
        // user still intends to play it.
        if playback.userIntendsToPlay {
            playback.pause()
        } else {
            playback.play()
        }
    }
}

/// Outer Liquid Glass shell wrapping the popover.
/// macOS 26+: strip system NSVisualEffectView (would block wallpaper refraction)
/// and replace with one `.glassEffect` capsule. macOS 14/15: keep system chrome
/// (Liquid Glass unavailable; doubling `.regularMaterial` adds nothing).
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
                .font(DesignTokens.Typography.badge)
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
    let openAction: () -> Void
    let previousAction: () -> Void
    let playbackAction: () -> Void
    let nextAction: () -> Void

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                Button(action: openAction) {
                    HStack(spacing: 8) {
                        DisplayIconTile(systemImage: iconName, state: visualState)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: title)
                                .font(DesignTokens.Typography.bodyEmphasized)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(subtitle)
                                .font(DesignTokens.Typography.caption)
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
        .padding(.horizontal, MenuBarMetrics.rowPaddingHorizontal)
        .padding(.vertical, MenuBarMetrics.rowPaddingVertical)
        .frame(maxWidth: .infinity)
    }
}

private struct DisplayIconTile: View {
    let systemImage: String
    let state: DisplayVisualState

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(state.tint)
            .frame(width: 26, height: 26)
            .adaptiveGlassSurface(.roundedRectangle(8))
            .accessibilityHidden(true)
    }
}

private struct VolumeControlRow: View {
    let videoVolume: Binding<Double>

    /// Local mirror of the upstream binding. The icon and the percent text
    /// read from this @State during a drag so they re-render on every
    /// continuous Slider commit — relying on the upstream binding alone
    /// left them stuck at the pre-drag value because the binding setter
    /// hops through `screenManager → configurationStore → observation`
    /// before the view's getter re-resolves.
    ///
    /// `onChange` re-syncs from the upstream binding so external writes
    /// (preview-pane slider, mute toggle, persisted state on reopen) keep
    /// the menubar slider in lockstep.
    @State private var liveValue: Double = 0

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: volumeIcon(for: liveValue))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)

            Slider(value: liveBinding, in: 0...1)
                .controlSize(.mini)
                .tint(.secondary)
                .accessibilityLabel(Text("Video volume"))
                .accessibilityValue(Text("\(volumePercent(liveValue)) percent"))

            Text(verbatim: "\(volumePercent(liveValue))%")
                .font(DesignTokens.Typography.metric)
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .onAppear { liveValue = videoVolume.wrappedValue }
        .onChange(of: videoVolume.wrappedValue) { _, newValue in
            if abs(liveValue - newValue) > 0.001 {
                liveValue = newValue
            }
        }
    }

    private var liveBinding: Binding<Double> {
        Binding(
            get: { liveValue },
            set: { newValue in
                liveValue = newValue
                videoVolume.wrappedValue = newValue
            }
        )
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
    let accessibilityLabel: LocalizedStringKey
    var isProminent: Bool = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(isProminent ? Color.white : Color.primary)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .adaptiveGlassSurface(.circle, tint: isProminent ? Color.accentColor : nil, interactive: true)
        .disabled(!isEnabled)
        .accessibilityLabel(Text(accessibilityLabel))
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
    let help: Text
    let accessibilityLabel: Text

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(role == .destructiveGlyph ? Color.red : Color.primary)
                .frame(width: 38, height: 38)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .adaptiveGlassSurface(.circle, interactive: true)
        .help(help)
        .accessibilityLabel(accessibilityLabel)
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

/// Strips the menubar popover chrome (macOS 26+ only) so desktop wallpaper
/// bleeds through Liquid Glass: clears `NSWindow.isOpaque/backgroundColor`
/// AND hides the dark-vibrancy `NSVisualEffectView` that `MenuBarExtra(.window)`
/// plants as a sibling of the SwiftUI host (the window backdrop alone is not
/// enough). Idempotent across popover open/close cycles.
private struct MenuBarWindowChromeClearer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { Self.stripChrome(anchoredAt: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
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
            vfx.isHidden = true
        }
        for subview in view.subviews {
            hideVisualEffectViews(in: subview)
        }
    }
}
