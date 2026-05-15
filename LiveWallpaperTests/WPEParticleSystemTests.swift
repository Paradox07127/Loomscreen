import Foundation
import Metal
import Testing
@testable import LiveWallpaper

struct WPEParticleSystemTests {

    @Test("Parses canonical snowflat-style particle JSON")
    func parsesCanonicalParticleJSON() throws {
        // Excerpt from the snowflat preset that ships with WPE: covers
        // the four initializer + emitter combinations the runtime
        // depends on. Anything else is parsed leniently with defaults.
        let json = #"""
        {
            "material": "materials/presets/snowflat.json",
            "maxcount": 300,
            "starttime": 5,
            "emitter": [{
                "rate": 15,
                "origin": "0 650 0",
                "distancemin": 10,
                "distancemax": 1200
            }],
            "initializer": [
                {"name": "lifetimerandom", "min": 15, "max": 23},
                {"name": "sizerandom", "min": 2, "max": 30},
                {"name": "velocityrandom", "min": "-10 -50 0", "max": "-37 -90 0"},
                {"name": "colorrandom", "min": "95 98 100", "max": "255 255 255"}
            ],
            "operator": [{"name": "alphafade", "fadeintime": 0.4}]
        }
        """#
        let data = Data(json.utf8)
        let def = try #require(WPEParticleDefinitionParser.parse(data: data))

        #expect(def.materialRelativePath == "materials/presets/snowflat.json")
        #expect(def.maxCount == 300)
        #expect(def.startDelay == 5)
        #expect(def.rate == 15)
        #expect(def.lifetimeMin == 15)
        #expect(def.lifetimeMax == 23)
        #expect(def.sizeMin == 2)
        #expect(def.sizeMax == 30)
        #expect(def.fadeInSeconds == 0.4)
        #expect(def.colorMax.x == 255 && def.colorMax.y == 255)
    }

    @Test("Emitter respects start delay before spawning")
    func emitterRespectsStartDelay() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var def = WPEParticleDefinition.empty
        def = WPEParticleDefinition(
            materialRelativePath: nil,
            maxCount: 16,
            rate: 100,
            startDelay: 1.0,
            lifetimeMin: 5, lifetimeMax: 5,
            sizeMin: 4, sizeMax: 4,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: 0, dispersalMax: 0,
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0.1
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        // First tick at time 0 → before start delay; nothing spawns.
        system.tick(now: 0)
        #expect(system.liveInstanceCount == 0)
        // Tick at 0.5s → still before start delay; nothing.
        system.tick(now: 0.5)
        #expect(system.liveInstanceCount == 0)
        // Tick past start delay; spawn proceeds.
        system.tick(now: 1.5)
        #expect(system.liveInstanceCount > 0)
    }

    @Test("Emitter caps live count at maxCount")
    func emitterCapsAtMaxCount() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil,
            maxCount: 8,
            rate: 1000,
            startDelay: 0,
            lifetimeMin: 100, lifetimeMax: 100,
            sizeMin: 4, sizeMax: 4,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: 0, dispersalMax: 0,
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0.1
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        system.tick(now: 0)      // initialize lastTickTime
        system.tick(now: 1.0)    // 1 second × 1000/s = 1000 spawn requests
        #expect(system.liveInstanceCount == 8)  // capped
    }

    @Test("Particle system allocates GPU buffer of expected size")
    func allocatesGPUBuffer() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 64,
            rate: 0, startDelay: 0,
            lifetimeMin: 1, lifetimeMax: 1,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: 0, dispersalMax: 0,
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0.1
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        #expect(system.capacity == 64)
        #expect(system.instanceBuffer.length == 64 * MemoryLayout<WPEParticleInstance>.stride)
    }

    @Test("Capacity ceiling protects against malformed maxcount")
    func capacityCeiling() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 100_000,
            rate: 0, startDelay: 0,
            lifetimeMin: 1, lifetimeMax: 1,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: 0, dispersalMax: 0,
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0.1
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        #expect(system.capacity == WPEParticleSystem.absoluteCap)
    }
}
