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

        static let useWallpaper = String(
            localized: "panel.prompt.use_wallpaper",
            defaultValue: "Use Wallpaper",
            comment: "Confirmation button in onboarding file and folder pickers."
        )

        static let preview = String(
            localized: "panel.prompt.preview",
            defaultValue: "Preview",
            comment: "Confirmation button for previewing a selected wallpaper video."
        )

        static let importProject = String(
            localized: "panel.prompt.import_project",
            defaultValue: "Import Project",
            comment: "Confirmation button for choosing a Wallpaper Engine project folder."
        )

        static let grantAccess = String(
            localized: "panel.prompt.grant_access",
            defaultValue: "Grant Access",
            comment: "Confirmation button for granting one-time folder access."
        )

        static let grantLibraryAccess = String(
            localized: "panel.prompt.grant_library_access",
            defaultValue: "Grant Library Access",
            comment: "Confirmation button for granting access to the Wallpaper Engine library folder."
        )

        static let changeFolder = String(
            localized: "panel.prompt.change_folder",
            defaultValue: "Change Folder",
            comment: "Confirmation button for changing the selected library folder."
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

        static let workshopProjectsFolderMessage = String(
            localized: "panel.message.workshop_projects_folder",
            defaultValue: "Select your Wallpaper Engine projects folder",
            comment: "Message shown in the folder picker for choosing a Wallpaper Engine projects folder."
        )

        static let appleAerialsAccessMessage = String(
            localized: "panel.message.apple_aerials_access",
            defaultValue: "macOS requires one-time approval to read Apple's wallpaper folder. Just click \"Grant Access\" — you do not need to pick any specific file.",
            comment: "Message shown in the folder picker for granting access to Apple's wallpaper folder."
        )

        /// Returns the appropriate prompt for the Workshop library folder picker.
        static func workshopLibraryPrompt(hasLibraryRoot: Bool) -> String {
            hasLibraryRoot ? changeFolder : grantLibraryAccess
        }
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
    }
}
