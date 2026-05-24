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

    @Test("Scene-object origin is Y-flipped + centered once at construction")
    func sceneObjectOriginCenteredAtConstruction() throws {
        let transform = WPEParticleSceneTransform(
            sceneSize: SIMD2<Float>(3840, 2160),
            objectOrigin: SIMD3<Float>(0, 0, 0),
            objectScale: SIMD3<Float>(1, 1, 1),
            objectAngleZ: 0
        )
        // (0,0) top-left → (-1920, 1080) centered + Y-up
        #expect(abs(transform.renderOrigin.x - (-1920)) < 0.0001)
        #expect(abs(transform.renderOrigin.y - 1080) < 0.0001)
    }

    @Test("applyModelMatrix maps local zero to the centered render origin")
    func applyModelToZeroReturnsRenderOrigin() {
        let transform = WPEParticleSceneTransform(
            sceneSize: SIMD2<Float>(3840, 2160),
            objectOrigin: SIMD3<Float>(2019.58, 1280.80, 0),
            objectScale: SIMD3<Float>(1, 1, 1),
            objectAngleZ: 0
        )
        let p = transform.applyModelMatrix(toLocalPoint: SIMD3<Float>(0, 0, 0))
        // Author (2019.58, 1280.80) → centered (99.58, -200.80)
        #expect(abs(p.x - 99.58) < 0.01)
        #expect(abs(p.y - (-200.80)) < 0.01)
    }

    @Test("angles.z is negated in the model matrix (Y-flip convention)")
    func angleZIsNegated() {
        // A 90° turn around +Z in the WPE author frame must rotate
        // (1, 0, 0) towards the -Y axis in the Y-up render frame —
        // the linux-wallpaperengine note in CParticle.cpp:1850.
        let transform = WPEParticleSceneTransform(
            sceneSize: SIMD2<Float>(1920, 1080),
            objectOrigin: SIMD3<Float>(960, 540, 0), // → renderOrigin (0,0)
            objectScale: SIMD3<Float>(1, 1, 1),
            objectAngleZ: .pi * 0.5
        )
        let p = transform.applyModelMatrix(toLocalPoint: SIMD3<Float>(1, 0, 0))
        // Rz(-π/2) on (1,0): cos(-π/2)=0, sin(-π/2)=-1
        // x = 1·0 - 0·(-1) = 0 ; y = 1·(-1) + 0·0 = -1
        #expect(abs(p.x) < 0.0001)
        #expect(abs(p.y - (-1)) < 0.0001)
    }

    @Test("applyModelDirection rotates without translating")
    func directionApplyHasNoTranslation() {
        let transform = WPEParticleSceneTransform(
            sceneSize: SIMD2<Float>(1920, 1080),
            objectOrigin: SIMD3<Float>(960, 540, 0), // renderOrigin (0,0)
            objectScale: SIMD3<Float>(2, 3, 1),
            objectAngleZ: 0
        )
        let v = transform.applyModelDirection(SIMD3<Float>(10, -7, 0))
        #expect(abs(v.x - 20) < 0.0001) // 10 * 2
        #expect(abs(v.y - (-21)) < 0.0001) // -7 * 3
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

    @Test("System spawn places emitter origin in the expected world quadrant")
    func systemSpawnInWorldSpace() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        // Author-space emitter origin (100, 200) inside an object at
        // author origin (1000, 540) on a 1920×1080 stage with no
        // rotation/scale.
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
        // renderOrigin = (1000 - 960, 540 - 540) = (40, 0)
        // emitter origin Y-flipped = (100, -200)
        // applyModelMatrix(identity) = renderOrigin + (100, -200) = (140, -200)
        #expect(abs(instances[0].positionAndSize.x - 140) < 0.5)
        #expect(abs(instances[0].positionAndSize.y - (-200)) < 0.5)
    }

    @Test("Velocity Y is flipped at spawn (matches WPE source semantics)")
    func velocityIsYFlippedAtSpawn() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        // Author velocity (10, -50, 0) → after Y-flip + identity scale/
        // rotate → render-frame velocity (10, +50, 0). With identity
        // origin at (0,0) author = (-W/2, +H/2) renderOrigin, integrate
        // for ~0.05s and expect the +Y movement to lift particle.y up.
        let def = makeDefinition(
            originOffset: SIMD3(960, 540, 0),
            velocityMin: SIMD3(10, -50, 0),
            velocityMax: SIMD3(10, -50, 0)
        )
        let transform = WPEParticleSceneTransform(
            sceneSize: SIMD2<Float>(1920, 1080),
            objectOrigin: SIMD3<Float>(0, 0, 0),
            objectScale: SIMD3<Float>(1, 1, 1),
            objectAngleZ: 0
        )
        let system = try #require(WPEParticleSystem(
            definition: def,
            device: device,
            blendMode: .translucent,
            sceneTransform: transform
        ))
        // Walk forward in small steps so the spawn lands in tick 2 and
        // subsequent ticks integrate.
        for step in 1...5 {
            system.tick(now: Double(step) * 0.05)
        }
        let inst = system.instanceBuffer.contents()
            .bindMemory(to: WPEParticleInstance.self, capacity: 4)[0]
        // emitter origin (960, 540) author → Y-flipped (960, -540)
        // renderOrigin = (0 - 960, 540 - 0) = (-960, 540)
        // initial spawn position = (-960 + 960, 540 + (-540)) = (0, 0)
        // velocity (10, -50) → Y-flipped (10, +50) → after ~0.2s ≈ (2, +10)
        #expect(inst.positionAndSize.x > 0)
        #expect(inst.positionAndSize.y > 0) // moved up
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
        // renderOrigin (0,0); emitter origin (0,0); dispersal Y mask 0
        // → Y component of every particle stays on the y=0 plane.
        for index in 0..<system.liveInstanceCount {
            #expect(abs(instances[index].positionAndSize.y) < 0.01)
        }
    }
}
