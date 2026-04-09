import Foundation
import AVFoundation

// MARK: - Wallpaper Type

enum WallpaperType: String, Codable, CaseIterable, Identifiable {
    case video = "Video"
    case html = "HTML"
    case metalShader = "Shader"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .video: return "film"
        case .html: return "globe"
        case .metalShader: return "wand.and.stars"
        }
    }
}

// MARK: - Particle Effect

enum ParticleEffect: String, Codable, CaseIterable, Identifiable {
    case none = "None"
    case snow = "Snow"
    case rain = "Rain"
    case bokeh = "Bokeh"
    case fireflies = "Fireflies"
    case fallingLeaves = "Leaves"
    case sakura = "Sakura"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .none: return "xmark.circle"
        case .snow: return "snowflake"
        case .rain: return "cloud.rain"
        case .bokeh: return "sparkles"
        case .fireflies: return "lightbulb"
        case .fallingLeaves: return "leaf"
        case .sakura: return "camera.macro"
        }
    }
}

// MARK: - Video Effect Configuration

struct VideoEffectConfig: Codable, Equatable {
    var blurRadius: Double = 0
    var saturation: Double = 1.0
    var brightness: Double = 0
    var warmth: Double = 6500  // color temperature in Kelvin (6500 = neutral)
    var vignetteIntensity: Double = 0
    var autoTimeTint: Bool = false  // auto-adjust warmth by time of day
    var weatherReactive: Bool = false // auto-adjust effects based on real-time weather
    var particleDensity: Double = 1.0 // multiplier on particle birth rate (0.2 ... 3.0)
    var glassRainEffect: Bool = false // AE/PR style refractive rain drops on glass

    static let `default` = VideoEffectConfig()

    var hasActiveEffect: Bool {
        blurRadius > 0 || saturation != 1.0 || brightness != 0 ||
        warmth != 6500 || vignetteIntensity > 0 || autoTimeTint || weatherReactive || glassRainEffect
    }

    // Custom decoder: tolerate missing keys from older saved configs
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        blurRadius = try container.decodeIfPresent(Double.self, forKey: .blurRadius) ?? 0
        saturation = try container.decodeIfPresent(Double.self, forKey: .saturation) ?? 1.0
        brightness = try container.decodeIfPresent(Double.self, forKey: .brightness) ?? 0
        warmth = try container.decodeIfPresent(Double.self, forKey: .warmth) ?? 6500
        vignetteIntensity = try container.decodeIfPresent(Double.self, forKey: .vignetteIntensity) ?? 0
        autoTimeTint = try container.decodeIfPresent(Bool.self, forKey: .autoTimeTint) ?? false
        weatherReactive = try container.decodeIfPresent(Bool.self, forKey: .weatherReactive) ?? false
        particleDensity = try container.decodeIfPresent(Double.self, forKey: .particleDensity) ?? 1.0
        glassRainEffect = try container.decodeIfPresent(Bool.self, forKey: .glassRainEffect) ?? false
    }

    init() {}
}

// MARK: - Schedule Slot

struct ScheduleSlot: Codable, Equatable, Identifiable {
    var id = UUID()
    var startHour: Int   // 0-23
    var endHour: Int     // 0-23
    var videoBookmarkData: Data?
    var label: String

    static let defaultSlots: [ScheduleSlot] = [
        ScheduleSlot(startHour: 6, endHour: 12, label: "Morning"),
        ScheduleSlot(startHour: 12, endHour: 18, label: "Afternoon"),
        ScheduleSlot(startHour: 18, endHour: 22, label: "Evening"),
        ScheduleSlot(startHour: 22, endHour: 6, label: "Night"),
    ]

    func containsHour(_ hour: Int) -> Bool {
        if startHour <= endHour {
            return hour >= startHour && hour < endHour
        } else {
            // Wraps midnight (e.g., 22-6)
            return hour >= startHour || hour < endHour
        }
    }
}

// MARK: - Metal Shader Preset

enum MetalShaderPreset: String, Codable, CaseIterable, Identifiable {
    case waves = "Waves"
    case plasma = "Plasma"
    case gradient = "Gradient"
    case noise = "Noise"
    case aurora = "Aurora"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .waves: return "water.waves"
        case .plasma: return "flame"
        case .gradient: return "paintpalette"
        case .noise: return "cloud.fog"
        case .aurora: return "sparkle"
        }
    }
}

// MARK: - Frame Rate Limit

enum FrameRateLimit: Int, CaseIterable, Identifiable, Codable {
    case fps30 = 30
    case fps60 = 60
    case unlimited = 0

    var id: Int { rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(Int.self)
        self = FrameRateLimit(rawValue: rawValue) ?? .fps60
    }

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

    func getEffectiveLimit(videoFrameRate: Double, screenRefreshRate: Double) -> Float {
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

    /// Resolves a concrete frames-per-second value for use as a CIFilter
    /// composition `frameDuration`. Unlike `getEffectiveLimit` (which returns
    /// `0` for "use native"), this always returns a positive number so the
    /// caller can build a non-degenerate `CMTime`.
    ///
    /// Resolution order:
    ///   1. Use the result of `getEffectiveLimit` when it produces a cap.
    ///   2. Fall back to `videoFrameRate` if known.
    ///   3. Fall back to `screenRefreshRate` if known.
    ///   4. Last resort: use the limit's nominal raw value (60 for unlimited).
    static func resolveCompositionFPS(
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

// MARK: - Video Fit Mode

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

struct ScreenConfiguration: Codable, Equatable {
    let screenID: UInt32
    let videoBookmarkData: Data
    var playbackSpeed: Double
    var fitMode: VideoFitMode
    var pauseOnBattery: Bool
    var frameRateLimit: FrameRateLimit

    // New feature fields
    var wallpaperType: WallpaperType
    var particleEffect: ParticleEffect
    var effectConfig: VideoEffectConfig
    var htmlContent: String?           // HTML string or URL for web wallpaper
    var shaderPreset: MetalShaderPreset?
    var scheduleSlots: [ScheduleSlot]?
    var playlistBookmarks: [Data]?     // additional videos for playlist mode
    var shufflePlaylist: Bool
    var playlistRotationMinutes: Int?  // nil = no auto-rotation, >0 = rotate every N minutes
    var setAsLockScreen: Bool          // extract frame for lock screen

    init(
        screenID: CGDirectDisplayID,
        videoBookmarkData: Data,
        playbackSpeed: Double = 1.0,
        fitMode: VideoFitMode = .aspectFill,
        pauseOnBattery: Bool = false,
        frameRateLimit: FrameRateLimit = .fps60,
        wallpaperType: WallpaperType = .video,
        particleEffect: ParticleEffect = .none,
        effectConfig: VideoEffectConfig = .default,
        htmlContent: String? = nil,
        shaderPreset: MetalShaderPreset? = nil,
        scheduleSlots: [ScheduleSlot]? = nil,
        playlistBookmarks: [Data]? = nil,
        shufflePlaylist: Bool = false,
        playlistRotationMinutes: Int? = nil,
        setAsLockScreen: Bool = false
    ) {
        self.screenID = screenID
        self.videoBookmarkData = videoBookmarkData
        self.playbackSpeed = playbackSpeed
        self.fitMode = fitMode
        self.pauseOnBattery = pauseOnBattery
        self.frameRateLimit = frameRateLimit
        self.wallpaperType = wallpaperType
        self.particleEffect = particleEffect
        self.effectConfig = effectConfig
        self.htmlContent = htmlContent
        self.shaderPreset = shaderPreset
        self.scheduleSlots = scheduleSlots
        self.playlistBookmarks = playlistBookmarks
        self.shufflePlaylist = shufflePlaylist
        self.playlistRotationMinutes = playlistRotationMinutes
        self.setAsLockScreen = setAsLockScreen
    }

    // Custom decoder: tolerate missing keys from older saved configs
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        screenID = try c.decode(UInt32.self, forKey: .screenID)
        videoBookmarkData = try c.decode(Data.self, forKey: .videoBookmarkData)
        playbackSpeed = try c.decodeIfPresent(Double.self, forKey: .playbackSpeed) ?? 1.0
        fitMode = try c.decodeIfPresent(VideoFitMode.self, forKey: .fitMode) ?? .aspectFill
        pauseOnBattery = try c.decodeIfPresent(Bool.self, forKey: .pauseOnBattery) ?? false
        frameRateLimit = try c.decodeIfPresent(FrameRateLimit.self, forKey: .frameRateLimit) ?? .fps60
        wallpaperType = try c.decodeIfPresent(WallpaperType.self, forKey: .wallpaperType) ?? .video
        particleEffect = try c.decodeIfPresent(ParticleEffect.self, forKey: .particleEffect) ?? .none
        effectConfig = try c.decodeIfPresent(VideoEffectConfig.self, forKey: .effectConfig) ?? .default
        htmlContent = try c.decodeIfPresent(String.self, forKey: .htmlContent)
        shaderPreset = try c.decodeIfPresent(MetalShaderPreset.self, forKey: .shaderPreset)
        scheduleSlots = try c.decodeIfPresent([ScheduleSlot].self, forKey: .scheduleSlots)
        playlistBookmarks = try c.decodeIfPresent([Data].self, forKey: .playlistBookmarks)
        shufflePlaylist = try c.decodeIfPresent(Bool.self, forKey: .shufflePlaylist) ?? false
        playlistRotationMinutes = try c.decodeIfPresent(Int.self, forKey: .playlistRotationMinutes)
        setAsLockScreen = try c.decodeIfPresent(Bool.self, forKey: .setAsLockScreen) ?? false
    }

    func withUpdatedBookmark(_ bookmarkData: Data) -> ScreenConfiguration {
        let copy = self
        // Use reflection-free approach: create new with all existing values
        return ScreenConfiguration(
            screenID: screenID,
            videoBookmarkData: bookmarkData,
            playbackSpeed: copy.playbackSpeed,
            fitMode: copy.fitMode,
            pauseOnBattery: copy.pauseOnBattery,
            frameRateLimit: copy.frameRateLimit,
            wallpaperType: copy.wallpaperType,
            particleEffect: copy.particleEffect,
            effectConfig: copy.effectConfig,
            htmlContent: copy.htmlContent,
            shaderPreset: copy.shaderPreset,
            scheduleSlots: copy.scheduleSlots,
            playlistBookmarks: copy.playlistBookmarks,
            shufflePlaylist: copy.shufflePlaylist,
            playlistRotationMinutes: copy.playlistRotationMinutes,
            setAsLockScreen: copy.setAsLockScreen
        )
    }
}

// MARK: - Global Settings

struct GlobalSettings: Codable {
    var globalPauseOnBattery: Bool
    var preservePlaybackOnLock: Bool
    var startOnLogin: Bool
    var minimumBatteryLevel: Double?
    var defaultFrameRateLimit: FrameRateLimit
    var pauseOnFullScreen: Bool
    var batteryResolutionCap: Bool   // reduce decode resolution on battery

    init(
        globalPauseOnBattery: Bool = true,
        preservePlaybackOnLock: Bool = false,
        startOnLogin: Bool = false,
        minimumBatteryLevel: Double? = nil,
        defaultFrameRateLimit: FrameRateLimit = .fps60,
        pauseOnFullScreen: Bool = true,
        batteryResolutionCap: Bool = true
    ) {
        self.globalPauseOnBattery = globalPauseOnBattery
        self.preservePlaybackOnLock = preservePlaybackOnLock
        self.startOnLogin = startOnLogin
        self.minimumBatteryLevel = minimumBatteryLevel
        self.defaultFrameRateLimit = defaultFrameRateLimit
        self.pauseOnFullScreen = pauseOnFullScreen
        self.batteryResolutionCap = batteryResolutionCap
    }

    // Custom decoder: tolerate missing keys from older saved configs
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        globalPauseOnBattery = try c.decodeIfPresent(Bool.self, forKey: .globalPauseOnBattery) ?? true
        preservePlaybackOnLock = try c.decodeIfPresent(Bool.self, forKey: .preservePlaybackOnLock) ?? false
        startOnLogin = try c.decodeIfPresent(Bool.self, forKey: .startOnLogin) ?? false
        minimumBatteryLevel = try c.decodeIfPresent(Double.self, forKey: .minimumBatteryLevel)
        defaultFrameRateLimit = try c.decodeIfPresent(FrameRateLimit.self, forKey: .defaultFrameRateLimit) ?? .fps60
        pauseOnFullScreen = try c.decodeIfPresent(Bool.self, forKey: .pauseOnFullScreen) ?? true
        batteryResolutionCap = try c.decodeIfPresent(Bool.self, forKey: .batteryResolutionCap) ?? true
    }
}

// MARK: - Shared Utilities

enum FormatUtils {
    nonisolated(unsafe) private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .memory
        return f
    }()

    static func formatBytes(_ bytes: UInt64) -> String {
        byteFormatter.string(fromByteCount: Int64(bytes))
    }

    static func formatBytes(_ bytes: Int64) -> String {
        byteFormatter.string(fromByteCount: max(0, bytes))
    }

    static func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, !seconds.isNaN else { return "Unknown" }
        let total = max(0, Int(seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
