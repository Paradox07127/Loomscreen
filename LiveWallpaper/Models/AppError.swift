import Foundation

/// Centralized error type for user-facing errors.
enum AppError: LocalizedError, Equatable {
    case fileAccessDenied(String)
    case videoNotPlayable(String)
    case configurationSaveFailed
    case effectsPipelineFailed(String)
    case shaderLoadFailed
    case htmlLoadFailed(String)
    case wpePackageInvalid(String)
    case wpeUnsupportedType(String)
    case wpeImportFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileAccessDenied(let name):
            return String(
                localized: "error.app.file_access_denied",
                defaultValue: "Cannot access \"\(name)\"",
                comment: "Error shown when the app cannot access a selected wallpaper file."
            )
        case .videoNotPlayable(let name):
            return String(
                localized: "error.app.video_not_playable",
                defaultValue: "\"\(name)\" is not playable",
                comment: "Error shown when a selected video cannot be played."
            )
        case .configurationSaveFailed:
            return String(
                localized: "error.app.configuration_save_failed",
                defaultValue: "Failed to save configuration",
                comment: "Error shown when app settings cannot be saved."
            )
        case .effectsPipelineFailed(let detail):
            return String(
                localized: "error.app.effects_pipeline_failed",
                defaultValue: "Effects error: \(detail)",
                comment: "Error shown when the video effects pipeline fails."
            )
        case .shaderLoadFailed:
            return String(
                localized: "error.app.shader_load_failed",
                defaultValue: "Failed to load shader wallpaper",
                comment: "Error shown when a shader wallpaper cannot be loaded."
            )
        case .htmlLoadFailed(let url):
            return String(
                localized: "error.app.html_load_failed",
                defaultValue: "Failed to load web content: \(url)",
                comment: "Error shown when an HTML wallpaper cannot be loaded."
            )
        case .wpePackageInvalid(let detail):
            return String(
                localized: "error.app.wpe_package_invalid",
                defaultValue: "Invalid Wallpaper Engine package: \(detail)",
                comment: "Error shown when a Wallpaper Engine package is invalid."
            )
        case .wpeUnsupportedType(let kind):
            return String(
                localized: "error.app.wpe_unsupported_type",
                defaultValue: "Wallpaper Engine \"\(kind)\" type is not supported",
                comment: "Error shown when a Wallpaper Engine package type is unsupported."
            )
        case .wpeImportFailed(let detail):
            return String(
                localized: "error.app.wpe_import_failed",
                defaultValue: "Wallpaper Engine import failed: \(detail)",
                comment: "Error shown when importing a Wallpaper Engine package fails."
            )
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .fileAccessDenied:
            return String(
                localized: "error.app.file_access_denied.recovery",
                defaultValue: "Try selecting the file again",
                comment: "Recovery suggestion for file access errors."
            )
        case .videoNotPlayable:
            return String(
                localized: "error.app.video_not_playable.recovery",
                defaultValue: "The file format may not be supported",
                comment: "Recovery suggestion for unsupported video files."
            )
        case .configurationSaveFailed:
            return String(
                localized: "error.app.configuration_save_failed.recovery",
                defaultValue: "Try restarting the app",
                comment: "Recovery suggestion for configuration save failures."
            )
        case .effectsPipelineFailed:
            return String(
                localized: "error.app.effects_pipeline_failed.recovery",
                defaultValue: "Try disabling effects",
                comment: "Recovery suggestion for video effects failures."
            )
        case .shaderLoadFailed:
            return String(
                localized: "error.app.shader_load_failed.recovery",
                defaultValue: "Your GPU may not support this shader",
                comment: "Recovery suggestion for shader wallpaper load failures."
            )
        case .htmlLoadFailed:
            return String(
                localized: "error.app.html_load_failed.recovery",
                defaultValue: "Check the URL and try again",
                comment: "Recovery suggestion for HTML wallpaper load failures."
            )
        case .wpePackageInvalid:
            return String(
                localized: "error.app.wpe_package_invalid.recovery",
                defaultValue: "Try re-downloading from Steam Workshop",
                comment: "Recovery suggestion for invalid Wallpaper Engine packages."
            )
        case .wpeUnsupportedType:
            return String(
                localized: "error.app.wpe_unsupported_type.recovery",
                defaultValue: "Look for a video version of this wallpaper",
                comment: "Recovery suggestion for unsupported Wallpaper Engine package types."
            )
        case .wpeImportFailed:
            return String(
                localized: "error.app.wpe_import_failed.recovery",
                defaultValue: "Re-select the workshop folder and try again",
                comment: "Recovery suggestion for Wallpaper Engine import failures."
            )
        }
    }

    // Equatable: compare by case + payload (not localized text), so locale changes
    // don't break @Observable change detection.
    //
    // We delegate to an exhaustive `comparisonKey` switch so adding a new case
    // forces a compile-time update here (no `default` fallthrough hiding gaps).
    private var comparisonKey: ComparisonKey {
        switch self {
        case .fileAccessDenied(let s):       return .fileAccessDenied(s)
        case .videoNotPlayable(let s):       return .videoNotPlayable(s)
        case .configurationSaveFailed:       return .configurationSaveFailed
        case .effectsPipelineFailed(let s):  return .effectsPipelineFailed(s)
        case .shaderLoadFailed:              return .shaderLoadFailed
        case .htmlLoadFailed(let s):         return .htmlLoadFailed(s)
        case .wpePackageInvalid(let s):      return .wpePackageInvalid(s)
        case .wpeUnsupportedType(let s):     return .wpeUnsupportedType(s)
        case .wpeImportFailed(let s):        return .wpeImportFailed(s)
        }
    }

    private enum ComparisonKey: Equatable {
        case fileAccessDenied(String)
        case videoNotPlayable(String)
        case configurationSaveFailed
        case effectsPipelineFailed(String)
        case shaderLoadFailed
        case htmlLoadFailed(String)
        case wpePackageInvalid(String)
        case wpeUnsupportedType(String)
        case wpeImportFailed(String)
    }

    static func == (lhs: AppError, rhs: AppError) -> Bool {
        lhs.comparisonKey == rhs.comparisonKey
    }
}
