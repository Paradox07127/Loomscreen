import Foundation

/// Centralized localized strings for AppKit-bridged surfaces (NSOpenPanel, NSWindow, NSMenu)
/// where SwiftUI's automatic LocalizedStringKey resolution is unavailable.
///
/// Naming convention: `<bucket>.<scope>.<descriptor>` (snake_case).
/// Buckets in use: `panel.prompt.*`, `panel.message.*`, `window.title.*`.
enum L10n {
    enum Panel {
        static let useAsWallpaper = String(
            localized: "panel.prompt.use_as_wallpaper",
            defaultValue: "Use as Wallpaper",
            comment: "Confirmation button in file pickers for applying a selected file as wallpaper."
        )

        static let importProject = String(
            localized: "panel.prompt.import_project",
            defaultValue: "Apply Project",
            comment: "Confirmation button for choosing and applying a copied local project folder."
        )

        static let grantAccess = String(
            localized: "panel.prompt.grant_access",
            defaultValue: "Grant Access",
            comment: "Confirmation button for granting one-time folder access."
        )

        static let addVideos = String(
            localized: "panel.prompt.add_videos",
            defaultValue: "Add Videos",
            comment: "Confirmation button for adding selected videos to a playlist."
        )

        static let setVideo = String(
            localized: "panel.prompt.set_video",
            defaultValue: "Set Video",
            comment: "Confirmation button for assigning a selected video to a schedule slot."
        )

        static let appleAerialsAccessMessage = String(
            localized: "panel.message.apple_aerials_access",
            defaultValue: "macOS requires one-time approval to read Apple's wallpaper folder. Just click \"Grant Access\" — you do not need to pick any specific file.",
            comment: "Message shown in the folder picker for granting access to Apple's wallpaper folder."
        )
    }

    enum Window {
        static let settingsTitle = String(
            localized: "window.title.settings",
            defaultValue: "LiveWallpaper Settings",
            comment: "Title of the LiveWallpaper settings window."
        )
    }

    enum Toolbar {
        static let preferences = String(
            localized: "toolbar.preferences",
            defaultValue: "Preferences",
            comment: "Settings window toolbar button for opening general preferences."
        )
        static let addWallpaper = String(
            localized: "toolbar.addWallpaper",
            defaultValue: "Add wallpaper",
            comment: "Settings window toolbar button that opens a video picker for the selected display."
        )
    }
}
