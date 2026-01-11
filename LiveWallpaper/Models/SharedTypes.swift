import Foundation
import AVFoundation

// MARK: - Frame Rate Limit
/// Represents frame rate limitation options for video playback
enum FrameRateLimit: Int, CaseIterable, Identifiable, Codable {
    case fps30 = 30
    case fps60 = 60
    case unlimited = 0

    var id: Int { rawValue }

    var description: String {
        switch self {
        case .fps30: return "30 FPS"
        case .fps60: return "60 FPS"
        case .unlimited: return "Unlimited"
        }
    }

    var iconName: String {
        switch self {
        case .fps30: return "tortoise"
        case .fps60: return "hare"
        case .unlimited: return "infinity"
        }
    }

    /// Calculate the effective limit taking into account both the video's native frame rate and the screen refresh rate
    /// - Parameters:
    ///   - videoFrameRate: The video's native frame rate
    ///   - screenRefreshRate: The display's refresh rate
    /// - Returns: The effective frame rate limit to apply
    func getEffectiveLimit(videoFrameRate: Double, screenRefreshRate: Double) -> Float {
        // Handle unlimited case
        if self == .unlimited {
            // When unlimited is selected, respect screen refresh rate as the maximum
            // to avoid wasting GPU resources on frames that won't be visible
            if screenRefreshRate > 0 && videoFrameRate > screenRefreshRate {
                return Float(screenRefreshRate)
            }
            return 0 // No limit (will use video's native frame rate)
        }

        // Get the raw limit value
        let rawLimit = Float(self.rawValue)

        // If screen refresh rate is lower than the selected limit, cap at screen refresh rate
        if screenRefreshRate > 0 && screenRefreshRate < Double(rawLimit) {
            return Float(screenRefreshRate)
        }

        // If original frame rate is lower than the limit, no need to limit
        if videoFrameRate > 0 && videoFrameRate < Double(rawLimit) {
            return 0 // No limit needed (already below threshold)
        }

        // Apply the selected limit
        return rawLimit
    }
}

// MARK: - Video Fit Mode
/// Video fit modes for displaying video content
enum VideoFitMode: String, Codable, CaseIterable, Identifiable {
    case aspectFill = "Fill"
    case aspectFit = "Fit"
    case stretch = "Stretch"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .aspectFill: return "Fill screen (may crop video)"
        case .aspectFit: return "Fit entire video (may show borders)"
        case .stretch: return "Stretch to fill screen (may distort)"
        }
    }

    var iconName: String {
        switch self {
        case .aspectFill: return "rectangle.fill"
        case .aspectFit: return "rectangle"
        case .stretch: return "arrow.up.left.and.arrow.down.right"
        }
    }

    var avLayerVideoGravity: AVLayerVideoGravity {
        switch self {
        case .aspectFill: return .resizeAspectFill
        case .aspectFit: return .resizeAspect
        case .stretch: return .resize
        }
    }
}

// MARK: - Screen Configuration
/// Configuration for a single screen's video wallpaper
struct ScreenConfiguration: Codable, Equatable {
    let screenID: UInt32
    let videoBookmarkData: Data
    var playbackSpeed: Double
    var fitMode: VideoFitMode
    var pauseOnBattery: Bool
    var frameRateLimit: FrameRateLimit

    init(
        screenID: CGDirectDisplayID,
        videoBookmarkData: Data,
        playbackSpeed: Double = 1.0,
        fitMode: VideoFitMode = .aspectFill,
        pauseOnBattery: Bool = false,
        frameRateLimit: FrameRateLimit = .fps60
    ) {
        self.screenID = screenID
        self.videoBookmarkData = videoBookmarkData
        self.playbackSpeed = playbackSpeed
        self.fitMode = fitMode
        self.pauseOnBattery = pauseOnBattery
        self.frameRateLimit = frameRateLimit
    }

    /// Create a copy with updated bookmark data (for stale bookmark refresh)
    func withUpdatedBookmark(_ bookmarkData: Data) -> ScreenConfiguration {
        var copy = self
        copy = ScreenConfiguration(
            screenID: screenID,
            videoBookmarkData: bookmarkData,
            playbackSpeed: playbackSpeed,
            fitMode: fitMode,
            pauseOnBattery: pauseOnBattery,
            frameRateLimit: frameRateLimit
        )
        return copy
    }
}

// MARK: - Global Settings
/// Global application settings
struct GlobalSettings: Codable {
    var globalPauseOnBattery: Bool
    var preservePlaybackOnLock: Bool
    var startOnLogin: Bool
    var minimumBatteryLevel: Double?
    var defaultFrameRateLimit: FrameRateLimit

    init(
        globalPauseOnBattery: Bool = true,
        preservePlaybackOnLock: Bool = false,
        startOnLogin: Bool = false,
        minimumBatteryLevel: Double? = nil,
        defaultFrameRateLimit: FrameRateLimit = .fps60
    ) {
        self.globalPauseOnBattery = globalPauseOnBattery
        self.preservePlaybackOnLock = preservePlaybackOnLock
        self.startOnLogin = startOnLogin
        self.minimumBatteryLevel = minimumBatteryLevel
        self.defaultFrameRateLimit = defaultFrameRateLimit
    }
}
