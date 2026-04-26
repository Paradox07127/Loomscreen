import AVFoundation
import Foundation

enum PlayableVideoLoader {
    static func validatePlayableVideo(at url: URL) async throws {
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
}
