import Foundation
import AVKit

@MainActor
class ResourceUtilities {
    // MARK: - Security-Scoped Bookmarks

    static func createBookmark(for url: URL) -> Data? {
        do {
            return try url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: [.isReadableKey, .fileSizeKey, .contentTypeKey],
                relativeTo: nil
            )
        } catch {
            Logger.error("Failed to create bookmark: \(error.localizedDescription)", category: .fileAccess)
            return nil
        }
    }

    // MARK: - Bookmark Resolution

    /// Resolves a security-scoped bookmark to a file name.
    /// Used by ScheduleSection, PlaylistSection, and StatusBarController
    /// to display the video's last path component without duplicating
    /// the resolution boilerplate.
    static func resolveBookmarkName(_ data: Data) -> String? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        return url.lastPathComponent
    }

    // MARK: - NSOpenPanel Configuration

    static func configureVideoOpenPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.movie]
        panel.title = "Select Video for Wallpaper"
        panel.prompt = "Choose Video"
        panel.message = "Select a video file to use as your desktop wallpaper"

        if let lastDirectory = SettingsManager.shared.getLastUsedDirectory() {
            panel.directoryURL = lastDirectory
        }

        return panel
    }
}
