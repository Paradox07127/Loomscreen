import AppKit
@preconcurrency import AVFoundation
import Foundation
@testable import LiveWallpaper
import Testing

@MainActor
@Suite("Video resolution characterization baselines", .serialized)
struct VideoResolutionContractCharacterizationTests {
    @Test("A local item stores the HLS-only resolution preference without proving a decoder cap")
    func localItemStoresResolutionPreferenceAsConfigurationOnly() {
        let asset = AVURLAsset(
            url: URL(fileURLWithPath: "/tmp/rr13-local-resolution-contract.mov")
        )
        let item = AVPlayerItem(asset: asset)
        let requestedResolution = CGSize(width: 1920, height: 1080)

        item.preferredMaximumResolution = requestedResolution

        #expect(asset.url.isFileURL)
        #expect(item.preferredMaximumResolution == requestedResolution)
    }

    @Test("Current local-only player contains no HLS-only resolution preference path")
    func currentLocalPlayerHasNoHLSResolutionPreferencePath() throws {
        let source = try RepositoryRoot.source(
            "LiveWallpaper/VideoPlayback/WallpaperVideoPlayer.swift"
        )

        #expect(!source.contains("preferredMaximumResolution"))
        #expect(!source.contains("applyResolutionCap"))
        #expect(!source.contains("attachedScreen"))
    }

    @Test("Current local measurement baseline uses AVPlayerLayer and source-sized compositions")
    func localPresentationAndCompositionSizingBaseline() throws {
        let playerSource = try RepositoryRoot.source(
            "LiveWallpaper/VideoPlayback/WallpaperVideoPlayer.swift"
        )
        let frameRatePolicy = try Self.slice(
            playerSource,
            from: "func setFrameRateLimit(",
            to: "private func observeInitialCurrentItemForDeferredFrameRateLimit"
        )
        let compactFrameRatePolicy = Self.compact(frameRatePolicy)

        #expect(compactFrameRatePolicy.contains("videoTrack.load(.naturalSize)"))
        #expect(compactFrameRatePolicy.contains("videoTrack.load(.preferredTransform)"))
        #expect(compactFrameRatePolicy.contains("let displayed = naturalSize.applying(transform)"))
        #expect(
            compactFrameRatePolicy.contains(
                "let renderSize = CGSize(width: abs(displayed.width), height: abs(displayed.height))"
            )
        )
        #expect(compactFrameRatePolicy.contains("compositionConfig.renderSize = renderSize"))
        #expect(compactFrameRatePolicy.contains("mutableComposition.renderSize = renderSize"))
        #expect(!frameRatePolicy.contains("attachedScreen"))
        #expect(!frameRatePolicy.contains("preferredMaximumResolution"))

        let containerSource = try RepositoryRoot.source(
            "LiveWallpaper/VideoPlayback/VideoContainerView.swift"
        )
        let playerHost = try Self.slice(
            containerSource,
            from: "final class PlayerHostView: NSView",
            to: "// MARK: - VideoContainerView"
        )
        let compactPlayerHost = Self.compact(playerHost)

        #expect(compactPlayerHost.contains("let layer = AVPlayerLayer()"))
        #expect(compactPlayerHost.contains("playerLayer?.videoGravity = gravity"))
        #expect(compactPlayerHost.contains("playerLayer?.frame = bounds"))
        #expect(
            compactPlayerHost.contains(
                "if let scale = window?.backingScaleFactor { playerLayer?.contentsScale = scale }"
            )
        )
    }

    @Test("Current WPE measurement baseline mirrors decoder pixel-buffer dimensions")
    func wpeOutputSizingBaseline() throws {
        let source = try RepositoryRoot.source(
            "LiveWallpaper/Runtime/Assets/WPEVideoTextureSource.swift"
        )
        let itemOutputSettings = try Self.slice(
            source,
            from: "private static let outputPixelBufferAttributes",
            to: "private static let resourceLoaderQueue"
        )
        let playerOutputSettings = try Self.slice(
            source,
            from: "let outputSettings:",
            to: "specification.defaultOutputSettings"
        )
        let publishPath = try Self.slice(
            source,
            from: "private func publish(pixelBuffer:",
            to: "private static let bufferHintSeconds"
        )

        for settings in [itemOutputSettings, playerOutputSettings] {
            #expect(settings.contains("kCVPixelBufferPixelFormatTypeKey"))
            #expect(settings.contains("kCVPixelBufferMetalCompatibilityKey"))
            #expect(settings.contains("kCVPixelBufferIOSurfacePropertiesKey"))
            #expect(!settings.contains("kCVPixelBufferWidthKey"))
            #expect(!settings.contains("kCVPixelBufferHeightKey"))
        }

        let compactPublishPath = Self.compact(publishPath)
        #expect(compactPublishPath.contains("let width = CVPixelBufferGetWidth(pixelBuffer)"))
        #expect(compactPublishPath.contains("let height = CVPixelBufferGetHeight(pixelBuffer)"))
        #expect(compactPublishPath.contains(".bgra8Unorm_srgb, width, height, 0"))
        #expect(compactPublishPath.contains(".bgra8Unorm, width, height, 0"))
    }

    private enum SourceContractError: Error {
        case missingBoundary(String)
    }

    private static func slice(
        _ source: String,
        from startMarker: String,
        to endMarker: String
    ) throws -> String {
        guard let start = source.range(of: startMarker)?.lowerBound else {
            throw SourceContractError.missingBoundary(startMarker)
        }
        guard let end = source.range(of: endMarker, range: start ..< source.endIndex)?.lowerBound else {
            throw SourceContractError.missingBoundary(endMarker)
        }
        return String(source[start ..< end])
    }

    private static func compact(_ source: String) -> String {
        source.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
    }
}
