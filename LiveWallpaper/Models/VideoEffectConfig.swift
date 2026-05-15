import Foundation

struct VideoEffectConfig: Codable, Equatable, Sendable {
    var blurRadius: Double = 0
    var saturation: Double = 1.0
    var brightness: Double = 0
    var warmth: Double = 6500
    var vignetteIntensity: Double = 0
    var autoTimeTint: Bool = false
    var weatherReactive: Bool = false
    var particleDensity: Double = 1.0
    var glassRainEffect: Bool = false

    static let `default` = VideoEffectConfig()

    var hasActiveEffect: Bool {
        blurRadius > 0 || saturation != 1.0 || brightness != 0 ||
        warmth != 6500 || vignetteIntensity > 0 || autoTimeTint || weatherReactive || glassRainEffect
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        blurRadius = try container.decodeIfPresent(Double.self, forKey: .blurRadius) ?? 0
        saturation = try container.decodeIfPresent(Double.self, forKey: .saturation) ?? 1.0
        brightness = try container.decodeIfPresent(Double.self, forKey: .brightness) ?? 0
        warmth = try container.decodeIfPresent(Double.self, forKey: .warmth) ?? 6500
        vignetteIntensity = try container.decodeIfPresent(Double.self, forKey: .vignetteIntensity) ?? 0
        autoTimeTint = try container.decodeIfPresent(Bool.self, forKey: .autoTimeTint) ?? false
        weatherReactive = try container.decodeIfPresent(Bool.self, forKey: .weatherReactive) ?? false
        particleDensity = try container.decodeIfPresent(Double.self, forKey: .particleDensity) ?? 1.0
        glassRainEffect = try container.decodeIfPresent(Bool.self, forKey: .glassRainEffect) ?? false
    }

    init() {}
}
