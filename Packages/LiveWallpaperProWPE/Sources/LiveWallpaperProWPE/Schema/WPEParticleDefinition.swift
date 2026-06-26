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

/// How a particle walks its sprite-sheet atlas over its lifetime.
///
/// - `.sequence`: play the atlas frames in order, `sequencemultiplier`
///   full cycles across the particle's life (the default WPE playback).
/// - `.randomFrame`: each particle locks onto ONE random frame at spawn
///   and never animates — WPE's `"animationmode": "randomframe"`, used by
///   shatter/debris/ember presets so every shard is a *different static*
///   piece of the atlas rather than the whole atlas flip-booking.
///
/// A particle JSON that omits `animationmode` defaults to `.sequence`.
public enum WPEParticleAnimationMode: String, Sendable, Equatable, CaseIterable {
    case sequence
    case randomFrame

    public init(wpeString raw: String?) {
        switch raw?.lowercased() {
        case "randomframe": self = .randomFrame
        default: self = .sequence
        }
    }
}

/// A WPE particle "control point" — a named anchor an emitter or operator can
/// reference. `id 0` is the emitter's spawn origin by convention. `flags & 1`
/// means the point tracks the mouse pointer (WPE's "Lock to pointer"); the
/// runtime feeds it the live cursor position each frame.
public struct WPEParticleControlPoint: Equatable, Sendable {
    public let id: Int
    public let offset: SIMD3<Double>
    public let pointerLocked: Bool

    public init(id: Int, offset: SIMD3<Double>, pointerLocked: Bool) {
        self.id = id
        self.offset = offset
        self.pointerLocked = pointerLocked
    }
}

/// A `controlpointattract` operator: applies a per-frame force pulling particles
/// toward (`scale > 0`) or away from (`scale < 0`, i.e. "cursor avoid") the
/// referenced control point, falling off to zero at `threshold` distance.
public struct WPEParticleControlPointAttractor: Equatable, Sendable {
    public let controlPointID: Int
    public let scale: Double
    public let threshold: Double

    public init(controlPointID: Int, scale: Double, threshold: Double) {
        self.controlPointID = controlPointID
        self.scale = scale
        self.threshold = max(0, threshold)
    }
}

/// A child particle-system reference from a WPE `children` array. Multiple
/// entries may intentionally point at the same particle file with different
/// `origin` offsets (e.g. the matrix-rain spawner instances one column
/// preset 27 times across the screen width), so callers must preserve this
/// as an ordered list rather than deduping by `relativePath`.
public struct WPEParticleChildReference: Equatable, Sendable {
    public let id: Int?
    public let relativePath: String
    public let originOffset: SIMD3<Double>
    public let type: String?

    /// WPE `type: "eventfollow"` — the child system's emitter rides the
    /// parent's live particles rather than spawning at a static origin.
    public var isEventFollow: Bool {
        type?.lowercased() == "eventfollow"
    }

    public init(
        id: Int? = nil,
        relativePath: String,
        originOffset: SIMD3<Double> = SIMD3<Double>(0, 0, 0),
        type: String? = nil
    ) {
        self.id = id
        self.relativePath = relativePath
        self.originOffset = originOffset
        self.type = type
    }
}

/// `alphachange` operator: a lifetime-fraction alpha multiplier ramp from
/// `startValue` to `endValue` over `[startTime, endTime]` (lifetime fractions).
public struct WPEParticleAlphaChange: Equatable, Sendable {
    public let startTime: Double
    public let endTime: Double
    public let startValue: Double
    public let endValue: Double

    public init(startTime: Double, endTime: Double, startValue: Double, endValue: Double) {
        self.startTime = startTime
        self.endTime = endTime
        self.startValue = startValue
        self.endValue = endValue
    }

    public func factor(lifetimeFraction: Double) -> Double {
        wpeParticleLifetimeRamp(
            lifetimeFraction,
            startTime: startTime, endTime: endTime,
            startValue: startValue, endValue: endValue
        )
    }
}

/// `oscillatealpha` operator: a sine-wave alpha multiplier clamped to [0, 1].
public struct WPEParticleOscillateAlpha: Equatable, Sendable {
    public let frequency: Double
    public let scale: Double
    public let phase: Double

    public init(frequency: Double, scale: Double, phase: Double) {
        self.frequency = frequency
        self.scale = scale
        self.phase = phase
    }

    public func factor(age: Double) -> Double {
        guard frequency != 0, scale != 0 else { return 1 }
        let value = 1 + sin((age + phase) * frequency * 2 * Double.pi) * scale
        return min(max(value, 0), 1)
    }
}

/// Shared linear ramp for the lifetime-fraction operators
/// (`alphachange`/`sizechange`/`colorchange`): clamps the fraction, maps it
/// across `[startTime, endTime]`, and interpolates `startValue → endValue`.
@inline(__always)
func wpeParticleLifetimeRamp(
    _ lifetimeFraction: Double,
    startTime: Double,
    endTime: Double,
    startValue: Double,
    endValue: Double
) -> Double {
    let fraction = min(max(lifetimeFraction, 0), 1)
    let span = endTime - startTime
    let t: Double
    if abs(span) < 0.000_001 {
        t = fraction >= endTime ? 1 : 0
    } else {
        t = min(max((fraction - startTime) / span, 0), 1)
    }
    return startValue + (endValue - startValue) * t
}

/// `sizechange` operator: a lifetime-fraction SIZE multiplier ramp. Same shape
/// as `alphachange`, but scales the sprite quad instead of its opacity
/// (fireworks grow from a point with `startValue:0, endValue:1`; embers shrink).
public struct WPEParticleSizeChange: Equatable, Sendable {
    public let startTime: Double
    public let endTime: Double
    public let startValue: Double
    public let endValue: Double

    public init(startTime: Double, endTime: Double, startValue: Double, endValue: Double) {
        self.startTime = startTime
        self.endTime = endTime
        self.startValue = startValue
        self.endValue = endValue
    }

    public func factor(lifetimeFraction: Double) -> Double {
        wpeParticleLifetimeRamp(
            lifetimeFraction,
            startTime: startTime, endTime: endTime,
            startValue: startValue, endValue: endValue
        )
    }
}

/// `colorchange` operator: a lifetime-fraction RGB multiplier ramp. Each channel
/// interpolates from `startColor` to `endColor` (0…1 tint multipliers) and
/// modulates the particle's per-instance colour.
public struct WPEParticleColorChange: Equatable, Sendable {
    public let startTime: Double
    public let endTime: Double
    public let startColor: SIMD3<Double>
    public let endColor: SIMD3<Double>

    public init(startTime: Double, endTime: Double, startColor: SIMD3<Double>, endColor: SIMD3<Double>) {
        self.startTime = startTime
        self.endTime = endTime
        self.startColor = startColor
        self.endColor = endColor
    }

    public func color(lifetimeFraction: Double) -> SIMD3<Double> {
        SIMD3<Double>(
            wpeParticleLifetimeRamp(lifetimeFraction, startTime: startTime, endTime: endTime,
                                    startValue: startColor.x, endValue: endColor.x),
            wpeParticleLifetimeRamp(lifetimeFraction, startTime: startTime, endTime: endTime,
                                    startValue: startColor.y, endValue: endColor.y),
            wpeParticleLifetimeRamp(lifetimeFraction, startTime: startTime, endTime: endTime,
                                    startValue: startColor.z, endValue: endColor.z)
        )
    }
}

/// `oscillateposition` operator: a per-particle sine sway. Frequency, amplitude
/// (`scale`, in pixels) and phase are randomized per particle from their
/// min/max ranges at spawn; `mask` selects which axes sway. The displacement is
/// transient — derived from age each frame, never integrated into the stored
/// position — so the particle sways without drifting off its path.
public struct WPEParticleOscillatePosition: Equatable, Sendable {
    public let frequencyMin: Double
    public let frequencyMax: Double
    public let scaleMin: Double
    public let scaleMax: Double
    public let phaseMin: Double
    public let phaseMax: Double
    public let mask: SIMD3<Double>

    public init(
        frequencyMin: Double, frequencyMax: Double,
        scaleMin: Double, scaleMax: Double,
        phaseMin: Double, phaseMax: Double,
        mask: SIMD3<Double>
    ) {
        self.frequencyMin = min(frequencyMin, frequencyMax)
        self.frequencyMax = max(frequencyMin, frequencyMax)
        self.scaleMin = min(scaleMin, scaleMax)
        self.scaleMax = max(scaleMin, scaleMax)
        self.phaseMin = min(phaseMin, phaseMax)
        self.phaseMax = max(phaseMin, phaseMax)
        self.mask = mask
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
    public let childReferences: [WPEParticleChildReference]
    /// Whether this system draws its own sprites. A WPE root spawner with an
    /// empty `renderer: []` array only emits/expands its children and must NOT
    /// register a drawable system (it has no material/sprite of its own).
    public let rendersSprite: Bool
    public let maxCount: Int
    public let rate: Double
    /// Emitter `instantaneous` count: particles spawned in a one-time burst
    /// when the emitter starts (explosions, fireworks hits, initial seeding),
    /// in addition to the continuous `rate`. Zero ⇒ rate-only emission.
    public let instantaneousCount: Int
    public let startDelay: Double
    public let lifetimeMin: Double
    public let lifetimeMax: Double
    public let sizeMin: Double
    public let sizeMax: Double
    /// `sizerandom` `exponent` (default 1). WPE samples `min + (max-min)·rand^exp`,
    /// so exp>1 biases toward `min` (e.g. petals/leaves with exp 2 are mostly
    /// small). Sampling uniformly over-sizes the average.
    public let sizeExponent: Double
    public let originOffset: SIMD3<Double>
    public let dispersalMin: Double
    public let dispersalMax: Double
    public let directionMask: SIMD3<Double>
    public let velocityMin: SIMD3<Double>
    public let velocityMax: SIMD3<Double>
    public let colorMin: SIMD3<Double>
    public let colorMax: SIMD3<Double>
    /// Whether the particle authored an explicit `color`/`colorrandom`
    /// initializer. When false, the particle has no authored base colour, so the
    /// `colorchange` operator must NOT recolour it. (The `colorn` instance
    /// override still applies — it sets the colour directly, and for wildfire its
    /// `0.24,0.16,0.27` is exactly what dims the smoke to a faint haze.)
    /// Regression guard: 3460973721's wildfire is a white `r8` smoke with no colour
    /// initializer; applying its `colorchange`(橙→纯红) ramped the faint smoke to red.
    public let hasColorInitializer: Bool
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
    public let alphaChange: WPEParticleAlphaChange?
    public let oscillateAlpha: WPEParticleOscillateAlpha?
    public let sizeChange: WPEParticleSizeChange?
    public let colorChange: WPEParticleColorChange?
    public let oscillatePosition: WPEParticleOscillatePosition?
    /// `operator: movement.gravity` (world units / s²) and drag scalar.
    public let gravity: SIMD3<Double>
    public let drag: Double
    /// `operator: angularmovement` — applied on rotationZ.
    public let angularForceZ: Double
    public let angularDrag: Double
    /// `turbulentvelocityrandom` initializer parameters (per-particle
    /// random sample baked at spawn time, then the operator applies a
    /// noise field every frame).
    public let turbulenceSpeedMin: Double
    public let turbulenceSpeedMax: Double
    public let turbulenceScale: Double
    public let turbulenceTimescale: Double
    public let turbulenceOffset: Double
    public let turbulenceMask: SIMD3<Double>
    public let turbulencePhaseMin: Double
    public let turbulencePhaseMax: Double
    /// `sequencemultiplier` from the particle JSON. Multiplies the
    /// texture's `.tex-json` baseline `frames/duration` rate so the
    /// runtime can pick a sub-frame index every tick. `1` is the
    /// WPE default; `0` freezes on frame 0.
    public let sequenceMultiplier: Double
    public let animationMode: WPEParticleAnimationMode
    /// Parsed control points (mouse anchors). `id 0` is the emitter origin.
    public let controlPoints: [WPEParticleControlPoint]
    public let attractors: [WPEParticleControlPointAttractor]

    /// Ordered child particle file paths. Back-compat accessor over
    /// `childReferences`; preserves duplicates (same path, different origin).
    public var childRelativePaths: [String] {
        childReferences.map(\.relativePath)
    }

    /// True when the emitter's origin (control point `id 0`) tracks the cursor —
    /// the canonical "particles spawn at the pointer" / follow behavior.
    public var emitterTracksPointer: Bool {
        controlPoints.first(where: { $0.id == 0 })?.pointerLocked ?? false
    }

    /// Whether the system consumes the pointer at all (follow OR any attractor
    /// referencing a pointer-locked control point) — lets the runtime skip the
    /// pointer plumbing for non-interactive emitters.
    public var usesPointer: Bool {
        if emitterTracksPointer { return true }
        let pointerIDs = Set(controlPoints.filter(\.pointerLocked).map(\.id))
        return attractors.contains { pointerIDs.contains($0.controlPointID) }
    }

    public init(
        materialRelativePath: String?,
        childRelativePaths: [String] = [],
        childReferences: [WPEParticleChildReference]? = nil,
        rendersSprite: Bool = true,
        maxCount: Int,
        rate: Double,
        instantaneousCount: Int = 0,
        startDelay: Double,
        lifetimeMin: Double,
        lifetimeMax: Double,
        sizeMin: Double,
        sizeMax: Double,
        sizeExponent: Double = 1,
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
        alphaChange: WPEParticleAlphaChange? = nil,
        oscillateAlpha: WPEParticleOscillateAlpha? = nil,
        sizeChange: WPEParticleSizeChange? = nil,
        colorChange: WPEParticleColorChange? = nil,
        oscillatePosition: WPEParticleOscillatePosition? = nil,
        gravity: SIMD3<Double> = SIMD3<Double>(0, 0, 0),
        drag: Double = 0,
        angularForceZ: Double = 0,
        angularDrag: Double = 0,
        turbulenceSpeedMin: Double = 0,
        turbulenceSpeedMax: Double = 0,
        turbulenceScale: Double = 0.005,
        turbulenceTimescale: Double = 0.01,
        turbulenceOffset: Double = 0,
        turbulenceMask: SIMD3<Double> = SIMD3<Double>(1, 1, 1),
        turbulencePhaseMin: Double = 0,
        turbulencePhaseMax: Double = 0,
        sequenceMultiplier: Double = 1,
        animationMode: WPEParticleAnimationMode = .sequence,
        controlPoints: [WPEParticleControlPoint] = [],
        attractors: [WPEParticleControlPointAttractor] = [],
        hasColorInitializer: Bool = false
    ) {
        self.materialRelativePath = materialRelativePath
        // Prefer explicit child references; fall back to bare paths (origin 0)
        // for the convenience/back-compat `childRelativePaths:` initializer.
        self.childReferences = childReferences ?? childRelativePaths.map {
            WPEParticleChildReference(relativePath: $0)
        }
        self.rendersSprite = rendersSprite
        self.maxCount = maxCount
        self.rate = rate
        self.instantaneousCount = max(0, instantaneousCount)
        self.startDelay = startDelay
        self.lifetimeMin = lifetimeMin
        self.lifetimeMax = lifetimeMax
        self.sizeMin = sizeMin
        self.sizeMax = sizeMax
        self.sizeExponent = max(0.0001, sizeExponent)
        self.originOffset = originOffset
        self.dispersalMin = dispersalMin
        self.dispersalMax = dispersalMax
        self.directionMask = directionMask
        self.velocityMin = velocityMin
        self.velocityMax = velocityMax
        self.colorMin = colorMin
        self.colorMax = colorMax
        self.hasColorInitializer = hasColorInitializer
        self.alphaMin = alphaMin
        self.alphaMax = alphaMax
        self.rotationMin = rotationMin
        self.rotationMax = rotationMax
        self.angularVelocityMin = angularVelocityMin
        self.angularVelocityMax = angularVelocityMax
        self.fadeInSeconds = fadeInSeconds
        self.fadeOutSeconds = fadeOutSeconds
        self.alphaChange = alphaChange
        self.oscillateAlpha = oscillateAlpha
        self.sizeChange = sizeChange
        self.colorChange = colorChange
        self.oscillatePosition = oscillatePosition
        self.gravity = gravity
        self.drag = drag
        self.angularForceZ = angularForceZ
        self.angularDrag = angularDrag
        self.turbulenceSpeedMin = max(0, min(turbulenceSpeedMin, turbulenceSpeedMax))
        self.turbulenceSpeedMax = max(turbulenceSpeedMin, turbulenceSpeedMax)
        self.turbulenceScale = max(0, turbulenceScale)
        self.turbulenceTimescale = turbulenceTimescale
        self.turbulenceOffset = turbulenceOffset
        self.turbulenceMask = SIMD3<Double>(
            max(0, turbulenceMask.x),
            max(0, turbulenceMask.y),
            max(0, turbulenceMask.z)
        )
        self.turbulencePhaseMin = min(turbulencePhaseMin, turbulencePhaseMax)
        self.turbulencePhaseMax = max(turbulencePhaseMin, turbulencePhaseMax)
        self.sequenceMultiplier = max(0, sequenceMultiplier)
        self.animationMode = animationMode
        self.controlPoints = controlPoints
        self.attractors = attractors
    }

    public func applying(instanceOverride: WPESceneParticleInstanceOverride?) -> WPEParticleDefinition {
        guard let instanceOverride else { return self }

        let countScale = max(0, instanceOverride.count ?? 1)
        let rateScale = max(0, instanceOverride.rate ?? countScale)
        let lifetimeScale = max(0.0001, instanceOverride.lifetime ?? 1)
        let sizeScale = max(0, instanceOverride.size ?? 1)
        let speedScale = instanceOverride.speed ?? 1
        let alphaScale = max(0, instanceOverride.alpha ?? 1)
        let scaledMaxCount: Int
        if countScale == 0 || maxCount == 0 {
            scaledMaxCount = 0
        } else {
            scaledMaxCount = max(1, Int((Double(maxCount) * countScale).rounded()))
        }
        let scaledInstantaneous: Int
        if countScale == 0 || instantaneousCount == 0 {
            scaledInstantaneous = 0
        } else {
            scaledInstantaneous = max(1, Int((Double(instantaneousCount) * countScale).rounded()))
        }

        return WPEParticleDefinition(
            materialRelativePath: materialRelativePath,
            childReferences: childReferences,
            rendersSprite: rendersSprite,
            maxCount: scaledMaxCount,
            rate: rate * rateScale,
            instantaneousCount: scaledInstantaneous,
            startDelay: startDelay,
            lifetimeMin: lifetimeMin * lifetimeScale,
            lifetimeMax: lifetimeMax * lifetimeScale,
            sizeMin: sizeMin * sizeScale,
            sizeMax: sizeMax * sizeScale,
            sizeExponent: sizeExponent,
            originOffset: originOffset,
            dispersalMin: dispersalMin,
            dispersalMax: dispersalMax,
            velocityMin: velocityMin * speedScale,
            velocityMax: velocityMax * speedScale,
            // `colorn` instance override always applies — it's the author setting
            // the particle's colour directly (wildfire's `0.24,0.16,0.27` dims the
            // white smoke to a faint haze; dust's `0.84,0.74,0.69` warms it). Only
            // `colorchange` is gated (below), since that's what ramped it to red.
            colorMin: instanceOverride.color ?? colorMin,
            colorMax: instanceOverride.color ?? colorMax,
            fadeInSeconds: fadeInSeconds,
            directionMask: directionMask,
            alphaMin: alphaMin * alphaScale,
            alphaMax: alphaMax * alphaScale,
            rotationMin: rotationMin,
            rotationMax: rotationMax,
            angularVelocityMin: angularVelocityMin * speedScale,
            angularVelocityMax: angularVelocityMax * speedScale,
            fadeOutSeconds: fadeOutSeconds,
            alphaChange: alphaChange,
            oscillateAlpha: oscillateAlpha,
            sizeChange: sizeChange,
            colorChange: colorChange,
            oscillatePosition: oscillatePosition,
            gravity: gravity * speedScale,
            drag: drag,
            angularForceZ: angularForceZ * speedScale,
            angularDrag: angularDrag,
            turbulenceSpeedMin: turbulenceSpeedMin * speedScale,
            turbulenceSpeedMax: turbulenceSpeedMax * speedScale,
            turbulenceScale: turbulenceScale,
            turbulenceTimescale: turbulenceTimescale,
            turbulenceOffset: turbulenceOffset,
            turbulenceMask: turbulenceMask,
            turbulencePhaseMin: turbulencePhaseMin,
            turbulencePhaseMax: turbulencePhaseMax,
            sequenceMultiplier: sequenceMultiplier,
            animationMode: animationMode,
            controlPoints: controlPoints,
            attractors: attractors,
            hasColorInitializer: hasColorInitializer
        )
    }

    /// Returns a copy whose emitter origin is shifted by `delta`. Used to apply
    /// the per-child `origin` offset accumulated while expanding a nested
    /// `children` tree (e.g. spreading matrix-rain columns across the screen).
    public func offsettingOrigin(by delta: SIMD3<Double>) -> WPEParticleDefinition {
        guard delta != SIMD3<Double>(0, 0, 0) else { return self }
        return WPEParticleDefinition(
            materialRelativePath: materialRelativePath,
            childReferences: childReferences,
            rendersSprite: rendersSprite,
            maxCount: maxCount,
            rate: rate,
            instantaneousCount: instantaneousCount,
            startDelay: startDelay,
            lifetimeMin: lifetimeMin,
            lifetimeMax: lifetimeMax,
            sizeMin: sizeMin,
            sizeMax: sizeMax,
            sizeExponent: sizeExponent,
            originOffset: originOffset + delta,
            dispersalMin: dispersalMin,
            dispersalMax: dispersalMax,
            velocityMin: velocityMin,
            velocityMax: velocityMax,
            colorMin: colorMin,
            colorMax: colorMax,
            fadeInSeconds: fadeInSeconds,
            directionMask: directionMask,
            alphaMin: alphaMin,
            alphaMax: alphaMax,
            rotationMin: rotationMin,
            rotationMax: rotationMax,
            angularVelocityMin: angularVelocityMin,
            angularVelocityMax: angularVelocityMax,
            fadeOutSeconds: fadeOutSeconds,
            alphaChange: alphaChange,
            oscillateAlpha: oscillateAlpha,
            sizeChange: sizeChange,
            colorChange: colorChange,
            oscillatePosition: oscillatePosition,
            gravity: gravity,
            drag: drag,
            angularForceZ: angularForceZ,
            angularDrag: angularDrag,
            turbulenceSpeedMin: turbulenceSpeedMin,
            turbulenceSpeedMax: turbulenceSpeedMax,
            turbulenceScale: turbulenceScale,
            turbulenceTimescale: turbulenceTimescale,
            turbulenceOffset: turbulenceOffset,
            turbulenceMask: turbulenceMask,
            turbulencePhaseMin: turbulencePhaseMin,
            turbulencePhaseMax: turbulencePhaseMax,
            sequenceMultiplier: sequenceMultiplier,
            animationMode: animationMode,
            controlPoints: controlPoints,
            attractors: attractors,
            hasColorInitializer: hasColorInitializer
        )
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
        let childReferences = (json["children"] as? [[String: Any]])?
            .compactMap { child -> WPEParticleChildReference? in
                let path: String?
                if let name = child["name"] as? String, !name.isEmpty {
                    path = name
                } else if let particle = child["particle"] as? String, !particle.isEmpty {
                    path = particle
                } else {
                    path = nil
                }
                guard let path else { return nil }
                return WPEParticleChildReference(
                    id: intValue(child["id"]),
                    relativePath: path,
                    originOffset: WPEValueParser.vector3(child["origin"]) ?? SIMD3(0, 0, 0),
                    type: child["type"] as? String
                )
            } ?? []
        // Absent `renderer` keeps legacy drawable behavior; an explicit empty
        // array marks a simulation-only spawner (renders nothing itself).
        let rendersSprite = (json["renderer"] as? [[String: Any]]).map { !$0.isEmpty } ?? true
        let maxCount = (json["maxcount"] as? Int)
            ?? (json["maxcount"] as? Double).map { Int($0) }
            ?? 0
        let startDelay = WPEValueParser.double(json["starttime"]) ?? 0
        let sequenceMultiplier = WPEValueParser.double(json["sequencemultiplier"]) ?? 1
        let animationMode = WPEParticleAnimationMode(wpeString: json["animationmode"] as? String)

        var rate: Double = 0
        var instantaneousCount: Int = 0
        var origin: SIMD3<Double> = SIMD3(0, 0, 0)
        var dispersalMin: Double = 0
        var dispersalMax: Double = 0
        // WPE scene particles render as 2D billboards unless an emitter
        // explicitly opts into a Z axis. Defaulting missing `directions`
        // to Z=1 collapses depth-only random offsets back onto the same
        // screen-space center in the Metal 2D pipeline, creating bright
        // additive piles for bokeh-style emitters.
        var directionMask: SIMD3<Double> = SIMD3(1, 1, 0)

        if let emitters = json["emitter"] as? [[String: Any]], let first = emitters.first {
            rate = WPEValueParser.double(first["rate"]) ?? 0
            instantaneousCount = WPEValueParser.double(first["instantaneous"]).map { max(0, Int($0)) } ?? 0
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
        var sizeExponent: Double = def.sizeExponent
        var velocityMin = def.velocityMin
        var velocityMax = def.velocityMax
        var colorMin = def.colorMin
        var colorMax = def.colorMax
        var hasColorInitializer = false
        var alphaMin: Double = def.alphaMin
        var alphaMax: Double = def.alphaMax
        var rotationMin: SIMD3<Double> = def.rotationMin
        var rotationMax: SIMD3<Double> = def.rotationMax
        var angularVelocityMin: SIMD3<Double> = def.angularVelocityMin
        var angularVelocityMax: SIMD3<Double> = def.angularVelocityMax
        var turbulenceSpeedMin: Double = def.turbulenceSpeedMin
        var turbulenceSpeedMax: Double = def.turbulenceSpeedMax
        var turbulenceScale: Double = def.turbulenceScale
        var turbulenceTimescale: Double = def.turbulenceTimescale
        var turbulenceOffset: Double = def.turbulenceOffset
        var turbulenceMask: SIMD3<Double> = def.turbulenceMask
        var turbulencePhaseMin: Double = def.turbulencePhaseMin
        var turbulencePhaseMax: Double = def.turbulencePhaseMax

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
                    sizeExponent = WPEValueParser.double(entry["exponent"]) ?? sizeExponent
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
                    hasColorInitializer = true
                case "color":
                    if let v = WPEValueParser.vector3(entry["value"]) {
                        colorMin = v; colorMax = v
                    }
                    hasColorInitializer = true
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
                case "turbulentvelocityrandom":
                    turbulenceSpeedMin = WPEValueParser.double(entry["speedmin"]) ?? turbulenceSpeedMin
                    turbulenceSpeedMax = WPEValueParser.double(entry["speedmax"]) ?? turbulenceSpeedMax
                    turbulenceScale = WPEValueParser.double(entry["scale"]) ?? turbulenceScale
                    turbulenceTimescale = WPEValueParser.double(entry["timescale"]) ?? turbulenceTimescale
                    turbulenceOffset = WPEValueParser.double(entry["offset"]) ?? turbulenceOffset
                    turbulencePhaseMin = WPEValueParser.double(entry["phasemin"]) ?? turbulencePhaseMin
                    turbulencePhaseMax = WPEValueParser.double(entry["phasemax"]) ?? turbulencePhaseMax
                default:
                    break
                }
            }
        }

        // Control points: `flags & 1` == "locked to pointer". Control point 0 is
        // the emitter origin by WPE convention, so a pointer-locked id-0 makes
        // the emitter spawn at the cursor (the "follow" behavior).
        var controlPoints: [WPEParticleControlPoint] = []
        if let cps = json["controlpoint"] as? [[String: Any]] {
            for cp in cps {
                guard let id = (cp["id"] as? Int) ?? (cp["id"] as? Double).map({ Int($0) }) else { continue }
                let offset = WPEValueParser.vector3(cp["offset"]) ?? SIMD3(0, 0, 0)
                let flags = (cp["flags"] as? Int) ?? (cp["flags"] as? Double).map { Int($0) } ?? 0
                controlPoints.append(WPEParticleControlPoint(
                    id: id, offset: offset, pointerLocked: (flags & 1) != 0
                ))
            }
        }

        var fadeInSeconds: Double = 0.1
        var fadeOutSeconds: Double = 0
        var alphaChange: WPEParticleAlphaChange?
        var oscillateAlpha: WPEParticleOscillateAlpha?
        var sizeChange: WPEParticleSizeChange?
        var colorChange: WPEParticleColorChange?
        var oscillatePosition: WPEParticleOscillatePosition?
        var gravity: SIMD3<Double> = SIMD3(0, 0, 0)
        var drag: Double = 0
        var angularForceZ: Double = 0
        var angularDrag: Double = 0
        var attractors: [WPEParticleControlPointAttractor] = []
        if let operators = json["operator"] as? [[String: Any]] {
            for entry in operators {
                guard let name = (entry["name"] as? String)?.lowercased() else { continue }
                switch name {
                case "controlpointattract":
                    let cpID = (entry["controlpoint"] as? Int)
                        ?? (entry["controlpoint"] as? Double).map { Int($0) } ?? 0
                    let scale = WPEValueParser.double(entry["scale"]) ?? 0
                    let threshold = WPEValueParser.double(entry["threshold"]) ?? 0
                    if scale != 0, threshold > 0 {
                        attractors.append(WPEParticleControlPointAttractor(
                            controlPointID: cpID, scale: scale, threshold: threshold
                        ))
                    }
                case "alphafade":
                    fadeInSeconds = WPEValueParser.double(entry["fadeintime"]) ?? fadeInSeconds
                    fadeOutSeconds = WPEValueParser.double(entry["fadeouttime"]) ?? fadeOutSeconds
                case "alphachange":
                    alphaChange = WPEParticleAlphaChange(
                        startTime: WPEValueParser.double(entry["starttime"]) ?? 0,
                        endTime: WPEValueParser.double(entry["endtime"]) ?? 1,
                        startValue: WPEValueParser.double(entry["startvalue"]) ?? 1,
                        endValue: WPEValueParser.double(entry["endvalue"]) ?? 1
                    )
                case "oscillatealpha":
                    let frequency = WPEValueParser.double(entry["frequency"])
                        ?? WPEValueParser.double(entry["frequencymin"]) ?? 0
                    let scale = WPEValueParser.double(entry["scale"])
                        ?? WPEValueParser.double(entry["scalemin"]) ?? 0
                    let phase = WPEValueParser.double(entry["phase"])
                        ?? WPEValueParser.double(entry["phasemin"]) ?? 0
                    oscillateAlpha = WPEParticleOscillateAlpha(frequency: frequency, scale: scale, phase: phase)
                case "sizechange":
                    sizeChange = WPEParticleSizeChange(
                        startTime: WPEValueParser.double(entry["starttime"]) ?? 0,
                        endTime: WPEValueParser.double(entry["endtime"]) ?? 1,
                        startValue: WPEValueParser.double(entry["startvalue"]) ?? 1,
                        endValue: WPEValueParser.double(entry["endvalue"]) ?? 1
                    )
                case "colorchange":
                    // 0…1 RGB multipliers (unlike `colorrandom`, which is 0…255).
                    let identity = SIMD3<Double>(1, 1, 1)
                    let start = WPEValueParser.vector3(entry["startvalue"]) ?? identity
                    let end = WPEValueParser.vector3(entry["endvalue"]) ?? identity
                    colorChange = WPEParticleColorChange(
                        startTime: WPEValueParser.double(entry["starttime"]) ?? 0,
                        endTime: WPEValueParser.double(entry["endtime"]) ?? 1,
                        startColor: start,
                        endColor: end
                    )
                case "oscillateposition":
                    let freqMin = WPEValueParser.double(entry["frequencymin"])
                        ?? WPEValueParser.double(entry["frequency"]) ?? 0
                    let freqMax = WPEValueParser.double(entry["frequencymax"])
                        ?? WPEValueParser.double(entry["frequency"]) ?? freqMin
                    let scaleMin = WPEValueParser.double(entry["scalemin"])
                        ?? WPEValueParser.double(entry["scale"]) ?? 0
                    let scaleMax = WPEValueParser.double(entry["scalemax"])
                        ?? WPEValueParser.double(entry["scale"]) ?? scaleMin
                    let phaseMin = WPEValueParser.double(entry["phasemin"])
                        ?? WPEValueParser.double(entry["phase"]) ?? 0
                    let phaseMax = WPEValueParser.double(entry["phasemax"])
                        ?? WPEValueParser.double(entry["phase"]) ?? phaseMin
                    let mask = WPEValueParser.vector3(entry["mask"]) ?? SIMD3<Double>(1, 1, 1)
                    if scaleMax > 0, freqMax > 0 {
                        oscillatePosition = WPEParticleOscillatePosition(
                            frequencyMin: freqMin, frequencyMax: freqMax,
                            scaleMin: scaleMin, scaleMax: scaleMax,
                            phaseMin: phaseMin, phaseMax: phaseMax,
                            mask: mask
                        )
                    }
                case "movement":
                    gravity = WPEValueParser.vector3(entry["gravity"]) ?? gravity
                    drag = WPEValueParser.double(entry["drag"]) ?? drag
                case "angularmovement":
                    if let force = WPEValueParser.vector3(entry["force"]) {
                        angularForceZ = force.z
                    }
                    angularDrag = WPEValueParser.double(entry["drag"]) ?? angularDrag
                case "turbulence":
                    if let speedMin = WPEValueParser.double(entry["speedmin"]) {
                        turbulenceSpeedMin = speedMin
                        turbulenceSpeedMax = WPEValueParser.double(entry["speedmax"]) ?? speedMin
                    } else if let speedMax = WPEValueParser.double(entry["speedmax"]) {
                        turbulenceSpeedMax = speedMax
                    }
                    turbulenceScale = WPEValueParser.double(entry["scale"]) ?? turbulenceScale
                    turbulenceTimescale = WPEValueParser.double(entry["timescale"]) ?? turbulenceTimescale
                    turbulenceOffset = WPEValueParser.double(entry["offset"]) ?? turbulenceOffset
                    if let mask = WPEValueParser.vector3(entry["mask"]) {
                        turbulenceMask = mask
                    }
                default:
                    break
                }
            }
        }

        return WPEParticleDefinition(
            materialRelativePath: material,
            childReferences: childReferences,
            rendersSprite: rendersSprite,
            maxCount: max(0, maxCount),
            rate: max(0, rate),
            instantaneousCount: instantaneousCount,
            startDelay: max(0, startDelay),
            lifetimeMin: max(0.0001, lifetimeMin),
            lifetimeMax: max(lifetimeMin, lifetimeMax),
            sizeMin: max(0, sizeMin),
            sizeMax: max(sizeMin, sizeMax),
            sizeExponent: sizeExponent,
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
            alphaChange: alphaChange,
            oscillateAlpha: oscillateAlpha,
            sizeChange: sizeChange,
            colorChange: colorChange,
            oscillatePosition: oscillatePosition,
            gravity: gravity,
            drag: max(0, drag),
            angularForceZ: angularForceZ,
            angularDrag: max(0, angularDrag),
            turbulenceSpeedMin: turbulenceSpeedMin,
            turbulenceSpeedMax: turbulenceSpeedMax,
            turbulenceScale: turbulenceScale,
            turbulenceTimescale: turbulenceTimescale,
            turbulenceOffset: turbulenceOffset,
            turbulenceMask: turbulenceMask,
            turbulencePhaseMin: turbulencePhaseMin,
            turbulencePhaseMax: turbulencePhaseMax,
            sequenceMultiplier: sequenceMultiplier,
            animationMode: animationMode,
            controlPoints: controlPoints,
            attractors: attractors,
            hasColorInitializer: hasColorInitializer
        )
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let v = value as? Int { return v }
        if let v = value as? Double { return Int(v) }
        if let v = value as? String { return Int(v) }
        return nil
    }
}
