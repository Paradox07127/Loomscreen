import Foundation

/// Centralized error type for user-facing errors.
enum AppError: LocalizedError, Equatable {
    case fileAccessDenied(String)
    case videoNotPlayable(String)
    case configurationSaveFailed
    case effectsPipelineFailed(String)
    case shaderLoadFailed
    case htmlLoadFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileAccessDenied(let name): return "Cannot access \"\(name)\""
        case .videoNotPlayable(let name): return "\"\(name)\" is not playable"
        case .configurationSaveFailed: return "Failed to save configuration"
        case .effectsPipelineFailed(let detail): return "Effects error: \(detail)"
        case .shaderLoadFailed: return "Failed to load shader wallpaper"
        case .htmlLoadFailed(let url): return "Failed to load web content: \(url)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .fileAccessDenied: return "Try selecting the file again"
        case .videoNotPlayable: return "The file format may not be supported"
        case .configurationSaveFailed: return "Try restarting the app"
        case .effectsPipelineFailed: return "Try disabling effects"
        case .shaderLoadFailed: return "Your GPU may not support this shader"
        case .htmlLoadFailed: return "Check the URL and try again"
        }
    }

    // Equatable conformance for @Observable change detection
    static func == (lhs: AppError, rhs: AppError) -> Bool {
        lhs.errorDescription == rhs.errorDescription
    }
}
