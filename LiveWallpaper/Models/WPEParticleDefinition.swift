import CoreGraphics
import Foundation

/// Lean particle-system descriptor parsed from a WPE `particles/*.json`
/// file. We model just enough of the emitter/initializer/operator DSL to
/// drive a CPU emitter that produces visually-present results — full
/// fidelity (every operator, ribbon renderer, audio reactivity) waits on
/// later phases. The runtime can render any system that fits this
/// schema; missing fields fall back to sensible defaults so a partial
/// match doesn't drop the entire emitter.
struct WPEParticleDefinition: Equatable, Sendable {
    /// Path to the material this system's particles render with
    /// (relative to the scene cache root). The material's first pass's
    /// first texture supplies the sprite atlas.
    let materialRelativePath: String?
    /// Hard cap on alive particles per frame. WPE emitters honor this
    /// strictly — over the cap, new spawns get dropped.
    let maxCount: Int
    /// Particles per second.
    let rate: Double
    /// Seconds before the first particle spawns (matches WPE's
    /// `starttime`). Useful for staggered effects.
    let startDelay: Double
    /// Per-particle lifetime range, in seconds. Spawn picks uniformly.
    let lifetimeMin: Double
    let lifetimeMax: Double
    /// Per-particle base size in pixels. Min/max for uniform-random spawn.
    let sizeMin: Double
    let sizeMax: Double
    /// Initial position offset relative to the scene object's origin,
    /// expressed in the same pixel-space coordinates as the scene.
    let originOffset: SIMD3<Double>
    /// Emitter shape parameters. Sphere/box dispersal radius.
    let dispersalMin: Double
    let dispersalMax: Double
    /// Velocity range. Each component sampled independently.
    let velocityMin: SIMD3<Double>
    let velocityMax: SIMD3<Double>
    /// Per-particle tint range, encoded as 0…255 RGB (WPE's wire format).
    let colorMin: SIMD3<Double>
    let colorMax: SIMD3<Double>
    /// Linear alpha-fade-in time before the particle reaches full opacity.
    /// Combined with lifetime to compute a fade-out tail.
    let fadeInSeconds: Double

    static let empty = WPEParticleDefinition(
        materialRelativePath: nil,
        maxCount: 0,
        rate: 0,
        startDelay: 0,
        lifetimeMin: 1,
        lifetimeMax: 1,
        sizeMin: 4,
        sizeMax: 4,
        originOffset: SIMD3<Double>(0, 0, 0),
        dispersalMin: 0,
        dispersalMax: 0,
        velocityMin: SIMD3<Double>(0, 0, 0),
        velocityMax: SIMD3<Double>(0, 0, 0),
        colorMin: SIMD3<Double>(255, 255, 255),
        colorMax: SIMD3<Double>(255, 255, 255),
        fadeInSeconds: 0.1
    )
}

/// Pure-function parser. Tolerant: missing keys fall back to defaults so
/// we get a working emitter from any well-formed particle JSON. Returns
/// nil only when the input isn't a JSON object at all.
enum WPEParticleDefinitionParser {
    static func parse(data: Data) -> WPEParticleDefinition? {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: [.allowFragments]) as? [String: Any] else {
            return nil
        }
        return parse(dictionary: json)
    }

    static func parse(dictionary json: [String: Any]) -> WPEParticleDefinition {
        let def = WPEParticleDefinition.empty

        let material = json["material"] as? String
        let maxCount = (json["maxcount"] as? Int)
            ?? (json["maxcount"] as? Double).map { Int($0) }
            ?? 0
        let startDelay = WPEValueParser.double(json["starttime"]) ?? 0

        var rate: Double = 0
        var origin: SIMD3<Double> = SIMD3(0, 0, 0)
        var dispersalMin: Double = 0
        var dispersalMax: Double = 0

        if let emitters = json["emitter"] as? [[String: Any]], let first = emitters.first {
            rate = WPEValueParser.double(first["rate"]) ?? 0
            origin = WPEValueParser.vector3(first["origin"]) ?? SIMD3(0, 0, 0)
            dispersalMin = WPEValueParser.double(first["distancemin"]) ?? 0
            dispersalMax = WPEValueParser.double(first["distancemax"]) ?? 0
        }

        var lifetimeMin: Double = def.lifetimeMin
        var lifetimeMax: Double = def.lifetimeMax
        var sizeMin: Double = def.sizeMin
        var sizeMax: Double = def.sizeMax
        var velocityMin = def.velocityMin
        var velocityMax = def.velocityMax
        var colorMin = def.colorMin
        var colorMax = def.colorMax

        if let initializers = json["initializer"] as? [[String: Any]] {
            for entry in initializers {
                guard let name = (entry["name"] as? String)?.lowercased() else { continue }
                switch name {
                case "lifetimerandom":
                    lifetimeMin = WPEValueParser.double(entry["min"]) ?? lifetimeMin
                    lifetimeMax = WPEValueParser.double(entry["max"]) ?? lifetimeMax
                case "lifetime":
                    if let v = WPEValueParser.double(entry["value"]) {
                        lifetimeMin = v; lifetimeMax = v
                    }
                case "sizerandom":
                    sizeMin = WPEValueParser.double(entry["min"]) ?? sizeMin
                    sizeMax = WPEValueParser.double(entry["max"]) ?? sizeMax
                case "size":
                    if let v = WPEValueParser.double(entry["value"]) {
                        sizeMin = v; sizeMax = v
                    }
                case "velocityrandom":
                    velocityMin = WPEValueParser.vector3(entry["min"]) ?? velocityMin
                    velocityMax = WPEValueParser.vector3(entry["max"]) ?? velocityMax
                case "velocity":
                    if let v = WPEValueParser.vector3(entry["value"]) {
                        velocityMin = v; velocityMax = v
                    }
                case "colorrandom":
                    colorMin = WPEValueParser.vector3(entry["min"]) ?? colorMin
                    colorMax = WPEValueParser.vector3(entry["max"]) ?? colorMax
                case "color":
                    if let v = WPEValueParser.vector3(entry["value"]) {
                        colorMin = v; colorMax = v
                    }
                default:
                    break
                }
            }
        }

        var fadeInSeconds: Double = 0.1
        if let operators = json["operator"] as? [[String: Any]] {
            for entry in operators {
                guard let name = (entry["name"] as? String)?.lowercased() else { continue }
                if name == "alphafade" {
                    fadeInSeconds = WPEValueParser.double(entry["fadeintime"]) ?? fadeInSeconds
                }
            }
        }

        return WPEParticleDefinition(
            materialRelativePath: material,
            maxCount: max(0, maxCount),
            rate: max(0, rate),
            startDelay: max(0, startDelay),
            lifetimeMin: max(0.0001, lifetimeMin),
            lifetimeMax: max(lifetimeMin, lifetimeMax),
            sizeMin: max(0, sizeMin),
            sizeMax: max(sizeMin, sizeMax),
            originOffset: origin,
            dispersalMin: max(0, dispersalMin),
            dispersalMax: max(dispersalMin, dispersalMax),
            velocityMin: velocityMin,
            velocityMax: velocityMax,
            colorMin: colorMin,
            colorMax: colorMax,
            fadeInSeconds: max(0, fadeInSeconds)
        )
    }
}
