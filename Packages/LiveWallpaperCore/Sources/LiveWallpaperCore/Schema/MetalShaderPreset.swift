import SwiftUI

public enum MetalShaderPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case waves = "Waves"
    case plasma = "Plasma"
    case gradient = "Gradient"
    case noise = "Noise"
    case aurora = "Aurora"

    public var id: String { rawValue }

    public var titleKey: LocalizedStringKey {
        switch self {
        case .waves: return "Waves"
        case .plasma: return "Plasma"
        case .gradient: return "Gradient"
        case .noise: return "Noise"
        case .aurora: return "Aurora"
        }
    }

    public var localizedTitle: String {
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

    public var iconName: String {
        switch self {
        case .waves: return "water.waves"
        case .plasma: return "flame"
        case .gradient: return "paintpalette"
        case .noise: return "cloud.fog"
        case .aurora: return "sparkle"
        }
    }

    /// Fragment dispatch index — must stay in sync with the switch in
    /// `Shaders.metal::fragmentShader`. Exposing it on the enum keeps the
    /// live renderer and the thumbnail renderer from drifting apart.
    public var shaderTypeIndex: Int32 {
        switch self {
        case .waves:    return 0
        case .plasma:   return 1
        case .gradient: return 2
        case .noise:    return 3
        case .aurora:   return 4
        }
    }
}
