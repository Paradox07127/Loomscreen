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

    @Test("Parser captures child particle definitions")
    func parserCapturesChildParticleDefinitions() throws {
        let json = #"""
        {
            "children": [
                {"id": 13, "name": "particles/presets/leaves2b.json"}
            ],
            "maxcount": 5,
            "emitter": [{"rate": 1}]
        }
        """#

        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))

        #expect(def.childRelativePaths == ["particles/presets/leaves2b.json"])
    }

    @Test("Parser defaults sphere random emitters to 2D directions")
    func parserDefaultsSphereRandomEmittersTo2DDirections() throws {
        let json = #"""
        {
            "maxcount": 500,
            "emitter": [{
                "name": "sphererandom",
                "rate": 5,
                "distancemin": 64,
                "distancemax": 1024
            }]
        }
        """#

        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))

        #expect(def.directionMask == SIMD3<Double>(1, 1, 0))
    }

    @Test("Particle instance override scales count rate lifetime size and speed")
    func particleInstanceOverrideScalesDefinition() {
        let base = WPEParticleDefinition(
            materialRelativePath: nil,
            maxCount: 5,
            rate: 1.7,
            startDelay: 3,
            lifetimeMin: 20, lifetimeMax: 20,
            sizeMin: 100, sizeMax: 110,
            originOffset: SIMD3(350, 750, 0),
            dispersalMin: 0, dispersalMax: 750,
            velocityMin: SIMD3(-200, -100, 0), velocityMax: SIMD3(-300, -15, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 236, 0),
            fadeInSeconds: 0.1,
            turbulenceSpeedMin: 35,
            turbulenceSpeedMax: 100
        )
        let override = WPESceneParticleInstanceOverride(
            count: 0.2,
            rate: 0.5,
            lifetime: 1.77,
            size: 0.69,
            speed: 1.32,
            alpha: 0.03,
            color: SIMD3<Double>(192, 192, 192)
        )

        let scaled = base.applying(instanceOverride: override)

        #expect(scaled.maxCount == 1)
        #expect(abs(scaled.rate - 0.85) < 0.0001)
        #expect(abs(scaled.lifetimeMin - 35.4) < 0.0001)
        #expect(abs(scaled.sizeMin - 69) < 0.0001)
        #expect(abs(scaled.sizeMax - 75.9) < 0.0001)
        #expect(abs(scaled.velocityMin.x - (-264)) < 0.0001)
        #expect(abs(scaled.turbulenceSpeedMax - 132) < 0.0001)
        #expect(abs(scaled.alphaMin - 0.03) < 0.0001)
        #expect(abs(scaled.alphaMax - 0.03) < 0.0001)
        #expect(scaled.colorMin == SIMD3<Double>(192, 192, 192))
        #expect(scaled.colorMax == SIMD3<Double>(192, 192, 192))
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

    @Test("Gravity pulls particles down on screen (author writes +Y in Y-down emitter frame)")
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
            // Emitter-internal Y-down: +gy in JSON pulls particles
            // down on screen. The runtime Y-flips once at init so the
            // Y-up simulator integrates a -y velocity over time.
            gravity: SIMD3(0, 10, 0)
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        system.tick(now: 0)
        system.tick(now: 0.05)
        let initialY = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)[0].positionAndSize.y
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

    @Test("Parser captures turbulence operator parameters")
    func parserCapturesTurbulenceOperator() throws {
        let json = #"""
        {
            "maxcount": 10,
            "emitter": [{"rate": 5}],
            "operator": [
                {"name": "turbulence", "speedmin": 750, "speedmax": 900, "mask": "0.5 4 0"}
            ]
        }
        """#
        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))

        #expect(def.turbulenceSpeedMin == 750)
        #expect(def.turbulenceSpeedMax == 900)
        #expect(def.turbulenceMask.x == 0.5)
        #expect(def.turbulenceMask.y == 4)
        #expect(def.turbulenceMask.z == 0)
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

    @Test("alphafade timings are lifetime fractions, not seconds")
    func fadeTimingsAreLifetimeFractions() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        // leaves2-style: lifetime 10s, fadeintime 0.1 (= 10% lifetime = 1s).
        // At t≈1s (right after fade-in completes) alpha should be ~1.0.
        // If the implementation treats `0.1` as seconds we would see alpha
        // already at 1.0 by t=0.15s, but also have age==fadeInSeconds=0.1
        // mean "fully visible" — different from the fraction semantics that
        // demand alpha≈0.45 at age=0.45s. The test below pins the fraction
        // behaviour at the boundary where the two interpretations diverge.
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 1,
            rate: 1000, startDelay: 0,
            lifetimeMin: 10, lifetimeMax: 10,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: 0, dispersalMax: 0,
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0.1, // 10% lifetime
            fadeOutSeconds: 0.0
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        // First tick spawns, second tick advances ~0.05s (~0.5% lifetime).
        system.tick(now: 0)
        system.tick(now: 0.05)
        let mid = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)[0].color.w
        // age ≈ 0.05s, lifetime 10s, fraction ≈ 0.005, fadeInFrac 0.1
        // → alpha ≈ 0.005 / 0.1 = 0.05. If the impl treated 0.1 as seconds
        // we'd see alpha ≈ 0.5. Tolerance is generous around the boundary.
        #expect(mid < 0.15)
        // Now ramp to ~10% lifetime (age=1.0s) — fade-in should be done.
        for step in 2...22 {
            system.tick(now: Double(step) * 0.05)
        }
        let full = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)[0].color.w
        #expect(full > 0.95)
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

    @Test("Pre-warm reanchors simulation clock to runtime zero")
    func prewarmReanchorsSimulationClock() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 1,
            rate: 1000, startDelay: 0,
            lifetimeMin: 10, lifetimeMax: 10,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: 0, dispersalMax: 0,
            velocityMin: SIMD3(100, 0, 0), velocityMax: SIMD3(100, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0.05
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        system.prewarm(simulatedSeconds: 2)
        system.tick(now: 0)
        let before = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)[0].positionAndSize.x

        system.tick(now: 0.1)
        let after = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)[0].positionAndSize.x

        #expect(after > before + 5)
    }
}
