import LiveWallpaperCore
import LiveWallpaperSharedUI
import SwiftUI

struct ScreenDetailPreviewArea: View {
    let screen: Screen
    @Binding var draft: ScreenDetailDraftState
    let featureCatalog: FeatureCatalog
    let previewController: InspectorPreviewController
    let wpeOrigin: WPEOrigin?
    let isLoading: Bool
    let isDraggingOver: Bool
    let reduceMotion: Bool
    let showsGuideEmptyState: Bool
    let onChooseVideo: () -> Void
    let onChooseHTML: () -> Void
    let onChooseShader: () -> Void
    let onChooseScene: () -> Void
    let onSelectVideoFile: () -> Void
    let onStartPreview: () -> Void
    let onPlaybackSpeedChange: (Double) -> Void
    let onFitModeChange: (VideoFitMode) -> Void

    var body: some View {
        ZStack {
            DesignTokens.Colors.pageBackground

            if showsGuideEmptyState {
                EmptyStateGuideView(
                    onChooseVideo: onChooseVideo,
                    onChooseHTML: onChooseHTML,
                    onChooseShader: onChooseShader,
                    onChooseScene: onChooseScene
                )
            } else if draft.selectedWallpaperType == .video {
                videoContent
            } else if draft.selectedWallpaperType == .html {
                htmlContent
            } else if draft.selectedWallpaperType == .metalShader,
                      featureCatalog.isEnabled(.metalShader) {
                #if !LITE_BUILD
                ShaderWallpaperSection(screen: screen, selectedShaderPreset: $draft.selectedShaderPreset)
                    .padding(24)
                #else
                EmptyView()
                #endif
            } else if draft.selectedWallpaperType == .scene,
                      featureCatalog.isEnabled(.scene) {
                #if !LITE_BUILD
                WPESceneSection(screen: screen)
                #else
                EmptyView()
                #endif
            }
        }
        .frame(minWidth: DesignTokens.PreviewArea.minWidth, maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(1)
        .overlay {
            dragHintOverlay
                .animation(DesignTokens.motion(reduceMotion, .smooth(duration: 0.2)), value: isDraggingOver)
        }
    }

    @ViewBuilder
    private var videoContent: some View {
        if isLoading {
            ScreenDetailLoadingView()
        } else if draft.hasPreviewSource || previewController.hasPreviewContent {
            VStack(spacing: 16) {
                wpeOriginBadge

                if featureCatalog.isEnabled(.inspectorPreview) {
                    VideoPreviewSection(
                        previewController: previewController,
                        hasPreviewSource: draft.hasPreviewSource,
                        selectedFitMode: draft.selectedFitMode,
                        startPreview: onStartPreview
                    )
                    .aspectRatio(16/9, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .shadow(color: Color.black.opacity(0.18), radius: 12, x: 0, y: 4)
                }

                videoCommandBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        } else {
            IllustratedEmptyState(
                symbol: "film",
                title: "No Video Selected",
                message: "Video file (.mp4, .mov, …)",
                symbolColor: .accentColor,
                primary: .init("Select Video File", action: onSelectVideoFile),
                variant: .dropTarget
            )
            .padding(24)
        }
    }

    private var htmlContent: some View {
        VStack(spacing: 16) {
            wpeOriginBadge

            if featureCatalog.isEnabled(.inspectorPreview), draft.htmlSource != nil {
                HTMLPreviewSection(source: draft.htmlSource, config: draft.htmlConfig)
            }
            HTMLSourceSection(
                screen: screen,
                source: $draft.htmlSource,
                config: $draft.htmlConfig
            )
        }
        .padding(24)
    }

    @ViewBuilder
    private var wpeOriginBadge: some View {
        #if !LITE_BUILD
        if let origin = wpeOrigin, featureCatalog.isEnabled(.wpeImport) {
            WPEOriginBadge(origin: origin) {
                draft.selectedWallpaperType = .scene
            }
        }
        #endif
    }

    private var videoCommandBar: some View {
        AdaptiveGlassContainer(spacing: 14) {
            HStack(spacing: 14) {
                Spacer(minLength: 0)
                fitModeGroup
                Divider().frame(height: 30)
                speedSlider
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .adaptiveGlassSurface(.capsule)
        }
    }

    private var fitModeGroup: some View {
        HStack(spacing: 6) {
            ForEach(VideoFitMode.allCases) { mode in
                fitModeButton(mode)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Video fit mode"))
    }

    private func fitModeButton(_ mode: VideoFitMode) -> some View {
        let isSelected = draft.selectedFitMode == mode
        return Button {
            guard draft.selectedFitMode != mode else { return }
            draft.selectedFitMode = mode
            onFitModeChange(mode)
        } label: {
            VStack(spacing: 2) {
                Image(systemName: mode.iconName)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 28, height: 18)
                Text(mode.titleKey)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
            }
            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(mode.tooltipKey))
        .accessibilityLabel(Text(mode.titleKey))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var speedSlider: some View {
        HStack(spacing: 8) {
            Image(systemName: "tortoise.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Slider(value: speedBinding, in: 0.5...2.0, step: 0.25)
                .controlSize(.small)
                .frame(width: 110)
                .accessibilityLabel(Text("Playback speed"))
                .accessibilityValue(Text(speedAccessibilityValue))
            Image(systemName: "hare.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(speedDisplayLabel)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
        }
        .help(Text("Playback speed"))
    }

    private var speedBinding: Binding<Double> {
        Binding(
            get: { draft.playbackSpeed },
            set: { newValue in
                guard abs(draft.playbackSpeed - newValue) > 0.001 else { return }
                draft.playbackSpeed = newValue
                onPlaybackSpeedChange(newValue)
            }
        )
    }

    private var speedDisplayLabel: String {
        let speed = draft.playbackSpeed
        if abs(speed - speed.rounded()) < 0.001 {
            return "\(Int(speed))×"
        }
        return String(format: "%.2g×", speed)
    }

    private var speedAccessibilityValue: String {
        String(format: "%.2g×", draft.playbackSpeed)
    }

    @ViewBuilder
    private var dragHintOverlay: some View {
        if isDraggingOver {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.accentColor.opacity(0.08))
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 1.5)
                VStack(spacing: 10) {
                    Group {
                        if reduceMotion {
                            Image(systemName: "arrow.down.doc.fill")
                        } else if #available(macOS 15.0, *) {
                            Image(systemName: "arrow.down.doc.fill")
                                .symbolEffect(.bounce, options: .repeat(.continuous))
                        } else {
                            Image(systemName: "arrow.down.doc.fill")
                                .symbolEffect(.pulse, options: .continuouslyRepeating)
                        }
                    }
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    Text("Drop to use as wallpaper")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(dragHintSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .transition(.opacity)
            .allowsHitTesting(false)
        }
    }

    private var dragHintSubtitle: LocalizedStringKey {
        switch draft.selectedWallpaperType {
        case .video:        return "Video file (.mp4, .mov, …)"
        case .html:         return "HTML file or folder"
        case .metalShader:  return "Switch to Video or HTML to drop"
        case .scene:        return "Switch to Video or HTML to drop"
        }
    }
}
