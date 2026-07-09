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
        // `colorn` multiplies the authored colour (÷255) instead of replacing it:
        // 3462491575's matrix glyphs keep their green `colorrandom` under a white
        // `colorn` on Windows, which replacement would have bleached.
        #expect(scaled.colorMin == SIMD3<Double>(192, 192, 192))
        let expectedColorMax = SIMD3<Double>(192, 236.0 * 192.0 / 255.0, 0)
        #expect(abs(scaled.colorMax.x - expectedColorMax.x) < 0.0001)
        #expect(abs(scaled.colorMax.y - expectedColorMax.y) < 0.0001)
        #expect(abs(scaled.colorMax.z - expectedColorMax.z) < 0.0001)
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

    @Test("Pointer-tracking emitter stops + clears when Follow Cursor is off")
    func pointerEmitterStopsWhenFollowDisabled() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil,
            maxCount: 16,
            rate: 1000,
            startDelay: 0,
            lifetimeMin: 100, lifetimeMax: 100,
            sizeMin: 4, sizeMax: 4,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: 0, dispersalMax: 0,
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0.1,
            controlPoints: [WPEParticleControlPoint(id: 0, offset: SIMD3(0, 0, 0), pointerLocked: true)]
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        #expect(system.tracksPointer)

        system.pointerCentered = SIMD2<Float>(10, 20)
        system.tick(now: 0)
        system.tick(now: 1.0)
        #expect(system.liveInstanceCount > 0)

        // Follow Cursor off: clear removes the residual immediately, and the gate
        // keeps the emitter from re-spawning at the static scene origin.
        system.clearLiveParticles()
        #expect(system.liveInstanceCount == 0)
        system.pointerCentered = nil
        system.tick(now: 2.0)
        system.tick(now: 3.0)
        #expect(system.liveInstanceCount == 0)

        system.pointerCentered = SIMD2<Float>(30, 40)
        system.tick(now: 4.0)
        #expect(system.liveInstanceCount > 0)
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

    @Test("A seeded RNG makes particle spawn jitter reproducible run-to-run (oracle determinism)")
    func seededParticleRNGIsDeterministic() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        // RNG must actually affect the output: dispersal spread, per-particle size,
        // lifetime, velocity and color are all sampled at spawn.
        func makeDef() -> WPEParticleDefinition {
            WPEParticleDefinition(
                materialRelativePath: nil, maxCount: 64,
                rate: 2000, startDelay: 0,
                lifetimeMin: 2, lifetimeMax: 8,
                sizeMin: 2, sizeMax: 12,
                originOffset: SIMD3(0, 0, 0),
                dispersalMin: 0, dispersalMax: 200,
                velocityMin: SIMD3(-50, -50, 0), velocityMax: SIMD3(50, 50, 0),
                colorMin: SIMD3(0, 0, 0), colorMax: SIMD3(255, 255, 255),
                fadeInSeconds: 0.01
            )
        }
        // Byte-exact snapshot of the LIVE instance slice (dead slots past
        // `liveInstanceCount` hold stale memory and are not written each tick).
        func liveSnapshot(seed: UInt64?) throws -> Data {
            let system = try #require(WPEParticleSystem(definition: makeDef(), device: device, seed: seed))
            system.tick(now: 0)
            for step in 1...20 { system.tick(now: Double(step) * 0.05) }
            let liveBytes = system.liveInstanceCount * MemoryLayout<WPEParticleInstance>.stride
            #expect(liveBytes > 0)
            return Data(bytes: system.instanceBuffer.contents(), count: liveBytes)
        }
        let a = try liveSnapshot(seed: 0x00AB_CDEF)
        let b = try liveSnapshot(seed: 0x00AB_CDEF)
        let c = try liveSnapshot(seed: 0x0012_3456)
        #expect(a == b)   // same seed ⇒ byte-identical particle state
        #expect(a != c)   // different seed ⇒ different jitter (the seed really drives it)
    }

    @Test("deterministicSeed is stable per input and unique across scene/object/order")
    func deterministicSeedIsStableAndUnique() {
        let base = WPEParticleSystem.deterministicSeed(workshopID: "123456", objectID: "42", sortIndex: 3)
        #expect(base == WPEParticleSystem.deterministicSeed(workshopID: "123456", objectID: "42", sortIndex: 3))
        #expect(base != WPEParticleSystem.deterministicSeed(workshopID: "123457", objectID: "42", sortIndex: 3))
        #expect(base != WPEParticleSystem.deterministicSeed(workshopID: "123456", objectID: "43", sortIndex: 3))
        #expect(base != WPEParticleSystem.deterministicSeed(workshopID: "123456", objectID: "42", sortIndex: 4))
        // The '\' field separator must prevent "12"+"3456" from colliding with "123"+"456".
        #expect(WPEParticleSystem.deterministicSeed(workshopID: "12", objectID: "3456", sortIndex: 0)
            != WPEParticleSystem.deterministicSeed(workshopID: "123", objectID: "456", sortIndex: 0))
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

    @Test("Parser reads perspective flag (flags & 4)")
    func parserReadsPerspectiveFlag() throws {
        let perspective = try #require(WPEParticleDefinitionParser.parse(
            data: Data(#"{"maxcount": 4, "flags": 4, "emitter": [{"rate": 5}]}"#.utf8)))
        #expect(perspective.isPerspective)
        let flat = try #require(WPEParticleDefinitionParser.parse(
            data: Data(#"{"maxcount": 4, "flags": 0, "emitter": [{"rate": 5}]}"#.utf8)))
        #expect(!flat.isPerspective)
        let none = try #require(WPEParticleDefinitionParser.parse(
            data: Data(#"{"maxcount": 4, "emitter": [{"rate": 5}]}"#.utf8)))
        #expect(!none.isPerspective)
    }

    @Test("Perspective particles draw with depth-varied size")
    func perspectiveDepthVariesSize() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        // Sphere emitter with a wide Z dispersal → particles at many depths.
        // Positive Z projects toward the camera and grows, while nonpositive
        // depth remains near the authored size.
        let json = #"""
        {
            "maxcount": 200, "flags": 4,
            "emitter": [{"name": "sphererandom", "rate": 100000, "distancemin": 10, "distancemax": 1000, "directions": "1 1 1"}],
            "initializer": [
                {"name": "lifetimerandom", "min": 100, "max": 100},
                {"name": "sizerandom", "min": 40, "max": 40}
            ]
        }
        """#
        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
        #expect(def.isPerspective)
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        for step in 1...6 { system.tick(now: Double(step) * 0.05) }
        let n = system.liveInstanceCount
        try #require(n >= 32)
        let buf = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 200)
        var minSize: Float = .greatestFiniteMagnitude
        var maxSize: Float = 0
        for i in 0..<n {
            let s = buf[i].positionAndSize.w
            minSize = Swift.min(minSize, s)
            maxSize = Swift.max(maxSize, s)
        }
        // Authored size 40; the depth cue boosts NEAR flakes (depthScale up to
        // 1+boost) and leaves FAR ones at ~1×. So sizes span from ~40 (far) up
        // past 40 (near, boosted), a clear near/far spread.
        #expect(minSize <= 45, "far particles stay near the base size (min \(minSize))")
        #expect(maxSize > 60, "near particles are boosted bigger (max \(maxSize))")
        #expect(maxSize - minSize > 20, "depth should spread sizes (span \(maxSize - minSize))")
    }

    @Test("Perspective particles keep depth projection when Z comes from gravity")
    func perspectiveDepthAccountsForGravityTravel() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 1,
            rate: 1000, startDelay: 0,
            lifetimeMin: 5, lifetimeMax: 5,
            sizeMin: 10, sizeMax: 10,
            originOffset: SIMD3(100, 0, 0),
            dispersalMin: 0, dispersalMax: 0,
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0,
            directionMask: SIMD3(2, 2, 0),
            gravity: SIMD3(0, 0, 250),
            isPerspective: true
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        system.tick(now: 0)
        system.tick(now: 0.05)
        let near = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)[0].positionAndSize

        for step in 2...12 {
            system.tick(now: Double(step) * 0.05)
        }
        let mid = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)[0].positionAndSize

        for step in 13...40 {
            system.tick(now: Double(step) * 0.05)
        }
        let late = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)[0].positionAndSize

        // This starfield pattern spawns at z=0 and moves only through +Z
        // gravity. WPE renders that as motion toward the camera: particles
        // project farther from the vanishing point and grow over their life.
        #expect(mid.x > near.x + 1)
        #expect(mid.w > near.w + 0.1)
        #expect(late.x > mid.x + 5)
        #expect(late.w > mid.w + 0.5)
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

    @Test("Parser flags a turbulentvelocityrandom initializer")
    func parserFlagsTurbulentVelocityInit() throws {
        let seeded = try #require(WPEParticleDefinitionParser.parse(data: Data(#"""
        {
            "maxcount": 8, "emitter": [{"name": "boxrandom", "rate": 10}],
            "initializer": [{"name": "turbulentvelocityrandom", "offset": 0.5, "scale": 0.1}]
        }
        """#.utf8)))
        #expect(seeded.hasTurbulentVelocityInit)
        let plain = try #require(WPEParticleDefinitionParser.parse(data: Data(#"""
        {"maxcount": 8, "emitter": [{"name": "boxrandom", "rate": 10}]}
        """#.utf8)))
        #expect(!plain.hasTurbulentVelocityInit)
    }

    @Test("turbulentvelocityrandom seeds a travelling velocity (embers leave the box)")
    func turbulentVelocityInitSeedsMotion() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        // Ember-style: point spawn, zero base velocity, NO turbulence operator
        // (speedMax 0). The only Y-motion source is the seed. Without it the
        // sparks are stuck at spawn Y (invisible below-screen); with it they
        // travel out of the box.
        func makeDef(seed: Bool) -> WPEParticleDefinition {
            WPEParticleDefinition(
                materialRelativePath: nil, maxCount: 32,
                rate: 10000, startDelay: 0,
                lifetimeMin: 10, lifetimeMax: 10,
                sizeMin: 1, sizeMax: 1,
                originOffset: SIMD3(0, 0, 0),
                dispersalMin: 0, dispersalMax: 0,
                velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
                colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
                fadeInSeconds: 0,
                hasTurbulentVelocityInit: seed
            )
        }
        // Spread of Y across live particles: a point emitter with zero base
        // velocity keeps every spark on the SAME Y line unless the seed gives
        // each a distinct travelling velocity.
        func spreadY(_ def: WPEParticleDefinition) throws -> Float {
            let system = try #require(WPEParticleSystem(definition: def, device: device))
            for step in 1...6 { system.tick(now: Double(step) * 0.1) }
            let n = system.liveInstanceCount
            try #require(n >= 8)
            let buf = system.instanceBuffer.contents()
                .bindMemory(to: WPEParticleInstance.self, capacity: 32)
            var lo: Float = .greatestFiniteMagnitude
            var hi: Float = -.greatestFiniteMagnitude
            for i in 0..<n {
                let y = buf[i].positionAndSize.y
                lo = Swift.min(lo, y); hi = Swift.max(hi, y)
            }
            return hi - lo
        }
        let stuck = try spreadY(makeDef(seed: false))
        let travelled = try spreadY(makeDef(seed: true))
        #expect(stuck < 0.01, "no seed → all sparks stay on one Y line (spread \(stuck))")
        #expect(travelled > 10, "seed → sparks fan out in Y (spread \(travelled))")
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

    @Test("Authored starttime forces WPE-matching prewarm without the manual prewarm flag")
    func authoredStarttimeForcesPrewarm() {
        let delayed = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 5_000,
            rate: 250, startDelay: 200,
            lifetimeMin: 5, lifetimeMax: 5,
            sizeMin: 3, sizeMax: 5,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: 0, dispersalMax: 512,
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0.1
        )
        let immediate = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 128,
            rate: 10, startDelay: 0,
            lifetimeMin: 2, lifetimeMax: 2,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: 0, dispersalMax: 0,
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0
        )

        #expect(WPEMetalSceneRenderer.particlePrewarmSeconds(
            for: delayed,
            manualPrewarmEnabled: false
        ) == 205)
        #expect(WPEMetalSceneRenderer.particlePrewarmSeconds(
            for: immediate,
            manualPrewarmEnabled: false
        ) == nil)
        #expect(WPEMetalSceneRenderer.particlePrewarmSeconds(
            for: immediate,
            manualPrewarmEnabled: true
        ) == 2)
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

    @Test("controlpointattract repels particles away from a pointer-locked cursor (scene 3554161528 mechanism)")
    func cursorRepelPushesParticlesAway() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 1,
            rate: 1000, startDelay: 0,
            lifetimeMin: 100, lifetimeMax: 100,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: 0, dispersalMax: 0,
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0,
            controlPoints: [
                WPEParticleControlPoint(id: 0, offset: SIMD3(0, 0, 0), pointerLocked: false),
                WPEParticleControlPoint(id: 1, offset: SIMD3(0, 0, 0), pointerLocked: true)
            ],
            attractors: [
                WPEParticleControlPointAttractor(controlPointID: 1, scale: -1000, threshold: 200)
            ]
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        // Cursor just to the right of the spawn origin (0,0); a negative-scale
        // attractor must push the particle LEFT (away from the +x cursor).
        system.pointerCentered = SIMD2<Float>(20, 0)
        system.tick(now: 0)
        system.tick(now: 0.05)
        let pointer = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)
        let x0 = pointer[0].positionAndSize.x
        for step in 2...6 { system.tick(now: Double(step) * 0.05) }
        let x1 = pointer[0].positionAndSize.x
        #expect(x1 < x0)
        #expect(system.lastAttractorAffectedCount >= 1)
        #expect(system.cursorDebugSummary() != nil)
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

    @Test("Parser captures sizechange, colorchange, oscillateposition operators")
    func parserCapturesModulationOperators() throws {
        let json = #"""
        {
            "maxcount": 10,
            "emitter": [{"rate": 5}],
            "operator": [
                {"name": "sizechange", "starttime": 0, "endtime": 1, "startvalue": 0, "endvalue": 1},
                {"name": "colorchange", "startvalue": "1 1 1", "endvalue": "1 0 0"},
                {"name": "oscillateposition", "frequencymin": 0.8, "frequencymax": 1.0,
                 "scalemin": 20, "scalemax": 35, "phasemin": 0, "phasemax": 1, "mask": "1 0.5 0"}
            ]
        }
        """#
        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
        let size = try #require(def.sizeChange)
        #expect(size.startValue == 0)
        #expect(size.endValue == 1)
        let color = try #require(def.colorChange)
        #expect(color.endColor.x == 1)
        #expect(color.endColor.y == 0)
        let osc = try #require(def.oscillatePosition)
        #expect(osc.frequencyMin == 0.8)
        #expect(osc.frequencyMax == 1.0)
        #expect(osc.scaleMin == 20)
        #expect(osc.scaleMax == 35)
        #expect(osc.mask.x == 1)
        #expect(osc.mask.y == 0.5)
    }

    @Test("sizechange factor ramps over lifetime")
    func sizeChangeFactorRamps() {
        let s = WPEParticleSizeChange(startTime: 0, endTime: 1, startValue: 0, endValue: 1)
        #expect(abs(s.factor(lifetimeFraction: 0)) < 0.0001)
        #expect(abs(s.factor(lifetimeFraction: 0.5) - 0.5) < 0.0001)
        #expect(abs(s.factor(lifetimeFraction: 1) - 1) < 0.0001)
    }

    @Test("colorchange interpolates each channel independently")
    func colorChangeInterpolatesChannels() {
        let c = WPEParticleColorChange(
            startTime: 0, endTime: 1,
            startColor: SIMD3(1, 1, 1), endColor: SIMD3(1, 0, 0)
        )
        let mid = c.color(lifetimeFraction: 0.5)
        #expect(abs(mid.x - 1) < 0.0001)
        #expect(abs(mid.y - 0.5) < 0.0001)
        #expect(abs(mid.z - 0.5) < 0.0001)
    }

    @Test("sizechange grows the written sprite size over lifetime")
    func sizeChangeGrowsWrittenSize() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 1,
            rate: 1000, startDelay: 0,
            lifetimeMin: 1, lifetimeMax: 1,
            sizeMin: 10, sizeMax: 10,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: 0, dispersalMax: 0,
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0,
            sizeChange: WPEParticleSizeChange(startTime: 0, endTime: 1, startValue: 0, endValue: 1)
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        let pointer = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)
        system.tick(now: 0)
        system.tick(now: 0.05)
        let early = pointer[0].positionAndSize.w
        for step in 1...8 { system.tick(now: 0.05 + Double(step) * 0.1) }
        let late = pointer[0].positionAndSize.w
        #expect(early < 2)
        #expect(late > 6)
        #expect(late > early)
    }

    @Test("colorchange multiplies the written tint over lifetime")
    func colorChangeMultipliesWrittenColor() throws {
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
            colorChange: WPEParticleColorChange(
                startTime: 0, endTime: 1,
                startColor: SIMD3(1, 1, 1), endColor: SIMD3(1, 0, 0)
            ),
            hasColorInitializer: true
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        let pointer = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)
        system.tick(now: 0)
        system.tick(now: 0.05)
        let early = pointer[0].color
        for step in 1...8 { system.tick(now: 0.05 + Double(step) * 0.1) }
        let late = pointer[0].color
        #expect(early.y > 0.8)        // green starts ~white
        #expect(late.x > 0.8)         // red channel preserved (multiplier 1)
        #expect(late.y < late.x)      // green ramped down below red
    }

    @Test("oscillateposition sways the written position with bounded amplitude (transient, no drift)")
    func oscillatePositionSwaysBounded() throws {
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
            fadeInSeconds: 0,
            oscillatePosition: WPEParticleOscillatePosition(
                frequencyMin: 1, frequencyMax: 1,
                scaleMin: 50, scaleMax: 50,
                phaseMin: 0, phaseMax: 0,
                mask: SIMD3(1, 0, 0)
            )
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        let pointer = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)
        var minX = Float.greatestFiniteMagnitude
        var maxX = -Float.greatestFiniteMagnitude
        // Sample over >1 full period (freq 1 → 1s). A transient sine sway stays
        // bounded by ±scale forever; an integrated offset would widen each cycle.
        system.tick(now: 0)
        for step in 1...30 {
            system.tick(now: Double(step) * 0.05)
            let x = pointer[0].positionAndSize.x
            minX = min(minX, x)
            maxX = max(maxX, x)
        }
        let amplitude = (maxX - minX) / 2
        #expect(amplitude > 40)
        #expect(amplitude < 60)
    }

    @Test("colorchange multiplier composes with 0...255 colorrandom normalization")
    func colorChangeComposesWithColorNormalization() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 1,
            rate: 1000, startDelay: 0,
            lifetimeMin: 10, lifetimeMax: 10,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: 0, dispersalMax: 0,
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(128, 128, 128), colorMax: SIMD3(128, 128, 128),
            fadeInSeconds: 0,
            colorChange: WPEParticleColorChange(
                startTime: 0, endTime: 1,
                startColor: SIMD3(0.5, 0.5, 0.5), endColor: SIMD3(0.5, 0.5, 0.5)
            ),
            hasColorInitializer: true
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        let pointer = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)
        system.tick(now: 0)
        system.tick(now: 0.05)
        let written = pointer[0].color
        // 128/255 ≈ 0.502 (colorrandom, normalized once at spawn) × 0.5
        // (colorchange 0…1 multiplier) ≈ 0.251 — guards against re-normalizing.
        #expect(abs(written.x - 0.251) < 0.02)
    }

    @Test("colorchange does NOT recolour a particle with no colour initializer (white r8 smoke stays white)")
    func colorChangeSkippedWithoutColorInitializer() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        // Wildfire (scene 3460973721): white r8 smoke, NO color/colorrandom
        // initializer, but ships a colorchange operator (橙→纯红). The colour
        // must stay the texture's white — colorchange must not ramp it to red.
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 1,
            rate: 1000, startDelay: 0,
            lifetimeMin: 10, lifetimeMax: 10,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: 0, dispersalMax: 0,
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0,
            colorChange: WPEParticleColorChange(
                startTime: 0, endTime: 0.6,
                startColor: SIMD3(1, 0.749, 0), endColor: SIMD3(1, 0, 0)
            )
            // hasColorInitializer defaults false → colorchange must be skipped
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        let pointer = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)
        system.tick(now: 0)
        for step in 1...8 { system.tick(now: Double(step) * 0.1) }
        let c = pointer[0].color
        #expect(c.x > 0.9, "red stays ~white")
        #expect(c.y > 0.9, "green NOT ramped down — stays ~white")
        #expect(c.z > 0.9, "blue NOT zeroed — stays ~white")
    }

    @Test("colorn instance-override applies (dims) even without a colour initializer")
    func colornOverrideAppliesWithoutColorInitializer() throws {
        // wildfire-like: no colour initializer. colorn (暗紫) STILL applies and
        // dims the default white smoke to a faint haze — that dimming is exactly
        // why WPE's wildfire is barely visible. Only `colorchange` is gated off.
        let base = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 1,
            rate: 1, startDelay: 0,
            lifetimeMin: 1, lifetimeMax: 1,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: 0, dispersalMax: 0,
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0
        )
        let override = WPESceneParticleInstanceOverride(color: SIMD3(61, 41, 69)) // colorn 暗紫 ×255
        let applied = base.applying(instanceOverride: override)
        // colorn 暗紫 dims the default white (keeps wildfire faint, not pure white)
        #expect(applied.colorMin == SIMD3(61, 41, 69))
        #expect(applied.colorMax == SIMD3(61, 41, 69))
    }

    @Test("oscillateposition mask transforms into render space with object rotation")
    func oscillatePositionMaskRotatesWithObject() throws {
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
            fadeInSeconds: 0,
            oscillatePosition: WPEParticleOscillatePosition(
                frequencyMin: 1, frequencyMax: 1,
                scaleMin: 50, scaleMax: 50,
                phaseMin: 0, phaseMax: 0,
                mask: SIMD3(1, 0, 0)   // local +X sway
            )
        )
        // A 90° object rotation maps the local +X sway onto the render Y axis.
        let transform = WPEParticleSceneTransform(
            sceneSize: SIMD2(1000, 1000),
            objectOrigin: SIMD3(500, 500, 0),
            objectScale: SIMD3(1, 1, 1),
            objectAngleZ: Float.pi / 2
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device, sceneTransform: transform))
        let pointer = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)
        var minX = Float.greatestFiniteMagnitude, maxX = -Float.greatestFiniteMagnitude
        var minY = Float.greatestFiniteMagnitude, maxY = -Float.greatestFiniteMagnitude
        system.tick(now: 0)
        for step in 1...30 {
            system.tick(now: Double(step) * 0.05)
            let p = pointer[0].positionAndSize
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        #expect((maxX - minX) < 5)    // local-X sway must NOT land on render X
        #expect((maxY - minY) > 80)   // it lands on render Y after the rotation
    }

    @Test("object scale enlarges sprite size (WPE T·R·S model)")
    func objectScaleEnlargesSpriteSize() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 1,
            rate: 1000, startDelay: 0,
            lifetimeMin: 100, lifetimeMax: 100,
            sizeMin: 50, sizeMax: 50,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: 0, dispersalMax: 0,
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0
        )
        let transform = WPEParticleSceneTransform(
            sceneSize: SIMD2(1000, 1000), objectOrigin: SIMD3(500, 500, 0),
            objectScale: SIMD3(2, 2, 1), objectAngleZ: 0
        )
        let system = try #require(WPEParticleSystem(
            definition: def, device: device, sceneTransform: transform))
        system.tick(now: 0); system.tick(now: 0.05)
        let w = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)[0].positionAndSize.w
        #expect(abs(w - 100) < 1)   // 50 base × object scale 2
    }

    @Test("additive sprite size is capped near scene height; translucent is not")
    func additiveSpriteSizeCapped() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        func makeSized(blend: WPEParticleBlendMode) throws -> Float {
            let def = WPEParticleDefinition(
                materialRelativePath: nil, maxCount: 1,
                rate: 1000, startDelay: 0,
                lifetimeMin: 100, lifetimeMax: 100,
                sizeMin: 50, sizeMax: 50,
                originOffset: SIMD3(0, 0, 0),
                dispersalMin: 0, dispersalMax: 0,
                velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
                colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
                fadeInSeconds: 0
            )
            // object scale 100 → 50×100 = 5000 px before any cap.
            let transform = WPEParticleSceneTransform(
                sceneSize: SIMD2(1000, 1000), objectOrigin: SIMD3(500, 500, 0),
                objectScale: SIMD3(100, 100, 1), objectAngleZ: 0
            )
            let system = try #require(WPEParticleSystem(
                definition: def, device: device, blendMode: blend, sceneTransform: transform))
            system.tick(now: 0); system.tick(now: 0.05)
            return system.instanceBuffer.contents()
                .bindMemory(to: WPEParticleInstance.self, capacity: 1)[0].positionAndSize.w
        }
        #expect(abs(try makeSized(blend: .additive) - 1000) < 1)      // capped to scene height
        #expect(try makeSized(blend: .translucent) > 4000)            // uncapped (≈5000)
    }

    @Test("additive sprite cap also applies after sizechange growth")
    func additiveSpriteSizeCapAppliesAfterSizeChange() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 1,
            rate: 1000, startDelay: 0,
            lifetimeMin: 100, lifetimeMax: 100,
            sizeMin: 50, sizeMax: 50,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: 0, dispersalMax: 0,
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0,
            sizeChange: WPEParticleSizeChange(startTime: 0, endTime: 1, startValue: 2, endValue: 2)
        )
        // object scale 100 → 5000px at spawn (capped to 1000), then sizechange ×2.
        let transform = WPEParticleSceneTransform(
            sceneSize: SIMD2(1000, 1000), objectOrigin: SIMD3(500, 500, 0),
            objectScale: SIMD3(100, 100, 1), objectAngleZ: 0
        )
        let system = try #require(WPEParticleSystem(
            definition: def, device: device, blendMode: .additive, sceneTransform: transform))
        system.tick(now: 0); system.tick(now: 0.05)
        let w = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)[0].positionAndSize.w
        #expect(abs(w - 1000) < 1)   // final size still capped despite ×2 sizechange
    }

    @Test("Parser captures sizerandom exponent; spawn biases size toward min")
    func sizeRandomExponentBiasesTowardMin() throws {
        let json = #"""
        {
            "maxcount": 200, "material": "materials/particle/leaves5_1.json",
            "emitter": [{"name": "sphererandom", "rate": 1000}],
            "initializer": [{"name": "sizerandom", "min": 40, "max": 80, "exponent": 2}]
        }
        """#
        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
        #expect(def.sizeExponent == 2)
        // exp 2 → mean ≈ min + (max-min)/3 = 53.3 (vs uniform 60). Confirm the
        // written sizes average below the uniform midpoint.
        let device = try #require(MTLCreateSystemDefaultDevice())
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        for step in 0...40 { system.tick(now: Double(step) * 0.05) }
        let n = system.liveInstanceCount
        let ptr = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: n)
        let mean = (0..<n).map { ptr[$0].positionAndSize.w }.reduce(0, +) / Float(max(1, n))
        #expect(n > 30)
        #expect(mean < 58)   // below the uniform midpoint (60) from the exp-2 bias
        #expect(mean > 40)
    }

    @Test("Parser captures instantaneous burst from a verbatim WPE emitter (scene 3460973721)")
    func parserCapturesInstantaneousBurst() throws {
        // Emitter copied verbatim from scene.pkg 3460973721 (野火): a burst of 50
        // seeds the fire, then a continuous 15/s sustains it.
        let json = #"""
        {
            "maxcount": 200,
            "emitter": [{"directions": "1 0.5 0", "distancemax": 1024, "distancemin": 0,
                         "duration": 0, "id": 7, "instantaneous": 50, "name": "sphererandom",
                         "origin": "0 -0.5 0", "rate": 15, "speedmax": 5}],
            "operator": []
        }
        """#
        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
        #expect(def.instantaneousCount == 50)
        #expect(def.rate == 15)
    }

    @Test("instantaneous burst spawns exactly N particles once, even with rate 0")
    func instantaneousBurstSpawnsOnceWithZeroRate() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 100,
            rate: 0, instantaneousCount: 5, startDelay: 0,
            lifetimeMin: 100, lifetimeMax: 100,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: 0, dispersalMax: 0,
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        system.tick(now: 0)
        #expect(system.liveInstanceCount == 5)   // burst fired on the first tick
        // rate 0 + once-only burst → count stays put across many ticks.
        for step in 1...20 { system.tick(now: Double(step) * 0.1) }
        #expect(system.liveInstanceCount == 5)
    }

    @Test("instantaneous burst seeds population immediately alongside continuous rate")
    func instantaneousBurstSeedsWithContinuousRate() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 200,
            rate: 10, instantaneousCount: 30, startDelay: 0,
            lifetimeMin: 100, lifetimeMax: 100,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: 0, dispersalMax: 0,
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        // First tick has dt 0 (rate adds nothing yet) → only the burst shows,
        // proving the population is seeded at once instead of ramping from 0.
        system.tick(now: 0)
        #expect(system.liveInstanceCount == 30)
    }

    @Test("event-follow instantaneous burst waits for a live parent injection")
    func eventFollowInstantaneousBurstWaitsForParentInjection() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 10,
            rate: 0, instantaneousCount: 4, startDelay: 0,
            lifetimeMin: 100, lifetimeMax: 100,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: 0, dispersalMax: 0,
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0
        )
        let child = try #require(WPEParticleSystem(definition: def, device: device))
        child.requiresFollowParent = true

        // No live parent yet → the burst must NOT be consumed.
        child.tick(now: 0)
        #expect(child.liveInstanceCount == 0)

        // Parent appears → the burst fires (retried), at the injected position.
        let parentPosition = SIMD3<Float>(25, -10, 0)
        child.injectedControlPoints[child.followControlPointID] = parentPosition
        child.tick(now: 0.05)
        #expect(child.liveInstanceCount == 4)
        let first = child.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 4)[0]
        #expect(abs(first.positionAndSize.x - parentPosition.x) < 1)
        #expect(abs(first.positionAndSize.y - parentPosition.y) < 1)
    }

    @Test("instantaneous burst is capped by maxCount")
    func instantaneousBurstCappedByMaxCount() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 3,
            rate: 0, instantaneousCount: 10, startDelay: 0,
            lifetimeMin: 100, lifetimeMax: 100,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: 0, dispersalMax: 0,
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        system.tick(now: 0)
        #expect(system.liveInstanceCount == 3)   // burst of 10 capped to capacity
    }

    @Test("instance override count scales the instantaneous burst")
    func instanceOverrideScalesInstantaneousBurst() {
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 100,
            rate: 0, instantaneousCount: 10, startDelay: 0,
            lifetimeMin: 1, lifetimeMax: 1,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: 0, dispersalMax: 0,
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0
        )
        let scaled = def.applying(instanceOverride: WPESceneParticleInstanceOverride(count: 2))
        #expect(scaled.instantaneousCount == 20)
    }

    @Test("material overbright parse: numeric, absent default, bool guard, negative clamp")
    func materialOverbrightParse() {
        // Numeric value (real WPE case, e.g. 1.51).
        #expect(abs(WPEMetalSceneRenderer.overbright(
            fromConstants: ["ui_editor_properties_overbright": 1.51]) - 1.51) < 0.0001)
        // Absent / nil → 1.0 (no change).
        #expect(WPEMetalSceneRenderer.overbright(fromConstants: [:]) == 1.0)
        #expect(WPEMetalSceneRenderer.overbright(fromConstants: nil) == 1.0)
        // A JSON boolean must NOT be read as 0 (would black the particle out).
        #expect(WPEMetalSceneRenderer.overbright(
            fromConstants: ["ui_editor_properties_overbright": false]) == 1.0)
        // Negative clamps to 0.
        #expect(WPEMetalSceneRenderer.overbright(
            fromConstants: ["ui_editor_properties_overbright": -3]) == 0)
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

    // MARK: - Rope renderer (scene 3351072238)

    @Test("Parser flags renderer:[{name:rope}] as a rope; sprite/empty stay false")
    func parserDetectsRopeRenderer() throws {
        func def(_ renderer: String) -> WPEParticleDefinition? {
            let json = """
            {"maxcount": 8, "renderer": \(renderer),
             "emitter":[{"name":"sphererandom","rate":32}],
             "material":"materials/presets/trail_1.json"}
            """
            return WPEParticleDefinitionParser.parse(data: Data(json.utf8))
        }
        #expect(try #require(def("[{\"name\":\"rope\"}]")).isRope == true)
        #expect(try #require(def("[{\"name\":\"sprite\"}]")).isRope == false)
        #expect(try #require(def("[]")).isRope == false)
    }

    @Test("Rope builds a 2-vertex-per-knot ribbon with finite width")
    func ropeBuildsRibbonStrip() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        // Velocity spreads particles along +Y over time, so older knots sit higher
        // → an ordered, non-degenerate vertical ribbon.
        let def = WPEParticleDefinition(
            materialRelativePath: nil,
            isRope: true,
            maxCount: 32,
            rate: 64,
            startDelay: 0,
            lifetimeMin: 100, lifetimeMax: 100,
            sizeMin: 10, sizeMax: 10,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: 0, dispersalMax: 0,
            velocityMin: SIMD3(0, 200, 0), velocityMax: SIMD3(0, 200, 0),
            colorMin: SIMD3(85, 153, 255), colorMax: SIMD3(85, 153, 255),
            fadeInSeconds: 0
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        #expect(system.isRope)
        #expect(system.ropeVertexBuffer != nil)
        system.tick(now: 0)
        for step in 1...20 { system.tick(now: Double(step) * 0.05) }

        let alive = system.liveInstanceCount
        #expect(alive >= 2)
        #expect(system.ropeVertexCount == alive * 2)

        let verts = try #require(system.ropeVertexBuffer).contents()
            .bindMemory(to: WPEParticleRopeVertex.self, capacity: system.ropeVertexCount)
        var minX = Float.greatestFiniteMagnitude, maxX = -Float.greatestFiniteMagnitude
        var minY = Float.greatestFiniteMagnitude, maxY = -Float.greatestFiniteMagnitude
        for i in 0..<system.ropeVertexCount {
            minX = min(minX, verts[i].positionUV.x); maxX = max(maxX, verts[i].positionUV.x)
            minY = min(minY, verts[i].positionUV.y); maxY = max(maxY, verts[i].positionUV.y)
        }
        // Spine sits at x=0; each knot's edges straddle ±half-size, so a vertical
        // trail is ≈ size (10) wide in X — real ribbon area, not a collapsed spike.
        #expect(abs((maxX - minX) - 10) < 0.5)
        // The +Y velocity spreads knots along the trail: a genuine length, not a pile.
        #expect((maxY - minY) > 50)
        // v runs 0→1 head→tail along the rope.
        #expect(abs(verts[0].positionUV.w - 0) < 0.001)
        #expect(abs(verts[system.ropeVertexCount - 1].positionUV.w - 1) < 0.001)
        // The blue colorrandom (85,153,255)/255 survives onto the ribbon — NOT white.
        #expect(verts[0].color.x < 0.5 && verts[0].color.z > 0.9)
    }

    @Test("Stationary rope collapses to zero-area strip (no white blob)")
    func ropeStationaryDrawsNoArea() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        // Every particle spawns at one point and never moves (the trail_1 case at
        // rest): the ribbon must collapse to a colinear strip with no fill area.
        let def = WPEParticleDefinition(
            materialRelativePath: nil,
            isRope: true,
            maxCount: 32,
            rate: 64,
            startDelay: 0,
            lifetimeMin: 100, lifetimeMax: 100,
            sizeMin: 10, sizeMax: 10,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: 0, dispersalMax: 0,
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(85, 153, 255), colorMax: SIMD3(85, 153, 255),
            fadeInSeconds: 0
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        system.tick(now: 0)
        for step in 1...10 { system.tick(now: Double(step) * 0.05) }
        guard system.ropeVertexCount >= 4 else { return }

        let verts = try #require(system.ropeVertexBuffer).contents()
            .bindMemory(to: WPEParticleRopeVertex.self, capacity: system.ropeVertexCount)
        var minX = Float.greatestFiniteMagnitude, maxX = -Float.greatestFiniteMagnitude
        var minY = Float.greatestFiniteMagnitude, maxY = -Float.greatestFiniteMagnitude
        for i in 0..<system.ropeVertexCount {
            minX = min(minX, verts[i].positionUV.x); maxX = max(maxX, verts[i].positionUV.x)
            minY = min(minY, verts[i].positionUV.y); maxY = max(maxY, verts[i].positionUV.y)
        }
        // One axis has zero extent ⇒ the strip is colinear ⇒ zero rasterized area.
        #expect(min(maxX - minX, maxY - minY) < 0.001)
    }

    // MARK: - boxrandom emitter (scene 3351072238 rain pile)

    @Test("boxrandom parses vector distancemax and scatters across the box")
    func boxEmitterScattersAcrossExtent() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let json = """
        {"maxcount": 200, "renderer":[{"name":"sprite"}],
         "emitter":[{"name":"boxrandom","rate":400,"distancemax":"1200 1000 0"}],
         "initializer":[{"name":"lifetimerandom","min":100,"max":100}]}
        """
        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
        #expect(def.emitterShape == .box)
        #expect(def.dispersalMax == SIMD3<Double>(1200, 1000, 0))

        let system = try #require(WPEParticleSystem(
            definition: def, device: device, sceneTransform: centeredParticleTransform))
        system.tick(now: 0)
        for step in 1...8 { system.tick(now: Double(step) * 0.05) }
        let alive = system.liveInstanceCount
        #expect(alive > 20)

        let p = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: alive)
        var minX = Float.greatestFiniteMagnitude, maxX = -Float.greatestFiniteMagnitude
        var minY = Float.greatestFiniteMagnitude, maxY = -Float.greatestFiniteMagnitude
        for i in 0..<alive {
            minX = min(minX, p[i].positionAndSize.x); maxX = max(maxX, p[i].positionAndSize.x)
            minY = min(minY, p[i].positionAndSize.y); maxY = max(maxY, p[i].positionAndSize.y)
        }
        // Scattered across the box (≈ ±1200 × ±1000), NOT piled at the origin —
        // the regression that stacked 500 rain halos into a white blob.
        #expect((maxX - minX) > 800)
        #expect((maxY - minY) > 600)
    }

    @Test("Scalar sphererandom emitter still parses as a sphere")
    func sphereEmitterStaysScalar() throws {
        let json = """
        {"maxcount": 20, "emitter":[{"name":"sphererandom","rate":2,"distancemax":512}]}
        """
        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
        #expect(def.emitterShape == .sphere)
        #expect(def.dispersalMax == SIMD3<Double>(512, 512, 512))
    }
}
