#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE
import Metal
import simd

/// Per-instance attributes the GPU vertex stage reads from. Layout MUST
/// match `WPEParticleInstance` in `WPEMetalBuiltins.metal` exactly.
struct WPEParticleInstance {
    var positionAndSize: SIMD4<Float>   // x, y in centered scene pixels ; z (unused, reserved); w = size
    var color: SIMD4<Float>             // rgb 0…1, a = current alpha (base × fade envelope)
    var rotationAndLife: SIMD4<Float>   // x = rotationZ radians ; y = lifetimeFraction [0,1] ; z,w reserved
}

/// One-shot world-space placement applied to a `WPEParticleSystem` at
/// load time. Mirrors `CParticle::setup()` in linux-wallpaperengine:
/// the WPE authoring frame is top-left + Y-down pixels; the renderer
/// works in a centered + Y-up frame. We bake that conversion together
/// with the scene-object transform (origin / scale / angles.z) so the
/// hot tick loop stays in one coordinate space.
struct WPEParticleSceneTransform {
    var sceneSize: SIMD2<Float>
    var objectOrigin: SIMD3<Float>
    var objectScale: SIMD3<Float>
    var objectAngleZ: Float

    static let identity = WPEParticleSceneTransform(
        sceneSize: SIMD2<Float>(1, 1),
        objectOrigin: SIMD3<Float>(0, 0, 0),
        objectScale: SIMD3<Float>(1, 1, 1),
        objectAngleZ: 0
    )

    func worldOrigin(localOffset: SIMD3<Float>) -> SIMD3<Float> {
        let scaled = SIMD3<Float>(
            localOffset.x * objectScale.x,
            localOffset.y * objectScale.y,
            localOffset.z * objectScale.z
        )
        let cosA = cos(objectAngleZ)
        let sinA = sin(objectAngleZ)
        let rotated = SIMD3<Float>(
            scaled.x * cosA - scaled.y * sinA,
            scaled.x * sinA + scaled.y * cosA,
            scaled.z
        )
        // WPE author space (top-left origin, Y-down) → centered (Y-up).
        let worldX = (objectOrigin.x + rotated.x) - sceneSize.x * 0.5
        let worldY = sceneSize.y * 0.5 - (objectOrigin.y + rotated.y)
        return SIMD3<Float>(worldX, worldY, objectOrigin.z + rotated.z)
    }

    func worldVelocity(_ local: SIMD3<Float>) -> SIMD3<Float> {
        // WPE only Y-flips *position* origin (CParticle::setup) — velocity
        // is consumed verbatim, so a negative vy in JSON translates to
        // "position.y decreases" in our Y-up render frame, which the
        // author intended as "falls down on screen". Mirroring velocity
        // here would flip the wind direction for every scene.
        let scaled = SIMD3<Float>(
            local.x * objectScale.x,
            local.y * objectScale.y,
            local.z * objectScale.z
        )
        let cosA = cos(objectAngleZ)
        let sinA = sin(objectAngleZ)
        return SIMD3<Float>(
            scaled.x * cosA - scaled.y * sinA,
            scaled.x * sinA + scaled.y * cosA,
            scaled.z
        )
    }

    func worldSizeMultiplier() -> Float {
        // Particles are billboarded; size scales with the average of X/Y
        // axes (Z is depth, irrelevant for the screen-space quad).
        return max(0.0001, (abs(objectScale.x) + abs(objectScale.y)) * 0.5)
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

    private var aliveCount: Int = 0
    private var particles: [Particle]
    private var spawnAccumulator: Double = 0
    private var lastTickTime: Double?
    private var firstTickTime: Double?
    private var rng: SystemRandomNumberGenerator
    /// Cached gravity in render space (Y-up). Mirrors the velocity rule
    /// (no Y-flip) so a JSON `gravity = "0 -50 0"` actually pulls down
    /// on screen.
    private let gravity: SIMD3<Float>

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
        sceneTransform: WPEParticleSceneTransform = .identity
    ) {
        self.definition = definition
        self.blendMode = blendMode
        self.sceneTransform = sceneTransform
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
        self.gravity = SIMD3<Float>(
            Float(definition.gravity.x),
            Float(definition.gravity.y),
            Float(definition.gravity.z)
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
    }

    func tick(now: Double) {
        advance(now: now)
        let pointer = instanceBuffer.contents().bindMemory(to: WPEParticleInstance.self, capacity: capacity)
        var written = 0
        for index in 0..<capacity {
            guard particles[index].age != .greatestFiniteMagnitude else { continue }
            let particle = particles[index]
            let envelope = fadeEnvelope(age: particle.age, lifetime: particle.lifetime)
            let alpha = particle.alphaBase * envelope
            let lifetimeFraction = particle.lifetime > 0 ? min(1, max(0, particle.age / particle.lifetime)) : 0
            pointer[written] = WPEParticleInstance(
                positionAndSize: SIMD4<Float>(
                    particle.position.x, particle.position.y, particle.position.z, particle.size
                ),
                color: SIMD4<Float>(particle.color.x, particle.color.y, particle.color.z, alpha),
                rotationAndLife: SIMD4<Float>(particle.rotationZ, lifetimeFraction, 0, 0)
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
        let angularForce = Float(definition.angularForceZ)
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
                step.x += noise.x * particles[index].turbulenceSpeed
                step.y += noise.y * particles[index].turbulenceSpeed
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

    /// alphafade.fadeintime / fadeouttime are *seconds* (WPE absolute
    /// time, not lifetime fraction). When both are 0 we keep the base
    /// alpha for the whole lifespan — matches WPE's "no fade".
    private func fadeEnvelope(age: Float, lifetime: Float) -> Float {
        let fadeIn = Float(definition.fadeInSeconds)
        let fadeOut = Float(definition.fadeOutSeconds)
        var value: Float = 1
        if fadeIn > 0 && age < fadeIn {
            value = max(0, age / fadeIn)
        }
        if fadeOut > 0 {
            let tailStart = max(0, lifetime - fadeOut)
            if age > tailStart {
                let tailDuration = max(0.0001, lifetime - tailStart)
                value = min(value, max(0, 1 - (age - tailStart) / tailDuration))
            }
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
        let mask = definition.directionMask
        let dispersal = SIMD3<Float>(
            Float(radius * sin(phi) * cos(theta) * mask.x),
            Float(radius * sin(phi) * sin(theta) * mask.y),
            Float(radius * cos(phi) * mask.z)
        )
        let localOrigin = SIMD3<Float>(
            Float(definition.originOffset.x),
            Float(definition.originOffset.y),
            Float(definition.originOffset.z)
        ) + dispersal
        let localVelocity = uniformVector(definition.velocityMin, definition.velocityMax)
        let position = sceneTransform.worldOrigin(localOffset: localOrigin)
        let velocity = sceneTransform.worldVelocity(localVelocity)
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
            rotationZ: rotationVec.z,
            angularVelocityZ: angularVec.z,
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
