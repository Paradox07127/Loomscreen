enum MetalShaderPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case waves = "Waves"
    case plasma = "Plasma"
    case gradient = "Gradient"
    case noise = "Noise"
    case aurora = "Aurora"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .waves: return "water.waves"
        case .plasma: return "flame"
        case .gradient: return "paintpalette"
        case .noise: return "cloud.fog"
        case .aurora: return "sparkle"
        }
    }
}
