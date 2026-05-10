import CoreGraphics
import Foundation

struct ScreenConfiguration: Codable, Equatable {
    /// Mutable so `ScreenManager.applyConfigurationToAllDisplays` can clone
    /// a template for every other screen without recomposing each field.
    var screenID: UInt32
    var activeWallpaper: WallpaperContent
    var savedVideoBookmarkData: Data?
    /// Last applied HTML source — restored on type switch back to HTML.
    var savedHTMLSource: HTMLSource?
    var savedHTMLConfig: HTMLConfig?
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
    /// Wallpaper Engine workshop origin metadata, set when the active wallpaper
    /// was imported from a `~/Documents/Live Wallpapers/<appid>/<wid>/` project.
    /// Cleared automatically when the user replaces the wallpaper with non-WPE
    /// content via the standard pickers.
    var wpeOrigin: WPEOrigin?

    private enum CodingKeys: String, CodingKey {
        case screenID
        case activeWallpaper
        case savedVideoBookmarkData
        case savedHTMLSource
        case savedHTMLConfig
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
        case wpeOrigin

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
        if case .html(let source, let config) = wallpaper {
            self.savedHTMLSource = source
            self.savedHTMLConfig = config
        }
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
            if savedHTMLSource == nil, case .html(let source, let config) = decodedWallpaper {
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
              WPEPathSafety.isSafeCacheRelativePath(cacheRelativePath),
              let entryFile = origin.entryFile,
              WPEPathSafety.isSafeRelativePath(entryFile) else {
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

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(screenID, forKey: .screenID)
        try c.encode(activeWallpaper, forKey: .activeWallpaper)
        try c.encodeIfPresent(savedVideoBookmarkData, forKey: .savedVideoBookmarkData)
        try c.encodeIfPresent(savedHTMLSource, forKey: .savedHTMLSource)
        try c.encodeIfPresent(savedHTMLConfig, forKey: .savedHTMLConfig)
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
        try c.encodeIfPresent(wpeOrigin, forKey: .wpeOrigin)
    }

    mutating func setHTMLWallpaper(source: HTMLSource, config: HTMLConfig = .default) {
        preserveCurrentVideoBookmarkIfNeeded()
        savedHTMLSource = source
        savedHTMLConfig = config
        activeWallpaper = .html(source: source, config: config)
    }

    /// Legacy URL/raw-HTML bridge.
    mutating func setHTMLWallpaper(_ content: String) {
        setHTMLWallpaper(source: HTMLSource(legacyString: content), config: .default)
    }

    mutating func updateHTMLConfig(_ config: HTMLConfig) {
        guard case .html(let source, _) = activeWallpaper else { return }
        savedHTMLConfig = config
        activeWallpaper = .html(source: source, config: config)
    }

    mutating func setShaderWallpaper(_ preset: MetalShaderPreset) {
        preserveCurrentVideoBookmarkIfNeeded()
        preserveCurrentHTMLIfNeeded()
        activeWallpaper = .metalShader(preset)
    }

    @discardableResult
    mutating func activateSavedVideoWallpaper() -> Bool {
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
    mutating func activateSavedHTMLWallpaper() -> Bool {
        guard let source = savedHTMLSource else { return false }
        let config = savedHTMLConfig ?? .default
        preserveCurrentVideoBookmarkIfNeeded()
        activeWallpaper = .html(source: source, config: config)
        return true
    }

    /// Swap primary video while preserving per-screen settings + saved HTML.
    mutating func replacePrimaryVideo(bookmarkData: Data) {
        preserveCurrentHTMLIfNeeded()
        savedVideoBookmarkData = bookmarkData
        activeWallpaper = .video(bookmarkData: bookmarkData)
        // Reset cursor so rotation never points past a reshuffled list.
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

    private mutating func preserveCurrentHTMLIfNeeded() {
        if case .html(let source, let config) = activeWallpaper {
            savedHTMLSource = source
            savedHTMLConfig = config
        }
    }

    /// Clears `wpeOrigin` when the active wallpaper no longer points inside
    /// the WPE cache. Called by `ScreenManager` whenever the user mutates the
    /// active wallpaper (`setVideo` / `setHTMLWallpaper` / `setShaderWallpaper`)
    /// so the WPE badge stops claiming ownership of non-WPE content.
    /// Plan §A11: switching to Shader is treated as a transient state — the
    /// origin is preserved so switching back to Video/HTML restores the badge.
    mutating func reconcileWPEOrigin() {
        guard let origin = wpeOrigin else { return }
        guard origin.resourceLocation != .unsupported else {
            wpeOrigin = nil
            return
        }

        switch activeWallpaper {
        case .video(let bookmarkData):
            if !WPEOrigin.matchesBookmark(bookmarkData, origin: origin) {
                wpeOrigin = nil
            }
        case .html(let source, _):
            guard case .folder(let bookmarkData, _) = source,
                  WPEOrigin.matchesBookmark(bookmarkData, origin: origin) else {
                wpeOrigin = nil
                return
            }
        case .metalShader:
            return
        case .scene(let descriptor):
            // Scene content is cache-backed and identified by workshopID +
            // cacheRelativePath. Drop the origin only if either side disagrees
            // with the persisted descriptor (e.g. user re-imported a different
            // workshop project in-place).
            guard origin.workshopID == descriptor.workshopID,
                  origin.cacheRelativePath == descriptor.cacheRelativePath else {
                wpeOrigin = nil
                return
            }
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
