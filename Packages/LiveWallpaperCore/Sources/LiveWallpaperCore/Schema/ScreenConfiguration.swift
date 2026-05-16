import CoreGraphics
import Foundation

public struct ScreenConfiguration: Codable, Equatable, Sendable {
    /// Mutable so `ScreenManager.applyConfigurationToAllDisplays` can clone
    /// a template for every other screen without recomposing each field.
    public var screenID: UInt32
    public var activeWallpaper: WallpaperContent
    public var savedVideoBookmarkData: Data?
    /// Last applied HTML source — restored on type switch back to HTML.
    public var savedHTMLSource: HTMLSource?
    public var savedHTMLConfig: HTMLConfig?
    public var playbackSpeed: Double
    public var fitMode: VideoFitMode
    public var videoDisplayMode: VideoDisplayMode = .perDisplay
    public var frameRateLimit: FrameRateLimit

    public var particleEffect: ParticleEffect
    public var effectConfig: VideoEffectConfig
    public var scheduleSlots: [ScheduleSlot]?
    public var playlistBookmarks: [Data]?
    public var shufflePlaylist: Bool
    public var playlistRotationMinutes: Int?
    /// Cursor in `[savedVideoBookmarkData] + playlistBookmarks`.
    public var playlistCursorIndex: Int?
    public var setAsLockScreen: Bool
    public var wallpaperMode: WallpaperMode = .single
    /// Muted by default so wallpaper videos do not take over audio output.
    public var muted: Bool = true
    /// Per-screen video output level. `muted` stays separate so unmute can
    /// restore the user's previous level instead of jumping to full volume.
    public var videoVolume: Double = 1.0
    /// Wallpaper Engine workshop origin metadata, set when the active wallpaper
    /// was imported from a `~/Documents/Live Wallpapers/<appid>/<wid>/` project.
    /// Cleared automatically when the user replaces the wallpaper with non-WPE
    /// content via the standard pickers.
    public var wpeOrigin: WPEOrigin?

    private enum CodingKeys: String, CodingKey {
        case screenID
        case activeWallpaper
        case savedVideoBookmarkData
        case savedHTMLSource
        case savedHTMLConfig
        case playbackSpeed
        case fitMode
        case videoDisplayMode
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
        case videoVolume
        case wpeOrigin

        case videoBookmarkData
        case wallpaperType
        case htmlContent
        case shaderPreset
    }

    public init(
        screenID: CGDirectDisplayID,
        wallpaper: WallpaperContent,
        playbackSpeed: Double = 1.0,
        fitMode: VideoFitMode = .aspectFill,
        videoDisplayMode: VideoDisplayMode = .perDisplay,
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
        if case .html(let source, let config) = wallpaper, source.isRestorableHTMLSource {
            self.savedHTMLSource = source
            self.savedHTMLConfig = config
        }
        self.playbackSpeed = playbackSpeed
        self.fitMode = fitMode
        self.videoDisplayMode = videoDisplayMode
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

    public init(
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

    public init(
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
        case .html, .metalShader, .scene:
            // `.scene` no longer maps to a synthetic HTML placeholder — Phase 2.0
            // ships a real renderer. This convenience initializer is still
            // hit by legacy tests and migration paths that have no descriptor;
            // they degrade to an empty video so the type-pivot UI surfaces a
            // "not configured" Scene tab instead of crashing.
            let wallpaper: WallpaperContent = switch wallpaperType {
            case .html:
                .html(source: HTMLSource(legacyString: htmlContent ?? ""), config: .default)
            case .metalShader:
                .metalShader(shaderPreset ?? .waves)
            case .video:
                .video(bookmarkData: videoBookmarkData)
            case .scene:
                .video(bookmarkData: Data())
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

    public var wallpaperType: WallpaperType {
        activeWallpaper.wallpaperType
    }

    public var videoBookmarkData: Data? {
        activeWallpaper.activeVideoBookmarkData ?? savedVideoBookmarkData
    }

    public var hasConfiguredVideoSource: Bool {
        if let bookmarkData = activeWallpaper.activeVideoBookmarkData, !bookmarkData.isEmpty {
            return true
        }
        if let savedVideoBookmarkData, !savedVideoBookmarkData.isEmpty {
            return true
        }
        return false
    }

    public var preferredVideoBookmarkData: Data? {
        videoBookmarkData
    }

    public var htmlSource: HTMLSource? {
        activeWallpaper.htmlSource
    }

    public var htmlConfig: HTMLConfig? {
        activeWallpaper.htmlConfig
    }

    /// Textual HTML payload, if the source is URL or inline HTML.
    public var htmlContent: String? {
        guard let source = activeWallpaper.htmlSource else { return nil }
        switch source {
        case .url(let url): return url.absoluteString
        case .inline(let raw): return raw
        case .file, .folder: return nil
        }
    }

    public var shaderPreset: MetalShaderPreset? {
        activeWallpaper.shaderPreset
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        screenID = try c.decode(UInt32.self, forKey: .screenID)
        playbackSpeed = try c.decodeIfPresent(Double.self, forKey: .playbackSpeed) ?? 1.0
        fitMode = try c.decodeIfPresent(VideoFitMode.self, forKey: .fitMode) ?? .aspectFill
        videoDisplayMode = try c.decodeIfPresent(VideoDisplayMode.self, forKey: .videoDisplayMode) ?? .perDisplay
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
        videoVolume = Self.clampedVideoVolume(
            try c.decodeIfPresent(Double.self, forKey: .videoVolume) ?? 1.0
        )

        if let storedMode = try c.decodeIfPresent(WallpaperMode.self, forKey: .wallpaperMode) {
            wallpaperMode = storedMode
        } else if (scheduleSlots?.isEmpty == false) {
            wallpaperMode = .schedule
        } else if (playlistBookmarks?.isEmpty == false) {
            wallpaperMode = .playlist
        } else {
            wallpaperMode = .single
        }

        savedHTMLSource = try c.decodeIfPresent(HTMLSource.self, forKey: .savedHTMLSource)
        savedHTMLConfig = try c.decodeIfPresent(HTMLConfig.self, forKey: .savedHTMLConfig)
        // Lossy decode: a malformed wpeOrigin should not invalidate the whole
        // screen configuration; fallback to nil so the wallpaper itself loads.
        wpeOrigin = (try? c.decodeIfPresent(WPEOrigin.self, forKey: .wpeOrigin)) ?? nil

        if let decodedWallpaper = try c.decodeIfPresent(WallpaperContent.self, forKey: .activeWallpaper) {
            activeWallpaper = decodedWallpaper
            savedVideoBookmarkData = try c.decodeIfPresent(Data.self, forKey: .savedVideoBookmarkData)
                ?? decodedWallpaper.activeVideoBookmarkData
            // Backfill saved HTML if absent but currently HTML.
            if savedHTMLSource == nil,
               case .html(let source, let config) = decodedWallpaper,
               source.isRestorableHTMLSource {
                savedHTMLSource = source
                savedHTMLConfig = config
            }
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
            let legacySource = HTMLSource(legacyString: legacyHTML)
            activeWallpaper = .html(source: legacySource, config: .default)
            savedVideoBookmarkData = legacySavedBookmark
            if savedHTMLSource == nil { savedHTMLSource = legacySource }
            if savedHTMLConfig == nil { savedHTMLConfig = .default }
        case .metalShader:
            activeWallpaper = .metalShader(
                try c.decodeIfPresent(MetalShaderPreset.self, forKey: .shaderPreset) ?? .waves
            )
            savedVideoBookmarkData = legacySavedBookmark
        case .scene:
            // Legacy payloads predate `WallpaperContent.scene`. Backfill from
            // wpeOrigin when the user already imported a Steam scene workshop:
            // a valid `cacheRelativePath` + `entryFile` lets us reconstruct
            // a `SceneDescriptor` (.imageOnly is the optimistic default — the
            // import service will downgrade on next reconcile if needed).
            // Otherwise fall back to an empty video so the Scene tab surfaces
            // its placeholder instead of throwing decode errors.
            if let backfilled = Self.backfillSceneFromLegacyOrigin(wpeOrigin) {
                activeWallpaper = .scene(backfilled)
                savedVideoBookmarkData = legacySavedBookmark
            } else {
                activeWallpaper = .video(bookmarkData: Data())
                savedVideoBookmarkData = legacySavedBookmark
            }
        }
    }

    /// Phase 2.0 migration: a previously-stored `wallpaperType == .scene`
    /// blob from before the `.scene(SceneDescriptor)` case existed cannot
    /// carry a descriptor in `activeWallpaper`. Reconstruct one when the
    /// sibling `wpeOrigin` has the necessary fields; otherwise return nil
    /// so the caller falls back to an empty placeholder configuration.
    private static func backfillSceneFromLegacyOrigin(_ origin: WPEOrigin?) -> SceneDescriptor? {
        guard let origin,
              origin.originalType == .scene,
              origin.resourceLocation == .cache,
              let cacheRelativePath = origin.cacheRelativePath,
              isSafeCacheRelativePath(cacheRelativePath),
              let entryFile = origin.entryFile,
              isSafeRelativePath(entryFile) else {
            return nil
        }
        return SceneDescriptor(
            workshopID: origin.workshopID,
            cacheRelativePath: cacheRelativePath,
            entryFile: entryFile,
            capabilityTier: .imageOnly,
            dependencyWorkshopIDs: origin.dependencyWorkshopIDs
        )
    }

    // Inlined predicates so the Core init doesn't pull in WPEPathSafety
    // (which still lives in the main target's Infrastructure/ folder and
    // is destined for LiveWallpaperProWPE in Phase 4).
    private static func isSafeCacheRelativePath(_ path: String) -> Bool {
        path.hasPrefix("wpe-cache/")
            && !path.contains("\\")
            && !path.contains("..")
            && !path.contains("//")
    }

    private static func isSafeRelativePath(_ value: String) -> Bool {
        !value.isEmpty
            && !value.hasPrefix("/")
            && !value.contains("..")
            && value != "."
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(screenID, forKey: .screenID)
        try c.encode(activeWallpaper, forKey: .activeWallpaper)
        try c.encodeIfPresent(savedVideoBookmarkData, forKey: .savedVideoBookmarkData)
        try c.encodeIfPresent(savedHTMLSource, forKey: .savedHTMLSource)
        try c.encodeIfPresent(savedHTMLConfig, forKey: .savedHTMLConfig)
        try c.encode(playbackSpeed, forKey: .playbackSpeed)
        try c.encode(fitMode, forKey: .fitMode)
        try c.encode(videoDisplayMode, forKey: .videoDisplayMode)
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
        try c.encode(videoVolume, forKey: .videoVolume)
        try c.encodeIfPresent(wpeOrigin, forKey: .wpeOrigin)
    }

    private static func clampedVideoVolume(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        return min(max(value, 0), 1)
    }

    public mutating func setHTMLWallpaper(source: HTMLSource, config: HTMLConfig = .default) {
        preserveCurrentVideoBookmarkIfNeeded()
        if source.isRestorableHTMLSource {
            savedHTMLSource = source
            savedHTMLConfig = config
        }
        activeWallpaper = .html(source: source, config: config)
    }

    /// Legacy URL/raw-HTML bridge.
    public mutating func setHTMLWallpaper(_ content: String) {
        setHTMLWallpaper(source: HTMLSource(legacyString: content), config: .default)
    }

    public mutating func updateHTMLConfig(_ config: HTMLConfig) {
        guard case .html(let source, _) = activeWallpaper else { return }
        savedHTMLConfig = config
        activeWallpaper = .html(source: source, config: config)
    }

    public mutating func setShaderWallpaper(_ preset: MetalShaderPreset) {
        preserveCurrentVideoBookmarkIfNeeded()
        preserveCurrentHTMLIfNeeded()
        activeWallpaper = .metalShader(preset)
    }

    @discardableResult
    public mutating func activateSavedVideoWallpaper() -> Bool {
        guard let bookmarkData = savedVideoBookmarkData ?? activeWallpaper.activeVideoBookmarkData else {
            return false
        }
        preserveCurrentHTMLIfNeeded()
        activeWallpaper = .video(bookmarkData: bookmarkData)
        savedVideoBookmarkData = bookmarkData
        // Restart playlist cursor when explicitly returning to video.
        playlistCursorIndex = 0
        return true
    }

    /// Restore the previously applied HTML source after a type swap.
    @discardableResult
    public mutating func activateSavedHTMLWallpaper() -> Bool {
        guard let source = savedHTMLSource else { return false }
        let config = savedHTMLConfig ?? .default
        preserveCurrentVideoBookmarkIfNeeded()
        activeWallpaper = .html(source: source, config: config)
        return true
    }

    /// Swap primary video while preserving per-screen settings + saved HTML.
    public mutating func replacePrimaryVideo(bookmarkData: Data) {
        preserveCurrentHTMLIfNeeded()
        savedVideoBookmarkData = bookmarkData
        activeWallpaper = .video(bookmarkData: bookmarkData)
        // Reset cursor so rotation never points past a reshuffled list.
        playlistCursorIndex = 0
    }

    /// Activates a schedule slot without replacing the saved primary video.
    public mutating func applyScheduledBookmark(_ bookmarkData: Data) {
        activeWallpaper = .video(bookmarkData: bookmarkData)
    }

    private mutating func preserveCurrentVideoBookmarkIfNeeded() {
        if savedVideoBookmarkData == nil {
            savedVideoBookmarkData = activeWallpaper.activeVideoBookmarkData
        }
    }

    private mutating func preserveCurrentHTMLIfNeeded() {
        if case .html(let source, let config) = activeWallpaper {
            savedHTMLSource = source
            savedHTMLConfig = config
        }
    }

    /// Refreshes the bookmark currently driving playback.
    public func withUpdatedActiveBookmark(_ bookmarkData: Data) -> ScreenConfiguration {
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
