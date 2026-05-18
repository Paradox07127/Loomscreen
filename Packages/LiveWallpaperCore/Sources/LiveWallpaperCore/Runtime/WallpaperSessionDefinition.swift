import Foundation

/// Runtime-ready wallpaper definition derived from persisted configuration.
public enum WallpaperSessionDefinition: Equatable, Sendable {
    case video(bookmarkData: Data)
    case html(HTMLSource, HTMLConfig)
    case metalShader(MetalShaderPreset)
    case scene(SceneDescriptor)

    public init?(configuration: ScreenConfiguration) {
        switch configuration.activeWallpaper {
        case .video(let bookmarkData):
            guard !bookmarkData.isEmpty else { return nil }
            self = .video(bookmarkData: bookmarkData)
        case .html(let source, let config):
            if case .inline(let raw) = source, raw.isEmpty { return nil }
            self = .html(source, config)
        case .metalShader(let preset):
            self = .metalShader(preset)
        case .scene(let descriptor):
            guard !descriptor.workshopID.isEmpty,
                  !descriptor.cacheRelativePath.isEmpty,
                  !descriptor.entryFile.isEmpty else { return nil }
            self = .scene(descriptor)
        }
    }

    public func displayName(using bookmarkNameResolver: (Data) -> String?) -> String? {
        switch self {
        case .video(let bookmarkData):
            return bookmarkNameResolver(bookmarkData)
        case .html(let source, _):
            return source.displayName
        case .metalShader(let preset):
            return preset.rawValue
        case .scene(let descriptor):
            return "Scene \(descriptor.workshopID)"
        }
    }
}
