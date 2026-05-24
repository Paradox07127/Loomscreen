import Foundation
import LiveWallpaperProWPE
import Metal
import simd
import Testing
@testable import LiveWallpaper

struct WPEParticleSystemTests {

    @Test("Parses canonical snowflat-style particle JSON")
    func parsesCanonicalParticleJSON() throws {
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
        system.tick(now: 0)
        #expect(system.liveInstanceCount == 0)
        system.tick(now: 0.5)
        #expect(system.liveInstanceCount == 0)
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
        system.tick(now: 0)
        system.tick(now: 1.0)
        #expect(system.liveInstanceCount == 8)
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

    @Test("Parser captures rotation, angular velocity, alpha random, fadeout, gravity, drag")
    func parserCapturesP1Operators() throws {
        let json = #"""
        {
            "maxcount": 10,
            "emitter": [{"rate": 5}],
            "initializer": [
                {"name": "alpharandom", "min": 0.15, "max": 0.2},
                {"name": "rotationrandom", "min": "0 0 -1", "max": "0 0 1"},
                {"name": "angularvelocityrandom", "min": "0 0 -2", "max": "0 0 2"}
            ],
            "operator": [
                {"name": "alphafade", "fadeintime": 0.1, "fadeouttime": 0.9},
                {"name": "movement", "gravity": "0 -50 0", "drag": 0.5},
                {"name": "angularmovement", "force": "0 0 3", "drag": 0.2}
            ]
        }
        """#
        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
        #expect(def.alphaMin == 0.15)
        #expect(def.alphaMax == 0.2)
        #expect(def.rotationMin.z == -1)
        #expect(def.rotationMax.z == 1)
        #expect(def.angularVelocityMin.z == -2)
        #expect(def.angularVelocityMax.z == 2)
        #expect(def.fadeInSeconds == 0.1)
        #expect(def.fadeOutSeconds == 0.9)
        #expect(def.gravity.y == -50)
        #expect(def.drag == 0.5)
        #expect(def.angularForceZ == 3)
        #expect(def.angularDrag == 0.2)
    }

    @Test("Angular velocity advances rotationZ over time")
    func angularVelocityAdvancesRotation() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 4,
            rate: 1000, startDelay: 0,
            lifetimeMin: 10, lifetimeMax: 10,
            sizeMin: 4, sizeMax: 4,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: 0, dispersalMax: 0,
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0.01,
            angularVelocityMin: SIMD3(0, 0, 1.5),
            angularVelocityMax: SIMD3(0, 0, 1.5)
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        // First tick spawns; subsequent ticks integrate. dt is clamped
        // to 0.1s per tick to keep the simulator stable across stalls,
        // so cover the 0.5s window with explicit small steps.
        system.tick(now: 0)
        for step in 1...10 {
            system.tick(now: Double(step) * 0.05)
        }
        let pointer = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 4)
        // Particle spawned during the second tick (t=0.05); ticks
        // through t=0.5 add 9×0.05×1.5 ≈ 0.675 rad. Tolerance covers
        // sub-tick spawn placement and step accumulation rounding.
        #expect(abs(pointer[0].rotationAndLife.x - 0.675) < 0.1)
    }

    @Test("Gravity pulls velocity down over time")
    func gravityIntegrates() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 1,
            rate: 1000, startDelay: 0,
            lifetimeMin: 10, lifetimeMax: 10,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: 0, dispersalMax: 0,
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0.01,
            gravity: SIMD3(0, -10, 0)
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        system.tick(now: 0)
        system.tick(now: 0.05)
        let initialY = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)[0].positionAndSize.y
        // After another 0.1s with -10 ay, position.y should have fallen.
        system.tick(now: 0.15)
        let laterY = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)[0].positionAndSize.y
        #expect(laterY < initialY)
    }

    @Test("alpharandom selects per-particle base alpha")
    func alphaRandomScalesAlpha() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 8,
            rate: 1000, startDelay: 0,
            lifetimeMin: 5, lifetimeMax: 5,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: 0, dispersalMax: 0,
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0, // bypass the fade-in envelope
            alphaMin: 0.15, alphaMax: 0.15
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        // First tick spawns; second tick lands the spawned particles in
        // the GPU buffer with their full base alpha (fade-in disabled).
        system.tick(now: 0)
        system.tick(now: 0.05)
        let pointer = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 8)
        #expect(system.liveInstanceCount > 0)
        for index in 0..<system.liveInstanceCount {
            #expect(abs(pointer[index].color.w - 0.15) < 0.01)
        }
    }

    @Test("fadeOut envelope drops alpha near end of lifetime")
    func fadeOutDropsAlphaAtTail() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 1,
            rate: 1000, startDelay: 0,
            lifetimeMin: 1, lifetimeMax: 1,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: 0, dispersalMax: 0,
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0.0,
            fadeOutSeconds: 0.5
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        // Walk the simulator forward in 0.05s steps to stay under the
        // per-tick dt clamp (0.1s). The spawn happens in tick 2; by
        // tick 4 the particle has aged ~0.1s (well clear of fade-out).
        for step in 1...4 {
            system.tick(now: Double(step) * 0.05)
        }
        let early = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)[0].color.w
        // Continue past tailStart (0.5s) into the fade-out tail.
        for step in 5...17 {
            system.tick(now: Double(step) * 0.05)
        }
        let late = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)[0].color.w
        #expect(early > 0.9)
        #expect(late < early)
    }

    @Test("Parser captures turbulence parameters")
    func parserCapturesTurbulence() throws {
        let json = #"""
        {
            "maxcount": 10,
            "emitter": [{"rate": 5}],
            "initializer": [
                {"name": "turbulentvelocityrandom",
                 "speedmin": 35, "speedmax": 100,
                 "scale": 0.5, "offset": 3,
                 "timescale": 0.02,
                 "phasemin": 0, "phasemax": 6.28}
            ],
            "operator": []
        }
        """#
        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
        #expect(def.turbulenceSpeedMin == 35)
        #expect(def.turbulenceSpeedMax == 100)
        #expect(def.turbulenceScale == 0.5)
        #expect(def.turbulenceOffset == 3)
        #expect(def.turbulenceTimescale == 0.02)
        #expect(def.turbulencePhaseMax > 6.2)
    }

    @Test("Turbulence produces non-zero position delta")
    func turbulenceProducesPositionDelta() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let calmDef = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 4,
            rate: 1000, startDelay: 0,
            lifetimeMin: 10, lifetimeMax: 10,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: 0, dispersalMax: 0,
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0
        )
        let stormyDef = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 4,
            rate: 1000, startDelay: 0,
            lifetimeMin: 10, lifetimeMax: 10,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: 0, dispersalMax: 0,
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0,
            turbulenceSpeedMin: 50, turbulenceSpeedMax: 50,
            turbulenceScale: 0.1, turbulenceTimescale: 1,
            turbulencePhaseMin: 1, turbulencePhaseMax: 1
        )
        let calmSystem = try #require(WPEParticleSystem(definition: calmDef, device: device))
        let stormySystem = try #require(WPEParticleSystem(definition: stormyDef, device: device))
        for step in 1...10 {
            calmSystem.tick(now: Double(step) * 0.05)
            stormySystem.tick(now: Double(step) * 0.05)
        }
        let calm = calmSystem.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 4)[0]
            .positionAndSize
        let stormy = stormySystem.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 4)[0]
            .positionAndSize
        // Both systems share the same spawn placement (scene transform
        // is identity by default). Turbulence should push the stormy
        // particle clear of the calm baseline.
        let dx = stormy.x - calm.x
        let dy = stormy.y - calm.y
        #expect(sqrt(dx * dx + dy * dy) > 0.5)
    }

    @Test("Pre-warm advances simulation without prior tick")
    func prewarmAdvancesPopulation() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 16,
            rate: 8, startDelay: 1,
            lifetimeMin: 5, lifetimeMax: 5,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: 0, dispersalMax: 0,
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0.05
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        // Pre-warm 3 seconds — past startDelay (1) plus 2 seconds of
        // spawn time at 8/sec → expect ≈ 16 alive but capped at 16.
        system.prewarm(simulatedSeconds: 3)
        system.tick(now: 0)
        #expect(system.liveInstanceCount >= 8)
    }
}
