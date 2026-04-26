import Foundation

enum WallpaperContent: Codable, Equatable {
    case video(bookmarkData: Data)
    case html(String)
    case metalShader(MetalShaderPreset)

    var wallpaperType: WallpaperType {
        switch self {
        case .video:
            return .video
        case .html:
            return .html
        case .metalShader:
            return .metalShader
        }
    }

    var activeVideoBookmarkData: Data? {
        guard case .video(let bookmarkData) = self else { return nil }
        return bookmarkData
    }

    var htmlContent: String? {
        guard case .html(let content) = self else { return nil }
        return content
    }

    var shaderPreset: MetalShaderPreset? {
        guard case .metalShader(let preset) = self else { return nil }
        return preset
    }
}
