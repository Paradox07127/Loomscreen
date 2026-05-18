import AVFoundation
import CoreMedia
import Foundation

/// Validates and probes video assets prior to handing them to the player.
public protocol PlayableVideoLoading: Sendable {
    func validatePlayableVideo(at url: URL) async throws
    func detectFormat(at url: URL) async throws -> VideoFormatInfo
}

public struct PlayableVideoLoader: PlayableVideoLoading, Sendable {
    public init() {}

    public func validatePlayableVideo(at url: URL) async throws {
        try await Self.validatePlayableVideo(at: url)
    }

    public func detectFormat(at url: URL) async throws -> VideoFormatInfo {
        try await Self.detectFormat(at: url)
    }

    public static func validatePlayableVideo(at url: URL) async throws {
        let didStartScope = url.startAccessingSecurityScopedResource()
        defer {
            if didStartScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let asset = AVURLAsset(url: url)
        let isPlayable = try await asset.load(.isPlayable)

        guard isPlayable else {
            throw NSError(domain: "PlayableVideoLoader", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "The selected video is not playable."
            ])
        }
    }

    /// Probe codec, HDR transfer function, resolution, and frame rate from the first video track.
    public static func detectFormat(at url: URL) async throws -> VideoFormatInfo {
        let didStartScope = url.startAccessingSecurityScopedResource()
        defer {
            if didStartScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = videoTracks.first else {
            return VideoFormatInfo()
        }

        let descs = try await track.load(.formatDescriptions)
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let frameRate = try await track.load(.nominalFrameRate)

        let codec = descs.first.map { CMFormatDescriptionGetMediaSubType($0).fourCharString }
        let transfer = descs.first.flatMap { transferFunction(of: $0) }
        let isHDR = transfer.map { $0 == "PQ" || $0 == "HLG" } ?? false

        let displaySize = size.applying(transform)
        let displayResolution = CGSize(width: abs(displaySize.width), height: abs(displaySize.height))

        return VideoFormatInfo(
            codecFourCC: codec,
            isHDR: isHDR,
            resolution: displayResolution.width > 0 ? displayResolution : nil,
            frameRate: frameRate > 0 ? Double(frameRate) : nil
        )
    }

    /// Returns "PQ", "HLG", or nil for SDR / non-HDR transfer functions.
    private static func transferFunction(of description: CMFormatDescription) -> String? {
        let extensions = CMFormatDescriptionGetExtensions(description) as? [CFString: Any]
        guard let raw = extensions?[kCMFormatDescriptionExtension_TransferFunction] as? String else {
            return nil
        }
        if raw == kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String { return "PQ" }
        if raw == kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String { return "HLG" }
        return nil
    }
}

private extension FourCharCode {
    /// Convert a CoreMedia FourCharCode (e.g. 'apch') into a 4-letter Swift String.
    var fourCharString: String {
        let bytes: [UInt8] = [
            UInt8((self >> 24) & 0xff),
            UInt8((self >> 16) & 0xff),
            UInt8((self >> 8) & 0xff),
            UInt8(self & 0xff),
        ]
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? ""
    }
}
