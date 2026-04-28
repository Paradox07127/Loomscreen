import AppKit
import Observation

@MainActor @Observable
class Screen: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
    let frame: CGRect
    let nsScreen: NSScreen

    // MARK: - Unified Runtime Session

    private(set) var runtimeSession: (any WallpaperRuntimeSession)?

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

    /// Install a new session, cleaning up the previous one immediately.
    /// Used for direct replacements (initial install, clear, or any path
    /// that does not need a visual fade-through window of overlap).
    func installRuntimeSession(_ session: any WallpaperRuntimeSession) {
        guard !isSameSession(runtimeSession, session) else { return }
        let old = runtimeSession
        handleRuntimeSessionTransition(from: old, to: session)
        runtimeSession = session
        old?.cleanup()
    }

    /// Swap to `newSession` WITHOUT cleaning up the previous session.
    /// Returns the previous session so the caller — typically
    /// `ScreenManager.transitionSession(...)` — can clean it up after the
    /// visual crossfade animation finishes.
    @discardableResult
    func stageRuntimeSessionForTransition(_ session: any WallpaperRuntimeSession) -> (any WallpaperRuntimeSession)? {
        guard !isSameSession(runtimeSession, session) else { return nil }
        let old = runtimeSession
        handleRuntimeSessionTransition(from: old, to: session)
        runtimeSession = session
        return old
    }

    func adoptRuntimeSession(from existingScreen: Screen) {
        // Adoption shares the SAME session reference between screens, so we
        // never want to cleanup the previously-held session here.
        let new = existingScreen.runtimeSession
        guard !isSameSession(runtimeSession, new) else { return }
        handleRuntimeSessionTransition(from: runtimeSession, to: new)
        runtimeSession = new
    }

    func updateRuntimeFrame(to frame: CGRect) {
        runtimeSession?.updateFrame(to: frame)
    }

    /// Tear down and release the active wallpaper session for this screen.
    func resetRuntimeSession() {
        let old = runtimeSession
        guard old != nil else { return }
        handleRuntimeSessionTransition(from: old, to: nil)
        runtimeSession = nil
        old?.cleanup()
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

}
