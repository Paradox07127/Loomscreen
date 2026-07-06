import Foundation

/// Runtime-ready wallpaper definition derived from persisted configuration.
public enum WallpaperSessionDefinition: Equatable, Sendable {
    /// `packageEntryName` is non-nil for an in-place packaged video, where
    /// `bookmarkData` resolves to a `scene.pkg` and the player serves the
    /// entry windowed from the package (mirrors `WallpaperContent.video`).
    case video(bookmarkData: Data, packageEntryName: String?)
    case html(HTMLSource, HTMLConfig)
    case metalShader(ShaderSource)
    case scene(SceneDescriptor)
    case monitor(MonitorWallpaperConfiguration)

    public static func video(bookmarkData: Data) -> WallpaperSessionDefinition {
        .video(bookmarkData: bookmarkData, packageEntryName: nil)
    }

    public init?(configuration: ScreenConfiguration) {
        switch configuration.activeWallpaper {
        case .video(let bookmarkData, let packageEntryName):
            guard !bookmarkData.isEmpty else { return nil }
            self = .video(bookmarkData: bookmarkData, packageEntryName: packageEntryName)
        case .html(let source, let config):
            if case .inline(let raw) = source, raw.isEmpty { return nil }
            self = .html(source, config)
        case .metalShader(let shaderSource):
            self = .metalShader(shaderSource)
        case .scene(let descriptor):
            guard !descriptor.workshopID.isEmpty,
                  !descriptor.cacheRelativePath.isEmpty,
                  !descriptor.entryFile.isEmpty else { return nil }
            self = .scene(descriptor)
        case .monitor(let config):
            self = .monitor(config)
        }
    }

    public func displayName(using bookmarkNameResolver: (Data) -> String?) -> String? {
        switch self {
        case .video(let bookmarkData, _):
            return bookmarkNameResolver(bookmarkData)
        case .html(let source, _):
            return source.displayName
        case .metalShader(let shaderSource):
            switch shaderSource {
            case .builtin(let preset): return preset.rawValue
            case .custom(let id):      return "Custom (\(id.uuidString.prefix(8)))"
            }
        case .scene(let descriptor):
            return "Scene \(descriptor.workshopID)"
        case .monitor:
            return "Monitor"
        }
    }
}
