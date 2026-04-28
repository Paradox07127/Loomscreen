import CoreGraphics
import Foundation

struct ScreenConfiguration: Codable, Equatable {
    let screenID: UInt32
    var activeWallpaper: WallpaperContent
    var savedVideoBookmarkData: Data?
    var playbackSpeed: Double
    var fitMode: VideoFitMode
    var frameRateLimit: FrameRateLimit

    var particleEffect: ParticleEffect
    var effectConfig: VideoEffectConfig
    var scheduleSlots: [ScheduleSlot]?
    var playlistBookmarks: [Data]?
    var shufflePlaylist: Bool
    var playlistRotationMinutes: Int?
    /// Cursor in `[savedVideoBookmarkData] + playlistBookmarks`.
    var playlistCursorIndex: Int?
    var setAsLockScreen: Bool
    var wallpaperMode: WallpaperMode = .single
    /// Muted by default so wallpaper videos do not take over audio output.
    var muted: Bool = true

    private enum CodingKeys: String, CodingKey {
        case screenID
        case activeWallpaper
        case savedVideoBookmarkData
        case playbackSpeed
        case fitMode
        case frameRateLimit
        case particleEffect
        case effectConfig
        case scheduleSlots
        case playlistBookmarks
        case shufflePlaylist
        case playlistRotationMinutes
        case playlistCursorIndex
        case setAsLockScreen
        case wallpaperMode
        case muted

        case videoBookmarkData
        case wallpaperType
        case htmlContent
        case shaderPreset
    }

    init(
        screenID: CGDirectDisplayID,
        wallpaper: WallpaperContent,
        playbackSpeed: Double = 1.0,
        fitMode: VideoFitMode = .aspectFill,
        frameRateLimit: FrameRateLimit = .fps60,
        particleEffect: ParticleEffect = .none,
        effectConfig: VideoEffectConfig = .default,
        scheduleSlots: [ScheduleSlot]? = nil,
        playlistBookmarks: [Data]? = nil,
        shufflePlaylist: Bool = false,
        playlistRotationMinutes: Int? = nil,
        playlistCursorIndex: Int? = nil,
        setAsLockScreen: Bool = false,
        savedVideoBookmarkData: Data? = nil
    ) {
        self.screenID = screenID
        self.activeWallpaper = wallpaper
        self.savedVideoBookmarkData = savedVideoBookmarkData ?? wallpaper.activeVideoBookmarkData
        self.playbackSpeed = playbackSpeed
        self.fitMode = fitMode
        self.frameRateLimit = frameRateLimit
        self.particleEffect = particleEffect
        self.effectConfig = effectConfig
        self.scheduleSlots = scheduleSlots
        self.playlistBookmarks = playlistBookmarks
        self.shufflePlaylist = shufflePlaylist
        self.playlistRotationMinutes = playlistRotationMinutes
        self.playlistCursorIndex = playlistCursorIndex
        self.setAsLockScreen = setAsLockScreen
    }

    init(
        screenID: CGDirectDisplayID,
        videoBookmarkData: Data,
        playbackSpeed: Double = 1.0,
        fitMode: VideoFitMode = .aspectFill,
        frameRateLimit: FrameRateLimit = .fps60,
        particleEffect: ParticleEffect = .none,
        effectConfig: VideoEffectConfig = .default,
        scheduleSlots: [ScheduleSlot]? = nil,
        playlistBookmarks: [Data]? = nil,
        shufflePlaylist: Bool = false,
        playlistRotationMinutes: Int? = nil,
        playlistCursorIndex: Int? = nil,
        setAsLockScreen: Bool = false
    ) {
        self.init(
            screenID: screenID,
            wallpaper: .video(bookmarkData: videoBookmarkData),
            playbackSpeed: playbackSpeed,
            fitMode: fitMode,
            frameRateLimit: frameRateLimit,
            particleEffect: particleEffect,
            effectConfig: effectConfig,
            scheduleSlots: scheduleSlots,
            playlistBookmarks: playlistBookmarks,
            shufflePlaylist: shufflePlaylist,
            playlistRotationMinutes: playlistRotationMinutes,
            playlistCursorIndex: playlistCursorIndex,
            setAsLockScreen: setAsLockScreen,
            savedVideoBookmarkData: videoBookmarkData
        )
    }

    init(
        screenID: CGDirectDisplayID,
        videoBookmarkData: Data,
        playbackSpeed: Double = 1.0,
        fitMode: VideoFitMode = .aspectFill,
        frameRateLimit: FrameRateLimit = .fps60,
        wallpaperType: WallpaperType,
        particleEffect: ParticleEffect = .none,
        effectConfig: VideoEffectConfig = .default,
        htmlContent: String? = nil,
        shaderPreset: MetalShaderPreset? = nil,
        scheduleSlots: [ScheduleSlot]? = nil,
        playlistBookmarks: [Data]? = nil,
        shufflePlaylist: Bool = false,
        playlistRotationMinutes: Int? = nil,
        playlistCursorIndex: Int? = nil,
        setAsLockScreen: Bool = false
    ) {
        let savedVideoBookmarkData = videoBookmarkData.isEmpty ? nil : videoBookmarkData

        switch wallpaperType {
        case .video:
            self.init(
                screenID: screenID,
                videoBookmarkData: videoBookmarkData,
                playbackSpeed: playbackSpeed,
                fitMode: fitMode,
                frameRateLimit: frameRateLimit,
                particleEffect: particleEffect,
                effectConfig: effectConfig,
                scheduleSlots: scheduleSlots,
                playlistBookmarks: playlistBookmarks,
                shufflePlaylist: shufflePlaylist,
                playlistRotationMinutes: playlistRotationMinutes,
                playlistCursorIndex: playlistCursorIndex,
                setAsLockScreen: setAsLockScreen
            )
        case .html, .metalShader:
            let wallpaper: WallpaperContent = switch wallpaperType {
            case .html:
                .html(source: HTMLSource(legacyString: htmlContent ?? ""), config: .default)
            case .metalShader:
                .metalShader(shaderPreset ?? .waves)
            case .video:
                .video(bookmarkData: videoBookmarkData)
            }

            self.init(
                screenID: screenID,
                wallpaper: wallpaper,
                playbackSpeed: playbackSpeed,
                fitMode: fitMode,
                frameRateLimit: frameRateLimit,
                particleEffect: particleEffect,
                effectConfig: effectConfig,
                scheduleSlots: scheduleSlots,
                playlistBookmarks: playlistBookmarks,
                shufflePlaylist: shufflePlaylist,
                playlistRotationMinutes: playlistRotationMinutes,
                playlistCursorIndex: playlistCursorIndex,
                setAsLockScreen: setAsLockScreen,
                savedVideoBookmarkData: savedVideoBookmarkData
            )
        }
    }

    var wallpaperType: WallpaperType {
        activeWallpaper.wallpaperType
    }

    var videoBookmarkData: Data? {
        activeWallpaper.activeVideoBookmarkData ?? savedVideoBookmarkData
    }

    var preferredVideoBookmarkData: Data? {
        videoBookmarkData
    }

    var htmlSource: HTMLSource? {
        activeWallpaper.htmlSource
    }

    var htmlConfig: HTMLConfig? {
        activeWallpaper.htmlConfig
    }

    /// Textual HTML payload, if the source is URL or inline HTML.
    var htmlContent: String? {
        guard let source = activeWallpaper.htmlSource else { return nil }
        switch source {
        case .url(let url): return url.absoluteString
        case .inline(let raw): return raw
        case .file, .folder: return nil
        }
    }

    var shaderPreset: MetalShaderPreset? {
        activeWallpaper.shaderPreset
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        screenID = try c.decode(UInt32.self, forKey: .screenID)
        playbackSpeed = try c.decodeIfPresent(Double.self, forKey: .playbackSpeed) ?? 1.0
        fitMode = try c.decodeIfPresent(VideoFitMode.self, forKey: .fitMode) ?? .aspectFill
        // Legacy per-screen power settings now live in GlobalSettings.
        frameRateLimit = try c.decodeIfPresent(FrameRateLimit.self, forKey: .frameRateLimit) ?? .fps60
        particleEffect = try c.decodeIfPresent(ParticleEffect.self, forKey: .particleEffect) ?? .none
        effectConfig = try c.decodeIfPresent(VideoEffectConfig.self, forKey: .effectConfig) ?? .default
        scheduleSlots = try c.decodeIfPresent([ScheduleSlot].self, forKey: .scheduleSlots)
        playlistBookmarks = try c.decodeIfPresent([Data].self, forKey: .playlistBookmarks)
        shufflePlaylist = try c.decodeIfPresent(Bool.self, forKey: .shufflePlaylist) ?? false
        playlistRotationMinutes = try c.decodeIfPresent(Int.self, forKey: .playlistRotationMinutes)
        playlistCursorIndex = try c.decodeIfPresent(Int.self, forKey: .playlistCursorIndex)
        setAsLockScreen = try c.decodeIfPresent(Bool.self, forKey: .setAsLockScreen) ?? false
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? true

        if let storedMode = try c.decodeIfPresent(WallpaperMode.self, forKey: .wallpaperMode) {
            wallpaperMode = storedMode
        } else if (scheduleSlots?.isEmpty == false) {
            wallpaperMode = .schedule
        } else if (playlistBookmarks?.isEmpty == false) {
            wallpaperMode = .playlist
        } else {
            wallpaperMode = .single
        }

        if let decodedWallpaper = try c.decodeIfPresent(WallpaperContent.self, forKey: .activeWallpaper) {
            activeWallpaper = decodedWallpaper
            savedVideoBookmarkData = try c.decodeIfPresent(Data.self, forKey: .savedVideoBookmarkData)
                ?? decodedWallpaper.activeVideoBookmarkData
            return
        }

        let legacyWallpaperType = try c.decodeIfPresent(WallpaperType.self, forKey: .wallpaperType) ?? .video
        let legacyBookmark = try c.decodeIfPresent(Data.self, forKey: .videoBookmarkData)
        let legacySavedBookmark = (legacyBookmark?.isEmpty == false) ? legacyBookmark : nil

        switch legacyWallpaperType {
        case .video:
            let bookmark = legacyBookmark ?? Data()
            activeWallpaper = .video(bookmarkData: bookmark)
            savedVideoBookmarkData = bookmark
        case .html:
            let legacyHTML = try c.decodeIfPresent(String.self, forKey: .htmlContent) ?? ""
            activeWallpaper = .html(source: HTMLSource(legacyString: legacyHTML), config: .default)
            savedVideoBookmarkData = legacySavedBookmark
        case .metalShader:
            activeWallpaper = .metalShader(
                try c.decodeIfPresent(MetalShaderPreset.self, forKey: .shaderPreset) ?? .waves
            )
            savedVideoBookmarkData = legacySavedBookmark
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(screenID, forKey: .screenID)
        try c.encode(activeWallpaper, forKey: .activeWallpaper)
        try c.encodeIfPresent(savedVideoBookmarkData, forKey: .savedVideoBookmarkData)
        try c.encode(playbackSpeed, forKey: .playbackSpeed)
        try c.encode(fitMode, forKey: .fitMode)
        try c.encode(frameRateLimit, forKey: .frameRateLimit)
        try c.encode(particleEffect, forKey: .particleEffect)
        try c.encode(effectConfig, forKey: .effectConfig)
        try c.encodeIfPresent(scheduleSlots, forKey: .scheduleSlots)
        try c.encodeIfPresent(playlistBookmarks, forKey: .playlistBookmarks)
        try c.encode(shufflePlaylist, forKey: .shufflePlaylist)
        try c.encodeIfPresent(playlistRotationMinutes, forKey: .playlistRotationMinutes)
        try c.encodeIfPresent(playlistCursorIndex, forKey: .playlistCursorIndex)
        try c.encode(setAsLockScreen, forKey: .setAsLockScreen)
        try c.encode(wallpaperMode, forKey: .wallpaperMode)
        try c.encode(muted, forKey: .muted)
    }

    mutating func setHTMLWallpaper(source: HTMLSource, config: HTMLConfig = .default) {
        preserveCurrentVideoBookmarkIfNeeded()
        activeWallpaper = .html(source: source, config: config)
    }

    /// Legacy URL/raw-HTML bridge.
    mutating func setHTMLWallpaper(_ content: String) {
        setHTMLWallpaper(source: HTMLSource(legacyString: content), config: .default)
    }

    mutating func updateHTMLConfig(_ config: HTMLConfig) {
        guard case .html(let source, _) = activeWallpaper else { return }
        activeWallpaper = .html(source: source, config: config)
    }

    mutating func setShaderWallpaper(_ preset: MetalShaderPreset) {
        preserveCurrentVideoBookmarkIfNeeded()
        activeWallpaper = .metalShader(preset)
    }

    @discardableResult
    mutating func activateSavedVideoWallpaper() -> Bool {
        guard let bookmarkData = savedVideoBookmarkData ?? activeWallpaper.activeVideoBookmarkData else {
            return false
        }
        activeWallpaper = .video(bookmarkData: bookmarkData)
        savedVideoBookmarkData = bookmarkData
        // User explicitly switched back to video — restart playlist at primary.
        playlistCursorIndex = 0
        return true
    }

    /// Swaps the primary video while preserving per-screen settings.
    mutating func replacePrimaryVideo(bookmarkData: Data) {
        savedVideoBookmarkData = bookmarkData
        activeWallpaper = .video(bookmarkData: bookmarkData)
        // Reset cursor so rotation doesn't point past the end of a reshuffled list.
        playlistCursorIndex = 0
    }

    /// Activates a schedule slot without replacing the saved primary video.
    mutating func applyScheduledBookmark(_ bookmarkData: Data) {
        activeWallpaper = .video(bookmarkData: bookmarkData)
    }

    private mutating func preserveCurrentVideoBookmarkIfNeeded() {
        if savedVideoBookmarkData == nil {
            savedVideoBookmarkData = activeWallpaper.activeVideoBookmarkData
        }
    }

    /// Refreshes the bookmark currently driving playback.
    func withUpdatedActiveBookmark(_ bookmarkData: Data) -> ScreenConfiguration {
        var copy = self
        let oldActive = copy.activeWallpaper.activeVideoBookmarkData

        if case .video = copy.activeWallpaper {
            copy.activeWallpaper = .video(bookmarkData: bookmarkData)
        }

        guard let oldActive else { return copy }

        if oldActive == copy.savedVideoBookmarkData {
            copy.savedVideoBookmarkData = bookmarkData
            return copy
        }

        if var additional = copy.playlistBookmarks,
           let index = additional.firstIndex(of: oldActive) {
            additional[index] = bookmarkData
            copy.playlistBookmarks = additional
            return copy
        }

        if var slots = copy.scheduleSlots {
            for index in slots.indices where slots[index].videoBookmarkData == oldActive {
                slots[index].videoBookmarkData = bookmarkData
                copy.scheduleSlots = slots
                return copy
            }
        }

        return copy
    }
}
