import AVFoundation
import AppKit
import CoreGraphics

@MainActor
enum DesktopPictureFrameExtractor {
    static func applyCurrentFrame(
        from player: AVPlayer,
        screenID: CGDirectDisplayID,
        nsScreen: NSScreen?
    ) {
        guard let currentItem = player.currentItem else { return }

        let imageGenerator = AVAssetImageGenerator(asset: currentItem.asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.requestedTimeToleranceBefore = .zero
        imageGenerator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

        let currentTime = player.currentTime()
        nonisolated(unsafe) let generator = imageGenerator

        Task {
            do {
                let (cgImage, _) = try await generator.image(at: currentTime)
                let nsImage = NSImage(
                    cgImage: cgImage,
                    size: NSSize(width: cgImage.width, height: cgImage.height)
                )

                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("LiveWallpaper_LockScreen_\(screenID).png")

                guard let tiffData = nsImage.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiffData),
                      let pngData = bitmap.representation(using: .png, properties: [:]) else {
                    return
                }

                try pngData.write(to: tempURL)

                await MainActor.run {
                    guard let nsScreen else { return }

                    do {
                        try NSWorkspace.shared.setDesktopImageURL(tempURL, for: nsScreen, options: [:])
                        Logger.info("Updated desktop picture for screen \(screenID)", category: .screenManager)
                    } catch {
                        Logger.error("Failed to set desktop picture: \(error.localizedDescription)", category: .screenManager)
                    }
                }
            } catch {
                await MainActor.run {
                    Logger.error("Failed to extract desktop picture frame: \(error.localizedDescription)", category: .screenManager)
                }
            }
        }
    }
}
