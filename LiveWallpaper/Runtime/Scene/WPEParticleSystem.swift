#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE
import Metal
import simd

/// Layout MUST match `WPEParticleInstance` in `WPEMetalBuiltins.metal` exactly.
struct WPEParticleInstance {
    var positionAndSize: SIMD4<Float>   // x, y in centered scene pixels ; z = signed sprite X scale; w = size
    var color: SIMD4<Float>             // rgb 0…1, a = current alpha (base × fade envelope)
    var rotationAndLife: SIMD4<Float>   // x = rotationZ radians ; y = lifetimeFraction [0,1] ; z = spriteFrameIndex; w = signed sprite Y scale
    /// xy = render-space velocity (scene px/s). Only the TRAILRENDERER path
    /// reads it — WPE gates the matching `a_TexCoordVec4C1` on THICKFORMAT.
    var velocity: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 0)
}

/// One ribbon-strip vertex for the rope renderer. Layout MUST match
/// `WPEParticleRopeVertex` in `WPEMetalBuiltins.metal`.
struct WPEParticleRopeVertex {
    var positionUV: SIMD4<Float>        // xy = centered scene pixels (Y-up) ; zw = uv (u across, v along the rope)
    var color: SIMD4<Float>             // rgb 0…1, a = current alpha
}

/// Random source for particle spawn jitter. Value-typed so the existing
/// `Double.random(in:using:&rng)` / `Int.random(...:using:&rng)` call sites
/// compile unchanged — no existential opening, no heap allocation.
///
/// Production uses `.system` (the platform CSPRNG), byte-for-byte the historical
/// behavior. The render oracle injects `.seeded` so a scene renders identically
/// across runs — the prerequisite for same-machine before/after golden diffs.
enum WPEParticleRNG: RandomNumberGenerator {
    case system(SystemRandomNumberGenerator)
    case seeded(SplitMix64)

    mutating func next() -> UInt64 {
        switch self {
        case .system(var generator):
            let value = generator.next()
            self = .system(generator)
            return value
        case .seeded(var generator):
            let value = generator.next()
            self = .seeded(generator)
            return value
        }
    }
}

/// Deterministic, allocation-free 64-bit generator (Vigna's SplitMix64). Used only
/// under the render oracle to make particle spawn jitter reproducible run-to-run.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// One-shot world-space placement applied to a `WPEParticleSystem` at load time.
///
/// **Coordinate convention: WPE author space is Y-up, bottom-left
/// origin throughout — NO Y-flip anywhere.** Scene-object `origin`,
/// emitter `origin`, per-particle `velocity`, `gravity`, and the
/// object's `angles.z` rotation are all used as authored (`Rz(+angleZ)`),
/// matching the image-layer path (`WPEMetalRenderExecutor` passes
/// `geometry.angles.z` UNNEGATED into the quad rotation). An earlier
/// `Rz(-angleZ)` was justified as "clockwise author → Y-up CCW", but the
/// image quad — validated across many rotated layers — does NOT negate,
/// so the two disagreed; and its "verification" leaned on saber (~0°) and
/// 3725117707 (~159°), both sign-insensitive (0° trivial, 159°≈180°
/// symmetric). Scene 3462491575's 雪景 (angleZ −57.6°, sign-sensitive)
/// drifted right under `-angleZ` where WPE blows it left → align to the
/// image-layer `+angleZ`. Flipping preserves the leaves' vertical fall/rise
/// (that only depended on the ~180° symmetry) and mirrors their horizontal.
///
/// **Do NOT re-add an "emitter-internal Y-down" flip on
/// `velocity.y`/`gravity.y`/`origin.y`.** P7 (`dfbccce`) did exactly
/// that, believing it made leaves fall — it actually *inverted* every
/// leaf scene. The trap: scenes 3526278753 (saber) and 3725117707 share
/// ONE leaves preset but differ by a ~159° emitter rotation, so under
/// the correct no-flip Y-up convention the saber's leaves fall (down)
/// while 3725117707's rotated emitter sends them up. Whoever "fixes"
/// one scene's direction by toggling the global flip silently inverts
/// the other (this oscillated P4→P6→P7). The flip is the bug, not the
/// fix.
struct WPEParticleSceneTransform {
    var renderOrigin: SIMD3<Float>
    var objectScale: SIMD3<Float>
    var objectAngleZ: Float
    /// Scene render height (px); used to cap pathologically large additive
    /// sprites so a hugely-scaled emitter can't saturate the whole frame.
    var sceneHeight: Float

    init(sceneSize: SIMD2<Float>, objectOrigin: SIMD3<Float>, objectScale: SIMD3<Float>, objectAngleZ: Float) {
        self.renderOrigin = SIMD3<Float>(
            objectOrigin.x - sceneSize.x * 0.5,
            objectOrigin.y - sceneSize.y * 0.5,
            objectOrigin.z
        )
        self.objectScale = objectScale
        self.objectAngleZ = objectAngleZ
        self.sceneHeight = max(1, sceneSize.y)
    }

    static let identity = WPEParticleSceneTransform(
        sceneSize: SIMD2<Float>(1, 1),
        objectOrigin: SIMD3<Float>(0, 0, 0),
        objectScale: SIMD3<Float>(1, 1, 1),
        objectAngleZ: 0
    )

    /// Apply the scene-object model matrix
    /// `T(renderOrigin) · Rz(+angleZ) · S(scale)` to a point already
    /// in the emitter's Y-up local frame (matches the image-layer quad).
    func applyModelMatrix(toLocalPoint p: SIMD3<Float>) -> SIMD3<Float> {
        let scaled = SIMD3<Float>(p.x * objectScale.x, p.y * objectScale.y, p.z * objectScale.z)
        let cosA = cos(objectAngleZ)
        let sinA = sin(objectAngleZ)
        return renderOrigin + SIMD3<Float>(
            scaled.x * cosA - scaled.y * sinA,
            scaled.x * sinA + scaled.y * cosA,
            scaled.z
        )
    }

    /// Rotation + scale chain, no translation — for velocity, gravity, and
    /// other free vectors. NO Y-flip (author space and render frame are both
    /// Y-up); rotation is `+angleZ` (see the type doc — matches image layers).
    ///
    /// Oracle-tested (saber 3526278753): flipping velocity Y makes the leaves
    /// RISE (sim vy +78 instead of -74), whereas WPE's decoded velocity
    /// (TEXCOORD1) and ours are both NEGATIVE = falling. The older "velocity
    /// already had its Y flipped at spawn" note was wrong.
    func applyModelDirection(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let scaled = SIMD3<Float>(v.x * objectScale.x, v.y * objectScale.y, v.z * objectScale.z)
        let cosA = cos(objectAngleZ)
        let sinA = sin(objectAngleZ)
        return SIMD3<Float>(
            scaled.x * cosA - scaled.y * sinA,
            scaled.x * sinA + scaled.y * cosA,
            scaled.z
        )
    }

    func worldSizeMultiplier() -> Float {
        // WPE's CParticle model matrix is `T·R·S(scale)`, so the scene object's
        // scale DOES enlarge each billboard sprite (verified vs the 3426865175
        // preview). 2D (x,y) magnitude, averaged since sprites are square.
        // Additive-saturation risk from a hugely-scaled emitter is handled by a
        // blend-aware size cap at spawn, not by disabling the coupling.
        let s = (abs(objectScale.x) + abs(objectScale.y)) * 0.5
        return max(0, s)
    }

    func visualScaleSigns() -> SIMD2<Float> {
        SIMD2<Float>(
            objectScale.x < 0 ? -1 : 1,
            objectScale.y < 0 ? -1 : 1
        )
    }

    func visualRotationZ(localRotationZ: Float) -> Float {
        let signs = visualScaleSigns()
        let localRotation = signs.x * signs.y < 0 ? -localRotationZ : localRotationZ
        // `+angleZ` to match the flipped position/velocity chain and the image quad.
        return objectAngleZ + localRotation
    }

    func visualAngularZ(localAngularZ: Float) -> Float {
        let signs = visualScaleSigns()
        return signs.x * signs.y < 0 ? -localAngularZ : localAngularZ
    }
}

/// CPU-side emitter + GPU buffer. One instance per scene particle object.
///
/// Lifecycle:
///   - `init` clamps capacity, allocates the persistent GPU instance
///     buffer, and bakes the scene transform once.
///   - `prewarm(simulatedSeconds:)` (optional, after load) runs the
///     simulator forward without writing the GPU buffer so the first
///     frame the renderer presents already has the spawn population
///     spread out, killing the cold-start "one-particle-per-second"
///     visual stutter.
///   - `tick(now:)` advances every alive particle by the elapsed delta
///     since the last tick, recycles dead ones, and emits new ones at
///     the configured rate.
///   - `liveInstanceCount` returns the slice the renderer should bind.
final class WPEParticleSystem {
    let definition: WPEParticleDefinition
    let capacity: Int
    let blendMode: WPEParticleBlendMode
    let sceneTransform: WPEParticleSceneTransform
    let instanceBuffer: MTLBuffer
    /// True for a `renderer: [{name:"rope"}]` ribbon/trail. When set, `tick`
    /// fills `ropeVertexBuffer` with a triangle strip instead of `instanceBuffer`,
    /// and the executor draws that strip rather than instanced quads.
    let isRope: Bool
    /// Triangle-strip ribbon vertices (2 per knot), allocated only for rope
    /// systems. `nil` for ordinary sprite systems.
    let ropeVertexBuffer: MTLBuffer?
    /// Live ribbon vertex count written by the last `tick`; 0 ⇒ nothing to draw
    /// (fewer than 2 knots). The executor draws `[0, ropeVertexCount)` as a strip.
    private(set) var ropeVertexCount: Int = 0
    /// Atlas slicing metadata for the sprite texture. `nil` ⇒ single-
    /// frame static texture, the executor binds a full-UV pass-through
    /// sprite-sheet uniform (cols=rows=frames=1, mask=0).
    let spriteSheet: WPEParticleSpriteSheet?
    /// Per-axis camera-parallax depth (WPE Vec2) of the owning particle object;
    /// drives the per-frame parallax translation applied to the whole system at
    /// draw time.
    var parallaxDepth: SIMD2<Double> = SIMD2<Double>(0, 0)
    /// Owning particle object's WPE scene paint index — where this system
    /// composites relative to image layers (background behind, character front).
    var sortIndex: Int = 0
    /// Material `ui_editor_properties_overbright` colour multiplier (>1 brighter,
    /// <1 dimmer). Bound into the fragment uniform; defaults to 1 (no change).
    var overbright: Float = 1.0
    /// `genericparticle` REFRACT: draw via the screen-space refraction pipeline
    /// (multiply by the scene framebuffer at a normal-offset UV) instead of a flat
    /// sprite. Set only when the refraction normal map also loaded.
    var isRefract: Bool = false
    /// `g_RefractAmount` — screen-UV refraction offset scale (WPE default 0.05).
    var refractAmount: Float = 0.05
    /// True for a system expanded from a `children` reference. WPE scales a
    /// nested child's sprites by the CHILD's own scale (its reference carries
    /// `scale`, here always 1), not the owning layer's: 3462491575's matrix
    /// glyphs (size 100 on a 2× layer) measure ~100px on Windows, not 200px.
    /// The layer scale still spreads child spawn POSITIONS via
    /// `applyModelMatrix` — only the per-sprite quad size opts out.
    var isNestedChildSystem: Bool = false
    /// Full-frame R8 opacity mask baked from the particle's parent composelayer
    /// (WPE isolates the system into that group and applies its opacity effect).
    /// When set, the fragment multiplies each sprite's alpha by the mask sampled
    /// at screen position — confining the system to the authored region (matrix
    /// rain → upper-centre blob). `nil` = no spatial confine.
    var groupOpacityMask: MTLTexture?
    /// Colour multiplier baked from the parent composelayer's tint effect
    /// (1,1,1 = no tint). Applied in the particle fragment.
    var groupTint: SIMD3<Float> = SIMD3<Float>(1, 1, 1)
    /// Live cursor position in the centered render frame (Y-up), or `nil` when
    /// the scene's "Follow Cursor" toggle is off / no pointer is available. Set
    /// by the renderer each frame; drives pointer-locked control points
    /// (emitter-follow + `controlpointattract`).
    var pointerCentered: SIMD2<Float>?

    /// Event-follow (`type:"eventfollow"`) wiring. The renderer injects the
    /// parent system's live particle position into `injectedControlPoints` each
    /// frame so this child's emitter + `controlpointattract` ride the parent
    /// (the matrix trail follows its falling code head). WPE's follow control
    /// point is id 1.
    weak var followParent: WPEParticleSystem?
    var followControlPointID: Int = 1
    var requiresFollowParent: Bool = false
    var injectedControlPoints: [Int: SIMD3<Float>] = [:]

    private let attractors: [WPEParticleControlPointAttractor]
    private let emitterTracksPointer: Bool
    /// Raw control-point offsets keyed by id; pointer-locked ids resolve against
    /// the live cursor, others against the static scene-object transform.
    private let controlPointRawOffsets: [Int: SIMD3<Float>]
    private let pointerLockedControlPointIDs: Set<Int>

    private var aliveCount: Int = 0
    /// Diagnostic: how many particles a control-point attractor pushed/pulled
    /// on the last tick. With attractors present and a live pointer, 0 means
    /// nothing is landing in range.
    private(set) var lastAttractorAffectedCount = 0
    private var particles: [Particle]
    private var spawnAccumulator: Double = 0
    /// One-shot guard for the emitter's `instantaneous` burst, which fires the
    /// first time `elapsed` reaches `startDelay` (explosions/fireworks/seed).
    private var hasEmittedBurst = false
    private var lastTickTime: Double?
    private var firstTickTime: Double?
    private var rng: WPEParticleRNG
    /// `turbulentvelocityrandom` noise sample point — ONE per system, not one per
    /// particle: WPE captures it in the initializer closure and lets each spawn
    /// nudge it along its own curl streamline, so successive particles ride the
    /// same slowly-turning gust. Seeded once (below); the walk consumes no RNG.
    private var turbulentSamplePoint = SIMD3<Double>.zero
    /// Cached gravity in render space (Y-up). Mirrors the velocity rule:
    /// flip emitter-local Y once, then apply the scene object's scale
    /// and rotation without translating.
    private let gravity: SIMD3<Float>
    /// `oscillateposition` sway mask transformed into render space (so the
    /// displacement rotates/scales with the scene object, like velocity).
    /// `applyModelDirection` is linear, so the per-particle amplitude can be
    /// multiplied in afterwards. Zero when the operator is absent.
    private let oscillatePositionMask: SIMD3<Float>

    /// Pre-allocated GPU buffer of explicit TEXS frame UV rects (vertex
    /// buffer index 4). Built once at init from `spriteSheet.frameRects`,
    /// so the draw loop never re-uploads them and large atlases can't trip
    /// the 4 KB `setVertexBytes` inline-constant limit. `nil` ⇒ uniform-grid
    /// slicing (or no sheet).
    let frameRectsBuffer: MTLBuffer?

    /// Hard ceiling so a single emitter can't blow the GPU memory budget.
    /// 8K particles × 48 bytes = 384 KB per system.
    static let absoluteCap = 8192
    /// Perspective near-depth boost. Positive Z is toward the camera in WPE's
    /// particle perspective path: `depthScale(z) = 1 + boost * clamp(z/maxDepth)`.
    /// This makes +Z gravity starfields expand radially toward the viewer instead
    /// of collapsing back to the vanishing point.
    static let perspectiveNearBoost: Float = 1.5

    /// Stable per-system oracle seed: reproducible across reloads, unique per
    /// (scene, object, paint order). Uses FNV-1a for the scene id — NOT Swift's
    /// `Hasher`, which is randomly salted per process and would break run-to-run
    /// reproducibility. Only consulted when `WPEOracleMode.isEnabled`.
    static func deterministicSeed(workshopID: String, objectID: String, sortIndex: Int) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325  // FNV-1a 64-bit offset basis
        let prime: UInt64 = 0x0000_0100_0000_01B3  // FNV-1a 64-bit prime
        func mix(_ string: String) {
            for byte in string.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* prime
            }
            hash ^= 0x5C  // '\' separator so mix("a")+mix("b") ≠ mix("ab")
            hash = hash &* prime
        }
        mix(workshopID)
        mix(objectID)
        return hash ^ UInt64(bitPattern: Int64(sortIndex))
    }

    private struct Particle {
        var position: SIMD3<Float>
        var velocity: SIMD3<Float>
        var size: Float
        var color: SIMD3<Float>
        var rotationZ: Float
        var angularVelocityZ: Float
        var alphaBase: Float
        var lifetime: Float
        var age: Float       // Float.greatestFiniteMagnitude when slot is free
        /// Per-particle turbulence inputs sampled once at spawn; the
        /// operator pumps a deterministic noise field every frame.
        var turbulenceSpeed: Float
        var turbulencePhase: Float
        /// Sprite-sheet frame this particle locks onto when the system is
        /// in `.randomFrame` mode (chosen once at spawn). Ignored by
        /// `.sequence` particles, which animate off `age/lifetime`.
        var staticFrame: Float
        /// Per-particle `oscillateposition` inputs sampled once at spawn
        /// (frequency, amplitude in pixels, phase). The operator adds a
        /// transient sine displacement every frame; zero when absent.
        var oscPosFrequency: Float
        var oscPosScale: Float
        var oscPosPhase: Float
        /// Per-particle `oscillatealpha` draw (WPE randomizes both per particle,
        /// which is what keeps a star field twinkling out of phase).
        var oscAlphaFrequency: Float
        var oscAlphaPhase: Float
    }

    init?(
        definition: WPEParticleDefinition,
        device: MTLDevice,
        blendMode: WPEParticleBlendMode = .translucent,
        sceneTransform: WPEParticleSceneTransform = .identity,
        spriteSheet: WPEParticleSpriteSheet? = nil,
        seed: UInt64? = nil
    ) {
        self.definition = definition
        self.blendMode = blendMode
        self.sceneTransform = sceneTransform
        self.spriteSheet = spriteSheet
        let cap = max(1, min(definition.maxCount, Self.absoluteCap))
        self.capacity = cap
        self.particles = .init(repeating: Particle(
            position: .zero,
            velocity: .zero,
            size: 0,
            color: SIMD3(1, 1, 1),
            rotationZ: 0,
            angularVelocityZ: 0,
            alphaBase: 1,
            lifetime: 0,
            age: .greatestFiniteMagnitude,
            turbulenceSpeed: 0,
            turbulencePhase: 0,
            staticFrame: 0,
            oscPosFrequency: 0,
            oscPosScale: 0,
            oscPosPhase: 0,
            oscAlphaFrequency: 0,
            oscAlphaPhase: 0
        ), count: cap)
        guard let buffer = device.makeBuffer(
            length: cap * MemoryLayout<WPEParticleInstance>.stride,
            options: [.storageModeShared]
        ) else {
            return nil
        }
        buffer.label = "WPE particle instances"
        self.instanceBuffer = buffer
        self.isRope = definition.isRope
        if definition.isRope {
            // 2 edge vertices per knot. A failed allocation degrades to "no rope
            // draw" rather than failing the whole system.
            let ropeBuffer = device.makeBuffer(
                length: cap * 2 * MemoryLayout<WPEParticleRopeVertex>.stride,
                options: [.storageModeShared]
            )
            ropeBuffer?.label = "WPE particle rope strip"
            self.ropeVertexBuffer = ropeBuffer
        } else {
            self.ropeVertexBuffer = nil
        }
        // Production (seed == nil) keeps the system CSPRNG, byte-for-byte the
        // historical spawn jitter. The oracle passes a stable seed for reproducible
        // traces; see `WPEParticleSystem.deterministicSeed`.
        if let seed {
            self.rng = .seeded(SplitMix64(seed: seed))
        } else {
            self.rng = .system(SystemRandomNumberGenerator())
        }
        // Y-up author space: gravity is used as authored (no flip), then
        // honored through the scene object's scale/rotation like velocity.
        let localGravity = SIMD3<Float>(
            Float(definition.gravity.x),
            Float(definition.gravity.y),
            Float(definition.gravity.z)
        )
        self.gravity = sceneTransform.applyModelDirection(localGravity)
        if let osc = definition.oscillatePosition {
            // WPE's mask GATES an axis, it does not scale it
            // (WPParticleParser.cpp: `if (mask[d] < 0.01) continue;` then the
            // full-amplitude move). snowperspective authors "1 0.5 0" — scaling
            // by 0.5 halved the vertical sway instead of simply enabling it.
            let gate = SIMD3<Float>(
                osc.mask.x < 0.01 ? 0 : 1,
                osc.mask.y < 0.01 ? 0 : 1,
                osc.mask.z < 0.01 ? 0 : 1
            )
            self.oscillatePositionMask = sceneTransform.applyModelDirection(gate)
        } else {
            self.oscillatePositionMask = .zero
        }
        if let rects = spriteSheet?.frameRects, !rects.isEmpty {
            // Upload once; a failed allocation degrades to uniform-grid slicing
            // rather than failing the whole system.
            let buffer = rects.withUnsafeBytes { bytes in
                device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: [.storageModeShared])
            }
            buffer?.label = "WPE particle frame rects"
            self.frameRectsBuffer = buffer
        } else {
            self.frameRectsBuffer = nil
        }
        self.attractors = definition.attractors
        self.emitterTracksPointer = definition.emitterTracksPointer
        var offsets: [Int: SIMD3<Float>] = [:]
        var pointerIDs: Set<Int> = []
        for cp in definition.controlPoints {
            offsets[cp.id] = SIMD3<Float>(Float(cp.offset.x), Float(cp.offset.y), Float(cp.offset.z))
            if cp.pointerLocked { pointerIDs.insert(cp.id) }
        }
        self.controlPointRawOffsets = offsets
        self.pointerLockedControlPointIDs = pointerIDs
        // Drawn only for systems that actually have the initializer, so every
        // other system's spawn draw sequence stays byte-identical for the oracle.
        if definition.turbulentVelocityInit != nil {
            turbulentSamplePoint = SIMD3<Double>(
                Double.random(in: 0..<10, using: &rng),
                Double.random(in: 0..<10, using: &rng),
                Double.random(in: 0..<10, using: &rng)
            )
        }
    }

    /// Resolves a control point's position in the centered render frame.
    /// Injected points (event-follow parent position) win first, so a follow
    /// child attracts toward the parent particle instead of its static authored
    /// control point. Pointer-locked points follow the live cursor (nil when
    /// unavailable); static points are placed via the scene-object transform.
    func controlPointPosition(_ id: Int) -> SIMD3<Float>? {
        if let injected = injectedControlPoints[id] { return injected }
        if requiresFollowParent && id == followControlPointID { return nil }
        let rawOffset = controlPointRawOffsets[id] ?? .zero
        if pointerLockedControlPointIDs.contains(id) {
            guard let p = pointerCentered else { return nil }
            return SIMD3<Float>(p.x, p.y, 0) + sceneTransform.applyModelDirection(rawOffset)
        }
        return sceneTransform.applyModelMatrix(toLocalPoint: rawOffset)
    }

    /// One-line cursor-reactivity diagnostic snapshot; `nil` for systems with
    /// no cursor interaction. Reports whether the pointer-locked control point
    /// resolves (i.e. the cursor is live) and how many particles the
    /// attractors actually moved last tick.
    func cursorDebugSummary() -> String? {
        guard !attractors.isEmpty || !pointerLockedControlPointIDs.isEmpty else { return nil }
        func fmt(_ v: SIMD3<Float>?) -> String {
            v.map { "(\(Int($0.x)),\(Int($0.y)))" } ?? "nil"
        }
        let lockedCPs = pointerLockedControlPointIDs.sorted()
        let resolved = lockedCPs.map { "cp\($0)=\(fmt(controlPointPosition($0)))" }.joined(separator: " ")
        return "alive=\(aliveCount) attractors=\(attractors.count) "
            + "pointerLocked=[\(resolved)] affectedLastTick=\(lastAttractorAffectedCount)"
    }

    private func uniform(_ low: Double, _ high: Double) -> Double {
        // WPE min/max are two corners of a range, NOT ordered: `velocityrandom`
        // often authors max more-negative than min (e.g. snowperspective's
        // "-10 -50 0" … "-37 -90 0"). Sample the span regardless of order — the
        // old `high > low` guard returned `low`, pinning every such component to
        // its min so 3462491575's 雪景 fell at the slow end of its speed range.
        let lo = Swift.min(low, high)
        let hi = Swift.max(low, high)
        guard hi > lo else { return lo }
        let r = Double.random(in: 0...1, using: &rng)
        return lo + (hi - lo) * r
    }

    private func uniformVector(_ low: SIMD3<Double>, _ high: SIMD3<Double>) -> SIMD3<Float> {
        SIMD3<Float>(
            Float(uniform(low.x, high.x)),
            Float(uniform(low.y, high.y)),
            Float(uniform(low.z, high.z))
        )
    }

    /// `colorrandom` is the ONE VecRandom that does NOT draw per channel: WPE
    /// pulls a single `t` and lerps all three with it (WPParticleParser.cpp's
    /// `Color()`), so the result always lands on the min→max LINE. Drawing per
    /// channel lets each pick its own end — snowperspective
    /// (min 255,255,255 → max 95,98,100) then produced red/green flecks instead
    /// of WPE's single white→grey ramp.
    private func lerpVector(_ low: SIMD3<Double>, _ high: SIMD3<Double>) -> SIMD3<Float> {
        let t = uniform(0, 1)
        return SIMD3<Float>(
            Float(low.x + (high.x - low.x) * t),
            Float(low.y + (high.y - low.y) * t),
            Float(low.z + (high.z - low.z) * t)
        )
    }

    static func dispersalVector(
        radius: Double,
        theta: Double,
        phi: Double,
        mask: SIMD3<Float>
    ) -> SIMD3<Float> {
        let enabledX = abs(mask.x) > 0.0001
        let enabledY = abs(mask.y) > 0.0001
        let enabledZ = abs(mask.z) > 0.0001
        let enabledCount = [enabledX, enabledY, enabledZ].filter { $0 }.count
        let r = Float(radius)

        switch enabledCount {
        case 0:
            return SIMD3<Float>(0, 0, 0)
        case 1:
            let sign: Float = cos(theta) >= 0 ? 1 : -1
            return SIMD3<Float>(
                enabledX ? r * sign * mask.x : 0,
                enabledY ? r * sign * (-mask.y) : 0,
                enabledZ ? r * sign * mask.z : 0
            )
        case 2:
            let a = r * Float(cos(theta))
            let b = r * Float(sin(theta))
            if enabledX && enabledY {
                return SIMD3<Float>(a * mask.x, b * (-mask.y), 0)
            }
            if enabledX && enabledZ {
                return SIMD3<Float>(a * mask.x, 0, b * mask.z)
            }
            return SIMD3<Float>(0, a * (-mask.y), b * mask.z)
        default:
            return SIMD3<Float>(
                Float(radius * sin(phi) * cos(theta) * Double(mask.x)),
                Float(radius * sin(phi) * sin(theta) * Double(-mask.y)),
                Float(radius * cos(phi) * Double(mask.z))
            )
        }
    }

    /// Advance the simulator without writing the GPU instance buffer.
    /// Called once after scene load so the first real `tick(now:)`
    /// presents a population that's already past `startDelay` and has
    /// a few seconds of spread. `step` is the per-substep delta — pick
    /// something close to a frame (~16ms) so spawn/integration math
    /// stays accurate.
    func prewarm(simulatedSeconds: Double, step: Double = 1.0 / 60) {
        guard simulatedSeconds > 0, step > 0,
              definition.rate > 0 || definition.instantaneousCount > 0 else { return }
        let delay = max(0, definition.startDelay)
        let activeStart = min(delay, simulatedSeconds)
        if simulatedSeconds <= activeStart {
            firstTickTime = -simulatedSeconds
            lastTickTime = 0
            return
        }
        firstTickTime = 0
        lastTickTime = activeStart
        var virtualNow = activeStart
        let substeps = Int(((simulatedSeconds - activeStart) / step).rounded(.up))
        for _ in 0..<substeps {
            virtualNow = min(simulatedSeconds, virtualNow + step)
            advance(now: virtualNow)
        }
        // The renderer's real frame clock starts at 0 after load. Keep
        // the prewarmed particle ages/positions, but re-anchor internal
        // tick bookkeeping so the first live frames do not see a
        // future `lastTickTime` and freeze until wall time catches up.
        firstTickTime = -virtualNow
        lastTickTime = 0
    }

    /// Per-particle draw attributes shared by the sprite and rope paths: the
    /// operator-modulated alpha (fade envelope × alphachange × oscillatealpha),
    /// the `sizechange`-scaled + additive-capped size, the `colorchange` tint,
    /// the `oscillateposition`-swayed draw position, and the lifetime fraction.
    /// Rotation/sprite-frame are sprite-only and stay in `tick`.
    private func drawAttributes(
        of particle: Particle
    ) -> (position: SIMD3<Float>, rgb: SIMD3<Float>, alpha: Float, size: Float, lifetimeFraction: Float) {
        let envelope = fadeEnvelope(age: particle.age, lifetime: particle.lifetime)
        let lifetimeFraction = particle.lifetime > 0 ? min(1, max(0, particle.age / particle.lifetime)) : 0
        var alpha = particle.alphaBase * envelope
        if let alphaChange = definition.alphaChange {
            alpha *= Float(alphaChange.factor(lifetimeFraction: Double(lifetimeFraction)))
        }
        if let overrideAlpha = definition.overrideAlphaAnimation,
           let scale = overrideAlpha.scalar(at: systemElapsed) {
            alpha *= Float(max(0, scale))
        }
        if let oscillateAlpha = definition.oscillateAlpha {
            alpha *= Float(oscillateAlpha.factor(
                age: Double(particle.age),
                frequency: Double(particle.oscAlphaFrequency),
                phase: Double(particle.oscAlphaPhase)
            ))
        }
        alpha = min(max(alpha, 0), 1)
        // `sizechange`: lifetime-fraction multiplier on the sprite quad.
        var spriteSize = particle.size
        if let sizeChange = definition.sizeChange {
            spriteSize *= Float(sizeChange.factor(lifetimeFraction: Double(lifetimeFraction)))
        }
        // Re-apply the additive cap on the FINAL size: `sizechange` can grow
        // the sprite past the spawn-time cap and re-hit the saturation path.
        if blendMode == .additive {
            spriteSize = min(spriteSize, sceneTransform.sceneHeight)
        }
        // `colorchange`: lifetime-fraction RGB multiplier on the tint — only
        // for particles that authored a colour initializer. A texture-coloured
        // particle with no base colour (wildfire's white r8 smoke) must keep
        // its texture colour, not get ramped to the operator's hue → red.
        var rgb = particle.color
        if definition.hasColorInitializer, let colorChange = definition.colorChange {
            let c = colorChange.color(lifetimeFraction: Double(lifetimeFraction))
            rgb *= SIMD3<Float>(Float(c.x), Float(c.y), Float(c.z))
        }
        // `oscillateposition`: transient sine sway (never integrated into
        // the stored position, so the particle sways without drifting).
        var drawPosition = particle.position
        if particle.oscPosScale != 0, particle.oscPosFrequency != 0 {
            // `frequency` IS the angular rate, and `phase` is in radians. WPE's
            // GetMove computes `f = frequency/2π` then `w = 2π·f` — the two
            // cancel, so w == frequency. Folding an extra 2π in ran the sway
            // 6.28× too fast: its peak speed (A·w = 35·2π ≈ 220 px/s) overtook
            // snowperspective's 50–90 px/s fall, so snow visibly flew back
            // upward. At w = frequency the peak is ~35 px/s and the drift never
            // reverses, matching Windows.
            let sway = sin(particle.age * particle.oscPosFrequency + particle.oscPosPhase)
            drawPosition += oscillatePositionMask * (sway * particle.oscPosScale)
        }
        // Perspective (`flags & 4`): project draw position + size through a depth
        // scale about the emitter's vanishing point. Positive Z is near/toward
        // camera, so +Z motion pushes particles outward and makes them grow.
        if definition.isPerspective {
            let scale = perspectiveDepthScale(depth: particle.position.z)
            let vp = sceneTransform.renderOrigin
            drawPosition = SIMD3<Float>(
                vp.x + (drawPosition.x - vp.x) * scale,
                vp.y + (drawPosition.y - vp.y) * scale,
                drawPosition.z
            )
            spriteSize *= scale
        }
        return (drawPosition, rgb, alpha, spriteSize, lifetimeFraction)
    }

    /// `1 + boost * clamp(z/maxDepth)` in `[1, 1+boost]`: nonpositive/far depth
    /// stays at 1x, positive/toward-camera depth grows to `1+boost`. Drives both
    /// sprite size and draw-position projection, so a WPE perspective starfield
    /// with +Z gravity flies outward toward the camera. `maxDepth` must include
    /// authored spawn depth AND the Z distance a particle can travel during its
    /// life; some WPE starfields spawn in a flat XY disk (`directions.z == 0`)
    /// and move through depth solely via Z gravity.
    private func perspectiveDepthScale(depth z: Float) -> Float {
        let maxDepth = perspectiveDepthExtent()
        let t = min(max(z / maxDepth, 0), 1)
        return 1 + Self.perspectiveNearBoost * t
    }

    private func perspectiveDepthExtent() -> Float {
        let localSpawnDepth: Double
        switch definition.emitterShape {
        case .box:
            localSpawnDepth = abs(definition.dispersalMax.z)
        case .sphere:
            localSpawnDepth = abs(definition.dispersalMax.z * definition.directionMask.z)
        }
        let spawnDepth = Float(localSpawnDepth) * max(0.0001, abs(sceneTransform.objectScale.z))
        let lifetime = Float(max(definition.lifetimeMin, definition.lifetimeMax, 0))
        let localVelocityMin = SIMD3<Float>(
            Float(definition.velocityMin.x),
            Float(definition.velocityMin.y),
            Float(definition.velocityMin.z)
        )
        let localVelocityMax = SIMD3<Float>(
            Float(definition.velocityMax.x),
            Float(definition.velocityMax.y),
            Float(definition.velocityMax.z)
        )
        let velocityDepth = max(
            abs(sceneTransform.applyModelDirection(localVelocityMin).z),
            abs(sceneTransform.applyModelDirection(localVelocityMax).z)
        ) * lifetime
        let gravityDepth = abs(gravity.z) * lifetime * lifetime * 0.5
        return max(1, spawnDepth, velocityDepth, gravityDepth)
    }

    func tick(now: Double) {
        advance(now: now)
        if isRope {
            buildRopeGeometry()
            return
        }
        let pointer = instanceBuffer.contents().bindMemory(to: WPEParticleInstance.self, capacity: capacity)
        // Sprite-sheet frame selection splits on `animationmode`:
        //
        //   • `.sequence` — animate the atlas **lifetime-relative**: a
        //     particle sees `sequenceMultiplier` full cycles over its
        //     life (wildfire: multiplier 1, 32 frames over ~2.5s ≈ 13 fps).
        //     We deliberately ignore the `.tex-json` wall-clock `duration`
        //     (Almamu's ~90 fps reading on leaves7 flickers); the lifetime
        //     reading matches the pace workshop authors tune for. There is
        //     NO ×2 fudge — that was a single-scene hack that doubled every
        //     `sequence` particle's speed (see WPE wildfire too-fast bug).
        //
        //   • `.randomFrame` — each particle froze on one atlas cell at
        //     spawn (`spawn(into:)`), so it never animates; we emit that
        //     fixed `staticFrame` (debris shards, embers — a *different
        //     static* piece per particle, the WPE shatter look).
        //
        // `frameCount = 1` (no sheet) collapses to a static sprite either way.
        let frameCount: Float = Float(max(1, spriteSheet?.frameCount ?? 1))
        let animatesSequence = definition.animationMode == .sequence && frameCount > 1
        let cyclesPerLifetime = max(0.0001, Float(definition.sequenceMultiplier))
        let visualScaleSigns = sceneTransform.visualScaleSigns()
        var written = 0
        for index in 0..<capacity {
            guard particles[index].age != .greatestFiniteMagnitude else { continue }
            let particle = particles[index]
            let attrs = drawAttributes(of: particle)
            let lifetimeFraction = attrs.lifetimeFraction
            let alpha = attrs.alpha
            let spriteSize = attrs.size
            let rgb = attrs.rgb
            let drawPosition = attrs.position
            let frameIndex: Float
            if animatesSequence {
                let raw = lifetimeFraction * cyclesPerLifetime * frameCount
                frameIndex = raw.truncatingRemainder(dividingBy: frameCount)
            } else {
                // `.randomFrame` (or single-frame sprite): the spawn-time
                // locked cell, floored so the shader's cross-fade picks it
                // cleanly with blend 0.
                frameIndex = particle.staticFrame
            }
            pointer[written] = WPEParticleInstance(
                positionAndSize: SIMD4<Float>(
                    drawPosition.x, drawPosition.y, visualScaleSigns.x, spriteSize
                ),
                color: SIMD4<Float>(rgb.x, rgb.y, rgb.z, alpha),
                rotationAndLife: SIMD4<Float>(particle.rotationZ, lifetimeFraction, frameIndex, visualScaleSigns.y),
                velocity: SIMD4<Float>(particle.velocity.x, particle.velocity.y, 0, 0)
            )
            written += 1
        }
        aliveCount = written
    }

    /// Build the rope ribbon: order the live particles by age (emission order,
    /// since the slot pool interleaves free slots), then emit two edge vertices
    /// per knot offset ±half-size along the segment normal. A stationary control
    /// point ⇒ coincident knots ⇒ a zero-area strip that draws nothing, which is
    /// exactly why this replaces the additive-sprite pile (scene 3351072238).
    private func buildRopeGeometry() {
        guard let buffer = ropeVertexBuffer else {
            aliveCount = 0
            ropeVertexCount = 0
            return
        }
        var knots: [(position: SIMD2<Float>, color: SIMD4<Float>, halfSize: Float, age: Float)] = []
        knots.reserveCapacity(capacity)
        for index in 0..<capacity {
            let particle = particles[index]
            guard particle.age != .greatestFiniteMagnitude else { continue }
            let attrs = drawAttributes(of: particle)
            knots.append((
                SIMD2<Float>(attrs.position.x, attrs.position.y),
                SIMD4<Float>(attrs.rgb.x, attrs.rgb.y, attrs.rgb.z, attrs.alpha),
                max(0, attrs.size * 0.5),
                particle.age
            ))
        }
        aliveCount = knots.count
        guard knots.count >= 2 else {
            ropeVertexCount = 0
            return
        }
        knots.sort { $0.age < $1.age }

        let verts = buffer.contents().bindMemory(to: WPEParticleRopeVertex.self, capacity: capacity * 2)
        let count = knots.count
        // Carry the last valid normal across degenerate (coincident) segments so
        // a momentary overlap doesn't collapse the ribbon to a spike.
        var lastNormal = SIMD2<Float>(0, 1)
        var written = 0
        for i in 0..<count {
            let prev = knots[max(0, i - 1)].position
            let next = knots[min(count - 1, i + 1)].position
            let tangent = next - prev
            let length = (tangent.x * tangent.x + tangent.y * tangent.y).squareRoot()
            var normal = lastNormal
            if length > 1e-4 {
                let unit = tangent / length
                normal = SIMD2<Float>(-unit.y, unit.x)
                lastNormal = normal
            }
            let knot = knots[i]
            let offset = normal * knot.halfSize
            let along = Float(i) / Float(count - 1)   // v runs 0→1 head→tail
            verts[written] = WPEParticleRopeVertex(
                positionUV: SIMD4<Float>(knot.position.x + offset.x, knot.position.y + offset.y, 0, along),
                color: knot.color
            )
            verts[written + 1] = WPEParticleRopeVertex(
                positionUV: SIMD4<Float>(knot.position.x - offset.x, knot.position.y - offset.y, 1, along),
                color: knot.color
            )
            written += 2
        }
        ropeVertexCount = written
    }

    var liveInstanceCount: Int { aliveCount }

    /// True when control point 0 follows the cursor (particles spawn at the
    /// pointer). These are the "mouse-generated" particles that must stop and
    /// clear when Follow Cursor is turned off.
    var tracksPointer: Bool { emitterTracksPointer }

    /// Kill every live particle immediately and drop the in-flight emission
    /// backlog. Called when Follow Cursor is disabled so pointer-spawned
    /// particles vanish at once instead of aging out — and so a paused/static
    /// frame can't keep showing them.
    func clearLiveParticles() {
        for index in 0..<capacity {
            particles[index].age = .greatestFiniteMagnitude
        }
        aliveCount = 0
        spawnAccumulator = 0
    }

    /// Representative live particle in render-frame coordinates, used as the
    /// event-follow anchor for child systems. The youngest alive particle is
    /// the right choice (a maxcount-1 head returns its sole particle); `nil`
    /// when nothing is alive.
    var primaryLiveParticlePosition: SIMD3<Float>? {
        var bestPosition: SIMD3<Float>?
        var bestAge = Float.greatestFiniteMagnitude
        for particle in particles where particle.age != .greatestFiniteMagnitude && particle.age < bestAge {
            bestAge = particle.age
            bestPosition = particle.position
        }
        return bestPosition
    }

    /// Integrate every alive particle and spawn new ones. Split from
    /// `tick(now:)` so `prewarm` can advance the simulator without
    /// touching the GPU buffer.
    /// Seconds since this system's first tick. `instanceoverride.alpha` tracks run
    /// on this system timeline (not per-particle age).
    private var systemElapsed: Double = 0

    private func advance(now: Double) {
        defer { lastTickTime = now }
        if firstTickTime == nil { firstTickTime = now }
        let dt: Float
        if let last = lastTickTime {
            dt = Float(max(0, min(now - last, 0.1)))
        } else {
            dt = 0
        }
        let elapsed = now - (firstTickTime ?? now)
        systemElapsed = elapsed
        let dragScalar: Float = max(0, 1 - Float(definition.drag) * dt)
        let angularDragScalar: Float = max(0, 1 - Float(definition.angularDrag) * dt)
        let angularForce = sceneTransform.visualAngularZ(localAngularZ: Float(definition.angularForceZ))
        // `turbulence` OPERATOR: a per-frame curl-noise wind, applied in render
        // space as an ACCELERATION (velocity += force·dt), matching the reference
        // renderer — not a transient position nudge. Absent ⇒ no per-frame wind
        // (leaves, whose only turbulence is the spawn-time initializer, must NOT
        // get this continuous sway).
        let turbulenceOp = definition.turbulence
        let turbulenceScale = turbulenceOp.map { $0.scale * 2 } ?? 0
        let turbulenceTimescale = turbulenceOp.map(\.timescale) ?? 0
        let turbulenceMask = turbulenceOp.map {
            SIMD3<Double>($0.mask.x, $0.mask.y, $0.mask.z)
        } ?? .zero

        var attractorAffectedThisTick = 0
        for index in 0..<capacity {
            guard particles[index].age != .greatestFiniteMagnitude else { continue }
            particles[index].age += dt
            if particles[index].age >= particles[index].lifetime {
                particles[index].age = .greatestFiniteMagnitude
                continue
            }
            // Linear motion with gravity + drag.
            particles[index].velocity += gravity * dt
            if dragScalar < 1 { particles[index].velocity *= dragScalar }
            // Control-point attract/repel (cursor follow/avoid). Force points
            // toward the control point; negative `scale` repels. Linear falloff
            // to zero at `threshold`, in the scene plane.
            if !attractors.isEmpty {
                let pos = particles[index].position
                var affectedThisParticle = false
                for attractor in attractors {
                    guard let cp = controlPointPosition(attractor.controlPointID) else { continue }
                    let dx = cp.x - pos.x
                    let dy = cp.y - pos.y
                    let dist = (dx * dx + dy * dy).squareRoot()
                    let threshold = Float(attractor.threshold)
                    guard dist > 1e-3, dist < threshold else { continue }
                    let falloff = 1 - dist / threshold
                    let accel = Float(attractor.scale) * falloff / dist
                    particles[index].velocity.x += dx * accel * dt
                    particles[index].velocity.y += dy * accel * dt
                    affectedThisParticle = true
                }
                if affectedThisParticle { attractorAffectedThisTick += 1 }
            }
            if turbulenceOp != nil, particles[index].turbulenceSpeed > 0 {
                let pos = particles[index].position
                // Scroll the field along X by phase + timescale·t, then sample the
                // curl direction and accelerate along it (masked per axis).
                let sample = SIMD3<Double>(
                    Double(pos.x) + Double(particles[index].turbulencePhase) + turbulenceTimescale * elapsed,
                    Double(pos.y),
                    Double(pos.z)
                ) * turbulenceScale
                let dir = WPEParticleCurlNoise.direction(at: sample)
                let speed = Double(particles[index].turbulenceSpeed)
                particles[index].velocity.x += Float(dir.x * speed * turbulenceMask.x) * dt
                particles[index].velocity.y += Float(dir.y * speed * turbulenceMask.y) * dt
                particles[index].velocity.z += Float(dir.z * speed * turbulenceMask.z) * dt
            }
            particles[index].position += particles[index].velocity * dt
            // Angular motion with force + drag.
            particles[index].angularVelocityZ += angularForce * dt
            if angularDragScalar < 1 { particles[index].angularVelocityZ *= angularDragScalar }
            particles[index].rotationZ += particles[index].angularVelocityZ * dt
        }
        lastAttractorAffectedCount = attractorAffectedThisTick

        if elapsed >= definition.startDelay {
            // One-time `instantaneous` burst (explosions, fireworks, initial
            // seed). Fires once, the first time the emitter starts; capped by
            // free slots (i.e. maxCount). Independent of `rate`, so rate:0
            // burst-only emitters still spawn.
            if !hasEmittedBurst && definition.instantaneousCount > 0 {
                var blockedByMissingFollowParent = false
                for _ in 0..<definition.instantaneousCount {
                    guard let slot = nextFreeSlot() else { break }
                    if !spawn(into: slot) {
                        // Event-follow child with no live parent yet — retry the
                        // whole burst next tick rather than burning it on a no-op.
                        blockedByMissingFollowParent = true
                        break
                    }
                }
                if !blockedByMissingFollowParent {
                    hasEmittedBurst = true
                }
            }
            // Continuous `rate` emission (particles per second).
            if definition.rate > 0 {
                spawnAccumulator += Double(dt) * definition.rate
                while spawnAccumulator >= 1 {
                    spawnAccumulator -= 1
                    guard let slot = nextFreeSlot() else { break }
                    spawn(into: slot)
                }
                // While the pool is saturated (rate × lifetime > maxCount) the
                // backlog must not accrue, or every freed wave would replay it
                // as one synchronized burst instead of a continuous stream.
                spawnAccumulator = min(spawnAccumulator, 1)
            }
        }
    }

    #if !LITE_BUILD && DEBUG
    /// Dev-only: per-alive-particle state for oracle comparison against WPE's
    /// decoded particle vertex buffer (POSITION + TEXCOORD1.xyz=velocity +
    /// TEXCOORD.xyz/.w=rotation/size, confirmed from genericparticle.vert).
    func particleStateDumpText() -> String {
        var lines: [String] = [
            "alive=\(liveInstanceCount) speedScale-applied velocity is base; WPE TEXCOORD1=velocity",
            "(pos.xyz | vel.xy(base) | size | rotZ | turbSpeed | age/life)",
        ]
        for p in particles where p.age != .greatestFiniteMagnitude {
            lines.append(String(
                format: "  pos=(%.1f,%.1f,%.1f) vel=(%.1f,%.1f) size=%.1f rotZ=%.2f turb=%.1f age=%.2f/%.2f",
                p.position.x, p.position.y, p.position.z, p.velocity.x, p.velocity.y,
                p.size, p.rotationZ, p.turbulenceSpeed, p.age, p.lifetime))
        }
        return lines.joined(separator: "\n")
    }
    #endif

    /// alphafade.fadeintime / fadeouttime are **lifetime fractions** in
    /// the WPE schema — `fadeintime=0.1` means "fade-in completes at
    /// 10% of lifetime"; `fadeouttime=0.9` means "fade-out begins at
    /// 90% of lifetime". When both are 0 we keep the base alpha for
    /// the whole lifespan — matches WPE's "no fade".
    private func fadeEnvelope(age: Float, lifetime: Float) -> Float {
        guard lifetime > 0 else { return 1 }
        let fraction = max(0, min(1, age / lifetime))
        let fadeInFrac = Float(min(max(definition.fadeInSeconds, 0), 1))
        let fadeOutFrac = Float(min(max(definition.fadeOutSeconds, 0), 1))
        var value: Float = 1
        if fadeInFrac > 0 && fraction < fadeInFrac {
            value = max(0, fraction / fadeInFrac)
        }
        if fadeOutFrac > 0 && fraction > fadeOutFrac {
            let span = max(0.0001, 1 - fadeOutFrac)
            value = min(value, max(0, 1 - (fraction - fadeOutFrac) / span))
        }
        return value
    }

    private func nextFreeSlot() -> Int? {
        for index in 0..<capacity {
            if particles[index].age == .greatestFiniteMagnitude {
                return index
            }
        }
        return nil
    }

    /// Spawns into `slot`, returning whether a particle was actually written.
    /// Event-follow children return `false` when the parent has no live
    /// particle this frame, so a one-shot burst isn't consumed on a no-op.
    @discardableResult
    private func spawn(into slot: Int) -> Bool {
        // Y-up author space: emitter origin and per-particle velocity are
        // used as authored (no Y-flip). The scene object's scale/rotation
        // is then applied via applyModelMatrix/applyModelDirection — that
        // rotation is what makes the SAME leaves preset rise in a rotated
        // emitter (3725117707) yet fall in an un-rotated one (saber).
        let dispersal: SIMD3<Float>
        switch definition.emitterShape {
        case .box:
            // `boxrandom`: uniform per axis within ±half-extent around the origin —
            // how full-screen rain/snow scatters across the frame. Sampling a
            // sphere here (or failing to parse the vector extent) piled all 500 rain
            // halos on one point → a white blob (scene 3351072238). Inner-box
            // exclusion via distancemin is uncommon and intentionally not modeled.
            let ext = definition.dispersalMax
            dispersal = SIMD3<Float>(
                Float(uniform(-ext.x, ext.x)),
                Float(uniform(-ext.y, ext.y)),
                Float(uniform(-ext.z, ext.z))
            )
        case .sphere:
            let theta = Double.random(in: 0..<2 * .pi, using: &rng)
            let phi = Double.random(in: 0..<(.pi), using: &rng)
            let radius = uniform(definition.dispersalMin.x, definition.dispersalMax.x)
            dispersal = Self.dispersalVector(
                radius: radius,
                theta: theta,
                phi: phi,
                mask: SIMD3<Float>(
                    Float(definition.directionMask.x),
                    Float(definition.directionMask.y),
                    Float(definition.directionMask.z)
                )
            )
        }
        let emitterOriginLocal = SIMD3<Float>(
            Float(definition.originOffset.x),
            Float(definition.originOffset.y),
            Float(definition.originOffset.z)
        )
        let localPoint = emitterOriginLocal + dispersal
        var localVelocity = uniformVector(definition.velocityMin, definition.velocityMax)
        if let tvi = definition.turbulentVelocityInit {
            localVelocity += seedTurbulentVelocity(tvi)
        }
        let position: SIMD3<Float>
        if requiresFollowParent {
            // Event-follow child: ride the parent's live particle. Skip spawning
            // when the parent has no live particle this frame (no stale origin).
            guard let followPosition = injectedControlPoints[followControlPointID] else { return false }
            // The parent particle is already in render space and already carries
            // the inherited column/object offset; only scatter this emitter's
            // local dispersal around it (re-adding originOffset would double it).
            position = followPosition + sceneTransform.applyModelDirection(dispersal)
        } else if emitterTracksPointer {
            // Pointer-locked emitter (control point 0 tracks the cursor): spawn
            // at the cursor instead of the scene-object origin, keeping the
            // emitter's local shape (rotation/scale) intact. With Follow Cursor
            // off (`pointerCentered == nil`) it must NOT fall through to the
            // static scene origin — that kept emitting cursor particles piled at
            // one fixed point (the "stuck residual" after disabling follow, which
            // also reappeared on reload because the emitter never actually stopped).
            guard let p = pointerCentered else { return false }
            position = SIMD3<Float>(p.x, p.y, 0) + sceneTransform.applyModelDirection(localPoint)
        } else {
            position = sceneTransform.applyModelMatrix(toLocalPoint: localPoint)
        }
        let velocity = sceneTransform.applyModelDirection(localVelocity)
        // REFRACT "lens water" droplets: the object scale (e.g. 3.52×) is there to
        // spread the emitter BOX across the whole screen — but applying it to each
        // droplet too turns the authored 50–200px beads into 700px magnifying
        // lenses. Keep the authored size; the screen-wide scatter still comes from
        // objectScale via `applyModelMatrix` on the spawn position. (Targeted to
        // refract pending a Windows-WPE oracle size comparison.)
        let sizeScale = (isRefract || isNestedChildSystem) ? 1.0 : sceneTransform.worldSizeMultiplier()
        // `sizerandom` exponent: WPE samples min + (max-min)·rand^exp (exp>1
        // biases toward min). `uniform` is exp==1; only pay `pow` when it differs.
        let sizeSample: Double
        if abs(definition.sizeExponent - 1) < 0.0001 {
            sizeSample = uniform(definition.sizeMin, definition.sizeMax)
        } else if definition.sizeMax > definition.sizeMin {
            let r = pow(Double.random(in: 0...1, using: &rng), definition.sizeExponent)
            sizeSample = definition.sizeMin + (definition.sizeMax - definition.sizeMin) * r
        } else {
            sizeSample = definition.sizeMin
        }
        var size = Float(sizeSample) * sizeScale
        // Blend-aware cap: a hugely-scaled ADDITIVE emitter (e.g. 3426865175's
        // 7.8× light-shaft) would otherwise fill the frame with additive glow that
        // hard-clamps to white — the SDR pipeline has no headroom to recover it, so
        // bounding the sprite is the only lever. Cap additive sprites near scene
        // height; translucent sprites (atmospheric fog) stay uncapped.
        if blendMode == .additive {
            size = min(size, sceneTransform.sceneHeight)
        }
        let rawColor = lerpVector(definition.colorMin, definition.colorMax)
        let lifetime = Float(uniform(definition.lifetimeMin, definition.lifetimeMax))
        let alpha = Float(uniform(definition.alphaMin, definition.alphaMax))
        let rotationVec = uniformVector(definition.rotationMin, definition.rotationMax)
        let angularVec = uniformVector(definition.angularVelocityMin, definition.angularVelocityMax)
        // Per-particle wind speed/phase for the `turbulence` OPERATOR only. Drawn
        // solely when the operator is present so a system without it consumes NO
        // extra RNG (keeps the spawn draw sequence byte-identical for the oracle).
        let turbulenceSpeed: Float
        let turbulencePhase: Float
        if let turb = definition.turbulence {
            turbulenceSpeed = Float(uniform(turb.speedMin, turb.speedMax))
            turbulencePhase = Float(uniform(turb.phaseMin, turb.phaseMax))
        } else {
            turbulenceSpeed = 0
            turbulencePhase = 0
        }
        let oscPosFrequency: Float
        let oscPosScale: Float
        let oscPosPhase: Float
        if let osc = definition.oscillatePosition {
            oscPosFrequency = Float(uniform(osc.frequencyMin, osc.frequencyMax))
            oscPosScale = Float(uniform(osc.scaleMin, osc.scaleMax))
            // WPE samples the phase over [phasemin, phasemax + 2π] so a preset
            // authoring a narrow band (snowperspective: 0…1) still spreads its
            // flakes around the full sine instead of starting them in lockstep.
            oscPosPhase = Float(uniform(osc.phaseMin, osc.phaseMax + 2 * .pi))
        } else {
            oscPosFrequency = 0
            oscPosScale = 0
            oscPosPhase = 0
        }
        let oscAlphaFrequency: Float
        let oscAlphaPhase: Float
        if let osc = definition.oscillateAlpha {
            oscAlphaFrequency = Float(uniform(osc.frequencyMin, osc.frequencyMax))
            oscAlphaPhase = Float(uniform(osc.phaseMin, osc.phaseMax + 2 * .pi))
        } else {
            oscAlphaFrequency = 0
            oscAlphaPhase = 0
        }
        // `.randomFrame`: lock onto one atlas cell for life so each shard
        // is a different *static* piece of the sheet (WPE shatter look).
        // `.sequence` / single-frame sprites leave this at 0 — `tick`
        // computes their animated frame from age instead.
        let staticFrame: Float
        if definition.animationMode == .randomFrame, let sheet = spriteSheet, sheet.frameCount > 1 {
            staticFrame = Float(Int.random(in: 0..<sheet.frameCount, using: &rng))
        } else {
            staticFrame = 0
        }
        particles[slot] = Particle(
            position: position,
            velocity: velocity,
            size: size,
            color: SIMD3<Float>(
                min(max(rawColor.x / 255, 0), 1),
                min(max(rawColor.y / 255, 0), 1),
                min(max(rawColor.z / 255, 0), 1)
            ),
            rotationZ: sceneTransform.visualRotationZ(localRotationZ: rotationVec.z),
            angularVelocityZ: sceneTransform.visualAngularZ(localAngularZ: angularVec.z),
            alphaBase: min(max(alpha, 0), 1),
            lifetime: max(0.0001, lifetime),
            age: 0,
            turbulenceSpeed: turbulenceSpeed,
            turbulencePhase: turbulencePhase,
            staticFrame: staticFrame,
            oscPosFrequency: oscPosFrequency,
            oscPosScale: oscPosScale,
            oscPosPhase: oscPosPhase,
            oscAlphaFrequency: oscAlphaFrequency,
            oscAlphaPhase: oscAlphaPhase
        )
        return true
    }

    /// `turbulentvelocityrandom` spawn velocity in emitter-local space. A curl-noise
    /// direction is cone-limited toward `forward` (default +Y), then tilted `offset`
    /// radians about `right` (default +Z) and scaled by `uniform(speedMin, speedMax)`.
    /// The `offset` tilt is what makes the leaves preset (`offset ≈ 3`) fall instead
    /// of rise — WPE's downward drift is authored here, not gravity (which is 0).
    /// The emitter's own rotation is applied later by `applyModelDirection`, so the
    /// same preset falls under one emitter and rises under a rotated one.
    ///
    /// The field is sampled at the system's single `turbulentSamplePoint`, which
    /// each spawn advects a little further along its own curl streamline — so
    /// consecutive leaves share one gust that only swings as the point drifts.
    /// Sampling a fresh random point per particle instead (what we did before)
    /// preserves the ensemble average but scatters every leaf independently.
    private func seedTurbulentVelocity(_ tvi: WPEParticleTurbulentVelocityInit) -> SIMD3<Float> {
        let speed = uniform(tvi.speedMin, tvi.speedMax)
        // The emit interval is how much field time this particle owns (WPE hands
        // the initializer `1/rate`), so the gust turns at a wall-clock rate rather
        // than a per-particle one. A near-stalled emitter (>10s/particle) instead
        // teleports the point, so its rare particles don't all share one gust.
        var duration = definition.rate > 0 ? 1 / definition.rate : .infinity
        if duration > 10 {
            turbulentSamplePoint.x += speed
            duration = 0
        }
        let forward = simd_normalize(tvi.forward)
        // `timescale` = how fast the field evolves, so it divides the step. Guard
        // the division: an authored 0 would send the sample point to infinity.
        let timescale = tvi.timescale.isFinite && tvi.timescale > 0 ? tvi.timescale : 1
        let step = 0.005 / timescale
        var dir: SIMD3<Double>
        repeat {
            dir = WPEParticleCurlNoise.direction(at: turbulentSamplePoint, fallback: forward)
            turbulentSamplePoint += dir * step
            duration -= 0.01
        } while duration > 0.01
        // Cone limit: `scale` is the cone width as a hemisphere fraction (2 =
        // unrestricted). Rotate `dir` toward `forward` by `a·(1 - scale/2)·π`
        // about (dir × forward), where `a` is their angle over π.
        let coneFrac = tvi.scale / 2
        let c = min(max(simd_dot(dir, forward), -1), 1)
        let a = acos(c) / .pi
        if a > coneFrac {
            let axis = simd_cross(dir, forward)
            if simd_length(axis) > 1e-6 {
                dir = Self.rotate(dir, around: simd_normalize(axis), by: a * (1 - coneFrac) * .pi)
            }
        }
        if tvi.offset != 0, simd_length(tvi.right) > 1e-6 {
            dir = Self.rotate(dir, around: simd_normalize(tvi.right), by: tvi.offset)
        }
        let v = dir * speed
        return SIMD3<Float>(Float(v.x), Float(v.y), Float(v.z))
    }

    private static func rotate(_ v: SIMD3<Double>, around k: SIMD3<Double>, by angle: Double) -> SIMD3<Double> {
        let cosA = cos(angle)
        let sinA = sin(angle)
        return v * cosA + simd_cross(k, v) * sinA + k * simd_dot(k, v) * (1 - cosA)
    }
}
#endif
