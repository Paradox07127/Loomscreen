enum WallpaperType: String, Codable, CaseIterable, Identifiable {
    case video = "Video"
    case html = "HTML"
    case metalShader = "Shader"
    case scene = "Scene"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .video: return "film"
        case .html: return "globe"
        case .metalShader: return "wand.and.stars"
        case .scene: return "cube.transparent"
        }
    }

    /// `false` when this segment is a UI-only label (Wallpaper Engine import surface)
    /// that does not map to a `WallpaperContent` case at runtime.
    var hasDirectContent: Bool {
        self != .scene
    }
}
