import Foundation

public enum AppError: LocalizedError, Equatable {
    case fileAccessDenied(String)
    case wpePackageInvalid(String)
    case wpeImportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .fileAccessDenied(let name):
            return String(
                localized: "error.app.file_access_denied",
                defaultValue: "Cannot access \"\(name)\"",
                comment: "Error shown when the app cannot access a selected wallpaper file."
            )
        case .wpePackageInvalid(let detail):
            return String(
                localized: "error.app.wpe_package_invalid",
                defaultValue: "Invalid Wallpaper Engine package: \(detail)",
                comment: "Error shown when a Wallpaper Engine package is invalid."
            )
        case .wpeImportFailed(let detail):
            return String(
                localized: "error.app.wpe_import_failed",
                defaultValue: "Wallpaper Engine import failed: \(detail)",
                comment: "Error shown when importing a Wallpaper Engine package fails."
            )
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .fileAccessDenied:
            return String(
                localized: "error.app.file_access_denied.recovery",
                defaultValue: "Try selecting the file again",
                comment: "Recovery suggestion for file access errors."
            )
        case .wpePackageInvalid:
            return String(
                localized: "error.app.wpe_package_invalid.recovery",
                defaultValue: "Try re-downloading from Steam Workshop",
                comment: "Recovery suggestion for invalid Wallpaper Engine packages."
            )
        case .wpeImportFailed:
            return String(
                localized: "error.app.wpe_import_failed.recovery",
                defaultValue: "Re-select the workshop folder and try again",
                comment: "Recovery suggestion for Wallpaper Engine import failures."
            )
        }
    }
}
