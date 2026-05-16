import Foundation

public struct VideoEffectConfig: Codable, Equatable, Sendable {
    public var blurRadius: Double = 0
    public var saturation: Double = 1.0
    public var brightness: Double = 0
    public var warmth: Double = 6500
    public var vignetteIntensity: Double = 0
    public var autoTimeTint: Bool = false
    public var weatherReactive: Bool = false
    public var particleDensity: Double = 1.0

    public static let `default` = VideoEffectConfig()

    public var hasActiveEffect: Bool {
        blurRadius > 0 || saturation != 1.0 || brightness != 0 ||
        warmth != 6500 || vignetteIntensity > 0 || autoTimeTint || weatherReactive
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        blurRadius = try container.decodeIfPresent(Double.self, forKey: .blurRadius) ?? 0
        saturation = try container.decodeIfPresent(Double.self, forKey: .saturation) ?? 1.0
        brightness = try container.decodeIfPresent(Double.self, forKey: .brightness) ?? 0
        warmth = try container.decodeIfPresent(Double.self, forKey: .warmth) ?? 6500
        vignetteIntensity = try container.decodeIfPresent(Double.self, forKey: .vignetteIntensity) ?? 0
        autoTimeTint = try container.decodeIfPresent(Bool.self, forKey: .autoTimeTint) ?? false
        weatherReactive = try container.decodeIfPresent(Bool.self, forKey: .weatherReactive) ?? false
        particleDensity = try container.decodeIfPresent(Double.self, forKey: .particleDensity) ?? 1.0
    }

    public init() {}
}
