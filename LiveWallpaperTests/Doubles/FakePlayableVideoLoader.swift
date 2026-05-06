import Foundation
@testable import LiveWallpaper

enum FakePlayableVideoLoaderError: Error, Equatable, Sendable {
    case validationFailed
    case formatFailed
}

actor FakePlayableVideoLoader: PlayableVideoLoading {
    private(set) var validatedURLs: [URL] = []
    private(set) var detectedURLs: [URL] = []
    private let validationError: FakePlayableVideoLoaderError?
    private let formatError: FakePlayableVideoLoaderError?
    private let formatInfo: VideoFormatInfo

    init(
        validationError: FakePlayableVideoLoaderError? = nil,
        formatError: FakePlayableVideoLoaderError? = nil,
        formatInfo: VideoFormatInfo = VideoFormatInfo()
    ) {
        self.validationError = validationError
        self.formatError = formatError
        self.formatInfo = formatInfo
    }

    func validatePlayableVideo(at url: URL) async throws {
        validatedURLs.append(url)
        if let validationError {
            throw validationError
        }
    }

    func detectFormat(at url: URL) async throws -> VideoFormatInfo {
        detectedURLs.append(url)
        if let formatError {
            throw formatError
        }
        return formatInfo
    }
}
