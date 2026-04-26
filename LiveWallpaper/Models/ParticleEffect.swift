enum ParticleEffect: String, Codable, CaseIterable, Identifiable {
    case none = "None"
    case snow = "Snow"
    case rain = "Rain"
    case bokeh = "Bokeh"
    case fireflies = "Fireflies"
    case fallingLeaves = "Leaves"
    case sakura = "Sakura"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .none: return "xmark.circle"
        case .snow: return "snowflake"
        case .rain: return "cloud.rain"
        case .bokeh: return "sparkles"
        case .fireflies: return "lightbulb"
        case .fallingLeaves: return "leaf"
        case .sakura: return "camera.macro"
        }
    }
}
