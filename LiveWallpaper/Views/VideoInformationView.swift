import LiveWallpaperCore
import SwiftUI
import AVKit

/// Floating capsule shown on the video preview card. Surfaces "what is this
/// asset" glance information (format / resolution / FPS / file size) so the
/// user doesn't have to dig into Finder or QuickTime to identify a file.
///
/// Metadata is loaded from `AVURLAsset(url:)` rather than the live player so
/// the overlay can render across the active / poster / unloaded states —
/// playing the preview isn't a prerequisite for showing the badges.
struct VideoInformationOverlay: View {
    let videoURL: URL?
    /// Optional: present only while the preview is actively playing.
    /// Used solely as a load-trigger identity so toggling preview off and on
    /// doesn't refire a redundant metadata load for the same URL.
    let player: AVPlayer?

    @State private var videoResolution: (width: Int, height: Int)? = nil
    @State private var videoFrameRate: Double = 0
    @State private var fileSize: String = ""
    @State private var formatBadges: [VideoFormatBadge] = []

    @ViewBuilder
    var body: some View {
        if let url = videoURL {
            content
                .task(id: loadIdentity(for: url)) {
                    await loadVideoInformation(from: url)
                }
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            if !formatBadges.isEmpty {
                HStack(spacing: 4) {
                    ForEach(formatBadges, id: \.self) { badge in
                        Text(verbatim: badge.displayLabel)
                            .font(DesignTokens.Typography.badge)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.18), in: Capsule())
                    }
                }
            }
            if let res = videoResolution {
                HStack(spacing: 4) {
                    Image(systemName: "rectangle.3.group")
                    Text(verbatim: "\(res.width)×\(res.height)")
                }
            }
            if videoFrameRate > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "speedometer")
                    Text(verbatim: "\(Int(videoFrameRate)) FPS")
                }
            }
            if !fileSize.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "doc")
                    Text(verbatim: fileSize)
                }
            }
        }
        .font(DesignTokens.Typography.metric)
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.6))
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.3), radius: 5, x: 0, y: 2)
    }

    /// Identity key for `.task(id:)`.
    private func loadIdentity(for url: URL) -> String {
        url.absoluteString
    }

    @MainActor
    private func loadVideoInformation(from url: URL) async {
        resetVideoInformation()
        let didStartScope = url.startAccessingSecurityScopedResource()
        defer {
            if didStartScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        fileSize = Self.fileSizeDescription(for: url) ?? ""

        if let info = try? await PlayableVideoLoader.detectFormat(at: url) {
            guard !Task.isCancelled else { return }
            formatBadges = info.badges
        }

        do {
            let asset = AVURLAsset(url: url)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = videoTracks.first else { return }

            let naturalSize = try await track.load(.naturalSize)
            let preferredTransform = try await track.load(.preferredTransform)
            let nominalFrameRate = try await track.load(.nominalFrameRate)

            guard !Task.isCancelled else { return }
            let transformedSize = naturalSize.applying(preferredTransform)
            videoResolution = (width: abs(Int(transformedSize.width)),
                               height: abs(Int(transformedSize.height)))
            videoFrameRate = Double(nominalFrameRate)
        } catch {}
    }

    private func resetVideoInformation() {
        videoResolution = nil
        videoFrameRate = 0
        fileSize = ""
        formatBadges = []
    }

    private static func fileSizeDescription(for url: URL) -> String? {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
            return nil
        }
        return FormatUtils.formatBytes(size.int64Value)
    }
}
