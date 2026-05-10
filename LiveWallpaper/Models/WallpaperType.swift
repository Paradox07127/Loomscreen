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

    /// Phase 2.0+: every wallpaper type — including `.scene` — now maps to a
    /// `WallpaperContent` case at runtime. Kept around as an explicit hook so
    /// future UI-only labels can opt out without rewriting call sites.
    var hasDirectContent: Bool {
        true
    }
}
