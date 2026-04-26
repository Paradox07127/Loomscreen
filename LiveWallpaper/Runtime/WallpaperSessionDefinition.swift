import Foundation

enum HTMLWallpaperSource: Equatable {
    case remoteURL(URL)
    case localFile(URL)
    case inlineHTML(String)

    init(rawValue: String) {
        if let url = URL(string: rawValue), let scheme = url.scheme, scheme.hasPrefix("http") {
            self = .remoteURL(url)
        } else if FileManager.default.fileExists(atPath: rawValue) {
            self = .localFile(URL(fileURLWithPath: rawValue))
        } else {
            self = .inlineHTML(rawValue)
        }
    }

    var displayName: String {
        switch self {
        case .remoteURL(let url):
            return url.host ?? url.absoluteString
        case .localFile(let url):
            return url.lastPathComponent
        case .inlineHTML:
            return "Inline HTML"
        }
    }
}

enum WallpaperSessionDefinition: Equatable {
    case video(bookmarkData: Data)
    case html(HTMLWallpaperSource)
    case metalShader(MetalShaderPreset)

    init?(configuration: ScreenConfiguration) {
        switch configuration.activeWallpaper {
        case .video(let bookmarkData):
            self = .video(bookmarkData: bookmarkData)
        case .html(let htmlContent):
            guard !htmlContent.isEmpty else {
                return nil
            }
            self = .html(HTMLWallpaperSource(rawValue: htmlContent))
        case .metalShader(let preset):
            self = .metalShader(preset)
        }
    }

    func displayName(using bookmarkNameResolver: (Data) -> String?) -> String? {
        switch self {
        case .video(let bookmarkData):
            return bookmarkNameResolver(bookmarkData)
        case .html(let source):
            return source.displayName
        case .metalShader(let preset):
            return preset.rawValue
        }
    }
}
