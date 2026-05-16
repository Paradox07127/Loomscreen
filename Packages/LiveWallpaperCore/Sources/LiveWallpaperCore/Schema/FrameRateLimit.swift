import SwiftUI

public enum FrameRateLimit: Int, CaseIterable, Identifiable, Codable, Sendable {
    case fps30 = 30
    case fps60 = 60
    case unlimited = 0

    public var id: Int { rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(Int.self)
        self = FrameRateLimit(rawValue: rawValue) ?? .fps60
    }

    public var titleKey: LocalizedStringKey {
        switch self {
        case .fps30: return "30 FPS"
        case .fps60: return "60 FPS"
        case .unlimited: return "Unlimited"
        }
    }

    public var iconName: String {
        switch self {
        case .fps30: return "tortoise"
        case .fps60: return "hare"
        case .unlimited: return "infinity"
        }
    }

    public func getEffectiveLimit(videoFrameRate: Double, screenRefreshRate: Double) -> Float {
        if self == .unlimited {
            if screenRefreshRate > 0 && videoFrameRate > screenRefreshRate {
                return Float(screenRefreshRate)
            }
            return 0
        }
        let rawLimit = Float(self.rawValue)
        if screenRefreshRate > 0 && screenRefreshRate < Double(rawLimit) {
            return Float(screenRefreshRate)
        }
        if videoFrameRate > 0 && videoFrameRate < Double(rawLimit) {
            return 0
        }
        return rawLimit
    }

    public static func resolveCompositionFPS(
        limit: FrameRateLimit,
        videoFrameRate: Double,
        screenRefreshRate: Double
    ) -> Double {
        let effectiveLimit = limit.getEffectiveLimit(
            videoFrameRate: videoFrameRate,
            screenRefreshRate: screenRefreshRate
        )
        if effectiveLimit > 0 {
            return Double(effectiveLimit)
        }
        if videoFrameRate > 0 {
            return videoFrameRate
        }
        if screenRefreshRate > 0 {
            return screenRefreshRate
        }
        return Double(limit == .unlimited ? 60 : limit.rawValue)
    }
}

public enum PlainVideoFrameRateCompositionPolicy {
    public static func compositionLimit(
        frameRateLimit: FrameRateLimit,
        videoFrameRate: Double,
        screenRefreshRate: Double
    ) -> Float? {
        guard frameRateLimit == .fps30 else { return nil }

        let limit = frameRateLimit.getEffectiveLimit(
            videoFrameRate: videoFrameRate,
            screenRefreshRate: screenRefreshRate
        )
        guard limit > 0, videoFrameRate > Double(limit) else { return nil }
        return limit
    }
}
