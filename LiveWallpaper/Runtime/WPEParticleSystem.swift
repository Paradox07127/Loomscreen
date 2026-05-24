#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE
import Metal
import simd

/// Per-instance attributes the GPU vertex stage reads from. Layout MUST
/// match `WPEParticleInstance` in `WPEMetalBuiltins.metal` exactly.
struct WPEParticleInstance {
    var positionAndSize: SIMD4<Float> // x, y in centered scene pixels ; z (unused, reserved); w = size
    var color: SIMD4<Float>           // rgb 0…1, a = current alpha
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
///     buffer, and bakes the scene transform once. Subsequent ticks
///     spawn directly into world-space coordinates so the vertex shader
///     only needs the centered ortho projection.
///   - `tick(now:)` advances every alive particle by the elapsed delta
///     since the last tick, recycles dead ones, and emits new ones at
///     the configured rate.
///   - `aliveInstances` returns the slice the renderer should bind.
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

    /// Hard ceiling so a single emitter can't blow the GPU memory budget.
    /// 8K particles × 32 bytes = 256 KB per system, comfortably bounded.
    static let absoluteCap = 8192

    private struct Particle {
        var position: SIMD3<Float>
        var velocity: SIMD3<Float>
        var size: Float
        var color: SIMD3<Float>
        var lifetime: Float
        var age: Float       // Float.greatestFiniteMagnitude when slot is free
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
            lifetime: 0,
            age: .greatestFiniteMagnitude
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

    func tick(now: Double) {
        defer { lastTickTime = now }
        if firstTickTime == nil { firstTickTime = now }
        let dt: Float
        if let last = lastTickTime {
            dt = Float(max(0, min(now - last, 0.1)))
        } else {
            dt = 0
        }
        let elapsed = now - (firstTickTime ?? now)

        for index in 0..<capacity {
            guard particles[index].age != .greatestFiniteMagnitude else { continue }
            particles[index].age += dt
            if particles[index].age >= particles[index].lifetime {
                particles[index].age = .greatestFiniteMagnitude
                continue
            }
            particles[index].position += particles[index].velocity * dt
        }

        if elapsed >= definition.startDelay && definition.rate > 0 {
            spawnAccumulator += Double(dt) * definition.rate
            while spawnAccumulator >= 1 {
                spawnAccumulator -= 1
                guard let slot = nextFreeSlot() else { break }
                spawn(into: slot)
            }
        }

        let pointer = instanceBuffer.contents().bindMemory(to: WPEParticleInstance.self, capacity: capacity)
        var written = 0
        for index in 0..<capacity {
            guard particles[index].age != .greatestFiniteMagnitude else { continue }
            let particle = particles[index]
            let fadeIn = max(0.0001, Float(definition.fadeInSeconds))
            let fadeOutStart = particle.lifetime * 0.75
            var alpha: Float = 1
            if particle.age < fadeIn {
                alpha = particle.age / fadeIn
            } else if particle.age > fadeOutStart {
                let tail = max(0.0001, particle.lifetime - fadeOutStart)
                alpha = max(0, 1 - (particle.age - fadeOutStart) / tail)
            }
            pointer[written] = WPEParticleInstance(
                positionAndSize: SIMD4<Float>(particle.position.x, particle.position.y, particle.position.z, particle.size),
                color: SIMD4<Float>(particle.color.x, particle.color.y, particle.color.z, alpha)
            )
            written += 1
        }
        aliveCount = written
    }

    var liveInstanceCount: Int { aliveCount }

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
        particles[slot] = Particle(
            position: position,
            velocity: velocity,
            size: size,
            color: SIMD3<Float>(
                min(max(rawColor.x / 255, 0), 1),
                min(max(rawColor.y / 255, 0), 1),
                min(max(rawColor.z / 255, 0), 1)
            ),
            lifetime: max(0.0001, lifetime),
            age: 0
        )
    }
}
#endif
