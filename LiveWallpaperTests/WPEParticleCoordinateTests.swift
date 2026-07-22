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
            dispersalMin: SIMD3<Double>(0, 0, 0), dispersalMax: SIMD3<Double>(0, 0, 0),
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
        #expect(transform.renderOrigin.y < 0)
        #expect(abs(transform.renderOrigin.y - (-768)) < 0.01)
    }

    // MARK: - Emitter local Y-down (flips applied at spawn)

    @Test("angles.z rotates as authored (+angleZ), matching the image-layer quad")
    func angleZMatchesImageLayer() {
        let transform = WPEParticleSceneTransform(
            sceneSize: SIMD2<Float>(1920, 1080),
            objectOrigin: SIMD3<Float>(960, 540, 0),
            objectScale: SIMD3<Float>(1, 1, 1),
            objectAngleZ: .pi * 0.5
        )
        let p = transform.applyModelMatrix(toLocalPoint: SIMD3<Float>(1, 0, 0))
        #expect(abs(p.x) < 0.0001)
        #expect(abs(p.y - 1) < 0.0001)
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

    @Test("Object scale enlarges sprite size (T·R·S) and spreads the emitter")
    func sceneObjectScaleAffectsEmitterAndSpriteSize() {
        let transform = WPEParticleSceneTransform(
            sceneSize: SIMD2<Float>(1920, 1080),
            objectOrigin: SIMD3<Float>(0, 0, 0),
            objectScale: SIMD3<Float>(3, 3, 1),
            objectAngleZ: 0
        )
        #expect(abs(transform.worldSizeMultiplier() - 3) < 0.0001)
        let spread = transform.applyModelDirection(SIMD3<Float>(10, 0, 0))
        #expect(abs(spread.x - 30) < 0.0001)
    }

    @Test("Emitter origin is used as authored — Y-up, no flip")
    func emitterOriginIsNotYFlipped() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = makeDefinition(originOffset: SIMD3(100, 200, 0))
        let transform = WPEParticleSceneTransform(
            sceneSize: SIMD2<Float>(1920, 1080),
            objectOrigin: SIMD3<Float>(1000, 540, 0),
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
        #expect(abs(inst.positionAndSize.x - 140) < 0.5)
        #expect(abs(inst.positionAndSize.y - 200) < 0.5)
    }

    @Test("Velocity is used as authored — Y-up, no flip (negative vy drifts down)")
    func velocityIsNotYFlipped() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
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
        #expect(inst.positionAndSize.y < -5)
    }

    @Test("Rotated emitter sends negative-vy leaves UP (3725117707 case)")
    func rotatedEmitterInvertsVerticalDrift() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = makeDefinition(
            originOffset: SIMD3(0, 0, 0),
            velocityMin: SIMD3(0, -50, 0),
            velocityMax: SIMD3(0, -50, 0)
        )
        let transform = WPEParticleSceneTransform(
            sceneSize: SIMD2<Float>(4216, 2416),
            objectOrigin: SIMD3<Float>(2108, 1208, 0),
            objectScale: SIMD3<Float>(3, 3, 1),
            objectAngleZ: 2.77231
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
            dispersalMin: SIMD3<Double>(0, 0, 0),
            dispersalMax: SIMD3<Double>(0, 0, 0),
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
            dispersalMin: SIMD3<Double>(0, 0, 0),
            dispersalMax: SIMD3<Double>(0, 0, 0),
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
        #expect(abs(instance.rotationAndLife.x - 0.75) < 0.001)
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

    @Test("Sphere surface direction matches WPE GenSphereSurfaceNormal: gaussian(0, directions.axis) per enabled axis, disabled axis forced to 0, result normalized")
    func sphereSurfaceDirectionMatchesGenSphereSurfaceNormal() {
        var requestedStddevs: [Double] = []
        let normal = WPEParticleSystem.sphereSurfaceDirection(directions: SIMD3<Double>(3, 4, 0)) { mean, stddev in
            #expect(mean == 0)
            requestedStddevs.append(stddev)
            return stddev
        }
        #expect(requestedStddevs == [3, 4], "the disabled Z axis must not be sampled")
        #expect(abs(normal.x - 0.6) < 0.0001)
        #expect(abs(normal.y - 0.8) < 0.0001)
        #expect(abs(normal.z) < 0.0001)
    }

    @Test("Sphere surface direction with all axes disabled returns zero instead of dividing by zero")
    func sphereSurfaceDirectionZeroVectorGuard() {
        let normal = WPEParticleSystem.sphereSurfaceDirection(directions: SIMD3<Double>(0, 0, 0)) { _, stddev in stddev }
        #expect(normal == SIMD3<Double>(0, 0, 0))
    }

    @Test("Sphere surface direction with a single enabled axis always lands on ±that axis")
    func sphereSurfaceDirectionSingleAxisIsAlwaysUnitOnThatAxis() {
        let positive = WPEParticleSystem.sphereSurfaceDirection(directions: SIMD3<Double>(0, 0, 5)) { _, _ in 2.5 }
        #expect(positive == SIMD3<Double>(0, 0, 1))
        let negative = WPEParticleSystem.sphereSurfaceDirection(directions: SIMD3<Double>(0, 0, 5)) { _, _ in -2.5 }
        #expect(negative == SIMD3<Double>(0, 0, -1))
    }

    @Test("Sphere radius sampling is volume-uniform: lerp(pow(rand, 1/3), min, max), not naive lerp(rand, min, max)")
    func sphereRadiusIsVolumeUniform() {
        let r = WPEParticleSystem.sphereRadius(min: 0, max: 100, uniform01: 0.5)
        #expect(abs(r - 100 * pow(0.5, 1.0 / 3.0)) < 0.0001)
        #expect(r > 75, "volumetric bias should skew well past the naive-uniform midpoint of 50 (got \(r))")

        #expect(abs(WPEParticleSystem.sphereRadius(min: 10, max: 90, uniform01: 0) - 10) < 0.0001)
        #expect(abs(WPEParticleSystem.sphereRadius(min: 10, max: 90, uniform01: 1) - 90) < 0.0001)
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
            dispersalMin: SIMD3<Double>(100, 100, 100), dispersalMax: SIMD3<Double>(100, 100, 100),
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
