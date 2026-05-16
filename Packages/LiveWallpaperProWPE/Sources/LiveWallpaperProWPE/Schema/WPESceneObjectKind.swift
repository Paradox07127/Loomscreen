import Foundation

public enum WPESceneObjectKind: String, Equatable, Sendable {
    case image
    case sound
    case particle
    case text
    case light
    case unknown

    public var displayName: String {
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

public struct WPESceneObjectKindResolution: Equatable, Sendable {
    public let primary: WPESceneObjectKind
    public let candidates: [WPESceneObjectKind]
    public let explicitType: String?

    public init(primary: WPESceneObjectKind, candidates: [WPESceneObjectKind], explicitType: String?) {
        self.primary = primary
        self.candidates = candidates
        self.explicitType = explicitType
    }

    public var isAmbiguous: Bool { candidates.count > 1 }
}
