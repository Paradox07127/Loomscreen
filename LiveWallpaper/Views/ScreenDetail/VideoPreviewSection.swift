import LiveWallpaperCore
import LiveWallpaperSharedUI
import AVKit
import SwiftUI

struct VideoPreviewSection: View {
    var previewController: InspectorPreviewController
    let hasPreviewSource: Bool
    let selectedFitMode: VideoFitMode
    let startPreview: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            if let player = previewController.player {
                activePreview(player: player)
            } else if let posterImage = previewController.posterImage {
                posterPreview(posterImage)
            } else if hasPreviewSource {
                unloadedPreview
            }

            VStack {
                HStack {
                    VideoInformationOverlay(
                        videoURL: previewController.assetURL,
                        player: previewController.player
                    )
                    Spacer()
                }
                Spacer()
            }
            .padding(16)
            .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 1) {
            if previewController.player != nil {
                previewController.togglePlayback()
            } else {
                startPreview()
            }
        }
    }

    private func activePreview(player: AVPlayer) -> some View {
        ZStack(alignment: .bottom) {
            CustomVideoPlayer(player: player, fitMode: selectedFitMode)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .screenPreviewChrome()

            playbackControls
        }
    }

    private var playbackControls: some View {
        VStack(spacing: 8) {
            Slider(
                value: Binding(
                    get: { previewController.currentPosition },
                    set: { previewController.updateScrubPosition($0) }
                ),
                in: 0...max(1, previewController.duration),
                onEditingChanged: { editing in
                    if !editing {
                        previewController.seekToCurrentPosition()
                    }
                }
            )
            .padding(.horizontal, 24)
            .controlSize(.small)
            .accessibilityLabel(Text("Video position"))
            .accessibilityValue(Text("\(FormatUtils.formatDuration(previewController.currentPosition)) of \(FormatUtils.formatDuration(previewController.duration))"))
            .accessibilityHint(Text("Scrub through the video timeline"))

            HStack {
                Text(FormatUtils.formatDuration(previewController.currentPosition))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)

                Spacer()

                PlaybackToggleButton(isPlaying: previewController.isPlaying) {
                    previewController.togglePlayback()
                }
                .foregroundStyle(.white)

                Spacer()

                Text(FormatUtils.formatDuration(previewController.duration))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 16)
        }
        .padding(.vertical, 12)
        .background(
            LinearGradient(
                gradient: Gradient(colors: [Color.black.opacity(0), Color.black.opacity(0.8)]),
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16))
    }

    private func posterPreview(_ posterImage: NSImage) -> some View {
        ZStack {
            Image(nsImage: posterImage)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(Color.black.opacity(0.18))

            Button(action: startPreview) {
                Label("Play Preview", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityLabel(Text("Play preview"))
            .accessibilityHint(Text("Starts a temporary video preview for this settings panel"))
        }
        .screenPreviewChrome(shadow: false)
    }

    @ViewBuilder
    private var unloadedPreview: some View {
        let errorMessage = previewController.lastError.map(PIISanitizer.scrub)
        VStack(spacing: 14) {
            Image(systemName: errorMessage == nil ? (previewController.isLoading ? "hourglass" : "photo") : "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(errorMessage == nil ? Color.secondary : Color.orange)
            Text(errorMessage ?? (previewController.isLoading ? "Loading preview..." : "Preview paused"))
                .font(.subheadline)
                .foregroundStyle(errorMessage == nil ? Color.secondary : Color.primary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Button(errorMessage == nil ? "Load Preview" : "Retry Preview", action: startPreview)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityLabel(Text(errorMessage == nil ? "Load preview" : "Retry preview"))
                .accessibilityHint(Text("Starts a temporary video preview for this settings panel"))
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
        .screenPreviewChrome(stroke: true, shadow: false)
    }
}
