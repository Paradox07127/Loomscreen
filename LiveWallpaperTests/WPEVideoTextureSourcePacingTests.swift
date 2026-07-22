import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Metal
import Testing
@testable import LiveWallpaper

@MainActor
@Suite("WPEVideoTextureSource pacing", .serialized)
struct WPEVideoTextureSourcePacingTests {

    @Test("Stays paused until applyPerformanceProfile(.quality) — no auto-start in init")
    func staysPausedUntilProfileApplied() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let videoURL = try await SyntheticVideoFixture.writeMP4(
            durationSeconds: 1.0,
            frameRate: 24
        )
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let source = try WPEVideoTextureSource(device: device, videoURL: videoURL)
        defer { source.invalidate() }

        try await Task.sleep(for: .milliseconds(300))
        #expect(source.currentItemPlaybackSeconds == 0, "Source must not auto-start in init — renderer drives play/pause via applyPerformanceProfile")
    }

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
        source.applyPerformanceProfile(.quality)

        let texture = try await pollForTexture(from: source, timeout: 2.0)
        try #require(texture != nil, "AVPlayer-backed source must produce a frame within 2s")
        let format = try #require(texture?.pixelFormat)
        #expect(format == .bgra8Unorm_srgb || format == .bgra8Unorm,
                "Frames are BGRA8; the sRGB variant is preferred to match the pipeline's output attachment")
    }

    @Test("Playhead advances on the wall clock — not faster (the old AVAssetReader bug)")
    func playheadAdvancesAtRealTime() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let videoURL = try await SyntheticVideoFixture.writeMP4(
            durationSeconds: 4.0,
            frameRate: 24
        )
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let source = try WPEVideoTextureSource(device: device, videoURL: videoURL)
        defer { source.invalidate() }
        source.applyPerformanceProfile(.quality)

        try #require(try await pollForTexture(from: source, timeout: 2.0) != nil)
        let startSeconds = source.currentItemPlaybackSeconds

        let measurementWindow: TimeInterval = 0.6
        try await Task.sleep(for: .milliseconds(Int(measurementWindow * 1_000)))

        let endSeconds = source.currentItemPlaybackSeconds
        let advanced = endSeconds - startSeconds

        #expect(advanced <= measurementWindow * 2.0,
                "Playhead advanced \(advanced)s over \(measurementWindow)s wall-clock — AVPlayer pacing regression?")
        #expect(advanced >= 0.05,
                "Playhead did not advance at all (\(advanced)s) — player is stuck/paused")
    }

    @Test("Suspending freezes the playhead; resuming starts it again")
    func suspendFreezesPlayhead() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let videoURL = try await SyntheticVideoFixture.writeMP4(
            durationSeconds: 2.0,
            frameRate: 24
        )
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let source = try WPEVideoTextureSource(device: device, videoURL: videoURL)
        defer { source.invalidate() }
        source.applyPerformanceProfile(.quality)

        _ = try await pollForTexture(from: source, timeout: 2.0)
        source.applyPerformanceProfile(.suspended)
        let pausedAt = source.currentItemPlaybackSeconds

        try await Task.sleep(for: .milliseconds(300))
        let stillPausedAt = source.currentItemPlaybackSeconds
        #expect(abs(stillPausedAt - pausedAt) < 0.05,
                "Suspend must freeze the playhead (was \(pausedAt)s, now \(stillPausedAt)s)")
        #expect(source.texture(at: 0) != nil, "Cached frame must survive suspend")

        source.applyPerformanceProfile(.quality)
        try await Task.sleep(for: .milliseconds(300))
        let resumedAt = source.currentItemPlaybackSeconds
        #expect(resumedAt > pausedAt,
                "Resume must advance the playhead past the suspend point (paused at \(pausedAt)s, now at \(resumedAt)s)")
    }

    @Test("invalidate() drops the cached frame and removes the staged temp file")
    func invalidateClearsStateAndCleansUp() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let videoURL = try await SyntheticVideoFixture.writeMP4(
            durationSeconds: 1.0,
            frameRate: 24
        )
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let source = try WPEVideoTextureSource(device: device, videoURL: videoURL)
        source.applyPerformanceProfile(.quality)
        _ = try await pollForTexture(from: source, timeout: 2.0)
        #expect(FileManager.default.fileExists(atPath: videoURL.path))

        source.invalidate()

        #expect(source.texture(at: 0) == nil, "invalidate() must clear the cached frame")
        #expect(FileManager.default.fileExists(atPath: videoURL.path) == false, "invalidate() must remove the staged temp file")
    }

    @Test("invalidate() is idempotent — second call is a no-op")
    func invalidateIsIdempotent() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let videoURL = try await SyntheticVideoFixture.writeMP4(
            durationSeconds: 1.0,
            frameRate: 24
        )
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let source = try WPEVideoTextureSource(device: device, videoURL: videoURL)
        source.invalidate()
        source.invalidate()
        source.applyPerformanceProfile(.quality)
        #expect(source.texture(at: 0) == nil)
    }

    @Test("Script control plays the clip once and freezes — does not keep looping")
    func scriptControlPlaysOnceAndHolds() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let videoURL = try await SyntheticVideoFixture.writeMP4(durationSeconds: 1.0, frameRate: 24)
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let source = try WPEVideoTextureSource(device: device, videoURL: videoURL)
        defer { source.invalidate() }

        func pump(_ seconds: TimeInterval) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                _ = source.texture(at: 0)
                try await Task.sleep(for: .milliseconds(16))
            }
        }

        source.scriptPlay()
        try await pump(2.0)
        let frozenAt = source.currentItemPlaybackSeconds
        try await pump(0.6)
        let stillFrozenAt = source.currentItemPlaybackSeconds

        #expect(abs(stillFrozenAt - frozenAt) < 0.05,
                "Script-controlled source must freeze after one play, not keep looping")
        #expect(source.texture(at: 0) != nil, "A frame must still be shown while frozen")
    }

    // MARK: - Helpers

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
