import Foundation
import LiveWallpaperProWPE
import Metal
import simd
import Testing
@testable import LiveWallpaper

struct WPEParticleCoordinateTests {

    private func makeDefinition(
        originOffset: SIMD3<Double> = SIMD3(0, 0, 0),
        velocityMin: SIMD3<Double> = SIMD3(0, 0, 0),
        velocityMax: SIMD3<Double> = SIMD3(0, 0, 0),
        directionMask: SIMD3<Double> = SIMD3(1, 1, 1)
    ) -> WPEParticleDefinition {
        WPEParticleDefinition(
            materialRelativePath: nil,
            maxCount: 4,
            rate: 1000,
            startDelay: 0,
            lifetimeMin: 10, lifetimeMax: 10,
            sizeMin: 10, sizeMax: 10,
            originOffset: originOffset,
            dispersalMin: 0, dispersalMax: 0,
            velocityMin: velocityMin, velocityMax: velocityMax,
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0.01,
            directionMask: directionMask
        )
    }

    // MARK: - Scene-object Y-up (no flip)

    @Test("Scene-object origin centers without Y-flip (Y-up bottom-left)")
    func sceneObjectOriginCentersWithoutFlip() throws {
        let transform = WPEParticleSceneTransform(
            sceneSize: SIMD2<Float>(3840, 2160),
            objectOrigin: SIMD3<Float>(0, 0, 0),
            objectScale: SIMD3<Float>(1, 1, 1),
            objectAngleZ: 0
        )
        // Author (0,0) bottom-left → centered (-W/2, -H/2).
        #expect(abs(transform.renderOrigin.x - (-1920)) < 0.0001)
        #expect(abs(transform.renderOrigin.y - (-1080)) < 0.0001)
    }

    @Test("Fog-shape origin (1997, 440) lands in lower half (NDC y < 0)")
    func fogOriginInLowerHalf() {
        let transform = WPEParticleSceneTransform(
            sceneSize: SIMD2<Float>(4216, 2416),
            objectOrigin: SIMD3<Float>(1997, 440, 0),
            objectScale: SIMD3<Float>(1, 1, 1),
            objectAngleZ: 0
        )
        // y = 440 - 1208 = -768 → NDC ≈ -0.636 → bottom 64% of screen.
        #expect(transform.renderOrigin.y < 0)
        #expect(abs(transform.renderOrigin.y - (-768)) < 0.01)
    }

    // MARK: - Emitter local Y-down (flips applied at spawn)

    @Test("angles.z is negated in model matrix (emitter local Y-down convention)")
    func angleZIsNegated() {
        // A 90° turn around +Z in the WPE author frame maps to Rz(-π/2)
        // in the Y-up render frame (Win32 clockwise → Y-up
        // counterclockwise is -1 sign). Point (1, 0) should swing to
        // (0, -1) under this convention.
        let transform = WPEParticleSceneTransform(
            sceneSize: SIMD2<Float>(1920, 1080),
            objectOrigin: SIMD3<Float>(960, 540, 0), // renderOrigin (0,0)
            objectScale: SIMD3<Float>(1, 1, 1),
            objectAngleZ: .pi * 0.5
        )
        let p = transform.applyModelMatrix(toLocalPoint: SIMD3<Float>(1, 0, 0))
        #expect(abs(p.x) < 0.0001)
        #expect(abs(p.y - (-1)) < 0.0001)
    }

    @Test("applyModelDirection rotates without translating")
    func directionApplyHasNoTranslation() {
        let transform = WPEParticleSceneTransform(
            sceneSize: SIMD2<Float>(1920, 1080),
            objectOrigin: SIMD3<Float>(960, 540, 0),
            objectScale: SIMD3<Float>(2, 3, 1),
            objectAngleZ: 0
        )
        let v = transform.applyModelDirection(SIMD3<Float>(10, -7, 0))
        #expect(abs(v.x - 20) < 0.0001)
        #expect(abs(v.y - (-21)) < 0.0001)
    }

    @Test("Object scale amplifies size through worldSizeMultiplier")
    func sceneObjectScaleAffectsSize() {
        let transform = WPEParticleSceneTransform(
            sceneSize: SIMD2<Float>(1920, 1080),
            objectOrigin: SIMD3<Float>(0, 0, 0),
            objectScale: SIMD3<Float>(3, 3, 1),
            objectAngleZ: 0
        )
        #expect(abs(transform.worldSizeMultiplier() - 3) < 0.0001)
    }

    @Test("Emitter origin Y is flipped at spawn (Y-down emitter convention)")
    func emitterOriginYFlippedAtSpawn() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        // Author emitter origin (100, 200) in Y-down local frame
        // → Y-flipped to (100, -200) before composition.
        let def = makeDefinition(originOffset: SIMD3(100, 200, 0))
        let transform = WPEParticleSceneTransform(
            sceneSize: SIMD2<Float>(1920, 1080),
            objectOrigin: SIMD3<Float>(1000, 540, 0), // renderOrigin (40, 0)
            objectScale: SIMD3<Float>(1, 1, 1),
            objectAngleZ: 0
        )
        let system = try #require(WPEParticleSystem(
            definition: def,
            device: device,
            blendMode: .translucent,
            sceneTransform: transform
        ))
        system.tick(now: 0)
        system.tick(now: 0.05)
        #expect(system.liveInstanceCount > 0)
        let inst = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 4)[0]
        // renderOrigin (40, 0) + emitter origin Y-flipped (100, -200) = (140, -200).
        #expect(abs(inst.positionAndSize.x - 140) < 0.5)
        #expect(abs(inst.positionAndSize.y - (-200)) < 0.5)
    }

    @Test("Velocity Y is flipped at spawn (emitter-local Y-down convention)")
    func velocityIsYFlipped() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        // sceneObject origin (960, 540) → renderOrigin (0, 0)
        // emitter origin (0,0,0) → emitter-local Y-flipped (0,0)
        // velocity (0, -50) → Y-flipped (0, +50)
        // spawn position = (0, 0); after ~0.2s of integration → y ≈ +10
        let def = makeDefinition(
            originOffset: SIMD3(0, 0, 0),
            velocityMin: SIMD3(0, -50, 0),
            velocityMax: SIMD3(0, -50, 0)
        )
        let transform = WPEParticleSceneTransform(
            sceneSize: SIMD2<Float>(1920, 1080),
            objectOrigin: SIMD3<Float>(960, 540, 0),
            objectScale: SIMD3<Float>(1, 1, 1),
            objectAngleZ: 0
        )
        let system = try #require(WPEParticleSystem(
            definition: def,
            device: device,
            blendMode: .translucent,
            sceneTransform: transform
        ))
        for step in 1...5 {
            system.tick(now: Double(step) * 0.05)
        }
        let inst = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 4)[0]
        // y > 0 confirms the Y-flip on velocity put the particle into
        // the upper half despite the JSON's negative vy.
        #expect(inst.positionAndSize.y > 5)
    }

    @Test("Gravity follows scene object scale and rotation like velocity")
    func gravityUsesSceneObjectDirectionTransform() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil,
            maxCount: 1,
            rate: 1000,
            startDelay: 0,
            lifetimeMin: 10,
            lifetimeMax: 10,
            sizeMin: 1,
            sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: 0,
            dispersalMax: 0,
            velocityMin: SIMD3(0, 0, 0),
            velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255),
            colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0.01,
            gravity: SIMD3(10, 0, 0)
        )
        let transform = WPEParticleSceneTransform(
            sceneSize: SIMD2<Float>(1920, 1080),
            objectOrigin: SIMD3<Float>(960, 540, 0),
            objectScale: SIMD3<Float>(-1, 1, 1),
            objectAngleZ: 0
        )
        let system = try #require(WPEParticleSystem(
            definition: def,
            device: device,
            blendMode: .translucent,
            sceneTransform: transform
        ))

        system.tick(now: 0)
        system.tick(now: 0.05)
        let initialX = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)[0].positionAndSize.x
        system.tick(now: 0.15)
        let laterX = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)[0].positionAndSize.x

        #expect(laterX < initialX)
    }

    @Test("Particle sprite carries scene object mirror signs and rotation")
    func particleSpriteCarriesObjectMirrorAndRotation() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = WPEParticleDefinition(
            materialRelativePath: nil,
            maxCount: 1,
            rate: 1000,
            startDelay: 0,
            lifetimeMin: 10,
            lifetimeMax: 10,
            sizeMin: 1,
            sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: 0,
            dispersalMax: 0,
            velocityMin: SIMD3(0, 0, 0),
            velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255),
            colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0,
            rotationMin: SIMD3(0, 0, 0),
            rotationMax: SIMD3(0, 0, 0)
        )
        let transform = WPEParticleSceneTransform(
            sceneSize: SIMD2<Float>(1920, 1080),
            objectOrigin: SIMD3<Float>(960, 540, 0),
            objectScale: SIMD3<Float>(-1, 1, 1),
            objectAngleZ: 0.75
        )
        let system = try #require(WPEParticleSystem(
            definition: def,
            device: device,
            blendMode: .translucent,
            sceneTransform: transform
        ))

        system.tick(now: 0)
        system.tick(now: 0.05)
        let instance = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 1)[0]

        #expect(instance.positionAndSize.z < 0)
        #expect(instance.rotationAndLife.w > 0)
        #expect(abs(instance.rotationAndLife.x - (-0.75)) < 0.001)
    }

    @Test("Parser captures directions mask")
    func parserCapturesDirections() throws {
        let json = #"""
        {
            "emitter": [{"rate": 1, "directions": "1 0.2 0"}],
            "initializer": [],
            "operator": []
        }
        """#
        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
        #expect(abs(def.directionMask.x - 1) < 0.0001)
        #expect(abs(def.directionMask.y - 0.2) < 0.0001)
        #expect(abs(def.directionMask.z - 0) < 0.0001)
    }

    @Test("2D sphere random dispersal does not collapse through disabled Z")
    func sphereRandom2DDispersalDoesNotCollapseThroughDisabledZ() {
        let dispersal = WPEParticleSystem.dispersalVector(
            radius: 100,
            theta: 0.25,
            phi: 0,
            mask: SIMD3<Float>(1, 1, 0)
        )

        #expect(abs(hypot(dispersal.x, dispersal.y) - 100) < 0.001)
        #expect(abs(dispersal.z) < 0.001)
    }

    @Test("Direction mask zero collapses dispersal on that axis")
    func directionMaskZeroCollapsesAxis() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let radiused = WPEParticleDefinition(
            materialRelativePath: nil,
            maxCount: 4,
            rate: 1000, startDelay: 0,
            lifetimeMin: 10, lifetimeMax: 10,
            sizeMin: 1, sizeMax: 1,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: 100, dispersalMax: 100,
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: SIMD3(255, 255, 255), colorMax: SIMD3(255, 255, 255),
            fadeInSeconds: 0.01,
            directionMask: SIMD3(1, 0, 0)
        )
        let transform = WPEParticleSceneTransform(
            sceneSize: SIMD2<Float>(1920, 1080),
            objectOrigin: SIMD3<Float>(960, 540, 0),
            objectScale: SIMD3<Float>(1, 1, 1),
            objectAngleZ: 0
        )
        let system = try #require(WPEParticleSystem(
            definition: radiused,
            device: device,
            blendMode: .translucent,
            sceneTransform: transform
        ))
        system.tick(now: 0)
        system.tick(now: 0.05)
        let instances = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 4)
        for index in 0..<system.liveInstanceCount {
            #expect(abs(instances[index].positionAndSize.y) < 0.01)
        }
    }
}
