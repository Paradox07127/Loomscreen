import AppKit

class VideoWallpaperWindow: NSWindow {
    init(frame: CGRect) {
        super.init(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: true
        )
        
        // Essential settings
        isOpaque = false
        backgroundColor = .clear
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        ignoresMouseEvents = true
        
        // Additional optimizations
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        disableSnapshotRestoration()
    }
}
