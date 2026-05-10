import SwiftUI

enum MetalShaderPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case waves = "Waves"
    case plasma = "Plasma"
    case gradient = "Gradient"
    case noise = "Noise"
    case aurora = "Aurora"

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .waves: return "Waves"
        case .plasma: return "Plasma"
        case .gradient: return "Gradient"
        case .noise: return "Noise"
        case .aurora: return "Aurora"
        }
    }

    var localizedTitle: String {
        switch self {
        case .waves:
            return String(localized: "Waves", defaultValue: "Waves", comment: "Metal shader preset name.")
        case .plasma:
            return String(localized: "Plasma", defaultValue: "Plasma", comment: "Metal shader preset name.")
        case .gradient:
            return String(localized: "Gradient", defaultValue: "Gradient", comment: "Metal shader preset name.")
        case .noise:
            return String(localized: "Noise", defaultValue: "Noise", comment: "Metal shader preset name.")
        case .aurora:
            return String(localized: "Aurora", defaultValue: "Aurora", comment: "Metal shader preset name.")
        }
    }

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
