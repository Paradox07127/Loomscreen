import Foundation
import AVKit

// Utilities to help with resource management and common operations
class ResourceUtilities {
    // MARK: - Security-Scoped Bookmarks
    
    // Create a security-scoped bookmark from a URL
    // - Returns: Bookmark data or nil if failed
    static func createBookmark(for url: URL) -> Data? {
        do {
            let _ = PerformanceTimer(description: "Create bookmark", category: .fileAccess)
            let bookmarkData = try url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: [
                    .isReadableKey,
                    .fileSizeKey,
                    .contentTypeKey
                ],
                relativeTo: nil
            )
            Logger.debug("Created security-scoped bookmark for: \(url.lastPathComponent)", category: .fileAccess)
            return bookmarkData
        } catch {
            Logger.error("Failed to create bookmark: \(error.localizedDescription)", category: .fileAccess)
            return nil
        }
    }
    
    // Access a security-scoped resource using bookmark data
    // - Returns: A tuple containing the URL (if successful) and a cleanup function
    static func accessSecurityScopedResource(bookmarkData: Data) -> (url: URL?, cleanup: () -> Void) {
        var cleanup: () -> Void = {}
        
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            
            if isStale {
                Logger.warning("Stale bookmark detected for: \(url.lastPathComponent)", category: .fileAccess)
            }
            
            // Start accessing the resource
            let hasAccess = url.startAccessingSecurityScopedResource()
            
            if hasAccess {
                Logger.debug("Started accessing security-scoped resource: \(url.lastPathComponent)", category: .fileAccess)
                cleanup = {
                    url.stopAccessingSecurityScopedResource()
                    Logger.debug("Stopped accessing security-scoped resource: \(url.lastPathComponent)", category: .fileAccess)
                }
                return (url, cleanup)
            } else {
                Logger.error("Failed to access security-scoped resource: \(url.lastPathComponent)", category: .fileAccess)
                return (nil, cleanup)
            }
        } catch {
            Logger.error("Failed to resolve bookmark: \(error.localizedDescription)", category: .fileAccess)
            return (nil, cleanup)
        }
    }
    
    // MARK: - AVPlayer utilities
    
    // Create an AVPlayer from a URL with proper setup
    static func createPlayer(from url: URL, looping: Bool = true, volume: Float = 0.0) -> AVPlayer? {
        let asset = AVURLAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)
        
        // Set up quality of service for better performance
        playerItem.preferredForwardBufferDuration = 5.0
        
        // Configure player
        let player = AVPlayer(playerItem: playerItem)
        player.automaticallyWaitsToMinimizeStalling = true
        player.volume = volume
        player.allowsExternalPlayback = false // Optimization to prevent AirPlay detection
        
        // Set up looping if requested
        if looping {
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: playerItem,
                queue: .main
            ) { _ in
                player.seek(to: .zero)
                player.play()
            }
        }
        
        return player
    }
    
    // Create a preview player for the settings UI
    static func createPreviewPlayer(from bookmarkData: Data) -> AVPlayer? {
        let (url, cleanup) = accessSecurityScopedResource(bookmarkData: bookmarkData)
        defer { cleanup() }
        
        guard let url = url else { return nil }
        
        return createPlayer(from: url)
    }
    
    // MARK: - NSOpenPanel Configuration
    
    // Configure an NSOpenPanel for video selection
    static func configureVideoOpenPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.movie]
        panel.title = "Select Video for Wallpaper"
        panel.prompt = "Choose Video"
        panel.message = "Select a video file to use as your desktop wallpaper"
        
        // Try to use the last directory
        if let lastDirectory = SettingsManager.shared.getLastUsedDirectory() {
            panel.directoryURL = lastDirectory
        }
        
        return panel
    }
}
