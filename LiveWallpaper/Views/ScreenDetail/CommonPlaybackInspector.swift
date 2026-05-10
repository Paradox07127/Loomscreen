import SwiftUI

/// Shared playback / privacy controls that sit above the type-specific
/// inspector panel (video / HTML / shader / scene). The component is the
/// resolution of plan U-L1: keep "Mute" / "Frame Rate" / "Sync to Lock Screen"
/// / "Ephemeral Storage" / "Block Trackers" in a positionally stable spot
/// regardless of `wallpaperType`, so users don't hunt for the same toggle
/// after a content-type switch.
///
/// Bindings flow back to the parent (`ScreenDetailView`) for in-memory state,
/// and changes are committed to `ScreenManager` here so persistence happens
/// at the source of the user gesture instead of leaking through every parent
/// `onChange`.
struct CommonPlaybackInspector: View {
    var screen: Screen
    var wallpaperType: WallpaperType

    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Binding var muted: Bool
    @Binding var frameRateLimit: FrameRateLimit
    @Binding var syncToLockScreen: Bool
    /// Optional binding present only when `wallpaperType == .html`. Drives
    /// the HTML-specific extras (`useEphemeralStorage`, `blockTrackers`)
    /// AND the audio path so HTML's `WKWebView` actually mutes its media
    /// elements — `AVPlayer.muted` is a no-op for HTML wallpapers.
    var htmlConfig: Binding<HTMLConfig>?

    @AppStorage("Inspector.PlaybackExpanded") private var isPlaybackExpanded = true
    @State private var lockScreenExtracted = false

    var body: some View {
        GroupBox {
            CollapsibleSection(
                title: "Playback & Privacy",
                systemImage: "play.circle",
                isExpanded: $isPlaybackExpanded
            ) {
                VStack(spacing: 8) {
                    audioRow
                    if showsFrameRateRow {
                        Divider()
                        frameRateRow
                    }
                    if showsSyncToLockScreenRow {
                        Divider()
                        syncToLockScreenRow
                    }
                    if let htmlConfig {
                        Divider()
                        ephemeralStorageRow(htmlConfig)
                        Divider()
                        trackerBlockingRow(htmlConfig)
                    }
                }
            }
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }

    // MARK: - Row availability

    private var showsFrameRateRow: Bool {
        switch wallpaperType {
        case .video, .metalShader, .scene: return true
        case .html: return false
        }
    }

    private var showsSyncToLockScreenRow: Bool {
        wallpaperType == .video
    }

    // MARK: - Rows

    private var audioRow: some View {
        let mutedBinding = audioMutedBinding
        let isMuted = mutedBinding.wrappedValue
        return SettingRow(
            icon: isMuted ? "speaker.slash" : "speaker.wave.2",
            iconColor: isMuted ? .secondary : .blue,
            title: "Audio",
            subtitle: isMuted
                ? LocalizedStringKey("Muted (default)")
                : LocalizedStringKey("Routed through system output")
        ) {
            Toggle("", isOn: Binding(
                get: { !mutedBinding.wrappedValue },
                set: { mutedBinding.wrappedValue = !$0 }
            ))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(Text("Audio"))
                .accessibilityHint(Text("When off, audio tracks are disabled entirely so macOS does not engage the audio engine"))
        }
    }

    private var frameRateRow: some View {
        SettingRow(
            icon: "gauge.with.dots.needle.bottom.50percent",
            iconColor: .blue,
            title: "Frame Rate"
        ) {
            Picker("", selection: $frameRateLimit) {
                ForEach(FrameRateLimit.allCases) { limit in
                    Text(limit.titleKey).tag(limit)
                }
            }
            .labelsHidden()
            .frame(width: 86)
            .onChange(of: frameRateLimit) { _, newValue in
                screenManager.updateFrameRateLimit(newValue, for: screen)
            }
            .accessibilityLabel(Text("Frame rate limit"))
            .accessibilityValue(Text(frameRateLimit.titleKey))
        }
    }

    private var syncToLockScreenRow: some View {
        SettingRow(icon: "photo.on.rectangle", iconColor: .blue, title: "Desktop Picture") {
            HStack(spacing: 6) {
                if lockScreenExtracted {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                }
                Toggle("", isOn: $syncToLockScreen)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: syncToLockScreen) { _, newValue in
                        screenManager.updateSetAsDesktopPicture(newValue, for: screen)
                        guard newValue else { return }
                        screenManager.extractLockScreenFrame(for: screen)
                        withAnimation(DesignTokens.motion(reduceMotion, .snappy(duration: 0.25))) { lockScreenExtracted = true }
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            withAnimation(DesignTokens.motion(reduceMotion, .snappy(duration: 0.25))) { lockScreenExtracted = false }
                        }
                    }
                    .accessibilityLabel(Text("Set current frame as desktop picture"))
                    .accessibilityHint(Text("Captures the currently visible video frame and uses it as the macOS desktop picture"))
                    .help(Text("Apply the current video frame as the desktop picture"))
            }
        }
    }

    @ViewBuilder
    private func ephemeralStorageRow(_ htmlConfig: Binding<HTMLConfig>) -> some View {
        SettingRow(
            icon: "archivebox",
            iconColor: .purple,
            title: "Clear Data on Exit",
            subtitle: htmlConfig.wrappedValue.useEphemeralStorage
                ? LocalizedStringKey("Browsing data is cleared on each session")
                : LocalizedStringKey("Browsing data is saved across sessions")
        ) {
            Toggle("", isOn: htmlConfigBinding(htmlConfig, keyPath: \.useEphemeralStorage))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(Text("Ephemeral browsing data"))
                .accessibilityHint(Text("When on, the wallpaper's WKWebView starts fresh each session — cookies, localStorage, and cache are not persisted"))
        }
    }

    @ViewBuilder
    private func trackerBlockingRow(_ htmlConfig: Binding<HTMLConfig>) -> some View {
        SettingRow(
            icon: "shield",
            iconColor: .red,
            title: "Block Trackers"
        ) {
            Toggle("", isOn: htmlConfigBinding(htmlConfig, keyPath: \.blockTrackers))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(Text("Block trackers"))
                .accessibilityHint(Text("Filters analytics and ad scripts before they reach the wallpaper renderer"))
        }
    }

    // MARK: - Bindings

    /// Routes the audio toggle to the correct backing store: video sessions
    /// use `AVPlayer.muted` via `ScreenManager.updateMuted`, HTML sessions
    /// flip `HTMLConfig.muteAudio` so the WKWebView's media elements mute.
    /// Without this split the HTML mute toggle was a visual no-op.
    private var audioMutedBinding: Binding<Bool> {
        if let htmlConfig {
            return htmlConfigBinding(htmlConfig, keyPath: \.muteAudio)
        }
        return Binding(
            get: { muted },
            set: { newValue in
                guard muted != newValue else { return }
                muted = newValue
                screenManager.updateMuted(newValue, for: screen)
            }
        )
    }

    /// Threads `HTMLConfig` keypath writes back through the parent `Binding`
    /// AND `ScreenManager.updateHTMLConfig` so persistence and runtime apply
    /// happen in one place. Identity-noop sets are filtered to avoid extra
    /// session rebuilds.
    private func htmlConfigBinding<Value: Equatable>(
        _ htmlConfig: Binding<HTMLConfig>,
        keyPath: WritableKeyPath<HTMLConfig, Value>
    ) -> Binding<Value> {
        Binding(
            get: { htmlConfig.wrappedValue[keyPath: keyPath] },
            set: { newValue in
                guard htmlConfig.wrappedValue[keyPath: keyPath] != newValue else { return }
                var next = htmlConfig.wrappedValue
                next[keyPath: keyPath] = newValue
                htmlConfig.wrappedValue = next
                screenManager.updateHTMLConfig(next, for: screen)
            }
        )
    }
}
