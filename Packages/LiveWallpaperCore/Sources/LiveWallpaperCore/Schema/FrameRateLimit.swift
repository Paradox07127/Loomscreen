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
    /// The fps each wallpaper type should default to when a brand-new
    /// `ScreenConfiguration` is created (no saved frame-rate exists yet).
    ///
    /// Rationale:
    /// - `.video` → `.fps60` keeps the existing native pass-through; any
    ///   cap < 60 forces an `AVVideoComposition` recompose pass (see
    ///   `enforcesCompositionCap`) which costs CPU/GPU for no UX win on
    ///   plain video.
    /// - `.scene` → `.fps30` matches Wallpaper Engine's stock default
    ///   (Almamu's open-source reference ships `maximumFPS = 30`; the
    ///   official Windows app's "Balanced" preset also defaults to 30).
    ///   Most published WPE shaders are tuned around a 30 FPS clock —
    ///   running at 60 makes their `g_Time`-driven motion look ~2× too
    ///   fast (the "Neco Arc grain too fast" report that prompted this).
    /// - `.html`, `.metalShader` → `.fps60` keeps the prior behaviour;
    ///   these renderers don't share WPE's 30-FPS authoring convention.
    ///
    /// User-set values always win — this only seeds the initial default
    /// before the inspector picker is touched. Existing saved configs
    /// keep whatever value they previously persisted (the decoder
    /// fallback stays `.fps60` for backward compatibility).
    public static func naturalDefault(for wallpaperType: WallpaperType) -> FrameRateLimit {
        switch wallpaperType {
        case .scene:                       return .fps30
        case .video, .html, .metalShader:  return .fps60
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
