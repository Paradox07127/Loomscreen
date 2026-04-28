import Foundation

struct GlobalSettings: Codable {
    var globalPauseOnBattery: Bool
    var preservePlaybackOnLock: Bool
    var startOnLogin: Bool
    var minimumBatteryLevel: Double?
    var defaultFrameRateLimit: FrameRateLimit
    var pauseOnFullScreen: Bool

    init(
        // Default `false` so a freshly-installed or reset app plays its
        // wallpaper out of the box even when running on battery — power
        // savers can opt in via General Settings.
        globalPauseOnBattery: Bool = false,
        preservePlaybackOnLock: Bool = false,
        startOnLogin: Bool = false,
        minimumBatteryLevel: Double? = nil,
        defaultFrameRateLimit: FrameRateLimit = .fps60,
        pauseOnFullScreen: Bool = true
    ) {
        self.globalPauseOnBattery = globalPauseOnBattery
        self.preservePlaybackOnLock = preservePlaybackOnLock
        self.startOnLogin = startOnLogin
        self.minimumBatteryLevel = minimumBatteryLevel
        self.defaultFrameRateLimit = defaultFrameRateLimit
        self.pauseOnFullScreen = pauseOnFullScreen
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        globalPauseOnBattery = try c.decodeIfPresent(Bool.self, forKey: .globalPauseOnBattery) ?? false
        preservePlaybackOnLock = try c.decodeIfPresent(Bool.self, forKey: .preservePlaybackOnLock) ?? false
        startOnLogin = try c.decodeIfPresent(Bool.self, forKey: .startOnLogin) ?? false
        minimumBatteryLevel = try c.decodeIfPresent(Double.self, forKey: .minimumBatteryLevel)
        defaultFrameRateLimit = try c.decodeIfPresent(FrameRateLimit.self, forKey: .defaultFrameRateLimit) ?? .fps60
        pauseOnFullScreen = try c.decodeIfPresent(Bool.self, forKey: .pauseOnFullScreen) ?? true
        // Legacy `batteryResolutionCap` key is silently ignored on decode — superseded
        // by the "pause on battery = static wallpaper" model; no frame-rate or resolution
        // degradation is applied anymore.
    }
}
