import Foundation

enum WPESceneObjectKind: String, Equatable, Sendable {
    case image
    case sound
    case particle
    case text
    case light
    case unknown

    var displayName: String {
        switch self {
        case .image: return "Image"
        case .sound: return "Sound"
        case .particle: return "Particle"
        case .text: return "Text"
        case .light: return "Light"
        case .unknown: return "Unknown"
        }
    }
}

struct WPESceneObjectKindResolution: Equatable, Sendable {
    let primary: WPESceneObjectKind
    let candidates: [WPESceneObjectKind]
    let explicitType: String?

    var isAmbiguous: Bool { candidates.count > 1 }
}
