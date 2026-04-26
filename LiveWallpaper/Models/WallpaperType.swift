enum WallpaperType: String, Codable, CaseIterable, Identifiable {
    case video = "Video"
    case html = "HTML"
    case metalShader = "Shader"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .video: return "film"
        case .html: return "globe"
        case .metalShader: return "wand.and.stars"
        }
    }
}
