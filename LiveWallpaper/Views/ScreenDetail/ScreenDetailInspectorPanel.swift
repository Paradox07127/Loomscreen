import AppKit
import LiveWallpaperCore
import LiveWallpaperSharedUI
import SwiftUI

struct ScreenDetailInspectorPanel: View {
    let screen: Screen
    @Binding var draft: ScreenDetailDraftState
    let screenManager: ScreenManager
    let featureCatalog: FeatureCatalog
    let reduceMotion: Bool
    let inspectorPanelWidth: CGFloat
    @Binding var isEnvironmentExpanded: Bool
    @Binding var isColorExpanded: Bool
    let onParticleEffectChange: (ParticleEffect) -> Void
    let onParticleDensityChange: (Double) -> Void
    let onWeatherReactiveChange: (Bool) -> Void
    let onWallpaperModeChange: (WallpaperMode) -> Void
    let onResetDisplaySettings: () -> Void
    #if !LITE_BUILD
    @State private var wpeProjectCustomSettingsSchema: WallpaperEngineProjectPropertySchema?
    #endif

    var body: some View {
        ScrollView {
            AdaptiveGlassContainer(spacing: 16) {
                VStack(spacing: 16) {
                    if draft.selectedWallpaperType == .video,
                       featureCatalog.capabilities.selectableWallpaperModes.count > 1 {
                        wallpaperModeCard
                    }

                    CommonPlaybackInspector(
                        screen: screen,
                        wallpaperType: draft.selectedWallpaperType,
                        muted: $draft.videoMuted,
                        videoVolume: $draft.videoVolume,
                        videoDisplayMode: $draft.selectedVideoDisplayMode,
                        frameRateLimit: $draft.selectedFrameRateLimit,
                        syncToLockScreen: $draft.setAsLockScreen,
                        htmlConfig: draft.selectedWallpaperType == .html ? $draft.htmlConfig : nil
                    )

                    if draft.selectedWallpaperType == .html {
                        ContentSecurityInspector(
                            screen: screen,
                            source: draft.htmlSource,
                            htmlConfig: $draft.htmlConfig
                        )

                        HTMLOptionsInspector(
                            screen: screen,
                            config: $draft.htmlConfig
                        )

                        #if !LITE_BUILD
                        if let wpeProjectCustomSettingsSchema,
                           wpeProjectCustomSettingsSchema.hasMeaningfulSettings {
                            WPEProjectCustomSettingsCard(
                                screen: screen,
                                schema: wpeProjectCustomSettingsSchema,
                                config: $draft.htmlConfig
                            )
                        }
                        #endif

                        HTMLTransformInspector(
                            screen: screen,
                            config: $draft.htmlConfig
                        )

                        HTMLRenderingDiagnosticsInspector(
                            screen: screen,
                            source: draft.htmlSource,
                            config: draft.htmlConfig
                        )
                    }

                    if draft.selectedWallpaperType == .video,
                       featureCatalog.capabilities.selectableWallpaperModes.count > 1 {
                        videoSettingsContent
                    }
                }
                .padding(.horizontal, DesignTokens.Inspector.horizontalPadding(for: inspectorPanelWidth))
                .padding(.vertical, 14)
            }
        }
        .frame(width: inspectorPanelWidth)
        .fixedSize(horizontal: true, vertical: false)
        .background(Color(NSColor.windowBackgroundColor))
        .clipped()
        .accessibilityLabel(Text("Wallpaper Properties"))
        #if !LITE_BUILD
        .task(id: wpeProjectCustomSettingsLoadKey) {
            await loadWPEProjectCustomSettingsSchema()
        }
        #endif
    }

    #if !LITE_BUILD
    /// Stable identifier driving WPE project schema reloads. The inspector
    /// panel is always mounted while HTML properties are visible, unlike the
    /// card itself, so the async read cannot deadlock behind an initially empty
    /// card body.
    private var wpeProjectCustomSettingsLoadKey: String {
        guard draft.selectedWallpaperType == .html,
              case .folder(let bookmarkData, let indexFileName) = draft.htmlSource else {
            return "hidden"
        }
        if let originalType = draft.wpeOrigin?.originalType,
           originalType != .web {
            return "hidden"
        }
        return "\(screen.id):\(draft.wpeOrigin?.workshopID ?? "folder"):\(indexFileName):\(bookmarkData.base64EncodedString())"
    }

    @MainActor
    private func loadWPEProjectCustomSettingsSchema() async {
        guard draft.selectedWallpaperType == .html else {
            wpeProjectCustomSettingsSchema = nil
            return
        }

        let outcome = await WPEProjectCustomSettingsSchemaLoader.load(
            source: draft.htmlSource,
            wpeOrigin: draft.wpeOrigin
        )
        guard !Task.isCancelled else { return }
        if outcome.schema != nil || outcome.isExpectedAbsence {
            Logger.info("WPECustomSettings: \(outcome.log)", category: .screenManager)
        } else {
            Logger.warning("WPECustomSettings: \(outcome.log)", category: .screenManager)
        }
        wpeProjectCustomSettingsSchema = outcome.schema
    }
    #endif

    @ViewBuilder
    private var videoSettingsContent: some View {
        if featureCatalog.isEnabled(.videoEffects) {
            VStack(spacing: 16) {
                environmentGroup
                colorGroup
                resetDisplayButton
            }
        }
    }

    private var environmentGroup: some View {
        GroupBox {
            CollapsibleSection(
                title: "Environment",
                systemImage: "cloud.sun.rain",
                isExpanded: $isEnvironmentExpanded
            ) {
                VStack(spacing: 8) {
                    particleEffectRow

                    if draft.selectedParticleEffect != .none {
                        particleDensityRow
                    }

                    Divider()

                    weatherReactiveRow

                    if draft.effectConfig.weatherReactive {
                        WeatherStatusBadge(
                            weatherService: screenManager.weatherService,
                            refresh: screenManager.weatherService.refresh
                        )
                    }
                }
            }
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }

    private var particleEffectRow: some View {
        SettingRow(
            icon: "sparkles",
            iconColor: .purple,
            title: "Particles"
        ) {
            Picker("", selection: particleEffectBinding) {
                ForEach(ParticleEffect.allCases) { effect in
                    Text(effect.titleKey).tag(effect)
                }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(Text("Particle effect"))
            .accessibilityValue(Text(draft.selectedParticleEffect.titleKey))
        }
    }

    private var particleDensityRow: some View {
        SettingRow(icon: "circle.hexagongrid", iconColor: .purple, title: "Density") {
            HStack(spacing: 8) {
                Slider(value: particleDensityBinding, in: 0.2...3.0)
                    .controlSize(.small)
                    .frame(width: 80)
                    .accessibilityLabel(Text("Particle density"))
                    .accessibilityValue(String(format: "%.1f×", draft.particleDensity))
                Text(String(format: "%.1f", draft.particleDensity))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)
            }
        }
    }

    private var weatherReactiveRow: some View {
        SettingRow(
            icon: "cloud.sun",
            iconColor: .cyan,
            title: "Weather"
        ) {
            Toggle("", isOn: weatherReactiveBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(Text("Weather-reactive effects"))
        }
    }

    private var colorGroup: some View {
        GroupBox {
            CollapsibleSection(
                title: "Color & Filters",
                systemImage: "slider.horizontal.3",
                isExpanded: $isColorExpanded
            ) {
                ColorAdjustmentsView(
                    effectConfig: $draft.effectConfig,
                    videoColorSpace: $draft.videoColorSpace,
                    screen: screen,
                    screenManager: screenManager
                )
            }
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }

    private var resetDisplayButton: some View {
        HStack {
            Spacer()
            Button(action: onResetDisplaySettings) {
                Label("Reset This Display", systemImage: "arrow.counterclockwise.circle")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.red)
            .tint(Color.red)
            .adaptiveGlassSurface(.capsule, tint: .red, interactive: true)
            .contentShape(Capsule())
            .help(Text("Reset all playback, color, particle, audio, and layout settings on this display — wallpaper, playlist, and bookmarks stay"))
            Spacer()
        }
        .padding(.top, 8)
    }

    private var particleEffectBinding: Binding<ParticleEffect> {
        Binding(
            get: { draft.selectedParticleEffect },
            set: { newValue in
                guard draft.selectedParticleEffect != newValue else { return }
                draft.selectedParticleEffect = newValue
                onParticleEffectChange(newValue)
            }
        )
    }

    private var particleDensityBinding: Binding<Double> {
        Binding(
            get: { draft.particleDensity },
            set: { newValue in
                guard abs(draft.particleDensity - newValue) > 0.001 else { return }
                draft.particleDensity = newValue
                onParticleDensityChange(newValue)
            }
        )
    }

    private var weatherReactiveBinding: Binding<Bool> {
        Binding(
            get: { draft.effectConfig.weatherReactive },
            set: { newValue in
                guard draft.effectConfig.weatherReactive != newValue else { return }
                draft.effectConfig.weatherReactive = newValue
                onWeatherReactiveChange(newValue)
            }
        )
    }

    @ViewBuilder
    private var wallpaperModeCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                wallpaperModePill

                Group {
                    switch draft.selectedWallpaperMode {
                    case .playlist:
                        if featureCatalog.isEnabled(.playlists) {
                            Divider()
                            PlaylistSection(
                                playlistBookmarks: $draft.playlistBookmarks,
                                shufflePlaylist: $draft.shufflePlaylist,
                                rotationMinutes: $draft.playlistRotationMinutes,
                                screen: screen,
                                screenManager: screenManager
                            )
                        }
                    case .schedule:
                        if featureCatalog.isEnabled(.scheduleAutomation) {
                            Divider()
                            ScheduleSection(
                                scheduleSlots: $draft.scheduleSlots,
                                screen: screen,
                                screenManager: screenManager
                            )
                        }
                    }
                }
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .top)),
                    removal: .opacity
                ))
            }
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }

    private var wallpaperModePill: some View {
        HStack(spacing: 0) {
            ForEach(featureCatalog.capabilities.selectableWallpaperModes) { mode in
                Button {
                    withAnimation(DesignTokens.motion(reduceMotion, .snappy(duration: 0.18))) {
                        draft.selectedWallpaperMode = mode
                    }
                    onWallpaperModeChange(mode)
                } label: {
                    Text(mode.labelKey)
                        .font(.system(size: 12, weight: draft.selectedWallpaperMode == mode ? .semibold : .regular))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(draft.selectedWallpaperMode == mode ? Color.accentColor.opacity(0.35) : Color.clear)
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(wallpaperModeAccessibilityLabel(mode))
                .accessibilityAddTraits(
                    draft.selectedWallpaperMode == mode ? .isSelected : []
                )
            }
        }
        .padding(2)
        .adaptiveGlassSurface(.capsule, interactive: true)
    }

    private func wallpaperModeAccessibilityLabel(_ mode: WallpaperMode) -> Text {
        switch mode {
        case .playlist:
            return Text("Playlist mode", comment: "A11y label for the playlist wallpaper mode tab.")
        case .schedule:
            return Text("Schedule mode", comment: "A11y label for the schedule wallpaper mode tab.")
        }
    }
}
