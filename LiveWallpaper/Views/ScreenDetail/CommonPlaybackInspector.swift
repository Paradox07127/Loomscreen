import SwiftUI
import AppKit
import LiveWallpaperSharedUI

/// Shared playback / privacy controls that sit above the type-specific
/// inspector panel (video / HTML / shader / scene). The component is the
/// resolution of plan U-L1: keep "Mute" / "Frame Rate" / "Sync to Lock Screen"
/// in a positionally stable spot regardless of `wallpaperType`, so users
/// don't hunt for the same toggle after a content-type switch. HTML-only
/// privacy controls live in `ContentSecurityInspector` so the playback
/// section's mental model stays uniform across types.
///
/// Bindings flow back to the parent (`ScreenDetailView`) for in-memory state,
/// and changes are committed to `ScreenManager` here so persistence happens
/// at the source of the user gesture instead of leaking through every parent
/// `onChange`.
struct CommonPlaybackInspector: View {
    var screen: Screen
    var wallpaperType: WallpaperType

    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.featureCatalog) private var featureCatalog
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Binding var muted: Bool
    @Binding var videoVolume: Double
    @Binding var videoDisplayMode: VideoDisplayMode
    @Binding var frameRateLimit: FrameRateLimit
    @Binding var syncToLockScreen: Bool
    /// Scene-only cursor-reactivity toggle. Bound from the draft; only the
    /// scene row reads it.
    @Binding var sceneMouseInteractionEnabled: Bool
    /// Scene-only click-capture toggle (real mouse interaction; steals desktop
    /// clicks while on).
    @Binding var sceneClickCaptureEnabled: Bool

    /// One-shot "you understand this steals desktop clicks" acknowledgement so
    /// the first enable shows a confirmation; later toggles are silent.
    @AppStorage("Scene.ClickCapture.Acknowledged") private var clickCaptureAcknowledged = false
    @State private var showClickCaptureConfirm = false
    /// Optional binding present only when `wallpaperType == .html`. Drives
    /// the audio path so HTML's `WKWebView` actually mutes its media
    /// elements — `AVPlayer.muted` is a no-op for HTML wallpapers.
    var htmlConfig: Binding<HTMLConfig>?
    /// Current colour space override. When `.forceSDR`, the Rec.709
    /// composition takes ownership of `AVPlayerItem.videoComposition`, so
    /// the frame-rate cap (which writes the same slot) is dimmed and
    /// ignored — the picker reflects that disabled state.
    var videoColorSpace: VideoColorSpace = .auto

    @AppStorage("Inspector.PlaybackExpanded") private var isPlaybackExpanded = true
    @State private var lockScreenExtracted = false
    /// Monotonic counter that lets a late "clear ✓" Task drop itself when a
    /// newer toggle gesture has already taken over the visual feedback —
    /// same pattern as `ScheduleSection.conflictHighlightGeneration`.
    @State private var lockScreenFeedbackGeneration = 0

    var body: some View {
        GroupBox {
            CollapsibleSection(
                title: "Playback",
                systemImage: "play.circle",
                isExpanded: $isPlaybackExpanded
            ) {
                VStack(spacing: 8) {
                    audioRow
                    if showsFrameRateRow {
                        Divider()
                        frameRateRow
                    }
                    if showsVideoDisplayModeRow {
                        Divider()
                        videoDisplayModeRow
                    }
                    if showsMouseInteractionRow {
                        Divider()
                        mouseInteractionRow
                        Divider()
                        clickInteractionRow
                    }
                    if showsSyncToLockScreenRow {
                        Divider()
                        syncToLockScreenRow
                    }
                }
            }
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
        .alert("Enable Wallpaper Interaction?", isPresented: $showClickCaptureConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Enable") {
                clickCaptureAcknowledged = true
                setClickCapture(true)
            }
        } message: {
            Text("This lets you click elements inside the scene, but while it's on you can't click desktop icons or right-click the desktop on this display. Turn it off here to restore desktop clicks.")
        }
    }

    // MARK: - Row availability

    private var showsFrameRateRow: Bool {
        switch wallpaperType {
        case .video, .metalShader, .scene: return true
        case .html: return false
        }
    }

    /// Stays visible for video regardless of display count so the persisted
    /// `.spanAllDisplays` state never silently hides itself when the second
    /// display unplugs — the row goes disabled with a subtitle instead.
    private var showsVideoDisplayModeRow: Bool {
        wallpaperType == .video
    }

    private var hasMultipleDisplays: Bool {
        screenManager.screens.count > 1
    }

    /// Cursor-reactivity is a scene-only concept (camera parallax / pointer
    /// shaders) — video / HTML / shader wallpapers don't sample the pointer here.
    private var showsMouseInteractionRow: Bool {
        wallpaperType == .scene
    }

    private var showsSyncToLockScreenRow: Bool {
        wallpaperType == .video && featureCatalog.isEnabled(.lockScreenSnapshots)
    }

    // MARK: - Rows

    /// First N% of the slider is a mute "dead zone" — prevents a stray drag
    /// from leaking a 1-2% audio level. Past this threshold the slider's
    /// position maps linearly to the [0,1] internal volume.
    private static let audioDeadZone: Double = 0.04

    private var audioRow: some View {
        let mutedBinding = audioMutedBinding
        let isMuted = mutedBinding.wrappedValue
        let percent = videoVolumePercent
        return SettingRow(
            icon: isMuted ? "speaker.slash" : "speaker.wave.2",
            iconColor: isMuted ? .secondary : .blue,
            title: "Audio"
        ) {
            HStack(spacing: 8) {
                Slider(value: unifiedAudioBinding, in: 0...1)
                    .controlSize(.small)
                    .frame(width: 96)
                    .accessibilityLabel(Text("Audio"))
                    .accessibilityValue(audioAccessibilityValue(isMuted: isMuted, percent: percent))

                audioLevelLabel(isMuted: isMuted, percent: percent)
                    .font(DesignTokens.Typography.metric)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
                    .monospacedDigit()
            }
        }
    }

    @ViewBuilder
    private func audioLevelLabel(isMuted: Bool, percent: Int) -> some View {
        if isMuted {
            Text("Muted", comment: "Audio level display when the wallpaper is muted")
        } else {
            // Digit % is universal; ASCII renders identically across locales.
            Text(verbatim: "\(percent)%")
        }
    }

    private func audioAccessibilityValue(isMuted: Bool, percent: Int) -> Text {
        if isMuted {
            return Text("Muted", comment: "Audio level display when the wallpaper is muted")
        }
        return Text("\(percent) percent", comment: "Audio level accessibility value, e.g. \"35 percent\".")
    }

    private var frameRateRow: some View {
        let forceSDRActive = videoColorSpace == .forceSDR
        return SettingRow(
            icon: "gauge.with.dots.needle.bottom.50percent",
            iconColor: forceSDRActive ? .secondary : .blue,
            title: "Frame Rate",
            subtitle: forceSDRActive ? "Disabled while Force SDR is active" : nil,
            info: "Caps below 30 FPS force a compositing pass — useful when effects are active or to extend battery on long sessions. 60 FPS and Unlimited use the native playback path."
        ) {
            Picker("", selection: frameRateBinding) {
                ForEach(FrameRateLimit.allCases) { limit in
                    Text(limit.titleKey).tag(limit)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .disabled(forceSDRActive)
            .accessibilityLabel(Text("Frame rate limit"))
            .accessibilityValue(forceSDRActive
                ? Text("Disabled — Force SDR is active", comment: "Accessibility value when the frame-rate picker is dimmed because Force SDR owns the video composition slot.")
                : Text(frameRateLimit.titleKey))
        }
    }

    private var videoDisplayModeRow: some View {
        SettingRow(
            icon: "rectangle.split.2x1",
            iconColor: videoDisplayMode == .spanAllDisplays ? .blue : .secondary,
            title: "Span Displays",
            subtitle: hasMultipleDisplays ? nil : "Connect another display to enable",
            info: "When on, all connected displays render one stretched video. When off, each display plays its own copy independently — multi-display sync is not possible."
        ) {
            Toggle("", isOn: spanDisplaysBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!hasMultipleDisplays)
                .accessibilityLabel(Text("Span across displays"))
                .accessibilityHint(hasMultipleDisplays
                    ? Text("")
                    : Text("Disabled — connect another display to enable"))
        }
    }

    private var spanDisplaysBinding: Binding<Bool> {
        Binding(
            get: { videoDisplayMode == .spanAllDisplays },
            set: { newValue in
                let target: VideoDisplayMode = newValue ? .spanAllDisplays : .perDisplay
                guard videoDisplayMode != target else { return }
                videoDisplayMode = target
                screenManager.updateVideoDisplayMode(target, for: screen)
            }
        )
    }

    private var mouseInteractionRow: some View {
        SettingRow(
            icon: "cursorarrow.rays",
            iconColor: sceneMouseInteractionEnabled ? .blue : .secondary,
            title: "Follow Cursor",
            info: "Camera parallax and pointer-driven effects follow your cursor. Passive — safe for desktop icon clicks. Turn off to keep the scene perfectly still regardless of where the cursor is."
        ) {
            Toggle("", isOn: mouseInteractionBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(Text("Follow cursor"))
                .accessibilityHint(Text("When off, the scene stops following the cursor"))
        }
    }

    private var mouseInteractionBinding: Binding<Bool> {
        Binding(
            get: { sceneMouseInteractionEnabled },
            set: { newValue in
                guard sceneMouseInteractionEnabled != newValue else { return }
                sceneMouseInteractionEnabled = newValue
                screenManager.updateSceneMouseInteraction(newValue, for: screen)
            }
        )
    }

    /// Real click capture. Enabling raises the wallpaper above desktop icons and
    /// intercepts clicks (steals desktop clicks) so an interactive scene can
    /// respond — gated behind a one-time confirmation.
    private var clickInteractionRow: some View {
        SettingRow(
            icon: "cursorarrow.click",
            iconColor: sceneClickCaptureEnabled ? .blue : .secondary,
            title: "Interactive",
            info: "Lets the scene receive real clicks and drags (for interactive scenes). While on, clicks go to the wallpaper instead of the desktop on this display — you won't be able to click desktop icons until you turn it back off."
        ) {
            Toggle("", isOn: clickInteractionBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(Text("Interactive"))
                .accessibilityHint(Text("When on, the scene captures mouse clicks and the desktop can't be clicked on this display"))
        }
    }

    private var clickInteractionBinding: Binding<Bool> {
        Binding(
            get: { sceneClickCaptureEnabled },
            set: { newValue in
                guard sceneClickCaptureEnabled != newValue else { return }
                if newValue, !clickCaptureAcknowledged {
                    // First enable: confirm the desktop-click tradeoff before applying.
                    showClickCaptureConfirm = true
                    return
                }
                setClickCapture(newValue)
            }
        )
    }

    private func setClickCapture(_ enabled: Bool) {
        guard sceneClickCaptureEnabled != enabled else { return }
        sceneClickCaptureEnabled = enabled
        screenManager.updateSceneClickCapture(enabled, for: screen)
    }

    private var syncToLockScreenRow: some View {
        SettingRow(
            icon: "photo.on.rectangle",
            iconColor: .blue,
            title: "Desktop Picture",
            info: "Captures the currently visible video frame and uses it as the macOS desktop picture, so the lock screen mirrors what was playing."
        ) {
            HStack(spacing: 6) {
                if lockScreenExtracted {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(DesignTokens.Colors.Status.active)
                        .transition(.scale.combined(with: .opacity))
                        .accessibilityHidden(true)
                }
                Toggle("", isOn: syncToLockScreenBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel(Text("Set current frame as desktop picture"))
            }
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

    /// Single binding driving the audio slider. Slider position [0, 1] maps to:
    ///   - [0, deadZone]  → muted (volume 0 displayed)
    ///   - (deadZone, 1]  → unmuted; internal volume = (pos - deadZone) / (1 - deadZone)
    ///
    /// `<=` on the dead-zone boundary closes the previous `muted: false,
    /// volume: 0` edge state where the slider sat at exactly `deadZone`.
    private var unifiedAudioBinding: Binding<Double> {
        Binding(
            get: {
                if audioMutedBinding.wrappedValue { return 0 }
                let deadZone = Self.audioDeadZone
                return deadZone + Self.clampedVolume(currentVolume) * (1 - deadZone)
            },
            set: { sliderValue in
                let shouldMute = sliderValue <= Self.audioDeadZone
                let mutedBinding = audioMutedBinding

                if shouldMute {
                    if !mutedBinding.wrappedValue {
                        mutedBinding.wrappedValue = true
                    }
                    return
                }

                if mutedBinding.wrappedValue {
                    mutedBinding.wrappedValue = false
                }

                let normalized = (sliderValue - Self.audioDeadZone) / (1 - Self.audioDeadZone)
                let clampedValue = Self.clampedVolume(normalized)
                applyVolume(clampedValue)
            }
        )
    }

    private var currentVolume: Double {
        if let htmlConfig {
            return htmlConfig.wrappedValue.audioVolume
        }
        return videoVolume
    }

    private func applyVolume(_ value: Double) {
        if let htmlConfig {
            guard abs(htmlConfig.wrappedValue.audioVolume - value) > 0.001 else { return }
            var next = htmlConfig.wrappedValue
            next.audioVolume = HTMLConfig.clampedAudioVolume(value)
            htmlConfig.wrappedValue = next
            screenManager.updateHTMLConfig(next, for: screen)
            return
        }
        guard abs(videoVolume - value) > 0.001 else { return }
        videoVolume = value
        screenManager.updateVideoVolume(value, for: screen)
    }

    private var videoVolumePercent: Int {
        Int((Self.clampedVolume(currentVolume) * 100).rounded())
    }

    private static func clampedVolume(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        return min(max(value, 0), 1)
    }

    private var frameRateBinding: Binding<FrameRateLimit> {
        Binding(
            get: { frameRateLimit },
            set: { newValue in
                guard frameRateLimit != newValue else { return }
                frameRateLimit = newValue
                screenManager.updateFrameRateLimit(newValue, for: screen)
            }
        )
    }

    private var syncToLockScreenBinding: Binding<Bool> {
        Binding(
            get: { syncToLockScreen },
            set: { newValue in
                guard syncToLockScreen != newValue else { return }
                syncToLockScreen = newValue
                screenManager.updateSetAsDesktopPicture(newValue, for: screen)
                guard newValue else {
                    // Bump generation so any pending "clear ✓" Task spawned
                    // by a previous on→off→on doesn't show stale feedback.
                    lockScreenFeedbackGeneration += 1
                    lockScreenExtracted = false
                    return
                }
                // Only show ✓ if a frame was actually queued — guards against
                // showing success when the player isn't ready yet.
                guard screenManager.extractLockScreenFrame(for: screen) else { return }
                lockScreenFeedbackGeneration += 1
                let generation = lockScreenFeedbackGeneration
                withAnimation(DesignTokens.motion(reduceMotion, .snappy(duration: 0.25))) {
                    lockScreenExtracted = true
                }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    guard generation == lockScreenFeedbackGeneration else { return }
                    withAnimation(DesignTokens.motion(reduceMotion, .snappy(duration: 0.25))) {
                        lockScreenExtracted = false
                    }
                }
            }
        )
    }

    /// Threads `HTMLConfig` keypath writes back through the parent `Binding` AND `ScreenManager.updateHTMLConfig` so persistence and runtime apply happen in one place.
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

/// HTML-only privacy + origin-trust controls. Lives directly under the
/// playback section in the inspector column so all "what is the WKWebView
/// allowed to do" decisions sit together — ephemeral data, tracker blocking,
/// and (for remote URLs) the per-origin script execution grant moved here
/// from the source banner column.
struct ContentSecurityInspector: View {
    var screen: Screen
    var source: HTMLSource?
    @Binding var htmlConfig: HTMLConfig

    @Environment(ScreenManager.self) private var screenManager
    @State private var trustStore = TrustedHostStore.shared
    /// Holds the origin the user clicked "Trust…" for. Tracking the origin
    /// (not a bare Bool) prevents a source change while the dialog is open
    /// from re-targeting the confirmation at a different host.
    @State private var pendingTrustOrigin: TrustedHTMLOrigin?
    @AppStorage("Inspector.ContentSecurityExpanded") private var isExpanded = true

    var body: some View {
        GroupBox {
            CollapsibleSection(
                title: "Content Security",
                systemImage: "lock.shield",
                isExpanded: $isExpanded
            ) {
                VStack(spacing: 8) {
                    ephemeralStorageRow
                    Divider()
                    trackerBlockingRow
                    Divider()
                    cspEnforcementRow
                    Divider()
                    aggressiveSuspendRow
                    if let origin = remoteOrigin {
                        Divider()
                        originTrustRow(for: origin)
                    }
                }
            }
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }

    private var ephemeralStorageRow: some View {
        SettingRow(
            icon: "archivebox",
            iconColor: .purple,
            title: "Clear Data on Exit",
            info: "When on, the wallpaper's WKWebView starts fresh each session — cookies, localStorage, and cache are not persisted."
        ) {
            Toggle("", isOn: htmlConfigBinding(\.useEphemeralStorage))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(Text("Ephemeral browsing data"))
        }
    }

    private var trackerBlockingRow: some View {
        SettingRow(
            icon: "shield",
            iconColor: .red,
            title: "Block Trackers"
        ) {
            Toggle("", isOn: htmlConfigBinding(\.blockTrackers))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(Text("Block trackers"))
        }
    }

    private var cspEnforcementRow: some View {
        SettingRow(
            icon: "lock.shield.fill",
            iconColor: .indigo,
            title: "Enforce Content Security Policy",
            info: "Injects a strict CSP meta tag before the page evaluates its own scripts. Permits HTTPS + the bundled livewallpaper:// scheme; blocks data exfiltration via FTP / arbitrary schemes. Some wallpapers may break — toggling requires a reload."
        ) {
            Toggle("", isOn: htmlConfigBinding(\.cspEnforcementEnabled))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(Text("Enforce content security policy"))
        }
    }

    private var aggressiveSuspendRow: some View {
        SettingRow(
            icon: "bolt.slash.fill",
            iconColor: .yellow,
            title: "Aggressive Suspend",
            info: "On suspend, force-release every GPU canvas context. On resume, restore it. Drops GPU usage to zero when the wallpaper is occluded or thermal-throttled, but some pages do not handle context restore and stay black after the round-trip."
        ) {
            Toggle("", isOn: htmlConfigBinding(\.aggressiveSuspend))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(Text("Aggressive suspend"))
        }
    }

    private var remoteOrigin: TrustedHTMLOrigin? {
        guard let source else { return nil }
        switch HTMLTrust.evaluate(source: source, trustedOrigins: trustStore.originSet) {
        case .trustedRemote(let origin), .untrustedRemote(let origin):
            return origin
        case .localContent:
            return nil
        }
    }

    @ViewBuilder
    private func originTrustRow(for origin: TrustedHTMLOrigin) -> some View {
        let isTrusted = trustStore.originSet.contains(origin)
        // `LocalizedStringKey(origin.displayName)` is used here intentionally
        // for the subtitle: when no translation exists (host names never have
        // one) it falls back to the raw host string — the literal user data
        // we want to show. The xcstrings extractor will simply skip it.
        SettingRow(
            icon: isTrusted ? "checkmark.shield.fill" : "exclamationmark.shield",
            iconColor: isTrusted ? DesignTokens.Colors.Status.active : DesignTokens.Colors.Status.warning,
            title: "Origin Access",
            subtitle: LocalizedStringKey(origin.displayName),
            info: trustRowInfo(for: origin, isTrusted: isTrusted)
        ) {
            trustRowAction(for: origin, isTrusted: isTrusted)
        }
    }

    private func trustRowInfo(for origin: TrustedHTMLOrigin, isTrusted: Bool) -> LocalizedStringKey {
        if trustStore.isBuiltInTrusted(origin) {
            return "Built-in trust for the platform's official embed surface — cannot be revoked."
        }
        if isTrusted {
            return "JavaScript runs on this origin. Revoke to disable script execution."
        }
        if origin.isSecure {
            return "Scripts disabled. Trust this origin to allow JavaScript execution."
        }
        return "HTTP origins cannot be trusted. Use HTTPS instead."
    }

    @ViewBuilder
    private func trustRowAction(for origin: TrustedHTMLOrigin, isTrusted: Bool) -> some View {
        if trustStore.isBuiltInTrusted(origin) {
            // Built-in trust (e.g. youtube-nocookie.com) — can't be revoked,
            // show a static "Built-in" badge instead of a Revoke button.
            Text("Built-in")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15), in: Capsule())
                .fixedSize()
        } else if isTrusted {
            Button("Revoke") {
                guard let source else { return }
                _ = trustStore.revoke(origin)
                screenManager.setHTMLWallpaper(
                    source: source,
                    config: htmlConfig,
                    forceReload: true,
                    for: screen
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
        } else if origin.isSecure {
            Button("Trust…") {
                pendingTrustOrigin = origin
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .fixedSize()
            .confirmationDialog(
                Text("Trust \(origin.displayName) for JavaScript?"),
                isPresented: Binding(
                    get: { pendingTrustOrigin == origin },
                    set: { if !$0 { pendingTrustOrigin = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Trust Origin") {
                    defer { pendingTrustOrigin = nil }
                    // Source may have changed while the dialog was open; only
                    // grant trust if the current row's origin still matches.
                    guard let source, remoteOrigin == origin else { return }
                    _ = trustStore.trust(origin)
                    screenManager.setHTMLWallpaper(
                        source: source,
                        config: htmlConfig,
                        forceReload: true,
                        for: screen
                    )
                }
                Button("Cancel", role: .cancel) {
                    pendingTrustOrigin = nil
                }
            } message: {
                Text("This allows the wallpaper to run scripts, use local storage, and access WebGPU. Only trust origins you recognize.")
            }
        }
    }

    private func htmlConfigBinding<Value: Equatable>(
        _ keyPath: WritableKeyPath<HTMLConfig, Value>
    ) -> Binding<Value> {
        Binding(
            get: { htmlConfig[keyPath: keyPath] },
            set: { newValue in
                guard htmlConfig[keyPath: keyPath] != newValue else { return }
                var next = htmlConfig
                next[keyPath: keyPath] = newValue
                htmlConfig = next
                screenManager.updateHTMLConfig(next, for: screen)
            }
        )
    }
}

struct HTMLRenderingDiagnosticsInspector: View {
    var screen: Screen
    var source: HTMLSource?
    var config: HTMLConfig

    @AppStorage("Inspector.HTMLRenderingExpanded") private var isExpanded = true

    var body: some View {
        GroupBox {
            CollapsibleSection(
                title: "HTML Rendering",
                systemImage: "ruler",
                isExpanded: $isExpanded
            ) {
                let diagnostics = HTMLRenderingDiagnostics(
                    screen: screen,
                    source: source,
                    config: config
                )

                VStack(spacing: 6) {
                    diagnosticRow("Measurement", diagnostics.measurementText)
                    diagnosticRow("Screen points", diagnostics.pointSizeText)
                    diagnosticRow("Backing pixels", diagnostics.backingPixelSizeText)
                    diagnosticRow("Scale", diagnostics.scaleText)
                    diagnosticRow("HTML viewport", diagnostics.viewportText)
                    diagnosticRow("DPR", diagnostics.devicePixelRatioText)
                    diagnosticRow("Mode", diagnostics.modeText)
                }
                .help(Text("Screen points come from the live content view when available. Backing pixels use AppKit's convertToBacking path."))
            }
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }

    private func diagnosticRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(verbatim: value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }
}

@MainActor
private struct HTMLRenderingDiagnostics {
    let measurementText: String
    let pointSizeText: String
    let backingPixelSizeText: String
    let scaleText: String
    let viewportText: String
    let devicePixelRatioText: String
    let modeText: String

    init(screen: Screen, source: HTMLSource?, config: HTMLConfig) {
        let geometry = Self.currentGeometry(for: screen)
        let scaleX = geometry.pointSize.width > 0
            ? geometry.backingPixelSize.width / geometry.pointSize.width
            : screen.nsScreen.backingScaleFactor
        let scaleY = geometry.pointSize.height > 0
            ? geometry.backingPixelSize.height / geometry.pointSize.height
            : screen.nsScreen.backingScaleFactor
        let usesPhysicalPixels = Self.effectivePhysicalPixelLayout(source: source, config: config)
        let viewportSize = usesPhysicalPixels ? geometry.backingPixelSize : geometry.pointSize

        measurementText = geometry.usesLiveView ? "Live view" : "Screen frame"
        pointSizeText = Self.pointSizeText(geometry.pointSize)
        backingPixelSizeText = Self.pixelSizeText(geometry.backingPixelSize)
        scaleText = Self.scalePairText(x: scaleX, y: scaleY, suffix: true)
        viewportText = Self.cssViewportText(viewportSize)
        devicePixelRatioText = "\(Self.scalePairText(x: scaleX, y: scaleY, suffix: false)) (native)"
        modeText = if usesPhysicalPixels {
            config.physicalPixelLayout ? "Physical pixels" : "Physical pixels (auto)"
        } else {
            "CSS points"
        }
    }

    private static func currentGeometry(for screen: Screen) -> (
        pointSize: CGSize,
        backingPixelSize: CGSize,
        usesLiveView: Bool
    ) {
        if let contentView = screen.activeWallpaperWindow?.contentView {
            let bounds = contentView.bounds
            if bounds.width > 0, bounds.height > 0 {
                return (bounds.size, contentView.convertToBacking(bounds).size, true)
            }
        }

        let pointSize = screen.frame.size
        let scale = screen.nsScreen.backingScaleFactor
        return (
            pointSize,
            CGSize(width: pointSize.width * scale, height: pointSize.height * scale),
            false
        )
    }

    private static func effectivePhysicalPixelLayout(source: HTMLSource?, config: HTMLConfig) -> Bool {
        guard !config.physicalPixelLayout, let source else {
            return config.physicalPixelLayout
        }
        return HTMLWallpaperCompatibilityPolicy.looksLikeWallpaperEngineFolder(source)
    }

    private static func pointSizeText(_ size: CGSize) -> String {
        "\(pointLengthText(size.width))×\(pointLengthText(size.height)) pt"
    }

    private static func pixelSizeText(_ size: CGSize) -> String {
        "\(Int(size.width.rounded()))×\(Int(size.height.rounded())) px"
    }

    private static func cssViewportText(_ size: CGSize) -> String {
        "\(Int(size.width.rounded()))×\(Int(size.height.rounded())) CSS px"
    }

    private static func scalePairText(x: CGFloat, y: CGFloat, suffix: Bool) -> String {
        let xText = scaleValueText(x)
        let text: String
        if abs(x - y) < 0.005 {
            text = xText
        } else {
            text = "\(xText) / \(scaleValueText(y))"
        }
        return suffix ? "\(text)×" : text
    }

    private static func pointLengthText(_ value: CGFloat) -> String {
        if abs(value.rounded() - value) < 0.05 {
            return "\(Int(value.rounded()))"
        }
        return String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), Double(value))
    }

    private static func scaleValueText(_ value: CGFloat) -> String {
        if abs(value.rounded() - value) < 0.005 {
            return "\(Int(value.rounded()))"
        }
        return String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), Double(value))
    }
}
