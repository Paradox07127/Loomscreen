import SwiftUI
import AppKit

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
            Picker("", selection: frameRateBinding) {
                ForEach(FrameRateLimit.allCases) { limit in
                    Text(limit.titleKey).tag(limit)
                }
            }
            .labelsHidden()
            .frame(width: 86)
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
                Toggle("", isOn: syncToLockScreenBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
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
                guard newValue else { return }
                screenManager.extractLockScreenFrame(for: screen)
                withAnimation(DesignTokens.motion(reduceMotion, .snappy(duration: 0.25))) {
                    lockScreenExtracted = true
                }
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    withAnimation(DesignTokens.motion(reduceMotion, .snappy(duration: 0.25))) {
                        lockScreenExtracted = false
                    }
                }
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
        devicePixelRatioText = usesPhysicalPixels
            ? "1 (pinned)"
            : "\(Self.scalePairText(x: scaleX, y: scaleY, suffix: false)) (native)"
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
