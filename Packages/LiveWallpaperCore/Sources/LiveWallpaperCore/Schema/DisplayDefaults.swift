import Foundation

public struct DisplayPlaybackDefaults: Codable, Equatable, Sendable {
    public var playbackSpeed: Double
    public var fitMode: VideoFitMode
    public var videoDisplayMode: VideoDisplayMode
    public var frameRateLimit: FrameRateLimit
    public var muted: Bool
    public var videoVolume: Double
    public var videoColorSpace: VideoColorSpace
    public var sceneMouseInteractionEnabled: Bool
    public var interactiveInputEnabled: Bool

    public var sceneClickCaptureEnabled: Bool {
        get { interactiveInputEnabled }
        set { interactiveInputEnabled = newValue }
    }

    private enum CodingKeys: String, CodingKey {
        case playbackSpeed
        case fitMode
        case videoDisplayMode
        case frameRateLimit
        case muted
        case videoVolume
        case videoColorSpace
        case sceneMouseInteractionEnabled
        case interactiveInputEnabled
        case sceneClickCaptureEnabled
    }

    public init(
        playbackSpeed: Double = 1.0,
        fitMode: VideoFitMode = .aspectFill,
        videoDisplayMode: VideoDisplayMode = .perDisplay,
        frameRateLimit: FrameRateLimit,
        muted: Bool = true,
        videoVolume: Double = 1.0,
        videoColorSpace: VideoColorSpace = .auto,
        sceneMouseInteractionEnabled: Bool = true,
        interactiveInputEnabled: Bool? = nil,
        sceneClickCaptureEnabled: Bool = false
    ) {
        self.playbackSpeed = Self.clampedPlaybackSpeed(playbackSpeed)
        self.fitMode = fitMode
        self.videoDisplayMode = videoDisplayMode
        self.frameRateLimit = frameRateLimit
        self.muted = muted
        self.videoVolume = Self.clampedVolume(videoVolume)
        self.videoColorSpace = videoColorSpace
        self.sceneMouseInteractionEnabled = sceneMouseInteractionEnabled
        self.interactiveInputEnabled = interactiveInputEnabled ?? sceneClickCaptureEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let playbackSpeed = try c.decodeIfPresent(Double.self, forKey: .playbackSpeed) ?? 1.0
        self.playbackSpeed = Self.clampedPlaybackSpeed(playbackSpeed)
        fitMode = try c.decodeIfPresent(VideoFitMode.self, forKey: .fitMode) ?? .aspectFill
        videoDisplayMode = try c.decodeIfPresent(VideoDisplayMode.self, forKey: .videoDisplayMode) ?? .perDisplay
        frameRateLimit = try c.decodeIfPresent(FrameRateLimit.self, forKey: .frameRateLimit) ?? .fps60
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? true
        let videoVolume = try c.decodeIfPresent(Double.self, forKey: .videoVolume) ?? 1.0
        self.videoVolume = Self.clampedVolume(videoVolume)
        videoColorSpace = try c.decodeIfPresent(VideoColorSpace.self, forKey: .videoColorSpace) ?? .auto
        sceneMouseInteractionEnabled = try c.decodeIfPresent(Bool.self, forKey: .sceneMouseInteractionEnabled) ?? true
        interactiveInputEnabled = try c.decodeIfPresent(Bool.self, forKey: .interactiveInputEnabled)
            ?? c.decodeIfPresent(Bool.self, forKey: .sceneClickCaptureEnabled)
            ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(playbackSpeed, forKey: .playbackSpeed)
        try c.encode(fitMode, forKey: .fitMode)
        try c.encode(videoDisplayMode, forKey: .videoDisplayMode)
        try c.encode(frameRateLimit, forKey: .frameRateLimit)
        try c.encode(muted, forKey: .muted)
        try c.encode(videoVolume, forKey: .videoVolume)
        try c.encode(videoColorSpace, forKey: .videoColorSpace)
        try c.encode(sceneMouseInteractionEnabled, forKey: .sceneMouseInteractionEnabled)
        try c.encode(interactiveInputEnabled, forKey: .interactiveInputEnabled)
    }

    public static func natural(for wallpaperType: WallpaperType) -> DisplayPlaybackDefaults {
        DisplayPlaybackDefaults(frameRateLimit: FrameRateLimit.naturalDefault(for: wallpaperType))
    }

    public static func clampedPlaybackSpeed(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        return min(max(value, 0.25), 4.0)
    }

    public static func clampedVolume(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        return min(max(value, 0), 1)
    }
}

public struct DisplayDefaults: Codable, Equatable, Sendable {
    public var video: DisplayPlaybackDefaults
    public var html: DisplayPlaybackDefaults
    public var metalShader: DisplayPlaybackDefaults
    public var scene: DisplayPlaybackDefaults
    public var monitor: DisplayPlaybackDefaults

    public init(
        video: DisplayPlaybackDefaults = .natural(for: .video),
        html: DisplayPlaybackDefaults = .natural(for: .html),
        metalShader: DisplayPlaybackDefaults = .natural(for: .metalShader),
        scene: DisplayPlaybackDefaults = .natural(for: .scene),
        monitor: DisplayPlaybackDefaults = .natural(for: .monitor)
    ) {
        self.video = video
        self.html = html
        self.metalShader = metalShader
        self.scene = scene
        self.monitor = monitor
    }

    private enum CodingKeys: String, CodingKey {
        case video, html, metalShader, scene, monitor
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        video = try c.decodeIfPresent(DisplayPlaybackDefaults.self, forKey: .video) ?? .natural(for: .video)
        html = try c.decodeIfPresent(DisplayPlaybackDefaults.self, forKey: .html) ?? .natural(for: .html)
        metalShader = try c.decodeIfPresent(DisplayPlaybackDefaults.self, forKey: .metalShader) ?? .natural(for: .metalShader)
        scene = try c.decodeIfPresent(DisplayPlaybackDefaults.self, forKey: .scene) ?? .natural(for: .scene)
        monitor = try c.decodeIfPresent(DisplayPlaybackDefaults.self, forKey: .monitor) ?? .natural(for: .monitor)
    }

    public func playbackDefaults(for wallpaperType: WallpaperType) -> DisplayPlaybackDefaults {
        switch wallpaperType {
        case .video:
            video
        case .html:
            html
        case .metalShader:
            metalShader
        case .scene:
            scene
        case .monitor:
            monitor
        }
    }
}

public extension ScreenConfiguration {
    mutating func resetPlayback(to displayDefaults: DisplayDefaults) {
        let defaults = displayDefaults.playbackDefaults(for: wallpaperType)
        applyPlayback(defaults, for: wallpaperType)
    }

    func playbackDiffers(from displayDefaults: DisplayDefaults) -> Bool {
        var copy = self
        copy.resetPlayback(to: displayDefaults)
        return !playbackMatches(copy)
    }

    mutating func resetStoredPlayback(to displayDefaults: DisplayDefaults) {
        resetPlayback(to: displayDefaults)
        resetSavedHTMLPlayback(to: displayDefaults)
    }

    mutating func resetSavedHTMLPlayback(to displayDefaults: DisplayDefaults, createIfMissing: Bool = false) {
        guard createIfMissing || savedHTMLConfig != nil else { return }
        applySavedHTMLDefaults(displayDefaults.html)
    }

    func storedPlaybackDiffers(from displayDefaults: DisplayDefaults) -> Bool {
        var copy = self
        copy.resetStoredPlayback(to: displayDefaults)
        return !storedPlaybackMatches(copy)
    }

    func applyingDisplayDefaults(_ displayDefaults: DisplayDefaults) -> ScreenConfiguration {
        var copy = self
        copy.resetPlayback(to: displayDefaults)
        return copy
    }

    private mutating func applyPlayback(_ defaults: DisplayPlaybackDefaults, for wallpaperType: WallpaperType) {
        playbackSpeed = defaults.playbackSpeed
        fitMode = defaults.fitMode
        videoDisplayMode = defaults.videoDisplayMode
        frameRateLimit = defaults.frameRateLimit
        muted = defaults.muted
        videoVolume = defaults.videoVolume

        switch wallpaperType {
        case .video:
            videoColorSpace = defaults.videoColorSpace
        case .html:
            applyHTMLAudioDefaults(defaults)
        case .metalShader, .monitor:
            break
        case .scene:
            sceneMouseInteractionEnabled = defaults.sceneMouseInteractionEnabled
            sceneClickCaptureEnabled = defaults.sceneClickCaptureEnabled
        }
    }

    private mutating func applyHTMLAudioDefaults(_ defaults: DisplayPlaybackDefaults) {
        if case .html(let source, var config) = activeWallpaper {
            config.muteAudio = defaults.muted
            config.audioVolume = HTMLConfig.clampedAudioVolume(defaults.videoVolume)
            config.allowMouseInteraction = defaults.interactiveInputEnabled
            activeWallpaper = .html(source: source, config: config)
        }

        if var config = savedHTMLConfig {
            config.applyPlayback(defaults)
            savedHTMLConfig = config
        }
    }

    private mutating func applySavedHTMLDefaults(_ defaults: DisplayPlaybackDefaults) {
        var config = savedHTMLConfig ?? .default
        config.applyPlayback(defaults)
        savedHTMLConfig = config
    }

    private func playbackMatches(_ other: ScreenConfiguration) -> Bool {
        playbackSpeed == other.playbackSpeed
            && fitMode == other.fitMode
            && videoDisplayMode == other.videoDisplayMode
            && frameRateLimit == other.frameRateLimit
            && muted == other.muted
            && abs(videoVolume - other.videoVolume) <= 0.001
            && videoColorSpace == other.videoColorSpace
            && sceneMouseInteractionEnabled == other.sceneMouseInteractionEnabled
            && sceneClickCaptureEnabled == other.sceneClickCaptureEnabled
            && htmlPlaybackSignature == other.htmlPlaybackSignature
    }

    private func storedPlaybackMatches(_ other: ScreenConfiguration) -> Bool {
        playbackMatches(other)
            && savedHTMLPlaybackSignature == other.savedHTMLPlaybackSignature
    }

    private var htmlPlaybackSignature: HTMLPlaybackSignature? {
        guard case .html(_, let config) = activeWallpaper else { return nil }
        return HTMLPlaybackSignature(
            muted: config.muteAudio,
            volume: config.audioVolume,
            interaction: config.allowMouseInteraction
        )
    }

    private var savedHTMLPlaybackSignature: HTMLPlaybackSignature? {
        guard let config = savedHTMLConfig else { return nil }
        return HTMLPlaybackSignature(
            muted: config.muteAudio,
            volume: config.audioVolume,
            interaction: config.allowMouseInteraction
        )
    }
}

private struct HTMLPlaybackSignature: Equatable {
    var muted: Bool
    var volume: Double
    var interaction: Bool

    static func == (lhs: HTMLPlaybackSignature, rhs: HTMLPlaybackSignature) -> Bool {
        lhs.muted == rhs.muted
            && abs(lhs.volume - rhs.volume) <= 0.001
            && lhs.interaction == rhs.interaction
    }
}

private extension HTMLConfig {
    mutating func applyPlayback(_ defaults: DisplayPlaybackDefaults) {
        muteAudio = defaults.muted
        audioVolume = HTMLConfig.clampedAudioVolume(defaults.videoVolume)
        allowMouseInteraction = defaults.interactiveInputEnabled
    }
}
