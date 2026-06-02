import Foundation
import LiveWallpaperCore

/// In-flight, view-local mirror of every `ScreenConfiguration` field bound
/// to inspector controls. Consolidates 21 `@State` properties so a screen
/// switch can re-fan the view from a single atomic assignment — closing
/// the C3 finding where the previous "no-config" branch missed
/// `videoColorSpace`, `selectedShaderSource`, and `hasPreviewSource` resets.
struct ScreenDetailDraftState: Sendable, Equatable {
    var playbackSpeed: Double
    var selectedFitMode: VideoFitMode
    var selectedVideoDisplayMode: VideoDisplayMode
    var selectedWallpaperType: WallpaperType
    var selectedWallpaperMode: WallpaperMode
    var selectedParticleEffect: ParticleEffect
    var effectConfig: VideoEffectConfig
    var selectedShaderSource: ShaderSource
    var htmlSource: HTMLSource?
    var htmlConfig: HTMLConfig
    var wpeOrigin: WPEOrigin?
    var setAsLockScreen: Bool
    var playlistBookmarks: [Data]
    var shufflePlaylist: Bool
    var playlistRotationMinutes: Int?
    var scheduleSlots: [ScheduleSlot]
    var videoMuted: Bool
    var videoVolume: Double
    var videoColorSpace: VideoColorSpace
    var particleDensity: Double
    var selectedFrameRateLimit: FrameRateLimit
    /// Scene-only "Mouse Interaction" toggle (cursor-driven parallax / pointer
    /// shaders). Mirrors `ScreenConfiguration.sceneMouseInteractionEnabled`.
    var sceneMouseInteractionEnabled: Bool
    var hasPreviewSource: Bool
    /// Mirror of `WallpaperContent.scene(descriptor)` so the right-hand
    /// inspector can bind property overrides without round-tripping
    /// through the persistence store on every keystroke. Nil for non-
    /// scene wallpaper types.
    var sceneDescriptor: SceneDescriptor?

    static let `default` = ScreenDetailDraftState(
        playbackSpeed: 1.0,
        selectedFitMode: .aspectFill,
        selectedVideoDisplayMode: .perDisplay,
        selectedWallpaperType: .video,
        selectedWallpaperMode: .playlist,
        selectedParticleEffect: .none,
        effectConfig: .default,
        selectedShaderSource: .builtin(.waves),
        htmlSource: nil,
        htmlConfig: .default,
        wpeOrigin: nil,
        setAsLockScreen: false,
        playlistBookmarks: [],
        shufflePlaylist: false,
        playlistRotationMinutes: nil,
        scheduleSlots: [],
        videoMuted: true,
        videoVolume: 1.0,
        videoColorSpace: .auto,
        particleDensity: 1.0,
        selectedFrameRateLimit: .fps60,
        sceneMouseInteractionEnabled: true,
        hasPreviewSource: false,
        sceneDescriptor: nil
    )

    /// Maps a `ScreenConfiguration` onto a draft snapshot. When `config`
    /// is nil the result equals `.default` except `hasPreviewSource`, which
    /// follows the caller-supplied fallback (typically
    /// `screen.videoPlayer?.videoURL != nil` so we don't flash an empty
    /// state while the runtime player is still alive).
    static func from(
        config: ScreenConfiguration?,
        fallbackHasPreviewSource: Bool
    ) -> ScreenDetailDraftState {
        guard let config else {
            var state = Self.default
            state.hasPreviewSource = fallbackHasPreviewSource
            return state
        }

        return ScreenDetailDraftState(
            playbackSpeed: config.playbackSpeed,
            selectedFitMode: config.fitMode,
            selectedVideoDisplayMode: config.videoDisplayMode,
            selectedWallpaperType: config.wallpaperType,
            selectedWallpaperMode: config.wallpaperMode,
            selectedParticleEffect: config.particleEffect,
            effectConfig: config.effectConfig,
            selectedShaderSource: config.activeWallpaper.shaderSource ?? Self.default.selectedShaderSource,
            htmlSource: config.htmlSource,
            htmlConfig: config.htmlConfig ?? .default,
            wpeOrigin: config.wpeOrigin,
            setAsLockScreen: config.setAsLockScreen,
            playlistBookmarks: config.playlistBookmarks ?? [],
            shufflePlaylist: config.shufflePlaylist,
            playlistRotationMinutes: config.playlistRotationMinutes,
            scheduleSlots: config.scheduleSlots ?? [],
            videoMuted: config.muted,
            videoVolume: config.videoVolume,
            videoColorSpace: config.videoColorSpace,
            particleDensity: config.effectConfig.particleDensity,
            selectedFrameRateLimit: config.frameRateLimit,
            sceneMouseInteractionEnabled: config.sceneMouseInteractionEnabled,
            hasPreviewSource: config.wallpaperType == .video && config.hasConfiguredVideoSource,
            sceneDescriptor: config.activeWallpaper.sceneDescriptor
        )
    }
}
