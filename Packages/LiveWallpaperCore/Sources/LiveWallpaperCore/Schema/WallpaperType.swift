import SwiftUI

public enum WallpaperType: String, Codable, CaseIterable, Identifiable, Sendable {
    case video = "Video"
    case html = "HTML"
    case metalShader = "Shader"
    case scene = "Scene"

    public var id: String { rawValue }

    public var titleKey: LocalizedStringKey {
        switch self {
        case .video: return "Video"
        case .html: return "HTML"
        case .metalShader: return "Shader"
        case .scene: return "Scene"
        }
    }

    public var iconName: String {
        switch self {
        case .video: return "film"
        case .html: return "globe"
        case .metalShader: return "wand.and.stars"
        case .scene: return "cube.transparent"
        }
    }
}
