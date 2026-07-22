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

/// `oscillatealpha` operator: WPE's `FrequencyValue::GetScale` — a cosine that
/// lerps the alpha multiplier across `[scaleMin, scaleMax]`. Frequency and phase
/// are randomized PER PARTICLE at spawn, so stars twinkle out of step.
///
/// The reference computes `f = frequency/2π` then `w = 2π·f`, i.e. **w is the
/// authored frequency** — folding in another 2π ran it 6.28× too fast. Reading
/// only `frequency`/`frequencymin` was worse: presets that author bare
/// `frequencymax` (Stars.json: `{frequencymax:3, scalemin:0.2}`) collapsed to
/// frequency 0 and stopped twinkling altogether.
public struct WPEParticleOscillateAlpha: Equatable, Sendable {
    public let frequencyMin: Double
    public let frequencyMax: Double
    public let scaleMin: Double
    public let scaleMax: Double
    public let phaseMin: Double
    public let phaseMax: Double

    public init(
        frequencyMin: Double,
        frequencyMax: Double,
        scaleMin: Double,
        scaleMax: Double,
        phaseMin: Double,
        phaseMax: Double
    ) {
        self.frequencyMin = frequencyMin
        self.frequencyMax = frequencyMax
        self.scaleMin = scaleMin
        self.scaleMax = scaleMax
        self.phaseMin = phaseMin
        self.phaseMax = phaseMax
    }

    /// `frequency`/`phase` come from the particle's spawn-time draw.
    public func factor(age: Double, frequency: Double, phase: Double) -> Double {
        guard frequency != 0 else { return 1 }
        let wave = (cos(frequency * age + phase) + 1) * 0.5
        return min(max(scaleMin + (scaleMax - scaleMin) * wave, 0), 1)
    }
}

/// `spritetrail` / `ropetrail` renderer params. These ARE `g_RenderVar0.xy`
/// verbatim: the shader stretches the quad along the velocity by
/// `clamp(speed * length, min, maxLength)`
/// (`common_particles.h` ComputeParticleTrailTangents).
///
/// The DEFAULTS carry the whole effect and must not be invented
/// (`wpscene/WPParticleObject.h`: `length {0.05}`, `maxlength {10.0}`,
/// `subdivision {3.0}`). 3448877775's meteor authors `length: 3` and omits
/// `maxlength`: speed 100–250 × 3 = 300–750 is clamped by the default 10 to a
/// ~10× streak. Treating the absent `maxlength` as unbounded instead drew a
/// screen-crossing "laser". RenderDoc cross-checks the pair on the same scene's
/// rain (`length 0.005, maxlength 100` → `g_RenderVar0 = (0.005, 100.0, …)`,
/// speed 3000 → stretch 15).
public struct WPEParticleTrailRenderer: Equatable, Sendable {
    /// `spritetrail` = one velocity-stretched quad per particle (`genericparticle`
    /// TRAILRENDERER). `ropetrail` = a ribbon threaded through the particle's own
    /// position history (`genericropeparticle`), where length is a UV segment scale,
    /// NOT a velocity stretch. We lack the history buffer, so a `.rope` trail renders
    /// as a plain sprite; the kind gates the stretch in the render executor.
    public enum Kind: Sendable, Equatable { case sprite, rope }
    public let kind: Kind
    public let length: Double
    public let maxLength: Double
    /// Trail segment count — `subdivision`, NOT `length`. The default 3 is why
    /// RenderDoc shows `trailPosition` cycling 0,1,2,3 (4 points per particle).
    public let subdivision: Double

    public init(kind: Kind, length: Double, maxLength: Double, subdivision: Double) {
        self.kind = kind
        self.length = length
        self.maxLength = maxLength
        self.subdivision = subdivision
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

/// `turbulentvelocityrandom` INITIALIZER: seeds each particle, once at spawn,
/// with a velocity aimed along a curl-noise stream. This is what gives WPE's
/// leaves/petals/embers their initial drift — NOT the per-frame operator below.
///
/// The stream direction is a curl-noise sample, cone-limited around `forward`
/// (default +Y) and then rotated `offset` radians about `right` (default +Z).
/// `scale` is the cone WIDTH as a fraction of a hemisphere: `2` = every
/// direction, smaller = a tighter cone about `forward`. `offset` is what turns
/// an upward stream downward — the leaves preset authors `offset: 3` (≈172°),
/// rotating the +Y stream to nearly -Y so leaves fall. Speed is a per-particle
/// `uniform(speedMin, speedMax)`. Engine defaults mirror the reference renderer.
public struct WPEParticleTurbulentVelocityInit: Equatable, Sendable {
    public let speedMin: Double
    public let speedMax: Double
    public let scale: Double
    public let timescale: Double
    public let offset: Double
    public let phaseMin: Double
    public let phaseMax: Double
    public let forward: SIMD3<Double>
    public let right: SIMD3<Double>

    public init(
        speedMin: Double = 100,
        speedMax: Double = 250,
        scale: Double = 1,
        timescale: Double = 1,
        offset: Double = 0,
        phaseMin: Double = 0,
        phaseMax: Double = 0.1,
        forward: SIMD3<Double> = SIMD3<Double>(0, 1, 0),
        right: SIMD3<Double> = SIMD3<Double>(0, 0, 1)
    ) {
        self.speedMin = min(speedMin, speedMax)
        self.speedMax = max(speedMin, speedMax)
        self.scale = max(0, scale)
        self.timescale = timescale
        self.offset = offset
        self.phaseMin = min(phaseMin, phaseMax)
        self.phaseMax = max(phaseMin, phaseMax)
        self.forward = forward
        self.right = right
    }
}

/// `turbulence` OPERATOR: a per-frame acceleration sampled from a curl-noise
/// field that scrolls over time (`timescale`) — a continuous, axis-masked wind.
/// Distinct from the initializer above (which fires once at spawn): the operator
/// keeps pushing every particle each frame, so presets that use it usually pair
/// it with `drag` to bound the resulting velocity (fireflies drag 2.5). Applied
/// as `velocity += speed · normalize(curl((pos + X·(phase + timescale·t))·2·scale)) · mask · dt`.
/// Engine defaults mirror the reference renderer (500…1000, scale 0.01,
/// timescale 20, mask 1 1 0).
public struct WPEParticleTurbulenceOperator: Equatable, Sendable {
    public let speedMin: Double
    public let speedMax: Double
    public let scale: Double
    public let timescale: Double
    public let phaseMin: Double
    public let phaseMax: Double
    public let mask: SIMD3<Double>

    public init(
        speedMin: Double = 500,
        speedMax: Double = 1000,
        scale: Double = 0.01,
        timescale: Double = 20,
        phaseMin: Double = 0,
        phaseMax: Double = 0,
        mask: SIMD3<Double> = SIMD3<Double>(1, 1, 0)
    ) {
        self.speedMin = min(speedMin, speedMax)
        self.speedMax = max(speedMin, speedMax)
        self.scale = max(0, scale)
        self.timescale = timescale
        self.phaseMin = min(phaseMin, phaseMax)
        self.phaseMax = max(phaseMin, phaseMax)
        self.mask = SIMD3<Double>(max(0, mask.x), max(0, mask.y), max(0, mask.z))
    }
}

/// WPE emitter geometry. `sphererandom` scatters within a radius; `boxrandom`
/// scatters within an axis-aligned box (per-axis `distancemax` half-extents) —
/// how full-screen effects like rain spread across the frame.
public enum WPEParticleEmitterShape: String, Sendable, Equatable {
    case sphere
    case box
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
    /// `renderer: [{name:"rope"}]` — a ribbon/trail that connects its particles
    /// in emission order into one textured strip (meteor tails, cursor trails)
    /// instead of N independent billboards. Drawn as a per-frame triangle strip,
    /// NOT instanced quads: stacking the quads (all knots spawn at one point with
    /// no spread, relying on the rope to spread them along the control-point path)
    /// piled into an additive white blob (scene 3351072238).
    /// Keyframed `instanceoverride.alpha`, applied per frame by the system
    /// (NOT baked into `alphaMin/alphaMax` — see `applyingInstanceOverride`).
    public let overrideAlphaAnimation: WPESceneAnimatedValue?
    public let isRope: Bool
    /// `spritetrail` / `ropetrail`: today this only orients the quad along the
    /// particle's velocity instead of its rotation — the authored trail itself is
    /// not reproduced (see `WPEParticleTrailRenderer`). Distinct from `isRope`,
    /// which threads ONE ribbon through the whole particle chain.
    public let trailRenderer: WPEParticleTrailRenderer?
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
    /// Emission distribution. `.sphere` (the WPE default `sphererandom`) uses the
    /// `.x` of dispersalMin/Max as a scalar radius; `.box` (`boxrandom`) samples
    /// each axis independently within ±dispersalMax (per-axis half-extents). A box
    /// emitter parsed as a sphere collapses its vector `distancemax` to one point
    /// (scene 3351072238: 500 rain halos piled into a white blob).
    public let emitterShape: WPEParticleEmitterShape
    /// Per-axis emission bounds. Sphere reads `.x` as the radius; box reads all
    /// three as half-extents. Stored as a vector so `boxrandom`'s
    /// `distancemax: "1200 1000 0"` survives instead of failing scalar parsing.
    public let dispersalMin: SIMD3<Double>
    public let dispersalMax: SIMD3<Double>
    public let directionMask: SIMD3<Double>
    /// `emitter[].sign`, normalized to -1/0/1 per axis (WPParticleObject.cpp
    /// `Emitter::FromJson`: `v != 0 ? v / abs(v) : 0`). A nonzero axis forces
    /// that component of the sphere dispersal to `abs(value) * sign` — e.g.
    /// snowperspective's `"0 0 1"` keeps every dust mote in front of camera
    /// instead of half spawning at negative depth (scene 3462491575).
    public let sign: SIMD3<Double>
    public let velocityMin: SIMD3<Double>
    public let velocityMax: SIMD3<Double>
    public let colorMin: SIMD3<Double>
    public let colorMax: SIMD3<Double>
    /// Tracks explicit `color`/`colorrandom` initialization because `colorchange` must not recolor an unauthored base.
    /// Instance-level `colorn` remains applicable independently.
    public let hasColorInitializer: Bool
    /// Whether the particle JSON explicitly opted into sprite-sheet sequence
    /// animation (`"animationmode": "sequence"` or a non-null
    /// `sequencemultiplier`). `animationMode` alone can't distinguish this —
    /// an omitted `animationmode` also defaults to `.sequence` — and the
    /// distinction gates the derived-grid atlas fallback, which must not
    /// slice single-image sprites that merely inherited the default.
    public let declaresSequenceAnimation: Bool
    /// True when `flags & 4` enables depth-aware perspective sizing and motion.
    public let isPerspective: Bool
    /// `turbulentvelocityrandom` initializer, or nil when absent. Seeds each
    /// particle's spawn velocity along a curl-noise stream (rising embers, falling
    /// leaves). Without it such emitters would spawn motionless.
    public let turbulentVelocityInit: WPEParticleTurbulentVelocityInit?
    /// `turbulence` operator, or nil when absent. A per-frame curl-noise wind
    /// applied to every live particle. Independent from the initializer above —
    /// a preset may declare either, both, or neither.
    public let turbulence: WPEParticleTurbulenceOperator?
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
    /// `sequencemultiplier` from the particle JSON. Multiplies the
    /// texture's `.tex-json` baseline `frames/duration` rate so the
    /// runtime can pick a sub-frame index every tick. `1` is the
    /// WPE default; `0` freezes on frame 0.
    public let sequenceMultiplier: Double
    public let animationMode: WPEParticleAnimationMode
    /// Parsed control points (mouse anchors). `id 0` is the emitter origin.
    public let controlPoints: [WPEParticleControlPoint]
    public let attractors: [WPEParticleControlPointAttractor]

    /// True when the emitter's origin (control point `id 0`) tracks the cursor —
    /// the canonical "particles spawn at the pointer" / follow behavior.
    public var emitterTracksPointer: Bool {
        controlPoints.first(where: { $0.id == 0 })?.pointerLocked ?? false
    }

    public init(
        materialRelativePath: String?,
        childRelativePaths: [String] = [],
        childReferences: [WPEParticleChildReference]? = nil,
        rendersSprite: Bool = true,
        overrideAlphaAnimation: WPESceneAnimatedValue? = nil,
        isRope: Bool = false,
        trailRenderer: WPEParticleTrailRenderer? = nil,
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
        emitterShape: WPEParticleEmitterShape = .sphere,
        dispersalMin: SIMD3<Double>,
        dispersalMax: SIMD3<Double>,
        velocityMin: SIMD3<Double>,
        velocityMax: SIMD3<Double>,
        colorMin: SIMD3<Double>,
        colorMax: SIMD3<Double>,
        fadeInSeconds: Double,
        directionMask: SIMD3<Double> = SIMD3<Double>(1, 1, 1),
        sign: SIMD3<Double> = SIMD3<Double>(0, 0, 0),
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
        turbulentVelocityInit: WPEParticleTurbulentVelocityInit? = nil,
        turbulence: WPEParticleTurbulenceOperator? = nil,
        sequenceMultiplier: Double = 1,
        animationMode: WPEParticleAnimationMode = .sequence,
        controlPoints: [WPEParticleControlPoint] = [],
        attractors: [WPEParticleControlPointAttractor] = [],
        hasColorInitializer: Bool = false,
        declaresSequenceAnimation: Bool = false,
        isPerspective: Bool = false
    ) {
        self.materialRelativePath = materialRelativePath
        // Prefer explicit child references; fall back to bare paths (origin 0)
        // for the convenience/back-compat `childRelativePaths:` initializer.
        self.childReferences = childReferences ?? childRelativePaths.map {
            WPEParticleChildReference(relativePath: $0)
        }
        self.rendersSprite = rendersSprite
        self.overrideAlphaAnimation = overrideAlphaAnimation
        self.isRope = isRope
        self.trailRenderer = trailRenderer
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
        self.emitterShape = emitterShape
        self.dispersalMin = dispersalMin
        self.dispersalMax = dispersalMax
        self.directionMask = directionMask
        self.sign = sign
        self.velocityMin = velocityMin
        self.velocityMax = velocityMax
        self.colorMin = colorMin
        self.colorMax = colorMax
        self.hasColorInitializer = hasColorInitializer
        self.declaresSequenceAnimation = declaresSequenceAnimation
        self.isPerspective = isPerspective
        self.turbulentVelocityInit = turbulentVelocityInit
        self.turbulence = turbulence
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
        self.sequenceMultiplier = max(0, sequenceMultiplier)
        self.animationMode = animationMode
        self.controlPoints = controlPoints
        self.attractors = attractors
    }

    /// `colorn` arrives ×255 (see `parseNormalizedParticleColor`); treat it as a
    /// 0…1 fraction multiplying the 0…255 base colour channel-wise.
    private static func multiplyingColor(
        _ base: SIMD3<Double>,
        byNormalizedOverride override: SIMD3<Double>?
    ) -> SIMD3<Double> {
        guard let override else { return base }
        return SIMD3<Double>(
            base.x * max(0, override.x) / 255,
            base.y * max(0, override.y) / 255,
            base.z * max(0, override.z) / 255
        )
    }

    public func applying(instanceOverride: WPESceneParticleInstanceOverride?) -> WPEParticleDefinition {
        guard let instanceOverride else { return self }

        let countScale = max(0, instanceOverride.count ?? 1)
        let rateScale = max(0, instanceOverride.rate ?? countScale)
        let lifetimeScale = max(0.0001, instanceOverride.lifetime ?? 1)
        let sizeScale = max(0, instanceOverride.size ?? 1)
        let speedScale = instanceOverride.speed ?? 1
        // A KEYFRAMED override alpha must not be baked: `alpha` is only its static
        // seed. Leave the spawn alpha untouched and let the system apply the track
        // per frame (3448877775's star field ramps 0.01 → 1.0 across a 90s loop;
        // baking the seed pinned it at full brightness).
        let alphaScale = instanceOverride.alphaAnimation != nil
            ? 1
            : max(0, instanceOverride.alpha ?? 1)
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
        // `speed` override scales emission velocity — including the turbulence
        // seed/wind speeds (the reference renderer multiplies every velocity op).
        let scaledTurbulentVelocityInit = turbulentVelocityInit.map {
            WPEParticleTurbulentVelocityInit(
                speedMin: $0.speedMin * speedScale, speedMax: $0.speedMax * speedScale,
                scale: $0.scale, timescale: $0.timescale, offset: $0.offset,
                phaseMin: $0.phaseMin, phaseMax: $0.phaseMax,
                forward: $0.forward, right: $0.right
            )
        }
        let scaledTurbulence = turbulence.map {
            WPEParticleTurbulenceOperator(
                speedMin: $0.speedMin * speedScale, speedMax: $0.speedMax * speedScale,
                scale: $0.scale, timescale: $0.timescale,
                phaseMin: $0.phaseMin, phaseMax: $0.phaseMax, mask: $0.mask
            )
        }

        return WPEParticleDefinition(
            materialRelativePath: materialRelativePath,
            childReferences: childReferences,
            rendersSprite: rendersSprite,
            overrideAlphaAnimation: instanceOverride.alphaAnimation,
            isRope: isRope,
            trailRenderer: trailRenderer,
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
            emitterShape: emitterShape,
            dispersalMin: dispersalMin,
            dispersalMax: dispersalMax,
            velocityMin: velocityMin * speedScale,
            velocityMax: velocityMax * speedScale,
            // `colorn` is a per-instance colour MULTIPLIER, not a replacement.
            // Replace-vs-multiply only diverges when the base colour isn't white:
            // wildfire's smoke (no initializer, white base) dims to `0.24,0.16,0.27`
            // either way, but 3462491575's matrix glyphs pair a GREEN `colorrandom`
            // with a white `colorn` — replacement bleached them white; Windows keeps
            // them green. Only `colorchange` is gated (below).
            colorMin: Self.multiplyingColor(colorMin, byNormalizedOverride: instanceOverride.color),
            colorMax: Self.multiplyingColor(colorMax, byNormalizedOverride: instanceOverride.color),
            fadeInSeconds: fadeInSeconds,
            directionMask: directionMask,
            sign: sign,
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
            turbulentVelocityInit: scaledTurbulentVelocityInit,
            turbulence: scaledTurbulence,
            sequenceMultiplier: sequenceMultiplier,
            animationMode: animationMode,
            controlPoints: controlPoints,
            attractors: attractors,
            hasColorInitializer: hasColorInitializer,
            declaresSequenceAnimation: declaresSequenceAnimation,
            isPerspective: isPerspective
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
            isRope: isRope,
            trailRenderer: trailRenderer,
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
            emitterShape: emitterShape,
            dispersalMin: dispersalMin,
            dispersalMax: dispersalMax,
            velocityMin: velocityMin,
            velocityMax: velocityMax,
            colorMin: colorMin,
            colorMax: colorMax,
            fadeInSeconds: fadeInSeconds,
            directionMask: directionMask,
            sign: sign,
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
            turbulentVelocityInit: turbulentVelocityInit,
            turbulence: turbulence,
            sequenceMultiplier: sequenceMultiplier,
            animationMode: animationMode,
            controlPoints: controlPoints,
            attractors: attractors,
            hasColorInitializer: hasColorInitializer,
            declaresSequenceAnimation: declaresSequenceAnimation,
            isPerspective: isPerspective
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
        dispersalMin: SIMD3<Double>(0, 0, 0),
        dispersalMax: SIMD3<Double>(0, 0, 0),
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
        let rendererEntries = json["renderer"] as? [[String: Any]]
        let rendersSprite = rendererEntries.map { !$0.isEmpty } ?? true
        // `rope` = ONE ribbon threaded through the whole particle chain (our
        // `buildRopeGeometry`). `ropetrail`/`spritetrail` are NOT that: RenderDoc
        // on 3448877775 shows each particle carrying its OWN position history —
        // `TEXCOORD1.w` (trailPosition) runs 0,1,2,3,0,1,2,3… i.e. 80 vertices =
        // 20 meteors × 4 points, and each group's positions form one moving
        // particle's path (386→420→646→886→1141). `length: 3` is the SEGMENT
        // COUNT (3 segments = 4 points).
        //
        // So `ropetrail` must NOT take the rope path: threading one ribbon through
        // unrelated particles — the emitter is `boxrandom` over a 360×360 box —
        // draws a random zigzag across the sky. Until per-particle trail history
        // exists, it stays a sprite (see `trailRenderer`).
        let rendererNames = (rendererEntries ?? []).compactMap {
            ($0["name"] as? String)?.lowercased()
        }
        let isRope = rendererNames.contains("rope")
        let trailEntry = rendererEntries?.first {
            guard let n = ($0["name"] as? String)?.lowercased() else { return false }
            return n.hasSuffix("trail") && !isRope
        }
        // Engine defaults, NOT zero (wpscene/WPParticleObject.h ParticleRender).
        // An absent `maxlength` means 10, not "unbounded". `rope`-prefixed names
        // (`ropetrail`) are the history-ribbon kind — recorded but not stretched.
        let parsedTrail: WPEParticleTrailRenderer? = trailEntry.map {
            let name = ($0["name"] as? String)?.lowercased() ?? ""
            return WPEParticleTrailRenderer(
                kind: name.hasPrefix("rope") ? .rope : .sprite,
                length: WPEValueParser.double($0["length"]) ?? 0.05,
                maxLength: WPEValueParser.double($0["maxlength"]) ?? 10.0,
                subdivision: WPEValueParser.double($0["subdivision"]) ?? 3.0
            )
        }
        let maxCount = (json["maxcount"] as? Int)
            ?? (json["maxcount"] as? Double).map { Int($0) }
            ?? 0
        let startDelay = WPEValueParser.double(json["starttime"]) ?? 0
        let sequenceMultiplier = WPEValueParser.double(json["sequencemultiplier"]) ?? 1
        let animationMode = WPEParticleAnimationMode(wpeString: json["animationmode"] as? String)
        let declaresSequenceAnimation =
            (json["animationmode"] as? String)?.lowercased() == "sequence"
            || WPEValueParser.double(json["sequencemultiplier"]) != nil
        // Top-level `flags` bit 4 = perspective (WPE's snowperspective etc.):
        // particles carry a Z depth and draw with a perspective divide.
        let particleFlags = (json["flags"] as? Int)
            ?? (json["flags"] as? Double).map { Int($0) } ?? 0
        let isPerspective = (particleFlags & 4) != 0

        var rate: Double = 0
        var instantaneousCount: Int = 0
        var origin: SIMD3<Double> = SIMD3(0, 0, 0)
        var emitterShape: WPEParticleEmitterShape = .sphere
        var dispersalMin = SIMD3<Double>(0, 0, 0)
        var dispersalMax = SIMD3<Double>(0, 0, 0)
        // WPE scene particles render as 2D billboards unless an emitter
        // explicitly opts into a Z axis. Defaulting missing `directions`
        // to Z=1 collapses depth-only random offsets back onto the same
        // screen-space center in the Metal 2D pipeline, creating bright
        // additive piles for bokeh-style emitters.
        var directionMask: SIMD3<Double> = SIMD3(1, 1, 0)
        var sign: SIMD3<Double> = SIMD3(0, 0, 0)

        if let emitters = json["emitter"] as? [[String: Any]], let first = emitters.first {
            rate = WPEValueParser.double(first["rate"]) ?? 0
            instantaneousCount = WPEValueParser.double(first["instantaneous"]).map { max(0, Int($0)) } ?? 0
            origin = WPEValueParser.vector3(first["origin"]) ?? SIMD3(0, 0, 0)
            if (first["name"] as? String)?.lowercased() == "boxrandom" {
                // `boxrandom` distances are per-axis half-extents (e.g.
                // "1200 1000 0"). Scalar parsing would fail → collapse the box to
                // a point and pile every particle on the origin (scene 3351072238).
                emitterShape = .box
                func absVec(_ v: SIMD3<Double>?) -> SIMD3<Double> {
                    guard let v else { return SIMD3(0, 0, 0) }
                    return SIMD3(Swift.abs(v.x), Swift.abs(v.y), Swift.abs(v.z))
                }
                dispersalMin = absVec(WPEValueParser.vector3(first["distancemin"]))
                dispersalMax = absVec(WPEValueParser.vector3(first["distancemax"]))
            } else {
                let scalarMin = max(0, WPEValueParser.double(first["distancemin"]) ?? 0)
                let scalarMax = max(scalarMin, WPEValueParser.double(first["distancemax"]) ?? 0)
                dispersalMin = SIMD3(scalarMin, scalarMin, scalarMin)
                dispersalMax = SIMD3(scalarMax, scalarMax, scalarMax)
            }
            if let mask = WPEValueParser.vector3(first["directions"]) {
                directionMask = SIMD3<Double>(abs(mask.x), abs(mask.y), abs(mask.z))
            }
            // `Emitter::FromJson` normalizes each component to -1/0/1
            // (`v != 0 ? v / abs(v) : 0`) before `ApplySign` uses it.
            if let raw = WPEValueParser.vector3(first["sign"]) {
                func normalized(_ v: Double) -> Double { v != 0 ? (v > 0 ? 1 : -1) : 0 }
                sign = SIMD3<Double>(normalized(raw.x), normalized(raw.y), normalized(raw.z))
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
        var turbulentVelocityInit: WPEParticleTurbulentVelocityInit?
        var turbulence: WPEParticleTurbulenceOperator?
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
                    sizeExponent = WPEValueParser.double(entry["exponent"]) ?? sizeExponent
                case "size":
                    if let v = WPEValueParser.double(entry["value"]) {
                        sizeMin = v; sizeMax = v
                    }
                case "velocityrandom":
                    // Reference `WPParticleParser.cpp`: the operator seeds x,y ∈
                    // [-32,32], z=0 — an absent `min`/`max` keeps that default, NOT
                    // zero. (Inert on the current corpus: all 120 uses author both
                    // bounds; kept for reference-parity, like turbulentvelocityrandom.)
                    velocityMin = WPEValueParser.vector3(entry["min"]) ?? SIMD3(-32, -32, 0)
                    velocityMax = WPEValueParser.vector3(entry["max"]) ?? SIMD3(32, 32, 0)
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
                    // Reference `WPParticleParser.cpp`: default max is (0,0,2π) —
                    // only z spins, x/y stay 0. (x/y are inert here anyway: the 2D
                    // renderer consumes only `.z`.)
                    rotationMin = WPEValueParser.vector3(entry["min"]) ?? SIMD3(0, 0, 0)
                    rotationMax = WPEValueParser.vector3(entry["max"]) ?? SIMD3(0, 0, 2 * .pi)
                case "angularvelocityrandom":
                    // Reference `WPParticleParser.cpp`: the operator seeds z ∈ [-5,5]
                    // (x/y=0) — an absent `min`/`max` keeps that, NOT zero. Live:
                    // torchembers / fireworks2stars / wildfireembers author it bare
                    // and must spin.
                    angularVelocityMin = WPEValueParser.vector3(entry["min"]) ?? SIMD3(0, 0, -5)
                    angularVelocityMax = WPEValueParser.vector3(entry["max"]) ?? SIMD3(0, 0, 5)
                case "turbulentvelocityrandom":
                    // Absent fields take the reference-renderer engine defaults
                    // (speed 100…250, scale 1, timescale 1, phase 0…0.1, forward +Y,
                    // right +Z), NOT zero — presets like wildfireembers author only
                    // `scale` and rely on the rest defaulting.
                    let d = WPEParticleTurbulentVelocityInit()
                    turbulentVelocityInit = WPEParticleTurbulentVelocityInit(
                        speedMin: WPEValueParser.double(entry["speedmin"]) ?? d.speedMin,
                        speedMax: WPEValueParser.double(entry["speedmax"]) ?? d.speedMax,
                        scale: WPEValueParser.double(entry["scale"]) ?? d.scale,
                        timescale: WPEValueParser.double(entry["timescale"]) ?? d.timescale,
                        offset: WPEValueParser.double(entry["offset"]) ?? d.offset,
                        phaseMin: WPEValueParser.double(entry["phasemin"]) ?? d.phaseMin,
                        phaseMax: WPEValueParser.double(entry["phasemax"]) ?? d.phaseMax,
                        forward: WPEValueParser.vector3(entry["forward"]) ?? d.forward,
                        right: WPEValueParser.vector3(entry["right"]) ?? d.right
                    )
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
                    // WPE `FrequencyValue` engine defaults: frequency 0…10,
                    // scale 0…1, phase 0…2π. An absent bound takes the default,
                    // NOT the other bound — Stars.json authors only
                    // `frequencymax`/`scalemin` and relies on 0 and 1.
                    let freqMin = WPEValueParser.double(entry["frequencymin"])
                        ?? WPEValueParser.double(entry["frequency"]) ?? 0
                    var freqMax = WPEValueParser.double(entry["frequencymax"])
                        ?? WPEValueParser.double(entry["frequency"]) ?? 10
                    // Reference: `if (frequencymax == 0) frequencymax = frequencymin`.
                    if freqMax == 0 { freqMax = freqMin }
                    let scaleMin = WPEValueParser.double(entry["scalemin"])
                        ?? WPEValueParser.double(entry["scale"]) ?? 0
                    let scaleMax = WPEValueParser.double(entry["scalemax"]) ?? 1
                    let phaseMin = WPEValueParser.double(entry["phasemin"])
                        ?? WPEValueParser.double(entry["phase"]) ?? 0
                    let phaseMax = WPEValueParser.double(entry["phasemax"]) ?? 2 * .pi
                    oscillateAlpha = WPEParticleOscillateAlpha(
                        frequencyMin: freqMin,
                        frequencyMax: freqMax,
                        scaleMin: scaleMin,
                        scaleMax: scaleMax,
                        phaseMin: phaseMin,
                        phaseMax: phaseMax
                    )
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
                    // Engine defaults are 500…1000 / scale 0.01 / timescale 20 /
                    // mask "1 1 0" — much stronger than the initializer, and paired
                    // with drag in most presets. `phasemin/max` were dropped before.
                    let d = WPEParticleTurbulenceOperator()
                    turbulence = WPEParticleTurbulenceOperator(
                        speedMin: WPEValueParser.double(entry["speedmin"]) ?? d.speedMin,
                        speedMax: WPEValueParser.double(entry["speedmax"]) ?? d.speedMax,
                        scale: WPEValueParser.double(entry["scale"]) ?? d.scale,
                        timescale: WPEValueParser.double(entry["timescale"]) ?? d.timescale,
                        phaseMin: WPEValueParser.double(entry["phasemin"]) ?? d.phaseMin,
                        phaseMax: WPEValueParser.double(entry["phasemax"]) ?? d.phaseMax,
                        mask: WPEValueParser.vector3(entry["mask"]) ?? d.mask
                    )
                default:
                    break
                }
            }
        }

        return WPEParticleDefinition(
            materialRelativePath: material,
            childReferences: childReferences,
            rendersSprite: rendersSprite,
            isRope: isRope,
            trailRenderer: parsedTrail,
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
            emitterShape: emitterShape,
            dispersalMin: dispersalMin,
            dispersalMax: dispersalMax,
            velocityMin: velocityMin,
            velocityMax: velocityMax,
            colorMin: colorMin,
            colorMax: colorMax,
            fadeInSeconds: max(0, fadeInSeconds),
            directionMask: directionMask,
            sign: sign,
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
            turbulentVelocityInit: turbulentVelocityInit,
            turbulence: turbulence,
            sequenceMultiplier: sequenceMultiplier,
            animationMode: animationMode,
            controlPoints: controlPoints,
            attractors: attractors,
            hasColorInitializer: hasColorInitializer,
            declaresSequenceAnimation: declaresSequenceAnimation,
            isPerspective: isPerspective
        )
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let v = value as? Int { return v }
        if let v = value as? Double { return Int(v) }
        if let v = value as? String { return Int(v) }
        return nil
    }
}
