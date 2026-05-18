#if !LITE_BUILD
import Foundation
import Metal
import simd

/// Per-instance attributes the GPU vertex stage reads from. Layout MUST
/// match `WPEParticleInstance` in `WPEMetalBuiltins.metal` exactly.
struct WPEParticleInstance {
    var positionAndSize: SIMD4<Float> // x, y in pixel space ; z (unused, reserved); w = size
    var color: SIMD4<Float>           // rgb 0…1, a = current alpha
}

/// CPU-side emitter + GPU buffer. One instance per scene particle object.
///
/// Lifecycle:
///   - `prepare()` runs once on scene load: spawns the persistent
///     instance buffer sized to `definition.maxCount` (clamped to a sane
///     ceiling so a runaway descriptor doesn't allocate gigabytes).
///   - `tick(now:)` advances every alive particle by the elapsed delta
///     since the last tick, recycles dead ones, and emits new ones at
///     the configured rate. The pure-Swift loop is bounded by maxCount;
///     no per-frame allocations.
///   - `aliveInstances` returns the slice the renderer should bind.
///
/// Coordinate system: spawn positions are in WPE's pixel-space (e.g.
/// origin "0 650 0" means 650 px above scene center). The dispatcher's
/// vertex shader projects them into NDC using the scene's orthogonal
/// projection.
final class WPEParticleSystem {
    let definition: WPEParticleDefinition
    /// Capped allocation size — never larger than maxCount, never larger
    /// than `WPEParticleSystem.absoluteCap` (so a malformed JSON saying
    /// `maxcount=100000` doesn't OOM us).
    let capacity: Int
    /// GPU instance buffer, persistent for the system's lifetime.
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

    init?(definition: WPEParticleDefinition, device: MTLDevice) {
        self.definition = definition
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

    /// Fast random doubles bounded by [low, high].
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
        let dispersal = SIMD3<Float>(
            Float(radius * sin(phi) * cos(theta)),
            Float(radius * sin(phi) * sin(theta)),
            Float(radius * cos(phi))
        )
        let origin = SIMD3<Float>(
            Float(definition.originOffset.x),
            Float(definition.originOffset.y),
            Float(definition.originOffset.z)
        )
        let velocity = uniformVector(definition.velocityMin, definition.velocityMax)
        let size = Float(uniform(definition.sizeMin, definition.sizeMax))
        let rawColor = uniformVector(definition.colorMin, definition.colorMax)
        let lifetime = Float(uniform(definition.lifetimeMin, definition.lifetimeMax))
        particles[slot] = Particle(
            position: origin + dispersal,
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
