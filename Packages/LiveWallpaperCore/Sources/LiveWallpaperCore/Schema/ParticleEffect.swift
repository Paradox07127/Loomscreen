import SwiftUI

public enum ParticleEffect: String, Codable, CaseIterable, Identifiable, Sendable {
    case none = "None"
    case snow = "Snow"
    case rain = "Rain"
    case bokeh = "Bokeh"
    case fireflies = "Fireflies"
    case dust = "Dust"
    case stars = "Stars"
    case fallingLeaves = "Leaves"
    case sakura = "Sakura"

    public var id: String { rawValue }

    /// Tolerant decoder: a configuration persisted with a particle effect
    /// that no longer exists (e.g. the rolled-back `Lightning`) decodes to
    /// `.none` instead of failing the whole `ScreenConfiguration` parse.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = ParticleEffect(rawValue: rawValue) ?? .none
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var titleKey: LocalizedStringKey {
        switch self {
        case .none: return "None"
        case .snow: return "Snow"
        case .rain: return "Rain"
        case .bokeh: return "Bokeh"
        case .fireflies: return "Fireflies"
        case .dust: return "Dust"
        case .stars: return "Stars"
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
        case .dust: return "circle.dotted"
        case .stars: return "star"
        case .fallingLeaves: return "leaf"
        case .sakura: return "camera.macro"
        }
    }
}
