import Foundation

/// Validates and probes video assets prior to handing them to the player.
protocol PlayableVideoLoading: Sendable {
    func validatePlayableVideo(at url: URL) async throws
    func detectFormat(at url: URL) async throws -> VideoFormatInfo
}
