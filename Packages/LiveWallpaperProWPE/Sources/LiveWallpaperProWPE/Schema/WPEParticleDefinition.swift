import CoreGraphics
import Foundation

/// WPE material blending kind. Maps directly onto Metal blend factors
/// (see `WPEMetalRenderExecutor.particlePipelineState`). Unknown strings
/// fall back to `.translucent` — the most common particle case and the
/// least likely to over-saturate the frame buffer.
public enum WPEParticleBlendMode: String, Sendable, CaseIterable, Equatable {
    case normal
    case translucent
    case additive

    public init(materialString: String?) {
        guard let raw = materialString?.lowercased() else {
            self = .translucent
            return
        }
        self = WPEParticleBlendMode(rawValue: raw) ?? .translucent
    }
}

/// Lean particle-system descriptor parsed from a WPE `particles/*.json`
/// file. Fields cover the subset of the WPE DSL the runtime actually
/// drives — emitter geometry, the random initializers, and the operator
/// parameters that affect frame-by-frame motion (movement, alphafade,
/// angular movement). Anything not in the JSON falls back to a safe
/// default so partial schemas still produce a working emitter.
public struct WPEParticleDefinition: Equatable, Sendable {
    public let materialRelativePath: String?
    public let maxCount: Int
    public let rate: Double
    public let startDelay: Double
    public let lifetimeMin: Double
    public let lifetimeMax: Double
    public let sizeMin: Double
    public let sizeMax: Double
    public let originOffset: SIMD3<Double>
    public let dispersalMin: Double
    public let dispersalMax: Double
    public let directionMask: SIMD3<Double>
    public let velocityMin: SIMD3<Double>
    public let velocityMax: SIMD3<Double>
    public let colorMin: SIMD3<Double>
    public let colorMax: SIMD3<Double>
    /// Per-particle base alpha sampled on spawn (alpharandom). The
    /// fade-in/out envelope multiplies this value at draw time.
    public let alphaMin: Double
    public let alphaMax: Double
    /// Euler rotation ranges; only the Z component drives the 2D quad
    /// orientation today, but we keep the full vec3 so a future 3D
    /// renderer can hook in without another schema break.
    public let rotationMin: SIMD3<Double>
    public let rotationMax: SIMD3<Double>
    /// Angular-velocity initializer (radians/s); Z drives 2D spin.
    public let angularVelocityMin: SIMD3<Double>
    public let angularVelocityMax: SIMD3<Double>
    public let fadeInSeconds: Double
    public let fadeOutSeconds: Double
    /// `operator: movement.gravity` (world units / s²) and drag scalar.
    public let gravity: SIMD3<Double>
    public let drag: Double
    /// `operator: angularmovement` — applied on rotationZ.
    public let angularForceZ: Double
    public let angularDrag: Double

    public init(
        materialRelativePath: String?,
        maxCount: Int,
        rate: Double,
        startDelay: Double,
        lifetimeMin: Double,
        lifetimeMax: Double,
        sizeMin: Double,
        sizeMax: Double,
        originOffset: SIMD3<Double>,
        dispersalMin: Double,
        dispersalMax: Double,
        velocityMin: SIMD3<Double>,
        velocityMax: SIMD3<Double>,
        colorMin: SIMD3<Double>,
        colorMax: SIMD3<Double>,
        fadeInSeconds: Double,
        directionMask: SIMD3<Double> = SIMD3<Double>(1, 1, 1),
        alphaMin: Double = 1,
        alphaMax: Double = 1,
        rotationMin: SIMD3<Double> = SIMD3<Double>(0, 0, 0),
        rotationMax: SIMD3<Double> = SIMD3<Double>(0, 0, 0),
        angularVelocityMin: SIMD3<Double> = SIMD3<Double>(0, 0, 0),
        angularVelocityMax: SIMD3<Double> = SIMD3<Double>(0, 0, 0),
        fadeOutSeconds: Double = 0,
        gravity: SIMD3<Double> = SIMD3<Double>(0, 0, 0),
        drag: Double = 0,
        angularForceZ: Double = 0,
        angularDrag: Double = 0
    ) {
        self.materialRelativePath = materialRelativePath
        self.maxCount = maxCount
        self.rate = rate
        self.startDelay = startDelay
        self.lifetimeMin = lifetimeMin
        self.lifetimeMax = lifetimeMax
        self.sizeMin = sizeMin
        self.sizeMax = sizeMax
        self.originOffset = originOffset
        self.dispersalMin = dispersalMin
        self.dispersalMax = dispersalMax
        self.directionMask = directionMask
        self.velocityMin = velocityMin
        self.velocityMax = velocityMax
        self.colorMin = colorMin
        self.colorMax = colorMax
        self.alphaMin = alphaMin
        self.alphaMax = alphaMax
        self.rotationMin = rotationMin
        self.rotationMax = rotationMax
        self.angularVelocityMin = angularVelocityMin
        self.angularVelocityMax = angularVelocityMax
        self.fadeInSeconds = fadeInSeconds
        self.fadeOutSeconds = fadeOutSeconds
        self.gravity = gravity
        self.drag = drag
        self.angularForceZ = angularForceZ
        self.angularDrag = angularDrag
    }

    public static let empty = WPEParticleDefinition(
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
public enum WPEParticleDefinitionParser {
    public static func parse(data: Data) -> WPEParticleDefinition? {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: [.allowFragments]) as? [String: Any] else {
            return nil
        }
        return parse(dictionary: json)
    }

    public static func parse(dictionary json: [String: Any]) -> WPEParticleDefinition {
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
        var directionMask: SIMD3<Double> = def.directionMask

        if let emitters = json["emitter"] as? [[String: Any]], let first = emitters.first {
            rate = WPEValueParser.double(first["rate"]) ?? 0
            origin = WPEValueParser.vector3(first["origin"]) ?? SIMD3(0, 0, 0)
            dispersalMin = WPEValueParser.double(first["distancemin"]) ?? 0
            dispersalMax = WPEValueParser.double(first["distancemax"]) ?? 0
            if let mask = WPEValueParser.vector3(first["directions"]) {
                directionMask = SIMD3<Double>(abs(mask.x), abs(mask.y), abs(mask.z))
            }
        }

        var lifetimeMin: Double = def.lifetimeMin
        var lifetimeMax: Double = def.lifetimeMax
        var sizeMin: Double = def.sizeMin
        var sizeMax: Double = def.sizeMax
        var velocityMin = def.velocityMin
        var velocityMax = def.velocityMax
        var colorMin = def.colorMin
        var colorMax = def.colorMax
        var alphaMin: Double = def.alphaMin
        var alphaMax: Double = def.alphaMax
        var rotationMin: SIMD3<Double> = def.rotationMin
        var rotationMax: SIMD3<Double> = def.rotationMax
        var angularVelocityMin: SIMD3<Double> = def.angularVelocityMin
        var angularVelocityMax: SIMD3<Double> = def.angularVelocityMax

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
                case "alpharandom":
                    alphaMin = WPEValueParser.double(entry["min"]) ?? alphaMin
                    alphaMax = WPEValueParser.double(entry["max"]) ?? alphaMax
                case "alpha":
                    if let v = WPEValueParser.double(entry["value"]) {
                        alphaMin = v; alphaMax = v
                    }
                case "rotationrandom":
                    // WPE default range for `rotationrandom` is (0,0,0)..
                    // (2π,2π,2π) when min/max are absent — the runtime
                    // wants a full random rotation, not a flat zero.
                    let fallbackMax = SIMD3<Double>(2 * .pi, 2 * .pi, 2 * .pi)
                    rotationMin = WPEValueParser.vector3(entry["min"]) ?? SIMD3(0, 0, 0)
                    rotationMax = WPEValueParser.vector3(entry["max"]) ?? fallbackMax
                case "angularvelocityrandom":
                    angularVelocityMin = WPEValueParser.vector3(entry["min"]) ?? angularVelocityMin
                    angularVelocityMax = WPEValueParser.vector3(entry["max"]) ?? angularVelocityMax
                default:
                    break
                }
            }
        }

        var fadeInSeconds: Double = 0.1
        var fadeOutSeconds: Double = 0
        var gravity: SIMD3<Double> = SIMD3(0, 0, 0)
        var drag: Double = 0
        var angularForceZ: Double = 0
        var angularDrag: Double = 0
        if let operators = json["operator"] as? [[String: Any]] {
            for entry in operators {
                guard let name = (entry["name"] as? String)?.lowercased() else { continue }
                switch name {
                case "alphafade":
                    fadeInSeconds = WPEValueParser.double(entry["fadeintime"]) ?? fadeInSeconds
                    fadeOutSeconds = WPEValueParser.double(entry["fadeouttime"]) ?? fadeOutSeconds
                case "movement":
                    gravity = WPEValueParser.vector3(entry["gravity"]) ?? gravity
                    drag = WPEValueParser.double(entry["drag"]) ?? drag
                case "angularmovement":
                    if let force = WPEValueParser.vector3(entry["force"]) {
                        angularForceZ = force.z
                    }
                    angularDrag = WPEValueParser.double(entry["drag"]) ?? angularDrag
                default:
                    break
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
            fadeInSeconds: max(0, fadeInSeconds),
            directionMask: directionMask,
            alphaMin: max(0, min(alphaMin, alphaMax)),
            alphaMax: max(alphaMin, alphaMax),
            rotationMin: rotationMin,
            rotationMax: rotationMax,
            angularVelocityMin: angularVelocityMin,
            angularVelocityMax: angularVelocityMax,
            fadeOutSeconds: max(0, fadeOutSeconds),
            gravity: gravity,
            drag: max(0, drag),
            angularForceZ: angularForceZ,
            angularDrag: max(0, angularDrag)
        )
    }
}
