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

    @Test("Parser captures child references preserving duplicates and origin")
    func parserCapturesChildParticleDefinitions() throws {
        let json = #"""
        {
            "children": [
                {"id": 13, "name": "particles/presets/leaves2b.json"},
                {"id": 14, "name": "particles/presets/leaves2b.json", "origin": "60 0 0", "type": "eventfollow"}
            ],
            "maxcount": 5,
            "emitter": [{"rate": 1}]
        }
        """#

        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))

        #expect(def.childRelativePaths == [
            "particles/presets/leaves2b.json",
            "particles/presets/leaves2b.json"
        ])
        #expect(def.childReferences.count == 2)
        #expect(def.childReferences[0].id == 13)
        #expect(def.childReferences[0].originOffset == SIMD3<Double>(0, 0, 0))
        #expect(!def.childReferences[0].isEventFollow)
        #expect(def.childReferences[1].id == 14)
        #expect(def.childReferences[1].originOffset == SIMD3<Double>(60, 0, 0))
        #expect(def.childReferences[1].isEventFollow)
    }

    @Test("Parser treats explicit empty renderer as simulate-only")
    func parserCapturesRendererGate() throws {
        let spawner = #"""
        {
            "renderer": [],
            "children": [{"name": "particles/presets/child.json"}],
            "maxcount": 5,
            "emitter": [{"rate": 1}]
        }
        """#
        let drawable = #"""
        {
            "renderer": [{"name": "sprite"}],
            "maxcount": 5,
            "emitter": [{"rate": 1}]
        }
        """#
        let legacy = #"""
        {
            "maxcount": 5,
            "emitter": [{"rate": 1}]
        }
        """#

        #expect(try #require(WPEParticleDefinitionParser.parse(data: Data(spawner.utf8))).rendersSprite == false)
        #expect(try #require(WPEParticleDefinitionParser.parse(data: Data(drawable.utf8))).rendersSprite == true)
        #expect(try #require(WPEParticleDefinitionParser.parse(data: Data(legacy.utf8))).rendersSprite == true)
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
                {"name": "alphachange", "starttime": 0, "endtime": 0.8, "startvalue": 1, "endvalue": 0},
                {"name": "oscillatealpha", "frequency": 0.5, "scale": 0.6, "phasemin": 0.25},
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
        let alphaChange = try #require(def.alphaChange)
        #expect(alphaChange.startTime == 0)
        #expect(alphaChange.endTime == 0.8)
        #expect(alphaChange.startValue == 1)
        #expect(alphaChange.endValue == 0)
        let oscillateAlpha = try #require(def.oscillateAlpha)
        #expect(oscillateAlpha.frequency == 0.5)
        #expect(oscillateAlpha.scale == 0.6)
        #expect(oscillateAlpha.phase == 0.25)
        #expect(def.gravity.y == -50)
        #expect(def.drag == 0.5)
        #expect(def.angularForceZ == 3)
        #expect(def.angularDrag == 0.2)
    }

    @Test("alphachange interpolates over lifetime fractions")
    func alphaChangeInterpolatesOverLifetimeFractions() {
        let change = WPEParticleAlphaChange(startTime: 0, endTime: 0.8, startValue: 1, endValue: 0)
        #expect(abs(change.factor(lifetimeFraction: 0) - 1) < 0.0001)
        #expect(abs(change.factor(lifetimeFraction: 0.4) - 0.5) < 0.0001)
        #expect(abs(change.factor(lifetimeFraction: 0.8)) < 0.0001)
        #expect(abs(change.factor(lifetimeFraction: 1)) < 0.0001)
    }

    @Test("oscillatealpha clamps factor to [0,1]")
    func oscillateAlphaClampsFactor() {
        let oscillate = WPEParticleOscillateAlpha(frequency: 1, scale: 2, phase: 0)
        for age in stride(from: 0.0, through: 1.0, by: 0.05) {
            let factor = oscillate.factor(age: age)
            #expect(factor >= 0)
            #expect(factor <= 1)
        }
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

    @Test("Gravity integrates over time, pulling a particle along the gravity vector")
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
            // Author space is Y-up with NO Y-flip anywhere (see the
            // WPEParticleSceneTransform doc comment — the flip is the bug,
            // not the fix). The simulator integrates the authored gravity
            // vector as-is, so a negative gravity.y — "down on screen", the
            // sign real WPE presets use ("0 -50 0") — drives the particle's
            // Y downward over successive ticks.
            gravity: SIMD3(0, -10, 0)
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

    @Test("alphachange operator reduces written particle alpha over lifetime")
    func alphaChangeReducesWrittenAlphaOverLifetime() throws {
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
            fadeInSeconds: 0,
            alphaChange: WPEParticleAlphaChange(startTime: 0, endTime: 0.8, startValue: 1, endValue: 0)
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))

        system.tick(now: 0)
        system.tick(now: 0.05)
        let pointer = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)
        let early = pointer[0].color.w

        for step in 1...4 {
            system.tick(now: 0.05 + Double(step) * 0.1)
        }
        let middle = pointer[0].color.w

        for step in 5...8 {
            system.tick(now: 0.05 + Double(step) * 0.1)
        }
        let late = pointer[0].color.w

        #expect(early > 0.9)
        #expect(middle < early)
        #expect(late < 0.05)
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

    // MARK: - Mouse interaction: control points (M3)

    @Test("Cursor-follow: control point 0 with flags:1 makes the emitter track the pointer")
    func parsesCursorFollowControlPoints() throws {
        let json = #"""
        {
            "maxcount": 1000, "material": "materials/particle/halo.json",
            "controlpoint": [ {"flags":1,"id":0,"offset":"0 0 0"}, {"flags":0,"id":1,"offset":"0 0 0"} ],
            "emitter": [{"id":6,"name":"boxrandom","rate":200}],
            "operator": [{"name":"movement","drag":0.4}]
        }
        """#
        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
        #expect(def.controlPoints.count == 2)
        #expect(def.controlPoints.first(where: { $0.id == 0 })?.pointerLocked == true)
        #expect(def.controlPoints.first(where: { $0.id == 1 })?.pointerLocked == false)
        #expect(def.emitterTracksPointer == true)
        #expect(def.usesPointer == true)
        #expect(def.attractors.isEmpty)
    }

    @Test("Cursor-avoid: controlpointattract on a pointer-locked control point")
    func parsesCursorAvoidAttractor() throws {
        let json = #"""
        {
            "maxcount": 1000, "material": "materials/particle/halo.json",
            "controlpoint": [ {"flags":0,"id":0,"offset":"0 0 0"}, {"flags":1,"id":1,"offset":"0 0 0"} ],
            "emitter": [{"id":6,"name":"boxrandom","rate":200}],
            "operator": [
                {"name":"movement","drag":2.5},
                {"name":"controlpointattract","controlpoint":1,"scale":-5000,"threshold":64}
            ]
        }
        """#
        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
        #expect(def.emitterTracksPointer == false)   // id 0 not locked
        #expect(def.controlPoints.first(where: { $0.id == 1 })?.pointerLocked == true)
        let attractor = try #require(def.attractors.first)
        #expect(def.attractors.count == 1)
        #expect(attractor.controlPointID == 1)
        #expect(attractor.scale == -5000)
        #expect(attractor.threshold == 64)
        #expect(def.usesPointer == true)            // attractor references pointer-locked id 1
    }

    @Test("Pointer-locked emitter spawns particles at the cursor")
    func pointerLockedEmitterSpawnsAtCursor() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 4,
            rate: 1000, startDelay: 0,
            lifetimeMin: 10, lifetimeMax: 10,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: 0, dispersalMax: 0,
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0.05,
            controlPoints: [WPEParticleControlPoint(id: 0, offset: SIMD3(0, 0, 0), pointerLocked: true)]
        )
        // Object origin at the scene center → renderOrigin (0,0); no dispersal /
        // velocity, so a pointer-locked emitter spawns exactly at the cursor.
        let transform = WPEParticleSceneTransform(
            sceneSize: SIMD2(1000, 1000),
            objectOrigin: SIMD3(500, 500, 0),
            objectScale: SIMD3(1, 1, 1),
            objectAngleZ: 0
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device, sceneTransform: transform))
        system.pointerCentered = SIMD2(200, 150)
        system.tick(now: 0)       // dt=0, no spawn yet
        system.tick(now: 0.02)    // spawns at the cursor
        let inst = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 4)[0]
        #expect(abs(inst.positionAndSize.x - 200) < 1)
        #expect(abs(inst.positionAndSize.y - 150) < 1)
    }

    @Test("Event-follow control point injection wins over static resolution")
    func eventFollowControlPointInjectionWins() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = stillParticleDefinition(rate: 0, originOffset: SIMD3(300, 300, 0))
        let system = try #require(WPEParticleSystem(
            definition: def,
            device: device,
            sceneTransform: centeredParticleTransform
        ))
        let injected = SIMD3<Float>(120, -35, 9)

        system.injectedControlPoints[system.followControlPointID] = injected

        #expect(system.controlPointPosition(system.followControlPointID) == injected)
    }

    @Test("Event-follow child spawns at injected parent particle position")
    func eventFollowChildSpawnsAtInjectedParentPosition() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = stillParticleDefinition(maxCount: 1, originOffset: SIMD3(300, 300, 0))
        let system = try #require(WPEParticleSystem(
            definition: def,
            device: device,
            sceneTransform: centeredParticleTransform
        ))
        let injected = SIMD3<Float>(42, -84, 0)
        system.requiresFollowParent = true
        system.injectedControlPoints[system.followControlPointID] = injected

        system.tick(now: 0)
        system.tick(now: 0.02)

        #expect(system.liveInstanceCount == 1)
        let inst = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)[0]
        #expect(abs(inst.positionAndSize.x - injected.x) < 1)
        #expect(abs(inst.positionAndSize.y - injected.y) < 1)
    }

    @Test("Event-follow child does not spawn without a live parent injection")
    func eventFollowChildSkipsSpawnWithoutInjectedPosition() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let parent = try #require(WPEParticleSystem(
            definition: stillParticleDefinition(maxCount: 1),
            device: device,
            sceneTransform: centeredParticleTransform
        ))
        let child = try #require(WPEParticleSystem(
            definition: stillParticleDefinition(maxCount: 1),
            device: device,
            sceneTransform: centeredParticleTransform
        ))
        child.followParent = parent
        child.requiresFollowParent = true

        child.tick(now: 0)
        child.tick(now: 0.05)

        #expect(child.liveInstanceCount == 0)
    }

    @Test("Primary live particle position reports the youngest live particle")
    func primaryLiveParticlePositionReportsLiveParticle() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = stillParticleDefinition(maxCount: 1, originOffset: SIMD3(12, -8, 0))
        let system = try #require(WPEParticleSystem(
            definition: def,
            device: device,
            sceneTransform: centeredParticleTransform
        ))

        #expect(system.primaryLiveParticlePosition == nil)
        system.tick(now: 0)
        system.tick(now: 0.02)

        let position = try #require(system.primaryLiveParticlePosition)
        #expect(abs(position.x - 12) < 1)
        #expect(abs(position.y + 8) < 1)
    }

    private func stillParticleDefinition(
        maxCount: Int = 4,
        rate: Double = 1000,
        originOffset: SIMD3<Double> = SIMD3(0, 0, 0)
    ) -> WPEParticleDefinition {
        WPEParticleDefinition(
            materialRelativePath: nil,
            maxCount: maxCount,
            rate: rate,
            startDelay: 0,
            lifetimeMin: 10,
            lifetimeMax: 10,
            sizeMin: 1,
            sizeMax: 1,
            originOffset: originOffset,
            dispersalMin: 0,
            dispersalMax: 0,
            velocityMin: SIMD3(0, 0, 0),
            velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255),
            colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0
        )
    }

    private var centeredParticleTransform: WPEParticleSceneTransform {
        WPEParticleSceneTransform(
            sceneSize: SIMD2(1000, 1000),
            objectOrigin: SIMD3(500, 500, 0),
            objectScale: SIMD3(1, 1, 1),
            objectAngleZ: 0
        )
    }
}
