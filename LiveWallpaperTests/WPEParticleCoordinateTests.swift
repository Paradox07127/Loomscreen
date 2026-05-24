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

    @Test("Identity transform leaves origin in author space, then Y-flipped + centered")
    func identityTransformOnly() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let transform = WPEParticleSceneTransform(
            sceneSize: SIMD2<Float>(3840, 2160),
            objectOrigin: SIMD3<Float>(0, 0, 0),
            objectScale: SIMD3<Float>(1, 1, 1),
            objectAngleZ: 0
        )
        let origin = transform.worldOrigin(localOffset: SIMD3<Float>(0, 0, 0))
        // (0,0) top-left → (-1920, 1080) centered + Y-up
        #expect(abs(origin.x - (-1920)) < 0.0001)
        #expect(abs(origin.y - 1080) < 0.0001)
        _ = device
    }

    @Test("Scene-object origin composes with WPE Y-flip")
    func sceneObjectOriginComposes() {
        let transform = WPEParticleSceneTransform(
            sceneSize: SIMD2<Float>(3840, 2160),
            objectOrigin: SIMD3<Float>(2019.58, 1280.80, 0),
            objectScale: SIMD3<Float>(1, 1, 1),
            objectAngleZ: 0
        )
        let origin = transform.worldOrigin(localOffset: SIMD3<Float>(0, 0, 0))
        // Author space (2019.58, 1280.80) → centered (99.58, -200.80)
        #expect(abs(origin.x - 99.58) < 0.01)
        #expect(abs(origin.y - (-200.80)) < 0.01)
    }

    @Test("Velocity is NOT Y-mirrored (matches WPE author intent)")
    func velocityNotMirrored() {
        let transform = WPEParticleSceneTransform(
            sceneSize: SIMD2<Float>(1920, 1080),
            objectOrigin: SIMD3<Float>(0, 0, 0),
            objectScale: SIMD3<Float>(1, 1, 1),
            objectAngleZ: 0
        )
        // leaves2-style velocity: vy = -100..-15 (downward on screen)
        let v = transform.worldVelocity(SIMD3<Float>(-75, -50, 0))
        #expect(abs(v.x - (-75)) < 0.0001)
        #expect(abs(v.y - (-50)) < 0.0001)
    }

    @Test("Object scale amplifies size and dispersal")
    func sceneObjectScaleAffectsSize() {
        let transform = WPEParticleSceneTransform(
            sceneSize: SIMD2<Float>(1920, 1080),
            objectOrigin: SIMD3<Float>(0, 0, 0),
            objectScale: SIMD3<Float>(3, 3, 1),
            objectAngleZ: 0
        )
        #expect(abs(transform.worldSizeMultiplier() - 3) < 0.0001)
    }

    @Test("System spawn places particles in the expected world quadrant")
    func systemSpawnInWorldSpace() throws {
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
        let instances = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 4)
        // Composite (1000+100, 540+200) author space → centered Y-up:
        // x = 1100 - 960 = 140
        // y = 540 - (540+200) = -200
        #expect(abs(instances[0].positionAndSize.x - 140) < 0.5)
        #expect(abs(instances[0].positionAndSize.y - (-200)) < 0.5)
    }

    @Test("Parser captures directions mask and exposes through definition")
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

    @Test("Direction mask zero collapses dispersal axis")
    func directionMaskZeroCollapsesAxis() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let def = makeDefinition(
            directionMask: SIMD3(1, 0, 0)
        )
        // Force dispersal radius > 0 so direction mask is observable.
        let radiused = WPEParticleDefinition(
            materialRelativePath: def.materialRelativePath,
            maxCount: def.maxCount,
            rate: def.rate, startDelay: def.startDelay,
            lifetimeMin: def.lifetimeMin, lifetimeMax: def.lifetimeMax,
            sizeMin: def.sizeMin, sizeMax: def.sizeMax,
            originOffset: SIMD3(0, 0, 0),
            dispersalMin: 100, dispersalMax: 100,
            velocityMin: SIMD3(0, 0, 0), velocityMax: SIMD3(0, 0, 0),
            colorMin: def.colorMin, colorMax: def.colorMax,
            fadeInSeconds: def.fadeInSeconds,
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
        // emitter origin (960, 540) → centered (0, 0).
        // Y-axis dispersal is zero → particles stay on y = 0 plane.
        for index in 0..<system.liveInstanceCount {
            #expect(abs(instances[index].positionAndSize.y) < 0.01)
        }
    }
}
