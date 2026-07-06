import SwiftUI

public enum FrameRateLimit: Int, CaseIterable, Identifiable, Codable, Sendable {
    case fps15 = 15
    case fps24 = 24
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
        case .fps15: return "15 FPS"
        case .fps24: return "24 FPS"
        case .fps30: return "30 FPS"
        case .fps60: return "60 FPS"
        case .unlimited: return "Unlimited"
        }
    }

    public var iconName: String {
        switch self {
        case .fps15: return "leaf.fill"
        case .fps24: return "film"
        case .fps30: return "tortoise"
        case .fps60: return "hare"
        case .unlimited: return "infinity"
        }
    }

    /// Whether this limit is worth forcing a compositing pipeline for plain
    /// (effect-free) playback. Decoding cost is unaffected by frame rate, so
    /// strapping `AVVideoComposition` onto AVPlayer adds a render pass without
    /// reducing decode load. Only caps that meaningfully shrink the per-frame
    /// compositing budget (≤30 fps) pay back that overhead; `fps60` and
    /// `unlimited` stay on the native pass-through path on plain video. (When
    /// effects are active the composition is already mandatory — frame rate
    /// caps cooperate via `VideoEffectsApplicationService` regardless.)
    public var enforcesCompositionCap: Bool {
        switch self {
        case .fps15, .fps24, .fps30: return true
        case .fps60, .unlimited:     return false
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

extension FrameRateLimit {
    /// Initial FPS seed for a brand-new `ScreenConfiguration`. User-set
    /// values always win; saved configs keep their previous value.
    ///
    /// - `.scene` → 30: matches WPE authoring convention (Almamu reference
    ///   + Windows "Balanced" preset). Running at 60 doubles `g_Time`-driven
    ///   motion.
    /// - `.video`/`.html`/`.metalShader` → 60: native pass-through avoids
    ///   forcing an `AVVideoComposition` recompose (see `enforcesCompositionCap`).
    public static func naturalDefault(for wallpaperType: WallpaperType) -> FrameRateLimit {
        switch wallpaperType {
        case .scene:                                 return .fps30
        case .video, .html, .metalShader, .monitor:  return .fps60
        }
    }
}

public enum PlainVideoFrameRateCompositionPolicy {
    public static func compositionLimit(
        frameRateLimit: FrameRateLimit,
        videoFrameRate: Double,
        screenRefreshRate: Double
    ) -> Float? {
        guard frameRateLimit.enforcesCompositionCap else { return nil }

        let limit = frameRateLimit.getEffectiveLimit(
            videoFrameRate: videoFrameRate,
            screenRefreshRate: screenRefreshRate
        )
        guard limit > 0, videoFrameRate > Double(limit) else { return nil }
        return limit
    }
}
