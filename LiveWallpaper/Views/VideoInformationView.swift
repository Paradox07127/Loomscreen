import SwiftUI
import AVKit

struct VideoInformationOverlay: View {
    let player: AVPlayer

    @State private var videoResolution: (width: Int, height: Int)? = nil
    @State private var videoFrameRate: Double = 0
    @State private var fileSize: String = ""
    @State private var formatBadges: [String] = []

    var body: some View {
        HStack(spacing: 12) {
            if !formatBadges.isEmpty {
                HStack(spacing: 4) {
                    ForEach(formatBadges, id: \.self) { badge in
                        Text(verbatim: badge)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
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
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.6))
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.3), radius: 5, x: 0, y: 2)
        .task(id: currentItemID) {
            await loadVideoInformation()
        }
    }

    private var currentItemID: ObjectIdentifier? {
        guard let item = player.currentItem else { return nil }
        return ObjectIdentifier(item)
    }

    @MainActor
    private func loadVideoInformation() async {
        resetVideoInformation()
        guard let playerItem = player.currentItem else { return }

        if let urlAsset = playerItem.asset as? AVURLAsset {
            fileSize = Self.fileSizeDescription(for: urlAsset.url) ?? ""

            if let info = try? await PlayableVideoLoader.detectFormat(at: urlAsset.url) {
                guard !Task.isCancelled else { return }
                formatBadges = info.badges
            }
        }

        do {
            let videoTracks = try await playerItem.asset.loadTracks(withMediaType: .video)
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
