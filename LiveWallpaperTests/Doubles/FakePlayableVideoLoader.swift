import Foundation
@testable import LiveWallpaper

enum FakePlayableVideoLoaderError: Error, Equatable, Sendable {
    case validationFailed
    case formatFailed
}

actor FakePlayableVideoLoader: PlayableVideoLoading {
    private(set) var validatedURLs: [URL] = []
    private(set) var completedValidationCount = 0
    private(set) var detectedURLs: [URL] = []
    private let validationError: FakePlayableVideoLoaderError?
    private let formatError: FakePlayableVideoLoaderError?
    private let formatInfo: VideoFormatInfo
    private let suspendsValidation: Bool
    private var validationContinuations: [CheckedContinuation<Void, Never>] = []

    init(
        validationError: FakePlayableVideoLoaderError? = nil,
        formatError: FakePlayableVideoLoaderError? = nil,
        formatInfo: VideoFormatInfo = VideoFormatInfo(),
        suspendsValidation: Bool = false
    ) {
        self.validationError = validationError
        self.formatError = formatError
        self.formatInfo = formatInfo
        self.suspendsValidation = suspendsValidation
    }

    func validatePlayableVideo(at url: URL) async throws {
        validatedURLs.append(url)
        if suspendsValidation {
            await withCheckedContinuation { continuation in
                validationContinuations.append(continuation)
            }
        }
        try Task.checkCancellation()
        completedValidationCount += 1
        if let validationError {
            throw validationError
        }
    }

    var pendingValidationCount: Int { validationContinuations.count }

    func resumeAllValidations() {
        let pending = validationContinuations
        validationContinuations.removeAll()
        pending.forEach { $0.resume() }
    }

    func detectFormat(at url: URL) async throws -> VideoFormatInfo {
        detectedURLs.append(url)
        if let formatError {
            throw formatError
        }
        return formatInfo
    }
}
