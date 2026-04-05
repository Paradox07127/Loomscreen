import Foundation
import AVKit

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
