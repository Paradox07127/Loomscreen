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
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: Color.black.opacity(0.15), radius: 10, x: 0, y: 4)

            VStack {
                HStack {
                    VideoInformationOverlay(player: player)
                    Spacer()
                }
                Spacer()
            }
            .padding(16)

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
            .accessibilityLabel("Video position")
            .accessibilityValue("\(FormatUtils.formatDuration(previewController.currentPosition)) of \(FormatUtils.formatDuration(previewController.duration))")
            .accessibilityHint("Scrub through the video timeline")

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
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(Color.black.opacity(0.18))

            Button(action: startPreview) {
                Label("Play Preview", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityLabel("Play preview")
            .accessibilityHint("Starts a temporary video preview for this settings panel")
        }
    }

    private var unloadedPreview: some View {
        VStack(spacing: 14) {
            Image(systemName: previewController.isLoading ? "hourglass" : "photo")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(previewController.isLoading ? "Loading preview..." : "Preview paused")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Load Preview", action: startPreview)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityLabel("Load preview")
                .accessibilityHint("Starts a temporary video preview for this settings panel")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(.separatorColor), lineWidth: 1))
    }
}
