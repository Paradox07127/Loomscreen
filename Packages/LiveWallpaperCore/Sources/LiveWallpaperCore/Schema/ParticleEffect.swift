import SwiftUI

public enum ParticleEffect: String, Codable, CaseIterable, Identifiable, Sendable {
    case none = "None"
    case snow = "Snow"
    case rain = "Rain"
    case bokeh = "Bokeh"
    case fireflies = "Fireflies"
    case fallingLeaves = "Leaves"
    case sakura = "Sakura"

    public var id: String { rawValue }

    public var titleKey: LocalizedStringKey {
        switch self {
        case .none: return "None"
        case .snow: return "Snow"
        case .rain: return "Rain"
        case .bokeh: return "Bokeh"
        case .fireflies: return "Fireflies"
        case .fallingLeaves: return "Leaves"
        case .sakura: return "Sakura"
        }
    }

    public var iconName: String {
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
