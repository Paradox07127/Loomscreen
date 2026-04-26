import AppKit
import Observation

@MainActor @Observable
class Screen: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
    let frame: CGRect
    let nsScreen: NSScreen

    // MARK: - Unified Runtime Session

    private(set) var runtimeSession: (any WallpaperRuntimeSession)? {
        didSet {
            guard !isSameSession(oldValue, runtimeSession) else { return }
            // Observer transition MUST run while `oldValue` still owns its
            // player reference; teardown happens after.
            handleRuntimeSessionTransition(from: oldValue, to: runtimeSession)
            oldValue?.cleanup()
        }
    }

    var activeWallpaperWindow: NSWindow? {
        runtimeSession?.wallpaperWindow
    }

    var activeWallpaperType: WallpaperType {
        runtimeSession?.wallpaperType ?? .video
    }

    var videoPlayer: WallpaperVideoPlayer? {
        runtimeSession?.videoPlayer
    }

    var playbackController: (any WallpaperPlaybackControllable)? {
        runtimeSession as? any WallpaperPlaybackControllable
    }

    /// Incremented whenever the video player's playback state changes,
    /// triggering @Observable updates for any SwiftUI view reading it.
    var playbackStateVersion: Int = 0

    @objc private func notifyPlaybackStateChanged() {
        playbackStateVersion += 1
    }

    private func handleRuntimeSessionTransition(
        from oldSession: (any WallpaperRuntimeSession)?,
        to newSession: (any WallpaperRuntimeSession)?
    ) {
        let oldPlayer = oldSession?.videoPlayer
        let newPlayer = newSession?.videoPlayer

        if !isSameVideoPlayer(oldPlayer, newPlayer), let oldPlayer {
            NotificationCenter.default.removeObserver(
                self,
                name: WallpaperVideoPlayer.didChangePlaybackStateNotification,
                object: oldPlayer
            )
        }

        if !isSameVideoPlayer(oldPlayer, newPlayer), let newPlayer {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(notifyPlaybackStateChanged),
                name: WallpaperVideoPlayer.didChangePlaybackStateNotification,
                object: newPlayer
            )
        }

        playbackStateVersion += 1
    }

    private func isSameSession(
        _ lhs: (any WallpaperRuntimeSession)?,
        _ rhs: (any WallpaperRuntimeSession)?
    ) -> Bool {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            return ObjectIdentifier(lhs as AnyObject) == ObjectIdentifier(rhs as AnyObject)
        case (nil, nil):
            return true
        default:
            return false
        }
    }

    private func isSameVideoPlayer(_ lhs: WallpaperVideoPlayer?, _ rhs: WallpaperVideoPlayer?) -> Bool {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            return lhs === rhs
        case (nil, nil):
            return true
        default:
            return false
        }
    }

    var wallpaperSessionSummary: WallpaperSessionSummary {
        _ = playbackStateVersion
        return runtimeSession?.summary ?? .notConfigured
    }

    func installRuntimeSession(_ session: any WallpaperRuntimeSession) {
        // Setter's `didSet` cleans up the previous session AFTER the observer
        // transition runs, so do not pre-clean here — that nils the old
        // player and breaks observer removal.
        runtimeSession = session
    }

    func clearWallpaperRuntimeSession() {
        runtimeSession = nil
    }

    func adoptRuntimeSession(from existingScreen: Screen) {
        runtimeSession = existingScreen.runtimeSession
    }

    func updateRuntimeFrame(to frame: CGRect) {
        runtimeSession?.updateFrame(to: frame)
    }

    func resetRuntimeSession() {
        clearWallpaperRuntimeSession()
    }
    
    // MARK: - Initialization

    init(nsScreen: NSScreen) {
        self.nsScreen = nsScreen
        self.frame = nsScreen.frame

        // Get display ID safely with fallback.
        // `abs(Int.min)` would trap, so we bit-truncate into UInt32 instead —
        // the exact value doesn't matter, only that it's deterministic per screen.
        self.id = (nsScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32)
            ?? UInt32(truncatingIfNeeded: Self.generateFallbackID(for: nsScreen))

        // Get screen name with fallback
        let screenName = nsScreen.localizedName
        self.name = screenName.isEmpty
            ? "Display \(Int(frame.width))x\(Int(frame.height)) at (\(Int(frame.origin.x)),\(Int(frame.origin.y)))"
            : screenName
    }

    private static func generateFallbackID(for screen: NSScreen) -> Int {
        String(format: "%d-%d-%.0f-%.0f",
               Int(screen.frame.origin.x),
               Int(screen.frame.origin.y),
               screen.frame.width,
               screen.frame.height).hash
    }

    // MARK: - Hashable

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    nonisolated static func == (lhs: Screen, rhs: Screen) -> Bool {
        lhs.id == rhs.id
    }

    // MARK: - Cleanup

    nonisolated deinit {}
}
