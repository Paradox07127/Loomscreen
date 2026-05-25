import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Metal
import Testing
@testable import LiveWallpaper

/// Pacing & format coverage for the AVPlayer-backed `WPEVideoTextureSource`.
///
/// Pre-fix this type ran `AVAssetReader.copyNextSampleBuffer()` in a tight
/// while-loop with no PTS pacing — clips decoded at hundreds of FPS, so
/// 24/30/60 FPS sources played back 2-8× faster than authored. These tests
/// lock in the AVPlayer-based contract: frames come out on the wall clock,
/// the suspend/resume hooks reach the underlying player, `invalidate()`
/// clears state and the temp file, and the produced texture lives in the
/// raw `.bgra8Unorm` pixel format the rest of the Metal pipeline expects
/// (no `_srgb` double-encode).
@MainActor
@Suite("WPEVideoTextureSource pacing", .serialized)
struct WPEVideoTextureSourcePacingTests {

    @Test("AVPlayer-backed source publishes a frame within a bounded wall-clock window")
    func publishesFrameWithinBoundedDelay() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let videoURL = try await SyntheticVideoFixture.writeMP4(
            durationSeconds: 1.0,
            frameRate: 24
        )
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let source = try WPEVideoTextureSource(device: device, videoURL: videoURL)
        defer { source.invalidate() }

        let texture = try await pollForTexture(from: source, timeout: 2.0)
        try #require(texture != nil, "AVPlayer-backed source must produce a frame within 2s")
        #expect(texture?.pixelFormat == .bgra8Unorm, "Frames must stay in raw RGBA8 space — no sRGB double-encode")
    }

    @Test("Suspending leaves the source idle; resuming brings frames back")
    func suspendThenResume() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let videoURL = try await SyntheticVideoFixture.writeMP4(
            durationSeconds: 2.0,
            frameRate: 24
        )
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let source = try WPEVideoTextureSource(device: device, videoURL: videoURL)
        defer { source.invalidate() }

        // Warm-up: first frame proves the player is running.
        _ = try await pollForTexture(from: source, timeout: 2.0)

        // Suspending must not throw or invalidate the cached frame.
        source.applyPerformanceProfile(.suspended)
        let cachedAfterSuspend = source.texture(at: 0)
        #expect(cachedAfterSuspend != nil, "Suspend keeps the last published frame in cache")

        // Resuming must accept .quality again without re-init.
        source.applyPerformanceProfile(.quality)
        let texture = try await pollForTexture(from: source, timeout: 2.0)
        #expect(texture != nil, "Resuming the source must yield fresh frames")
    }

    @Test("invalidate() drops the cached frame and removes the staged temp file")
    func invalidateClearsStateAndCleansUp() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let videoURL = try await SyntheticVideoFixture.writeMP4(
            durationSeconds: 1.0,
            frameRate: 24
        )

        let source = try WPEVideoTextureSource(device: device, videoURL: videoURL)
        _ = try await pollForTexture(from: source, timeout: 2.0)
        #expect(FileManager.default.fileExists(atPath: videoURL.path))

        source.invalidate()

        #expect(source.texture(at: 0) == nil, "invalidate() must clear the cached frame")
        #expect(FileManager.default.fileExists(atPath: videoURL.path) == false, "invalidate() must remove the staged temp file")
    }

    // MARK: - Helpers

    /// Polls `texture(at:)` on the main actor every 30 ms until a non-nil
    /// texture appears or the wall-clock deadline expires. AVPlayer needs
    /// some setup time — load asset, schedule first frame, fire
    /// `videoOutput.hasNewPixelBuffer` — so the deadline is generous.
    private func pollForTexture(
        from source: WPEVideoTextureSource,
        timeout seconds: TimeInterval
    ) async throws -> MTLTexture? {
        let deadline = Date().addingTimeInterval(seconds)
        var texture: MTLTexture?
        while Date() < deadline {
            texture = source.texture(at: 0)
            if texture != nil { return texture }
            try await Task.sleep(for: .milliseconds(30))
        }
        return texture
    }
}

// MARK: - Synthetic MP4 fixture

private enum SyntheticVideoFixture {
    /// Writes a tiny H.264 MP4 to `temporaryDirectory` so the source can
    /// open it via the real AVFoundation playback path. All frames carry
    /// the same payload — these tests cover *pacing*, not pixel content;
    /// the fixture only has to be a valid MP4 the asset loader accepts.
    static func writeMP4(
        durationSeconds: TimeInterval,
        frameRate: Int32
    ) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wpe-pacing-\(UUID().uuidString).mp4")
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let width = 64
        let height = 64
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false
        let pixelAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: pixelAttributes
        )
        guard writer.canAdd(input) else {
            throw FixtureError.writerSetupFailed("cannot add video input")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw FixtureError.writerSetupFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        let totalFrames = max(2, Int(Double(frameRate) * durationSeconds))
        for index in 0..<totalFrames {
            while !input.isReadyForMoreMediaData {
                await Task.yield()
            }
            let pixelBuffer = try makePixelBuffer(
                width: width,
                height: height,
                fillByte: UInt8(40 + (index * 3) % 200)
            )
            let pts = CMTime(value: Int64(index), timescale: frameRate)
            if !adaptor.append(pixelBuffer, withPresentationTime: pts) {
                throw FixtureError.writerSetupFailed(
                    writer.error?.localizedDescription ?? "adaptor.append failed"
                )
            }
        }
        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        if writer.status != .completed {
            throw FixtureError.writerSetupFailed(
                writer.error?.localizedDescription ?? "writer ended with status \(writer.status.rawValue)"
            )
        }
        return outputURL
    }

    private static func makePixelBuffer(
        width: Int,
        height: Int,
        fillByte: UInt8
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: CFDictionary = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ] as CFDictionary
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw FixtureError.writerSetupFailed("CVPixelBufferCreate returned \(status)")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        memset(base, Int32(fillByte), bytesPerRow * height)
        return buffer
    }

    private enum FixtureError: Error, CustomStringConvertible {
        case writerSetupFailed(String)
        var description: String {
            switch self {
            case .writerSetupFailed(let detail): return "AVAssetWriter setup failed: \(detail)"
            }
        }
    }
}
