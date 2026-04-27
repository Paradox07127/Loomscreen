import CoreGraphics
import Foundation

struct ScreenConfiguration: Codable, Equatable {
    let screenID: UInt32
    var activeWallpaper: WallpaperContent
    var savedVideoBookmarkData: Data?
    var playbackSpeed: Double
    var fitMode: VideoFitMode
    var pauseOnBattery: Bool
    var frameRateLimit: FrameRateLimit

    var particleEffect: ParticleEffect
    var effectConfig: VideoEffectConfig
    var scheduleSlots: [ScheduleSlot]?
    var playlistBookmarks: [Data]?
    var shufflePlaylist: Bool
    var playlistRotationMinutes: Int?
    /// Index in the combined playlist `[savedVideoBookmarkData] + playlistBookmarks`.
    /// `nil` or 0 means the primary is currently playing. Persisted so rotation
    /// position survives app restarts.
    var playlistCursorIndex: Int?
    var setAsLockScreen: Bool
    /// Top-level automation mode. Controls inspector section visibility and
    /// playlist/schedule guards. Default `.single`; legacy configs are inferred
    /// at decode time.
    var wallpaperMode: WallpaperMode = .single

    private enum CodingKeys: String, CodingKey {
        case screenID
        case activeWallpaper
        case savedVideoBookmarkData
        case playbackSpeed
        case fitMode
        case pauseOnBattery
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
        pauseOnBattery: Bool = false,
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
        self.pauseOnBattery = pauseOnBattery
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
        pauseOnBattery: Bool = false,
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
            pauseOnBattery: pauseOnBattery,
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
        pauseOnBattery: Bool = false,
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
                pauseOnBattery: pauseOnBattery,
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
                .html(htmlContent ?? "")
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
                pauseOnBattery: pauseOnBattery,
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

    var htmlContent: String? {
        activeWallpaper.htmlContent
    }

    var shaderPreset: MetalShaderPreset? {
        activeWallpaper.shaderPreset
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        screenID = try c.decode(UInt32.self, forKey: .screenID)
        playbackSpeed = try c.decodeIfPresent(Double.self, forKey: .playbackSpeed) ?? 1.0
        fitMode = try c.decodeIfPresent(VideoFitMode.self, forKey: .fitMode) ?? .aspectFill
        pauseOnBattery = try c.decodeIfPresent(Bool.self, forKey: .pauseOnBattery) ?? false
        frameRateLimit = try c.decodeIfPresent(FrameRateLimit.self, forKey: .frameRateLimit) ?? .fps60
        particleEffect = try c.decodeIfPresent(ParticleEffect.self, forKey: .particleEffect) ?? .none
        effectConfig = try c.decodeIfPresent(VideoEffectConfig.self, forKey: .effectConfig) ?? .default
        scheduleSlots = try c.decodeIfPresent([ScheduleSlot].self, forKey: .scheduleSlots)
        playlistBookmarks = try c.decodeIfPresent([Data].self, forKey: .playlistBookmarks)
        shufflePlaylist = try c.decodeIfPresent(Bool.self, forKey: .shufflePlaylist) ?? false
        playlistRotationMinutes = try c.decodeIfPresent(Int.self, forKey: .playlistRotationMinutes)
        playlistCursorIndex = try c.decodeIfPresent(Int.self, forKey: .playlistCursorIndex)
        setAsLockScreen = try c.decodeIfPresent(Bool.self, forKey: .setAsLockScreen) ?? false

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
            activeWallpaper = .html(try c.decodeIfPresent(String.self, forKey: .htmlContent) ?? "")
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
        try c.encode(pauseOnBattery, forKey: .pauseOnBattery)
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
    }

    mutating func setHTMLWallpaper(_ content: String) {
        preserveCurrentVideoBookmarkIfNeeded()
        activeWallpaper = .html(content)
    }

    mutating func setShaderWallpaper(_ preset: MetalShaderPreset) {
        preserveCurrentVideoBookmarkIfNeeded()
        activeWallpaper = .metalShader(preset)
    }

    @discardableResult
    mutating func activateSavedVideoWallpaper() -> Bool {
        guard let bookmarkData = videoBookmarkData else { return false }
        activeWallpaper = .video(bookmarkData: bookmarkData)
        savedVideoBookmarkData = bookmarkData
        // User explicitly switched back to video — restart playlist at primary.
        playlistCursorIndex = 0
        return true
    }

    /// Swap the primary video bookmark. Used when the user picks a new file.
    /// Preserves effects, playlist, schedule, etc.; only the current file identity changes.
    mutating func replacePrimaryVideo(bookmarkData: Data) {
        savedVideoBookmarkData = bookmarkData
        activeWallpaper = .video(bookmarkData: bookmarkData)
        // Reset cursor so rotation doesn't point past the end of a reshuffled list.
        playlistCursorIndex = 0
    }

    /// Replace `activeWallpaper` with a scheduled-slot bookmark.
    /// Preserves `savedVideoBookmarkData` (primary) and the playlist cursor so that
    /// rotating/returning after the slot ends still works.
    mutating func applyScheduledBookmark(_ bookmarkData: Data) {
        activeWallpaper = .video(bookmarkData: bookmarkData)
    }

    private mutating func preserveCurrentVideoBookmarkIfNeeded() {
        if let activeVideoBookmarkData = activeWallpaper.activeVideoBookmarkData {
            savedVideoBookmarkData = activeVideoBookmarkData
        }
    }

    /// Refresh the bookmark of whatever slot is currently driving playback.
    ///
    /// Source detection is content-based, not cursor-based. The cursor only
    /// tracks playlist position and would mis-attribute schedule-slot playback
    /// (which never moves the cursor) to the primary video.
    ///
    /// Resolution order — match the CURRENT active bookmark against:
    ///   1. `savedVideoBookmarkData` (primary)              → refresh primary
    ///   2. an entry in `playlistBookmarks`                 → refresh that entry
    ///   3. an entry in `scheduleSlots[*].videoBookmarkData` → refresh that slot
    ///
    /// If no source matches (or `activeWallpaper` isn't a video), only
    /// `activeWallpaper` is updated — the player keeps using the fresh
    /// bookmark without touching any persisted slot.
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
