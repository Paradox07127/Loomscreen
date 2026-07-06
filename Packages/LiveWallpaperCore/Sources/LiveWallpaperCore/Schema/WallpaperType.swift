import SwiftUI

public enum WallpaperType: String, Codable, CaseIterable, Identifiable, Sendable {
    case video = "Video"
    case html = "HTML"
    case metalShader = "Shader"
    case scene = "Scene"
    case monitor = "Monitor"

    public var id: String { rawValue }

    public var titleKey: LocalizedStringKey {
        switch self {
        case .video: return "Video"
        case .html: return "Web"
        case .metalShader: return "Shader"
        case .scene: return "Scene"
        case .monitor: return "Monitor"
        }
    }

    public var iconName: String {
        switch self {
        case .video: return "film"
        case .html: return "globe"
        case .metalShader: return "wand.and.stars"
        case .scene: return "cube.transparent"
        case .monitor: return "gauge.with.dots.needle.67percent"
        }
    }
}
