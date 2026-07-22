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

        #expect(def.childReferences.map(\.relativePath) == [
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
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(750, 750, 750),
            velocityMin: SIMD3(-200, -100, 0), velocityMax: SIMD3(-300, -15, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 236, 0),
            fadeInSeconds: 0.1,
            turbulentVelocityInit: WPEParticleTurbulentVelocityInit(speedMin: 35, speedMax: 100)
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
        #expect(abs((scaled.turbulentVelocityInit?.speedMax ?? 0) - 132) < 0.0001)
        #expect(abs(scaled.alphaMin - 0.03) < 0.0001)
        #expect(abs(scaled.alphaMax - 0.03) < 0.0001)
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
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
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
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
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
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
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
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
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
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
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
                {"name": "oscillatealpha", "frequencymin": 0.5, "frequencymax": 0.5, "scalemin": 0.6, "phasemin": 0.25},
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
        #expect(oscillateAlpha.frequencyMin == 0.5)
        #expect(oscillateAlpha.frequencyMax == 0.5)
        #expect(oscillateAlpha.scaleMin == 0.6)
        #expect(oscillateAlpha.scaleMax == 1)
        #expect(oscillateAlpha.phaseMin == 0.25)
        #expect(def.gravity.y == -50)
        #expect(def.drag == 0.5)
        #expect(def.angularForceZ == 3)
        #expect(def.angularDrag == 0.2)
    }

    @Test("Bare random initializers seed engine defaults, not zero")
    func bareRandomInitializersTakeEngineDefaults() throws {
        let json = #"""
        {
            "maxcount": 10,
            "emitter": [{"rate": 5}],
            "initializer": [
                {"name": "velocityrandom"},
                {"name": "angularvelocityrandom"},
                {"name": "rotationrandom"}
            ]
        }
        """#
        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
        #expect(def.velocityMin == SIMD3<Double>(-32, -32, 0))
        #expect(def.velocityMax == SIMD3<Double>(32, 32, 0))
        #expect(def.angularVelocityMin.z == -5)
        #expect(def.angularVelocityMax.z == 5)
        #expect(def.rotationMax.z == 2 * .pi)
        #expect(def.rotationMax.x == 0)
        #expect(def.rotationMax.y == 0)
    }

    @Test("Only a literal rope takes the ribbon path; ropetrail/spritetrail do not")
    func trailRendererTaxonomy() throws {
        func def(_ renderer: String, extra: String = "") throws -> WPEParticleDefinition {
            let json = #"""
            {
                "maxcount": 100,
                "material": "materials/m.json",
                "initializer": [{"name": "lifetimerandom", "min": 4, "max": 4}],
                "renderer": [{"name": "\#(renderer)"\#(extra)}]
            }
            """#
            return try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
        }

        let ropetrail = try def("ropetrail", extra: #", "length": 3"#)
        #expect(!ropetrail.isRope, "ropetrail must not join the whole chain")
        #expect(ropetrail.trailRenderer?.length == 3)
        #expect(ropetrail.trailRenderer?.kind == .rope)

        let spritetrail = try def("spritetrail", extra: #", "length": 5, "maxlength": 40"#)
        #expect(!spritetrail.isRope)
        #expect(spritetrail.trailRenderer?.length == 5)
        #expect(spritetrail.trailRenderer?.maxLength == 40)
        #expect(spritetrail.trailRenderer?.kind == .sprite)

        let defaulted = try #require(ropetrail.trailRenderer)
        #expect(defaulted.maxLength == 10, "absent maxlength is 10, never unbounded")
        #expect(defaulted.subdivision == 3)
        let bare = try #require(try def("spritetrail").trailRenderer)
        #expect(bare.length == 0.05)
        #expect(bare.maxLength == 10)

        let rope = try def("rope")
        #expect(rope.isRope)
        #expect(rope.trailRenderer == nil)

        let sprite = try def("sprite")
        #expect(!sprite.isRope)
        #expect(sprite.trailRenderer == nil)
    }

    @Test("Parser reads emitter sign and normalizes each axis to -1/0/1")
    func parserReadsEmitterSign() throws {
        let json = #"""
        {
            "maxcount": 10,
            "emitter": [{
                "name": "sphererandom", "rate": 1,
                "distancemin": 10, "distancemax": 100,
                "sign": "0 -0.5 3"
            }]
        }
        """#
        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
        #expect(def.sign == SIMD3<Double>(0, -1, 1))
    }

    @Test("Emitter sign defaults to zero (no axis forced) when absent")
    func parserDefaultsSignToZero() throws {
        let json = #"""
        {"maxcount": 10, "emitter": [{"name": "sphererandom", "rate": 1}]}
        """#
        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
        #expect(def.sign == SIMD3<Double>(0, 0, 0))
    }

    @Test("applyEmitterSign forces a nonzero axis to abs(value) * sign, passes zero axes through")
    func applyEmitterSignForcesOnlyNonzeroAxes() {
        let p = SIMD3<Double>(-2, 3, -5)
        let zOnly = WPEParticleSystem.applyEmitterSign(p, sign: SIMD3<Double>(0, 0, 1))
        #expect(zOnly == SIMD3<Double>(-2, 3, 5))

        let allForced = WPEParticleSystem.applyEmitterSign(p, sign: SIMD3<Double>(1, -1, 1))
        #expect(allForced == SIMD3<Double>(2, -3, 5))

        let untouched = WPEParticleSystem.applyEmitterSign(p, sign: SIMD3<Double>(0, 0, 0))
        #expect(untouched == p)
    }

    #if !LITE_BUILD && DEBUG
    @Test("Sphere emitter sign=\"0 0 1\" keeps every spawned particle at non-negative depth (scene 3462491575 snowperspective dust)")
    func sphereEmitterSignKeepsParticlesInFrontOfCamera() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let json = #"""
        {
            "maxcount": 400, "flags": 4,
            "emitter": [{
                "name": "sphererandom", "rate": 100000,
                "distancemin": 10, "distancemax": 500,
                "directions": "1 1 1", "sign": "0 0 1"
            }]
        }
        """#
        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
        #expect(def.sign == SIMD3<Double>(0, 0, 1))
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        for step in 1...4 { system.tick(now: Double(step) * 0.05) }
        try #require(system.liveInstanceCount >= 32)

        var sampled = 0
        for rawLine in system.particleStateDumpText().split(separator: "\n") {
            let line = String(rawLine)
            guard let open = line.range(of: "pos=("),
                  let close = line.range(of: ")", range: open.upperBound..<line.endIndex)
            else { continue }
            let parts = line[open.upperBound..<close.lowerBound].split(separator: ",")
            guard parts.count == 3, let z = Double(parts[2]) else { continue }
            #expect(z >= 0, "sign=\"0 0 1\" must force every particle's depth non-negative (z=\(z))")
            sampled += 1
        }
        #expect(sampled >= 32)
    }

    @Test("Sphere radius sampling is volume-uniform: seeded average lands well past the naive-uniform midpoint")
    func sphereRadiusSamplingIsVolumeUniformUnderSeed() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let json = #"""
        {
            "maxcount": 300,
            "emitter": [{
                "name": "sphererandom", "rate": 100000,
                "distancemin": 0, "distancemax": 100,
                "directions": "0 0 1", "sign": "0 0 1"
            }]
        }
        """#
        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
        let system = try #require(WPEParticleSystem(definition: def, device: device, seed: 0x00A5_11CE))
        system.tick(now: 0)
        system.tick(now: 0.01)
        try #require(system.liveInstanceCount >= 100)

        var total = 0.0
        var count = 0
        for rawLine in system.particleStateDumpText().split(separator: "\n") {
            let line = String(rawLine)
            guard let open = line.range(of: "pos=("),
                  let close = line.range(of: ")", range: open.upperBound..<line.endIndex)
            else { continue }
            let parts = line[open.upperBound..<close.lowerBound].split(separator: ",")
            guard parts.count == 3, let z = Double(parts[2]) else { continue }
            #expect(z >= -0.01 && z <= 100.01)
            total += z
            count += 1
        }
        try #require(count >= 100)
        let average = total / Double(count)
        #expect(average > 60, "volumetric sampling should skew well past the naive-uniform mean of 50 (got \(average))")
    }
    #endif

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
        let oscillate = WPEParticleOscillateAlpha(
            frequencyMin: 1, frequencyMax: 1, scaleMin: 0, scaleMax: 2, phaseMin: 0, phaseMax: 0
        )
        for age in stride(from: 0.0, through: 1.0, by: 0.05) {
            let factor = oscillate.factor(age: age, frequency: 1, phase: 0)
            #expect(factor >= 0)
            #expect(factor <= 1)
        }
    }

    @Test("oscillatealpha honours a bare frequencymax and sweeps scalemin…scalemax")
    func oscillateAlphaBareFrequencyMaxTwinkles() throws {
        let json = #"""
        {
            "maxcount": 10,
            "material": "materials/m.json",
            "initializer": [{"name": "lifetimerandom", "min": 4, "max": 8}],
            "operator": [{"name": "oscillatealpha", "frequencymax": 3, "scalemin": 0.2}]
        }
        """#
        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
        let osc = try #require(def.oscillateAlpha)
        #expect(osc.frequencyMin == 0)
        #expect(osc.frequencyMax == 3)
        #expect(osc.scaleMin == 0.2)
        #expect(osc.scaleMax == 1)

        #expect(abs(osc.factor(age: 0, frequency: 3, phase: 0) - 1.0) < 0.0001)
        #expect(abs(osc.factor(age: .pi / 3, frequency: 3, phase: 0) - 0.2) < 0.0001)
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
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0.01,
            angularVelocityMin: SIMD3(0, 0, 1.5),
            angularVelocityMax: SIMD3(0, 0, 1.5)
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        system.tick(now: 0)
        for step in 1...10 {
            system.tick(now: Double(step) * 0.05)
        }
        let pointer = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 4)
        #expect(abs(pointer[0].rotationAndLife.x - 0.675) < 0.1)
    }

    @Test("A seeded RNG makes particle spawn jitter reproducible run-to-run (oracle determinism)")
    func seededParticleRNGIsDeterministic() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        func makeDef() -> WPEParticleDefinition {
            WPEParticleDefinition(
                materialRelativePath: nil, maxCount: 64,
                rate: 2000, startDelay: 0,
                lifetimeMin: 2, lifetimeMax: 8,
                sizeMin: 2, sizeMax: 12,
                originOffset: SIMD3(0, 0, 0),
                dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(200, 200, 200),
                velocityMin: SIMD3(-50, -50, 0), velocityMax: SIMD3(50, 50, 0),
                colorMin: SIMD3(0, 0, 0), colorMax: SIMD3(255, 255, 255),
                fadeInSeconds: 0.01
            )
        }
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
        #expect(a == b)
        #expect(a != c)
    }

    @Test("deterministicSeed is stable per input and unique across scene/object/order")
    func deterministicSeedIsStableAndUnique() {
        let base = WPEParticleSystem.deterministicSeed(workshopID: "123456", objectID: "42", sortIndex: 3)
        #expect(base == WPEParticleSystem.deterministicSeed(workshopID: "123456", objectID: "42", sortIndex: 3))
        #expect(base != WPEParticleSystem.deterministicSeed(workshopID: "123457", objectID: "42", sortIndex: 3))
        #expect(base != WPEParticleSystem.deterministicSeed(workshopID: "123456", objectID: "43", sortIndex: 3))
        #expect(base != WPEParticleSystem.deterministicSeed(workshopID: "123456", objectID: "42", sortIndex: 4))
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
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
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
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0,
            alphaMin: 0.15, alphaMax: 0.15
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
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
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0.0,
            fadeOutSeconds: 0.5
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        for step in 1...4 {
            system.tick(now: Double(step) * 0.05)
        }
        let early = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)[0].color.w
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
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
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
        let tvi = try #require(def.turbulentVelocityInit)
        #expect(tvi.speedMin == 35)
        #expect(tvi.speedMax == 100)
        #expect(tvi.scale == 0.5)
        #expect(tvi.offset == 3)
        #expect(tvi.timescale == 0.02)
        #expect(tvi.phaseMax > 6.2)
        #expect(def.turbulence == nil)
    }

    @Test("Parser fills engine defaults for a sparse turbulent-velocity initializer")
    func parserTurbulentVelocityDefaults() throws {
        let json = #"""
        {
            "maxcount": 10,
            "emitter": [{"rate": 5}],
            "initializer": [{"name": "turbulentvelocityrandom", "scale": 0.3}]
        }
        """#
        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
        let tvi = try #require(def.turbulentVelocityInit)
        #expect(tvi.scale == 0.3)
        #expect(tvi.speedMin == 100)
        #expect(tvi.speedMax == 250)
        #expect(tvi.timescale == 1)
        #expect(tvi.forward == SIMD3<Double>(0, 1, 0))
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

        let turb = try #require(def.turbulence)
        #expect(turb.speedMin == 750)
        #expect(turb.speedMax == 900)
        #expect(turb.mask.x == 0.5)
        #expect(turb.mask.y == 4)
        #expect(turb.mask.z == 0)
        #expect(def.turbulentVelocityInit == nil)
    }

    @Test("Initializer and operator turbulence parse independently without clobbering")
    func parserTurbulenceInitAndOperatorIndependent() throws {
        let json = #"""
        {
            "maxcount": 10,
            "emitter": [{"rate": 5}],
            "initializer": [{"name": "turbulentvelocityrandom", "offset": -0.5, "scale": 0.1}],
            "operator": [
                {"name": "movement"},
                {"name": "turbulence", "speedmin": 250, "speedmax": 1000,
                 "timescale": 50, "mask": "1 0.4 0"}
            ]
        }
        """#
        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
        let tvi = try #require(def.turbulentVelocityInit)
        let turb = try #require(def.turbulence)
        #expect(tvi.offset == -0.5)
        #expect(tvi.scale == 0.1)
        #expect(tvi.speedMin == 100)
        #expect(tvi.speedMax == 250)
        #expect(turb.speedMin == 250)
        #expect(turb.speedMax == 1000)
        #expect(turb.timescale == 50)
        #expect(turb.mask.y == 0.4)
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
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
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
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
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
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0,
            turbulence: WPEParticleTurbulenceOperator(
                speedMin: 50, speedMax: 50, scale: 0.1, timescale: 1,
                phaseMin: 1, phaseMax: 1, mask: SIMD3<Double>(1, 1, 0)
            )
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
        #expect(seeded.turbulentVelocityInit != nil)
        let plain = try #require(WPEParticleDefinitionParser.parse(data: Data(#"""
        {"maxcount": 8, "emitter": [{"name": "boxrandom", "rate": 10}]}
        """#.utf8)))
        #expect(plain.turbulentVelocityInit == nil)
    }

    @Test("turbulentvelocityrandom seeds a travelling velocity (embers leave the box)")
    func turbulentVelocityInitSeedsMotion() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        func makeDef(seed: Bool) -> WPEParticleDefinition {
            WPEParticleDefinition(
                materialRelativePath: nil, maxCount: 32,
                rate: 10000, startDelay: 0,
                lifetimeMin: 10, lifetimeMax: 10,
                sizeMin: 1, sizeMax: 1,
                originOffset: SIMD3(0, 0, 0),
                dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
                velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
                colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
                fadeInSeconds: 0,
                turbulentVelocityInit: seed ? WPEParticleTurbulentVelocityInit() : nil
            )
        }
        func maxTravel(_ def: WPEParticleDefinition) throws -> Float {
            let system = try #require(WPEParticleSystem(definition: def, device: device, seed: 0xEE1B_0A75))
            let buf = system.instanceBuffer.contents()
                .bindMemory(to: WPEParticleInstance.self, capacity: 32)
            system.tick(now: 0)
            system.tick(now: 0.1)
            let n = system.liveInstanceCount
            try #require(n >= 8)
            let spawned = (0..<n).map { SIMD2(buf[$0].positionAndSize.x, buf[$0].positionAndSize.y) }
            for step in 2...6 { system.tick(now: Double(step) * 0.1) }
            var travel: Float = 0
            for i in 0..<n {
                let p = SIMD2(buf[i].positionAndSize.x, buf[i].positionAndSize.y)
                travel = Swift.max(travel, simd_length(p - spawned[i]))
            }
            return travel
        }
        let stuck = try maxTravel(makeDef(seed: false))
        let travelled = try maxTravel(makeDef(seed: true))
        #expect(stuck < 0.01, "no seed → sparks never leave the spawn point (travel \(stuck))")
        #expect(travelled > 40, "seed → sparks travel away from spawn (travel \(travelled))")
    }

    @Test("turbulentvelocityrandom aims ONE system-wide gust, not a per-particle scatter")
    func turbulentVelocityInitIsOneGust() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let alignment = try Self.meanGustAlignment(device: device, timescale: 1)
        #expect(alignment > 0.7, "particles must share one gust direction (alignment \(alignment))")
    }

    @Test("turbulentvelocityrandom timescale sets how fast the gust turns")
    func turbulentVelocityInitTimescaleDrivesWalk() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fast = try Self.meanGustAlignment(device: device, timescale: 0.01)
        let slow = try Self.meanGustAlignment(device: device, timescale: 100)
        #expect(fast < 0.6, "a fast field must re-aim the gust between spawns (\(fast))")
        #expect(slow > 0.9, "a slow field must hold one gust (\(slow))")
    }

    private static func meanGustAlignment(device: MTLDevice, timescale: Double) throws -> Float {
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 32,
            rate: 100_000, startDelay: 0,
            lifetimeMin: 10, lifetimeMax: 10,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0,
            turbulentVelocityInit: WPEParticleTurbulentVelocityInit(
                speedMin: 100, speedMax: 250, scale: 2, timescale: timescale, offset: 0
            )
        )
        var total: Float = 0
        let seeds: [UInt64] = [0x6057_1234, 0x7A1E_5CA1, 0xBEEF_0001, 0x1EAF_FA11, 0xC0FF_EE42]
        for seed in seeds {
            let system = try #require(WPEParticleSystem(definition: def, device: device, seed: seed))
            let dirs = try seededSpawnDirections(system, capacity: 32)
            try #require(dirs.count >= 24)
            let mean = simd_normalize(dirs.reduce(SIMD2<Float>.zero, +) / Float(dirs.count))
            total += dirs.map { simd_dot($0, mean) }.reduce(0, +) / Float(dirs.count)
        }
        return total / Float(seeds.count)
    }

    private static func seededSpawnDirections(
        _ system: WPEParticleSystem, capacity: Int
    ) throws -> [SIMD2<Float>] {
        let buf = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: capacity)
        system.tick(now: 0)
        system.tick(now: 0.1)
        let n = system.liveInstanceCount
        let spawned = (0..<n).map { SIMD2(buf[$0].positionAndSize.x, buf[$0].positionAndSize.y) }
        system.tick(now: 0.2)
        return (0..<n).compactMap { i in
            let delta = SIMD2(buf[i].positionAndSize.x, buf[i].positionAndSize.y) - spawned[i]
            return simd_length(delta) > 1e-4 ? simd_normalize(delta) : nil
        }
    }

    @Test("turbulentvelocityrandom offset≈3 drives the stream DOWNWARD (leaves fall, not rise)")
    func turbulentVelocityOffsetFallsDown() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 200,
            rate: 20000, startDelay: 0,
            lifetimeMin: 10, lifetimeMax: 10,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0,
            turbulentVelocityInit: WPEParticleTurbulentVelocityInit(
                speedMin: 35, speedMax: 100, scale: 0.5, offset: 3
            )
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device, seed: 0x5EED_1EAF))
        func meanY() -> Float {
            let n = system.liveInstanceCount
            let buf = system.instanceBuffer.contents()
                .bindMemory(to: WPEParticleInstance.self, capacity: 200)
            var sum: Float = 0
            for i in 0..<n { sum += buf[i].positionAndSize.y }
            return sum / Float(n)
        }
        system.tick(now: 0)
        system.tick(now: 0.01)
        try #require(system.liveInstanceCount >= 32)
        let spawnY = meanY()
        system.tick(now: 0.11)
        let movedY = meanY()
        let displacement = movedY - spawnY
        #expect(
            displacement < -1,
            "offset=3 must seed a DOWNWARD stream; spawnY=\(spawnY) movedY=\(movedY) Δ=\(displacement)"
        )
    }

    @Test("An initializer-only system gets no per-frame turbulence sway (leaves drift straight)")
    func initializerOnlyHasNoOperatorSway() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 4,
            rate: 1000, startDelay: 0,
            lifetimeMin: 10, lifetimeMax: 10,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, -80, 0), velocityMax: SIMD3(0, -80, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0,
            turbulentVelocityInit: WPEParticleTurbulentVelocityInit(
                speedMin: 0, speedMax: 0, scale: 0
            )
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device, seed: 1))
        func y0() -> Float {
            system.instanceBuffer.contents()
                .bindMemory(to: WPEParticleInstance.self, capacity: 4)[0].positionAndSize.y
        }
        system.tick(now: 0)
        system.tick(now: 0.1)
        system.tick(now: 0.2)
        let y1 = y0()
        system.tick(now: 0.3)
        let y2 = y0()
        system.tick(now: 0.4)
        let y3 = y0()
        #expect(y1 < 0, "particle should be falling, y1=\(y1)")
        #expect(
            abs((y3 - y2) - (y2 - y1)) < 0.001,
            "expected constant-velocity motion (equal increments), y1=\(y1) y2=\(y2) y3=\(y3)"
        )
    }

    @Test("Turbulence operator path is reproducible under a fixed seed")
    func turbulenceOperatorIsReproducibleUnderSeed() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        func makeDef() -> WPEParticleDefinition {
            WPEParticleDefinition(
                materialRelativePath: nil, maxCount: 64,
                rate: 3000, startDelay: 0,
                lifetimeMin: 4, lifetimeMax: 8,
                sizeMin: 2, sizeMax: 6,
                originOffset: SIMD3(0, 0, 0),
                dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(50, 50, 0),
                velocityMin: SIMD3(-20, -20, 0), velocityMax: SIMD3(20, 20, 0),
                colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
                fadeInSeconds: 0.01,
                drag: 1.5,
                turbulentVelocityInit: WPEParticleTurbulentVelocityInit(scale: 0.1, offset: -0.5),
                turbulence: WPEParticleTurbulenceOperator(
                    speedMin: 250, speedMax: 1000, scale: 0.002, timescale: 50,
                    phaseMin: 5, phaseMax: 50, mask: SIMD3<Double>(1, 0.4, 0)
                )
            )
        }
        func snapshot(seed: UInt64) throws -> Data {
            let system = try #require(WPEParticleSystem(definition: makeDef(), device: device, seed: seed))
            system.tick(now: 0)
            for step in 1...20 { system.tick(now: Double(step) * 0.05) }
            let bytes = system.liveInstanceCount * MemoryLayout<WPEParticleInstance>.stride
            #expect(bytes > 0)
            return Data(bytes: system.instanceBuffer.contents(), count: bytes)
        }
        #expect(try snapshot(seed: 0xCAFE_F00D) == snapshot(seed: 0xCAFE_F00D))
        #expect(try snapshot(seed: 0xCAFE_F00D) != snapshot(seed: 0x0BAD_BEEF))
    }

    @Test("alphafade timings are lifetime fractions, not seconds")
    func fadeTimingsAreLifetimeFractions() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 1,
            rate: 1000, startDelay: 0,
            lifetimeMin: 10, lifetimeMax: 10,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0.1,
            fadeOutSeconds: 0.0
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        system.tick(now: 0)
        system.tick(now: 0.05)
        let mid = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)[0].color.w
        #expect(mid < 0.15)
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
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0.05
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
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
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
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
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(512, 512, 512),
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
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
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
        #expect(def.emitterTracksPointer == false)
        #expect(def.controlPoints.first(where: { $0.id == 1 })?.pointerLocked == true)
        let attractor = try #require(def.attractors.first)
        #expect(def.attractors.count == 1)
        #expect(attractor.controlPointID == 1)
        #expect(attractor.scale == -5000)
        #expect(attractor.threshold == 64)
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
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
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
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0.05,
            controlPoints: [WPEParticleControlPoint(id: 0, offset: SIMD3(0, 0, 0), pointerLocked: true)]
        )
        let transform = WPEParticleSceneTransform(
            sceneSize: SIMD2(1000, 1000),
            objectOrigin: SIMD3(500, 500, 0),
            objectScale: SIMD3(1, 1, 1),
            objectAngleZ: 0
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device, sceneTransform: transform))
        system.pointerCentered = SIMD2(200, 150)
        system.tick(now: 0)
        system.tick(now: 0.02)
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
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
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
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
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
        #expect(early.y > 0.8)
        #expect(late.x > 0.8)
        #expect(late.y < late.x)
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
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
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
        system.tick(now: 0)
        for step in 1...160 {
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
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
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
        #expect(abs(written.x - 0.251) < 0.02)
    }

    @Test("colorchange does NOT recolour a particle with no colour initializer (white r8 smoke stays white)")
    func colorChangeSkippedWithoutColorInitializer() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 1,
            rate: 1000, startDelay: 0,
            lifetimeMin: 10, lifetimeMax: 10,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0,
            colorChange: WPEParticleColorChange(
                startTime: 0, endTime: 0.6,
                startColor: SIMD3(1, 0.749, 0), endColor: SIMD3(1, 0, 0)
            )
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
        let base = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 1,
            rate: 1, startDelay: 0,
            lifetimeMin: 1, lifetimeMax: 1,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0
        )
        let override = WPESceneParticleInstanceOverride(color: SIMD3(61, 41, 69))
        let applied = base.applying(instanceOverride: override)
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
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
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
        for step in 1...160 {
            system.tick(now: Double(step) * 0.05)
            let p = pointer[0].positionAndSize
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        #expect((maxX - minX) < 5)
        #expect((maxY - minY) > 80)
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
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
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
        #expect(abs(w - 100) < 1)
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
                dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
                velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
                colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
                fadeInSeconds: 0
            )
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
        #expect(abs(try makeSized(blend: .additive) - 1000) < 1)
        #expect(try makeSized(blend: .translucent) > 4000)
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
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0,
            sizeChange: WPEParticleSizeChange(startTime: 0, endTime: 1, startValue: 2, endValue: 2)
        )
        let transform = WPEParticleSceneTransform(
            sceneSize: SIMD2(1000, 1000), objectOrigin: SIMD3(500, 500, 0),
            objectScale: SIMD3(100, 100, 1), objectAngleZ: 0
        )
        let system = try #require(WPEParticleSystem(
            definition: def, device: device, blendMode: .additive, sceneTransform: transform))
        system.tick(now: 0); system.tick(now: 0.05)
        let w = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)[0].positionAndSize.w
        #expect(abs(w - 1000) < 1)
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
        let device = try #require(MTLCreateSystemDefaultDevice())
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        for step in 0...40 { system.tick(now: Double(step) * 0.05) }
        let n = system.liveInstanceCount
        let ptr = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: n)
        let mean = (0..<n).map { ptr[$0].positionAndSize.w }.reduce(0, +) / Float(max(1, n))
        #expect(n > 30)
        #expect(mean < 58)
        #expect(mean > 40)
    }

    @Test("Parser captures instantaneous burst from a verbatim WPE emitter (scene 3460973721)")
    func parserCapturesInstantaneousBurst() throws {
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
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        system.tick(now: 0)
        #expect(system.liveInstanceCount == 5)
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
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
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
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0
        )
        let child = try #require(WPEParticleSystem(definition: def, device: device))
        child.requiresFollowParent = true

        child.tick(now: 0)
        #expect(child.liveInstanceCount == 0)

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
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0
        )
        let system = try #require(WPEParticleSystem(definition: def, device: device))
        system.tick(now: 0)
        #expect(system.liveInstanceCount == 3)
    }

    @Test("instance override count scales the instantaneous burst")
    func instanceOverrideScalesInstantaneousBurst() {
        let def = WPEParticleDefinition(
            materialRelativePath: nil, maxCount: 100,
            rate: 0, instantaneousCount: 10, startDelay: 0,
            lifetimeMin: 1, lifetimeMax: 1,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0
        )
        let scaled = def.applying(instanceOverride: WPESceneParticleInstanceOverride(count: 2))
        #expect(scaled.instantaneousCount == 20)
    }

    @Test("material overbright parse: numeric, absent default, bool guard, negative clamp")
    func materialOverbrightParse() {
        #expect(abs(WPEMetalSceneRenderer.overbright(
            fromConstants: ["ui_editor_properties_overbright": 1.51]) - 1.51) < 0.0001)
        #expect(WPEMetalSceneRenderer.overbright(fromConstants: [:]) == 1.0)
        #expect(WPEMetalSceneRenderer.overbright(fromConstants: nil) == 1.0)
        #expect(WPEMetalSceneRenderer.overbright(
            fromConstants: ["ui_editor_properties_overbright": false]) == 1.0)
        #expect(WPEMetalSceneRenderer.overbright(
            fromConstants: ["ui_editor_properties_overbright": -3]) == 0)
    }

    @Test("object brightness multiplies material overbright into the particle uniform")
    func objectBrightnessMultipliesOverbright() {
        #expect(abs(WPEMetalSceneRenderer.particleOverbright(
            material: nil, objectBrightness: 2.0) - 2.0) < 0.0001)
        #expect(abs(WPEMetalSceneRenderer.particleOverbright(
            material: 1.5, objectBrightness: 2.0) - 3.0) < 0.0001)
        #expect(WPEMetalSceneRenderer.particleOverbright(
            material: nil, objectBrightness: 1.0) == 1.0)
        #expect(WPEMetalSceneRenderer.particleOverbright(
            material: 1.0, objectBrightness: -2.0) == 0)
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
            dispersalMin: SIMD3<Double>(0, 0, 0),
            dispersalMax: SIMD3<Double>(0, 0, 0),
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
        let def = WPEParticleDefinition(
            materialRelativePath: nil,
            isRope: true,
            maxCount: 32,
            rate: 64,
            startDelay: 0,
            lifetimeMin: 100, lifetimeMax: 100,
            sizeMin: 10, sizeMax: 10,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
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
        #expect(abs((maxX - minX) - 10) < 0.5)
        #expect((maxY - minY) > 50)
        #expect(abs(verts[0].positionUV.w - 0) < 0.001)
        #expect(abs(verts[system.ropeVertexCount - 1].positionUV.w - 1) < 0.001)
        #expect(verts[0].color.x < 0.5 && verts[0].color.z > 0.9)
    }

    @Test("Stationary rope collapses to zero-area strip (no white blob)")
    func ropeStationaryDrawsNoArea() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil,
            isRope: true,
            maxCount: 32,
            rate: 64,
            startDelay: 0,
            lifetimeMin: 100, lifetimeMax: 100,
            sizeMin: 10, sizeMax: 10,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
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
