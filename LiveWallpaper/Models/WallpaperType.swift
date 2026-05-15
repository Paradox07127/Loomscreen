import SwiftUI

enum WallpaperType: String, Codable, CaseIterable, Identifiable {
    case video = "Video"
    case html = "HTML"
    case metalShader = "Shader"
    case scene = "Scene"

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .video: return "Video"
        case .html: return "HTML"
        case .metalShader: return "Shader"
        case .scene: return "Scene"
        }
    }

    var iconName: String {
        switch self {
        case .video: return "film"
        case .html: return "globe"
        case .metalShader: return "wand.and.stars"
        case .scene: return "cube.transparent"
        }
    }
}
