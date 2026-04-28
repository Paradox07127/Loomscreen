import Foundation

/// Runtime-ready wallpaper definition derived from persisted configuration.
enum WallpaperSessionDefinition: Equatable {
    case video(bookmarkData: Data)
    case html(HTMLSource, HTMLConfig)
    case metalShader(MetalShaderPreset)

    init?(configuration: ScreenConfiguration) {
        switch configuration.activeWallpaper {
        case .video(let bookmarkData):
            guard !bookmarkData.isEmpty else { return nil }
            self = .video(bookmarkData: bookmarkData)
        case .html(let source, let config):
            // Empty inline HTML means "user has not picked anything yet" —
            // surface as no-session so the runtime tears down gracefully.
            if case .inline(let raw) = source, raw.isEmpty { return nil }
            self = .html(source, config)
        case .metalShader(let preset):
            self = .metalShader(preset)
        }
    }

    func displayName(using bookmarkNameResolver: (Data) -> String?) -> String? {
        switch self {
        case .video(let bookmarkData):
            return bookmarkNameResolver(bookmarkData)
        case .html(let source, _):
            return source.displayName
        case .metalShader(let preset):
            return preset.rawValue
        }
    }
}
