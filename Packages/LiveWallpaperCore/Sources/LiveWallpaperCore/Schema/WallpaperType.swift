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
}
