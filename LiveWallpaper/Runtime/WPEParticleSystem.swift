#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE
import Metal
import simd

/// Per-instance attributes the GPU vertex stage reads from. Layout MUST
/// match `WPEParticleInstance` in `WPEMetalBuiltins.metal` exactly.
struct WPEParticleInstance {
    var positionAndSize: SIMD4<Float>   // x, y in centered scene pixels ; z = signed sprite X scale; w = size
    var color: SIMD4<Float>             // rgb 0…1, a = current alpha (base × fade envelope)
    var rotationAndLife: SIMD4<Float>   // x = rotationZ radians ; y = lifetimeFraction [0,1] ; z = spriteFrameIndex; w = signed sprite Y scale
}

/// One-shot world-space placement applied to a `WPEParticleSystem` at
/// load time.
///
/// **Coordinate convention: WPE author space is Y-up, bottom-left
/// origin throughout — NO Y-flip anywhere.** Scene-object `origin`,
/// emitter `origin`, per-particle `velocity`, and `gravity` are all
/// used as authored, and the Metal vertex stage is also Y-up, so the
/// pipeline runs one consistent Y-up frame. Only the scene-object's
/// `angles.z` rotation is negated (`Rz(-angleZ)`) because WPE's
/// clockwise author rotation maps to the Y-up frame's counter-clockwise
/// sense (that sign is about rotation *direction*, not position/velocity
/// Y, and is verified independently).
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
    /// Scene-object origin in the centered render frame.
    var renderOrigin: SIMD3<Float>
    var objectScale: SIMD3<Float>
    var objectAngleZ: Float

    init(sceneSize: SIMD2<Float>, objectOrigin: SIMD3<Float>, objectScale: SIMD3<Float>, objectAngleZ: Float) {
        self.renderOrigin = SIMD3<Float>(
            objectOrigin.x - sceneSize.x * 0.5,
            objectOrigin.y - sceneSize.y * 0.5,
            objectOrigin.z
        )
        self.objectScale = objectScale
        self.objectAngleZ = objectAngleZ
    }

    static let identity = WPEParticleSceneTransform(
        sceneSize: SIMD2<Float>(1, 1),
        objectOrigin: SIMD3<Float>(0, 0, 0),
        objectScale: SIMD3<Float>(1, 1, 1),
        objectAngleZ: 0
    )

    /// Apply the scene-object model matrix
    /// `T(renderOrigin) · Rz(-angleZ) · S(scale)` to a point already
    /// in the emitter's Y-down-flipped-to-Y-up local frame.
    func applyModelMatrix(toLocalPoint p: SIMD3<Float>) -> SIMD3<Float> {
        let scaled = SIMD3<Float>(p.x * objectScale.x, p.y * objectScale.y, p.z * objectScale.z)
        let cosA = cos(-objectAngleZ)
        let sinA = sin(-objectAngleZ)
        return renderOrigin + SIMD3<Float>(
            scaled.x * cosA - scaled.y * sinA,
            scaled.x * sinA + scaled.y * cosA,
            scaled.z
        )
    }

    /// Same rotation + scale chain, no translation — for velocity,
    /// gravity, or other free vectors that already had their Y flipped
    /// at spawn time.
    func applyModelDirection(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let scaled = SIMD3<Float>(v.x * objectScale.x, v.y * objectScale.y, v.z * objectScale.z)
        let cosA = cos(-objectAngleZ)
        let sinA = sin(-objectAngleZ)
        return SIMD3<Float>(
            scaled.x * cosA - scaled.y * sinA,
            scaled.x * sinA + scaled.y * cosA,
            scaled.z
        )
    }

    func worldSizeMultiplier() -> Float {
        // WPE authors particle sizes in absolute scene pixels. The scene
        // object's scale governs the *emitter* — it spreads spawn positions
        // (applyModelMatrix) and velocities (applyModelDirection) — but must
        // NOT enlarge each billboard sprite. Folding object scale into sprite
        // size made large-scaled emitters (e.g. a light-shaft layer scaled
        // ~7×, scene 3426865175) blow each 850–1000px sprite up to ~6500px,
        // saturating the whole frame with additive glow. Keep sprite size at
        // its authored value; only the emitter region scales.
        //
        // KNOWN LIMITATION (deferred to a visual-fidelity pass): the WPE
        // reference (Almamu CParticle model matrix `T·R·S(scale)`) DOES scale
        // the sprite quad by object scale, so this 1.0 under-sizes moderately
        // scaled particle scenes — e.g. 3725117707's leaves (object scale 3×)
        // render at ~70px instead of the original's ~210px. The right fix is
        // to restore the scale→size coupling but CLAMP the result (cap near
        // scene height) so the pathological 7.8× light-shaft can't saturate,
        // rather than disabling it globally. Re-enable when tuning effect
        // appearance; verify both 3725117707 (too small now) and 3426865175
        // (must not re-saturate) on device.
        return 1.0
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
        return -objectAngleZ + localRotation
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
    /// Atlas slicing metadata for the sprite texture. `nil` ⇒ single-
    /// frame static texture, the executor binds a full-UV pass-through
    /// sprite-sheet uniform (cols=rows=frames=1, mask=0).
    let spriteSheet: WPEParticleSpriteSheet?

    private var aliveCount: Int = 0
    private var particles: [Particle]
    private var spawnAccumulator: Double = 0
    private var lastTickTime: Double?
    private var firstTickTime: Double?
    private var rng: SystemRandomNumberGenerator
    /// Cached gravity in render space (Y-up). Mirrors the velocity rule:
    /// flip emitter-local Y once, then apply the scene object's scale
    /// and rotation without translating.
    private let gravity: SIMD3<Float>
    private let turbulenceMask: SIMD3<Float>

    /// Hard ceiling so a single emitter can't blow the GPU memory budget.
    /// 8K particles × 48 bytes = 384 KB per system.
    static let absoluteCap = 8192

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
    }

    init?(
        definition: WPEParticleDefinition,
        device: MTLDevice,
        blendMode: WPEParticleBlendMode = .translucent,
        sceneTransform: WPEParticleSceneTransform = .identity,
        spriteSheet: WPEParticleSpriteSheet? = nil
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
            turbulencePhase: 0
        ), count: cap)
        guard let buffer = device.makeBuffer(
            length: cap * MemoryLayout<WPEParticleInstance>.stride,
            options: [.storageModeShared]
        ) else {
            return nil
        }
        buffer.label = "WPE particle instances"
        self.instanceBuffer = buffer
        self.rng = SystemRandomNumberGenerator()
        // Y-up author space: gravity is used as authored (no flip), then
        // honored through the scene object's scale/rotation like velocity.
        let localGravity = SIMD3<Float>(
            Float(definition.gravity.x),
            Float(definition.gravity.y),
            Float(definition.gravity.z)
        )
        self.gravity = sceneTransform.applyModelDirection(localGravity)
        self.turbulenceMask = SIMD3<Float>(
            Float(definition.turbulenceMask.x),
            Float(definition.turbulenceMask.y),
            Float(definition.turbulenceMask.z)
        )
    }

    private func uniform(_ low: Double, _ high: Double) -> Double {
        guard high > low else { return low }
        let r = Double.random(in: 0...1, using: &rng)
        return low + (high - low) * r
    }

    private func uniformVector(_ low: SIMD3<Double>, _ high: SIMD3<Double>) -> SIMD3<Float> {
        SIMD3<Float>(
            Float(uniform(low.x, high.x)),
            Float(uniform(low.y, high.y)),
            Float(uniform(low.z, high.z))
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
        guard simulatedSeconds > 0, definition.rate > 0 else { return }
        let substeps = Int((simulatedSeconds / step).rounded(.up))
        var virtualNow: Double = 0
        for _ in 0..<substeps {
            virtualNow += step
            advance(now: virtualNow)
        }
        // The renderer's real frame clock starts at 0 after load. Keep
        // the prewarmed particle ages/positions, but re-anchor internal
        // tick bookkeeping so the first live frames do not see a
        // future `lastTickTime` and freeze until wall time catches up.
        firstTickTime = -virtualNow
        lastTickTime = 0
    }

    func tick(now: Double) {
        advance(now: now)
        let pointer = instanceBuffer.contents().bindMemory(to: WPEParticleInstance.self, capacity: capacity)
        // Sprite-sheet animation is **lifetime-relative**: a particle
        // sees `sequenceMultiplier` full atlas cycles over the course
        // of its life, regardless of `duration`. Almamu's wall-clock
        // reading (90 fps for leaves7) produces visible flicker even
        // with cross-fade; the lifetime-relative reading gives the
        // smooth ~10 fps "leaves slowly rotating as they fall" pace
        // workshop authors clearly tuned for. `frameCount = 1`
        // collapses to a static sprite.
        let frameCount: Float
        let cyclesPerLifetime: Float
        if let sheet = spriteSheet, sheet.frameCount > 1 {
            frameCount = Float(sheet.frameCount)
            // `sequenceMultiplier × 2` empirically lands between Almamu's
            // wall-clock rate (visibly fast/flickery at default settings)
            // and a pure lifetime-relative single-multiplier reading
            // (too slow on leaves2). For leaves7 (sequenceMultiplier 3,
            // lifetime ~9s, 30 frames): 6 cycles ≈ 20 fps — the natural
            // "leaves slowly rotating as they fall" pace.
            cyclesPerLifetime = max(0.0001, Float(definition.sequenceMultiplier) * 2)
        } else {
            frameCount = 1
            cyclesPerLifetime = 0
        }
        let visualScaleSigns = sceneTransform.visualScaleSigns()
        var written = 0
        for index in 0..<capacity {
            guard particles[index].age != .greatestFiniteMagnitude else { continue }
            let particle = particles[index]
            let envelope = fadeEnvelope(age: particle.age, lifetime: particle.lifetime)
            let alpha = particle.alphaBase * envelope
            let lifetimeFraction = particle.lifetime > 0 ? min(1, max(0, particle.age / particle.lifetime)) : 0
            let frameIndex: Float
            if cyclesPerLifetime > 0 {
                let raw = lifetimeFraction * cyclesPerLifetime * frameCount
                frameIndex = raw.truncatingRemainder(dividingBy: frameCount)
            } else {
                frameIndex = 0
            }
            pointer[written] = WPEParticleInstance(
                positionAndSize: SIMD4<Float>(
                    particle.position.x, particle.position.y, visualScaleSigns.x, particle.size
                ),
                color: SIMD4<Float>(particle.color.x, particle.color.y, particle.color.z, alpha),
                rotationAndLife: SIMD4<Float>(particle.rotationZ, lifetimeFraction, frameIndex, visualScaleSigns.y)
            )
            written += 1
        }
        aliveCount = written
    }

    var liveInstanceCount: Int { aliveCount }

    /// Integrate every alive particle and spawn new ones. Split from
    /// `tick(now:)` so `prewarm` can advance the simulator without
    /// touching the GPU buffer.
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
        let dragScalar: Float = max(0, 1 - Float(definition.drag) * dt)
        let angularDragScalar: Float = max(0, 1 - Float(definition.angularDrag) * dt)
        let angularForce = sceneTransform.visualAngularZ(localAngularZ: Float(definition.angularForceZ))
        let turbulenceScale = Float(definition.turbulenceScale)
        let turbulenceTimescale = Float(definition.turbulenceTimescale)
        let turbulenceOffset = Float(definition.turbulenceOffset)
        let turbulenceEnabled = definition.turbulenceSpeedMax > 0
        let elapsedFloat = Float(elapsed)

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
            var step = particles[index].velocity
            if turbulenceEnabled && particles[index].turbulenceSpeed > 0 {
                let pos = particles[index].position
                let t = elapsedFloat * turbulenceTimescale
                    + turbulenceOffset
                    + particles[index].turbulencePhase
                let noise = turbulenceNoise(
                    x: pos.x * turbulenceScale,
                    y: pos.y * turbulenceScale,
                    t: t
                )
                step.x += noise.x * particles[index].turbulenceSpeed * turbulenceMask.x
                step.y += noise.y * particles[index].turbulenceSpeed * turbulenceMask.y
            }
            particles[index].position += step * dt
            // Angular motion with force + drag.
            particles[index].angularVelocityZ += angularForce * dt
            if angularDragScalar < 1 { particles[index].angularVelocityZ *= angularDragScalar }
            particles[index].rotationZ += particles[index].angularVelocityZ * dt
        }

        if elapsed >= definition.startDelay && definition.rate > 0 {
            spawnAccumulator += Double(dt) * definition.rate
            while spawnAccumulator >= 1 {
                spawnAccumulator -= 1
                guard let slot = nextFreeSlot() else { break }
                spawn(into: slot)
            }
        }
    }

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

    private func spawn(into slot: Int) {
        let theta = Double.random(in: 0..<2 * .pi, using: &rng)
        let phi = Double.random(in: 0..<(.pi), using: &rng)
        let radius = uniform(definition.dispersalMin, definition.dispersalMax)
        // Y-up author space: emitter origin and per-particle velocity are
        // used as authored (no Y-flip). The scene object's scale/rotation
        // is then applied via applyModelMatrix/applyModelDirection — that
        // rotation is what makes the SAME leaves preset rise in a rotated
        // emitter (3725117707) yet fall in an un-rotated one (saber).
        let dispersal = Self.dispersalVector(
            radius: radius,
            theta: theta,
            phi: phi,
            mask: SIMD3<Float>(
                Float(definition.directionMask.x),
                Float(definition.directionMask.y),
                Float(definition.directionMask.z)
            )
        )
        let emitterOriginLocal = SIMD3<Float>(
            Float(definition.originOffset.x),
            Float(definition.originOffset.y),
            Float(definition.originOffset.z)
        )
        let localPoint = emitterOriginLocal + dispersal
        let localVelocity = uniformVector(definition.velocityMin, definition.velocityMax)
        let position = sceneTransform.applyModelMatrix(toLocalPoint: localPoint)
        let velocity = sceneTransform.applyModelDirection(localVelocity)
        let sizeScale = sceneTransform.worldSizeMultiplier()
        let size = Float(uniform(definition.sizeMin, definition.sizeMax)) * sizeScale
        let rawColor = uniformVector(definition.colorMin, definition.colorMax)
        let lifetime = Float(uniform(definition.lifetimeMin, definition.lifetimeMax))
        let alpha = Float(uniform(definition.alphaMin, definition.alphaMax))
        let rotationVec = uniformVector(definition.rotationMin, definition.rotationMax)
        let angularVec = uniformVector(definition.angularVelocityMin, definition.angularVelocityMax)
        let turbulenceSpeed = Float(uniform(definition.turbulenceSpeedMin, definition.turbulenceSpeedMax))
        let turbulencePhase = Float(uniform(definition.turbulencePhaseMin, definition.turbulencePhaseMax))
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
            turbulencePhase: turbulencePhase
        )
    }

    /// Cheap deterministic 2D noise field built from sine products —
    /// sufficient for "leaves drift on the breeze" feel without pulling
    /// in a full Perlin/simplex implementation. Each output component
    /// is bounded to roughly [-0.5, 0.5] so multiplying by `speed`
    /// caps the per-frame velocity contribution cleanly.
    private func turbulenceNoise(x: Float, y: Float, t: Float) -> SIMD2<Float> {
        let nx = sin(x * 0.10 + t * 0.5) + cos(y * 0.13 + t * 0.7)
        let ny = sin(x * 0.17 + t * 0.3) + cos(y * 0.09 + t * 0.4)
        return SIMD2<Float>(nx * 0.25, ny * 0.25)
    }
}
#endif
