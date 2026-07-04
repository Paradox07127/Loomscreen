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

    @Test("angles.z rotates as authored (+angleZ), matching the image-layer quad")
    func angleZMatchesImageLayer() {
        // The particle model matrix uses `Rz(+angleZ)` — same sign the image
        // quad applies (WPEMetalRenderExecutor passes geometry.angles.z
        // unnegated). A 90° turn swings (1, 0) → (0, +1). (An earlier
        // `Rz(-angleZ)` sent 3462491575's 雪景 rightward where WPE blows it left.)
        let transform = WPEParticleSceneTransform(
            sceneSize: SIMD2<Float>(1920, 1080),
            objectOrigin: SIMD3<Float>(960, 540, 0), // renderOrigin (0,0)
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
        // WPE's CParticle model matrix is T·R·S, so the object's 2D scale
        // folds into the billboard size as (|x|+|y|)/2 (verified vs the
        // 7.8×-scaled light-shaft in 3426865175). Additive saturation from
        // hugely-scaled emitters is handled by the blend-aware sceneHeight
        // cap at spawn (see WPEParticleSystemTests.additiveSpriteSizeCapped),
        // not by decoupling sprite size from object scale.
        #expect(abs(transform.worldSizeMultiplier() - 3) < 0.0001)
        // Object scale also spreads the emitter: a 10px dispersal offset
        // scales to 30px at scale 3 (isolated via applyModelDirection, which
        // applies scale+rotation without the origin translation).
        let spread = transform.applyModelDirection(SIMD3<Float>(10, 0, 0))
        #expect(abs(spread.x - 30) < 0.0001)
    }

    @Test("Emitter origin is used as authored — Y-up, no flip")
    func emitterOriginIsNotYFlipped() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        // Author emitter origin (100, 200) is Y-up bottom-left like the
        // rest of the author space — used as-is, NOT flipped to -200.
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
        // renderOrigin (40, 0) + emitter origin as-authored (100, +200) = (140, +200).
        #expect(abs(inst.positionAndSize.x - 140) < 0.5)
        #expect(abs(inst.positionAndSize.y - 200) < 0.5)
    }

    @Test("Velocity is used as authored — Y-up, no flip (negative vy drifts down)")
    func velocityIsNotYFlipped() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        // sceneObject origin (960, 540) → renderOrigin (0, 0)
        // emitter origin (0,0,0); velocity (0, -50) used as-is (Y-up):
        // negative vy → particle drifts DOWN (negative Y) on screen.
        // This is the un-rotated case (saber 3526278753): leaves fall.
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
        // y < 0 confirms no Y-flip: the JSON's negative vy drifts the
        // particle DOWN, not up (the P7 flip wrongly sent it up).
        #expect(inst.positionAndSize.y < -5)
    }

    @Test("Rotated emitter sends negative-vy leaves UP (3725117707 case)")
    func rotatedEmitterInvertsVerticalDrift() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        // Same preset as the saber (velocity (0,-50), would fall down
        // un-rotated), but the scene object is rotated ~159° like
        // 3725117707's leaf layer. The rotation flips the vertical
        // component, so the SAME negative vy now drifts the leaves UP.
        // This is why a single no-flip convention yields opposite
        // on-screen directions for the two scenes — and why toggling a
        // global Y-flip to "fix" one silently inverts the other.
        let def = makeDefinition(
            originOffset: SIMD3(0, 0, 0),
            velocityMin: SIMD3(0, -50, 0),
            velocityMax: SIMD3(0, -50, 0)
        )
        let transform = WPEParticleSceneTransform(
            sceneSize: SIMD2<Float>(4216, 2416),
            objectOrigin: SIMD3<Float>(2108, 1208, 0), // renderOrigin (0, 0)
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
        // Sprite rotation carries the object's `+angleZ` (matches the image quad;
        // the horizontal mirror rides positionAndSize.z sign, not the angle).
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
