import AppKit
import Foundation

enum WPEFolderPicker {
    @MainActor
    static func chooseImportFolder() -> URL? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.Panel.importProject
        panel.directoryURL = defaultImportDirectory()
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private static func defaultImportDirectory() -> URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let liveWallpapers = docs.appendingPathComponent("Live Wallpapers")
        guard FileManager.default.fileExists(atPath: liveWallpapers.path) else { return nil }
        return liveWallpapers
    }
}
