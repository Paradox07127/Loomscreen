import Foundation

/// Full playback / effect snapshot attached to a `WallpaperBookmark` so the
/// bookmark represents a complete plan ("what to play" + "how to play it"),
/// not just a file pointer.
///
/// Every field is optional so legacy bookmarks (saved before this struct
/// existed) decode cleanly with `nil` everywhere — the apply path treats
/// nil as "don't change this field on the target screen", preserving the
/// pre-expansion behavior of only setting content.
///
/// Playlist / schedule / wallpaper-mode are deliberately *not* included
/// here. Those are screen-level automation state, not a wallpaper plan,
/// and the user explicitly scoped this expansion to per-wallpaper config
/// rather than full per-screen preset.
public struct BookmarkPlaybackSettings: Codable, Equatable, Sendable {
    public var playbackSpeed: Double?
    public var fitMode: VideoFitMode?
    public var frameRateLimit: FrameRateLimit?
    public var particleEffect: ParticleEffect?
    public var effectConfig: VideoEffectConfig?
    public var muted: Bool?
    public var videoVolume: Double?
    public var setAsLockScreen: Bool?

    public init(
        playbackSpeed: Double? = nil,
        fitMode: VideoFitMode? = nil,
        frameRateLimit: FrameRateLimit? = nil,
        particleEffect: ParticleEffect? = nil,
        effectConfig: VideoEffectConfig? = nil,
        muted: Bool? = nil,
        videoVolume: Double? = nil,
        setAsLockScreen: Bool? = nil
    ) {
        self.playbackSpeed = playbackSpeed
        self.fitMode = fitMode
        self.frameRateLimit = frameRateLimit
        self.particleEffect = particleEffect
        self.effectConfig = effectConfig
        self.muted = muted
        self.videoVolume = videoVolume
        self.setAsLockScreen = setAsLockScreen
    }

    /// Snapshot every relevant field from a screen's current configuration.
    /// Fields not represented in the schema (e.g. `wallpaperMode`,
    /// `playlistBookmarks`, `scheduleSlots`) are intentionally omitted.
    public static func snapshot(of config: ScreenConfiguration) -> BookmarkPlaybackSettings {
        BookmarkPlaybackSettings(
            playbackSpeed: config.playbackSpeed,
            fitMode: config.fitMode,
            frameRateLimit: config.frameRateLimit,
            particleEffect: config.particleEffect,
            effectConfig: config.effectConfig,
            muted: config.muted,
            videoVolume: config.videoVolume,
            setAsLockScreen: config.setAsLockScreen
        )
    }
}
