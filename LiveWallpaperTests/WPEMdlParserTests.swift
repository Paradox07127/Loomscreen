import Foundation
import Testing
import simd
@testable import LiveWallpaper

@Suite("WPE puppet animation evaluator")
struct WPEPuppetAnimationEvaluatorTests {
    private func animation(
        frameCount: Int,
        mode: String,
        channels: [WPEPuppetAnimChannel]
    ) -> WPEPuppetAnimation {
        WPEPuppetAnimation(id: 1, name: "a", mode: mode, fps: 30, frameCount: frameCount, channels: channels)
    }

    private func channel(_ keys: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)]) -> WPEPuppetAnimChannel {
        WPEPuppetAnimChannel(
            boneIndex: 0,
            keyframes: keys.enumerated().map { index, k in
                WPEPuppetAnimKey(frame: index, translation: k.0, euler: k.1, scale: k.2)
            }
        )
    }

    @Test("Frame 0 yields an identity palette (the bind pose, so the rest mesh is unchanged)")
    func frameZeroIsIdentity() {
        let anim = animation(frameCount: 2, mode: "loop", channels: [
            channel([
                (SIMD3(0, 0, 0), SIMD3(0, 0, 0), SIMD3(1, 1, 1)),
                (SIMD3(10, 0, 0), SIMD3(0, 0, 0), SIMD3(1, 1, 1)),
                (SIMD3(20, 0, 0), SIMD3(0, 0, 0), SIMD3(1, 1, 1))
            ])
        ])
        let palette = WPEPuppetAnimationEvaluator.palette(for: anim, at: 0)
        #expect(palette.count == 1)
        #expect(palette.allSatisfy { simd_equal($0, matrix_identity_float4x4) })
    }

    @Test("Frame-0 identity fast path requires proof for every base channel")
    func baseFrameMatchesRawBindStrictness() {
        let identityRaw: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        let bone = WPEPuppetBone(index: 0, parentIndex: nil, rawMatrix: identityRaw)
        let restKey = WPEPuppetAnimKey(
            frame: 0, translation: .zero, euler: .zero, scale: SIMD3(1, 1, 1)
        )
        let matching = WPEPuppetAnimChannel(boneIndex: 0, keyframes: [restKey])
        #expect(WPEPuppetAnimationEvaluator.baseFrameMatchesRawBind(channels: [matching], bones: [bone]))

        // A channel whose bone has no raw matrix must not be assumed to match.
        let orphan = WPEPuppetAnimChannel(boneIndex: 5, keyframes: [restKey])
        #expect(!WPEPuppetAnimationEvaluator.baseFrameMatchesRawBind(
            channels: [matching, orphan], bones: [bone]
        ))

        // A channel without keyframes must not be assumed to match.
        let empty = WPEPuppetAnimChannel(boneIndex: 0, keyframes: [])
        #expect(!WPEPuppetAnimationEvaluator.baseFrameMatchesRawBind(channels: [empty], bones: [bone]))

        // Character-sheet signature: frame-0 pose differs from the raw bind.
        let assembled = WPEPuppetAnimChannel(boneIndex: 0, keyframes: [
            WPEPuppetAnimKey(frame: 0, translation: SIMD3(10, 0, 0), euler: .zero, scale: SIMD3(1, 1, 1))
        ])
        #expect(!WPEPuppetAnimationEvaluator.baseFrameMatchesRawBind(channels: [assembled], bones: [bone]))
    }

    @Test("Assembled bind-world uses frame-0 for character sheets, raw MDLS for pre-assembled")
    func assembledBindWorldPicksFrameZeroForCharacterSheet() {
        func rawBone(_ t: SIMD3<Float>) -> WPEPuppetBone {
            WPEPuppetBone(
                index: 0, parentIndex: nil,
                rawMatrix: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, t.x, t.y, t.z, 1]
            )
        }
        func model(rawT: SIMD3<Float>, frame0T: SIMD3<Float>) -> WPEPuppetModel {
            let channel = WPEPuppetAnimChannel(boneIndex: 0, keyframes: [
                WPEPuppetAnimKey(frame: 0, translation: frame0T, euler: .zero, scale: SIMD3(1, 1, 1))
            ])
            return WPEPuppetModel(
                version: 19,
                meshes: [],
                bones: [rawBone(rawT)],
                animations: [WPEPuppetAnimation(id: 1, name: "a", mode: "loop", fps: 30, frameCount: 1, channels: [channel])]
            )
        }
        // Character sheet: raw MDLS is the exploded layout, frame-0 is the assembled anchor → frame-0 wins.
        let sheet = WPEPuppetAnimationEvaluator.assembledBindWorldByBone(
            model: model(rawT: SIMD3(287, -672, 0), frame0T: SIMD3(2, -108, 0))
        )
        #expect(sheet[0].map { simd_equal($0.columns.3, SIMD4<Float>(2, -108, 0, 1)) } == true)
        // Pre-assembled: frame-0 == raw → raw path, no change.
        let assembled = WPEPuppetAnimationEvaluator.assembledBindWorldByBone(
            model: model(rawT: SIMD3(287, -672, 0), frame0T: SIMD3(287, -672, 0))
        )
        #expect(assembled[0].map { simd_equal($0.columns.3, SIMD4<Float>(287, -672, 0, 1)) } == true)
    }

    @Test("Assembled bind-world composes parent-child, falls back on missing channel and on a cycle")
    func assembledBindWorldCompositionAndFallbacks() {
        func rawBone(_ index: Int, parent: Int?, _ t: SIMD3<Float>) -> WPEPuppetBone {
            WPEPuppetBone(
                index: index, parentIndex: parent,
                rawMatrix: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, t.x, t.y, t.z, 1]
            )
        }
        func chan(_ bone: Int, _ t: SIMD3<Float>) -> WPEPuppetAnimChannel {
            WPEPuppetAnimChannel(boneIndex: bone, keyframes: [
                WPEPuppetAnimKey(frame: 0, translation: t, euler: .zero, scale: SIMD3(1, 1, 1))
            ])
        }
        // Character sheet, 2-level hierarchy. Bone 0 frame-0 = (10,0); bone 1 (child) frame-0 = (5,0)
        // → composed child world = (15,0). Bone 1 has NO channel → falls back to its raw local (100,0),
        // composed onto frame-0 parent (10,0) = (110,0).
        let model = WPEPuppetModel(
            version: 19, meshes: [],
            bones: [rawBone(0, parent: nil, SIMD3(1, 0, 0)),
                    rawBone(1, parent: 0, SIMD3(100, 0, 0))],
            animations: [WPEPuppetAnimation(
                id: 1, name: "a", mode: "loop", fps: 30, frameCount: 1,
                channels: [chan(0, SIMD3(10, 0, 0)), chan(1, SIMD3(5, 0, 0))]
            )]
        )
        let world = WPEPuppetAnimationEvaluator.assembledBindWorldByBone(model: model)
        #expect(world[0].map { simd_equal($0.columns.3, SIMD4<Float>(10, 0, 0, 1)) } == true)
        #expect(world[1].map { simd_equal($0.columns.3, SIMD4<Float>(15, 0, 0, 1)) } == true)

        // Missing channel for the child → raw local composed on the frame-0 parent.
        let missingChild = WPEPuppetModel(
            version: 19, meshes: [],
            bones: [rawBone(0, parent: nil, SIMD3(1, 0, 0)),
                    rawBone(1, parent: 0, SIMD3(100, 0, 0))],
            animations: [WPEPuppetAnimation(
                id: 1, name: "a", mode: "loop", fps: 30, frameCount: 1, channels: [chan(0, SIMD3(10, 0, 0))]
            )]
        )
        let missing = WPEPuppetAnimationEvaluator.assembledBindWorldByBone(model: missingChild)
        // Missing child channel makes frame-0 not match raw (parent differs), so the character-sheet
        // path is taken; the child has no frame-0 key so it uses its raw local (100,0) on parent (10,0).
        #expect(missing[1].map { simd_equal($0.columns.3, SIMD4<Float>(110, 0, 0, 1)) } == true)

        // A 0↔1 cycle must not fold the cycle into a bone's transform: each resolves to its own local.
        let cyclic = WPEPuppetModel(
            version: 19, meshes: [],
            bones: [rawBone(0, parent: 1, SIMD3(1, 0, 0)),
                    rawBone(1, parent: 0, SIMD3(2, 0, 0))],
            animations: []
        )
        let cyc = WPEPuppetAnimationEvaluator.assembledBindWorldByBone(model: cyclic)
        #expect(cyc[0].map { simd_equal($0.columns.3, SIMD4<Float>(1, 0, 0, 1)) } == true)
    }

    @Test("Loop mode wraps the sampled frame index")
    func loopModeWraps() {
        let anim = animation(frameCount: 2, mode: "loop", channels: [channel([
            (.zero, .zero, SIMD3(1, 1, 1))
        ])])
        #expect(WPEPuppetAnimationEvaluator.sampledFrameIndex(for: anim, at: 0) == 0)
        #expect(WPEPuppetAnimationEvaluator.sampledFrameIndex(for: anim, at: 1.0 / 30.0) == 1)
        #expect(WPEPuppetAnimationEvaluator.sampledFrameIndex(for: anim, at: 2.0 / 30.0) == 0)
    }

    @Test("Clamp (any non-loop, non-mirror mode) holds the last frame instead of wrapping or bouncing")
    func clampModeHoldsLastFrame() {
        let anim = animation(frameCount: 4, mode: "clamp", channels: [channel([
            (.zero, .zero, SIMD3(1, 1, 1))
        ])])
        let fps = 30.0
        let expected = [0, 1, 2, 3, 3, 3, 3]
        for (rawFrame, want) in expected.enumerated() {
            let time = Double(rawFrame) / fps
            #expect(WPEPuppetAnimationEvaluator.sampledFrameIndex(for: anim, at: time) == want)
        }
    }

    @Test("Mirror mode ping-pongs the sampled frame index instead of freezing on the last frame")
    func mirrorModeBounces() {
        // N=4 → period 2*(4-1)=6: 0,1,2,3,2,1,0,1,2,3,2,1,0,...
        let anim = animation(frameCount: 4, mode: "mirror", channels: [channel([
            (.zero, .zero, SIMD3(1, 1, 1))
        ])])
        let fps = 30.0
        let expected = [0, 1, 2, 3, 2, 1, 0, 1, 2, 3, 2, 1, 0]
        for (rawFrame, want) in expected.enumerated() {
            let time = Double(rawFrame) / fps
            #expect(WPEPuppetAnimationEvaluator.sampledFrameIndex(for: anim, at: time) == want)
        }
    }

    @Test("Mirror mode is case-insensitive and tolerates surrounding whitespace")
    func mirrorModeNormalizesCasingAndWhitespace() {
        let anim = animation(frameCount: 3, mode: " Mirror ", channels: [channel([
            (.zero, .zero, SIMD3(1, 1, 1))
        ])])
        // N=3 → period 2*(3-1)=4: 0,1,2,1,0,1,2,1,0,...
        #expect(WPEPuppetAnimationEvaluator.sampledFrameIndex(for: anim, at: 0) == 0)
        #expect(WPEPuppetAnimationEvaluator.sampledFrameIndex(for: anim, at: 1.0 / 30.0) == 1)
        #expect(WPEPuppetAnimationEvaluator.sampledFrameIndex(for: anim, at: 2.0 / 30.0) == 2)
        #expect(WPEPuppetAnimationEvaluator.sampledFrameIndex(for: anim, at: 3.0 / 30.0) == 1)
        #expect(WPEPuppetAnimationEvaluator.sampledFrameIndex(for: anim, at: 4.0 / 30.0) == 0)
    }

    @Test("Mirror mode with a single frame never divides by a zero period")
    func mirrorModeSingleFrame() {
        let anim = animation(frameCount: 1, mode: "mirror", channels: [channel([
            (.zero, .zero, SIMD3(1, 1, 1))
        ])])
        #expect(WPEPuppetAnimationEvaluator.sampledFrameIndex(for: anim, at: 0) == 0)
        #expect(WPEPuppetAnimationEvaluator.sampledFrameIndex(for: anim, at: 5.0 / 30.0) == 0)
    }

    @Test("Pure-translation channel skins by the per-frame delta from the bind pose")
    func translationDeltaMatrix() {
        let anim = animation(frameCount: 2, mode: "loop", channels: [
            channel([
                (SIMD3(0, 0, 0), SIMD3(0, 0, 0), SIMD3(1, 1, 1)),
                (SIMD3(10, 0, 0), SIMD3(0, 0, 0), SIMD3(1, 1, 1)),
                (SIMD3(20, 0, 0), SIMD3(0, 0, 0), SIMD3(1, 1, 1))
            ])
        ])
        let palette = WPEPuppetAnimationEvaluator.palette(for: anim, at: 1.0 / 30.0)
        let skinned = palette[0] * SIMD4<Float>(1, 2, 0, 1)
        #expect(skinned == SIMD4<Float>(11, 2, 0, 1))
    }

    @Test("Additive layer composes its delta on top of the base (blink-style Y-scale)")
    func additiveLayerComposesOnBase() {
        let base = animation(frameCount: 2, mode: "loop", channels: [channel([
            (SIMD3(0, 0, 0), SIMD3(0, 0, 0), SIMD3(1, 1, 1)),
            (SIMD3(0, 0, 0), SIMD3(0, 0, 0), SIMD3(1, 1, 1)),
            (SIMD3(0, 0, 0), SIMD3(0, 0, 0), SIMD3(1, 1, 1))
        ])])
        // Additive "blink" layer: bone 0 squashes vertically (Sy 1 → 0.5) at frame 1.
        let blink = animation(frameCount: 2, mode: "loop", channels: [channel([
            (SIMD3(0, 0, 0), SIMD3(0, 0, 0), SIMD3(1, 1, 1)),
            (SIMD3(0, 0, 0), SIMD3(0, 0, 0), SIMD3(1, 0.5, 1)),
            (SIMD3(0, 0, 0), SIMD3(0, 0, 0), SIMD3(1, 1, 1))
        ])])
        let layers = [
            WPEPuppetAnimationLayer(animation: base, rate: 1, additive: false, blend: 1),
            WPEPuppetAnimationLayer(animation: blink, rate: 1, additive: true, blend: 1)
        ]
        let atBind = WPEPuppetAnimationEvaluator.palette(layers: layers, bones: [], at: 0)
        #expect(atBind.allSatisfy { simd_equal($0, matrix_identity_float4x4) })
        // Frame 1: base unchanged + additive Sy 0.5 → a vertex at y=2 skins to y=1.
        let blended = WPEPuppetAnimationEvaluator.palette(layers: layers, bones: [], at: 1.0 / 30.0)
        let skinned = blended[0] * SIMD4<Float>(0, 2, 0, 1)
        #expect(abs(skinned.y - 1.0) < 1e-5)
        #expect(abs(skinned.x) < 1e-5)
    }

    @Test("Additive layer with a ZERO bind scale follows the authored absolute scale (eyelid inflate)")
    func additiveZeroBindScaleFollowsAuthoredAbsolute() {
        // 3226487183's eyelid rig: the blink layer's frame-0 scale is 0 (lid collapsed at rest) and
        // the clip inflates it to 1 mid-blink. A bind-relative ratio is undefined at 0; the old
        // guard returned ratio 1 and froze the lid at the base scale for the whole blink.
        let base = animation(frameCount: 3, mode: "loop", channels: [channel([
            (SIMD3(0, 0, 0), SIMD3(0, 0, 0), SIMD3(1, 1, 1)),
            (SIMD3(0, 0, 0), SIMD3(0, 0, 0), SIMD3(1, 1, 1)),
            (SIMD3(0, 0, 0), SIMD3(0, 0, 0), SIMD3(1, 1, 1))
        ])])
        let blink = animation(frameCount: 3, mode: "loop", channels: [channel([
            (SIMD3(0, 0, 0), SIMD3(0, 0, 0), SIMD3(0, 0, 1)),
            (SIMD3(0, 0, 0), SIMD3(0, 0, 0), SIMD3(1, 0.5, 1)),
            (SIMD3(0, 0, 0), SIMD3(0, 0, 0), SIMD3(0, 0, 1))
        ])])
        func layers(blend: Float) -> [WPEPuppetAnimationLayer] {
            [
                WPEPuppetAnimationLayer(animation: base, rate: 1, additive: false, blend: 1),
                WPEPuppetAnimationLayer(animation: blink, rate: 1, additive: true, blend: blend)
            ]
        }
        // Mid-blink (frame 1): composed scale follows the authored absolute (Sx 1, Sy 0.5).
        let peak = WPEPuppetAnimationEvaluator.palette(layers: layers(blend: 1), bones: [], at: 1.0 / 30.0)
        let peakSkinned = peak[0] * SIMD4<Float>(3, 2, 0, 1)
        #expect(abs(peakSkinned.x - 3.0) < 1e-5)
        #expect(abs(peakSkinned.y - 1.0) < 1e-5)
        // Back at the authored rest value (frame 2, past the frame-0 identity fast path): the lid
        // must collapse to the authored scale 0, not freeze at the base's full size.
        let rest = WPEPuppetAnimationEvaluator.palette(layers: layers(blend: 1), bones: [], at: 2.0 / 30.0)
        let restSkinned = rest[0] * SIMD4<Float>(3, 2, 0, 1)
        #expect(abs(restSkinned.x) < 1e-5)
        #expect(abs(restSkinned.y) < 1e-5)
        // Half blend lerps the running base scale toward the authored absolute: 1 + (0.5-1)*0.5 = 0.75.
        let half = WPEPuppetAnimationEvaluator.palette(layers: layers(blend: 0.5), bones: [], at: 1.0 / 30.0)
        let halfSkinned = half[0] * SIMD4<Float>(3, 2, 0, 1)
        #expect(abs(halfSkinned.y - 2.0 * 0.75) < 1e-5)
    }

    @Test("A parent bone's rotation propagates through the hierarchy into a child bone's palette")
    func parentRotationPropagatesToChild() {
        // Two-bone parent-local rig: root at the origin, child offset (100,0,0). MDLS raw matrices
        // are PARENT-LOCAL (the convention this skinning path composes), and each channel's frame 0
        // equals its raw local bind. Regression guard for scenes 3461168300 / 3554161528: the old
        // code left descendants ≈ identity (worldAbsolute / uncomposed raw bind) so a parent's
        // breathing/sway/blink never reached the bones it drives — the puppet skinned nearly static.
        func columnMajor(translation: SIMD3<Float>) -> [Float] {
            [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, translation.x, translation.y, translation.z, 1]
        }
        let bones = [
            WPEPuppetBone(index: 0, parentIndex: nil, rawMatrix: columnMajor(translation: .zero)),
            WPEPuppetBone(index: 1, parentIndex: 0, rawMatrix: columnMajor(translation: SIMD3(100, 0, 0)))
        ]
        // Root rotates 90° about Z at frame 1; the child has NO local motion — its world motion must
        // come entirely from inheriting the parent.
        let anim = WPEPuppetAnimation(
            id: 1, name: "sway", mode: "loop", fps: 30, frameCount: 2,
            channels: [
                WPEPuppetAnimChannel(boneIndex: 0, keyframes: [
                    WPEPuppetAnimKey(frame: 0, translation: .zero, euler: .zero, scale: SIMD3(1, 1, 1)),
                    WPEPuppetAnimKey(frame: 1, translation: .zero, euler: SIMD3(0, 0, .pi / 2), scale: SIMD3(1, 1, 1))
                ]),
                WPEPuppetAnimChannel(boneIndex: 1, keyframes: [
                    WPEPuppetAnimKey(frame: 0, translation: SIMD3(100, 0, 0), euler: .zero, scale: SIMD3(1, 1, 1)),
                    WPEPuppetAnimKey(frame: 1, translation: SIMD3(100, 0, 0), euler: .zero, scale: SIMD3(1, 1, 1))
                ])
            ]
        )
        let layers = [WPEPuppetAnimationLayer(animation: anim, rate: 1, additive: false, blend: 1)]

        // Frame 0: bind pose → identity palette for both bones (no-regression guard).
        let bind = WPEPuppetAnimationEvaluator.palette(layers: layers, bones: bones, at: 0)
        #expect(bind.count == 2)
        #expect(bind.allSatisfy { simd_equal($0, matrix_identity_float4x4) })

        // Frame 1: the child's bind-world anchor (100,0,0) must skin to the root-rotated (0,100,0).
        // Pre-fix this stayed at (100,0,0) because the child palette was ≈ identity.
        let posed = WPEPuppetAnimationEvaluator.palette(layers: layers, bones: bones, at: 1.0 / 30.0)
        let childAnchor = posed[1] * SIMD4<Float>(100, 0, 0, 1)
        #expect(abs(childAnchor.x) < 1e-3)
        #expect(abs(childAnchor.y - 100) < 1e-3)
    }
}

@Suite("WPE MDL parser")
struct WPEMdlParserTests {
    @Test("Parses MDLV23 textured mesh vertices indices and parts")
    func parsesMDLV23TexturedMesh() throws {
        let model = try WPEMdlParser.parse(data: makeSingleTriangleMDLV23())
        let mesh = try #require(model.meshes.first)

        #expect(model.version == 23)
        #expect(mesh.materialPath == "materials/test.json")
        #expect(mesh.vertices.count == 3)
        #expect(mesh.vertices[0].position == SIMD3<Float>(-10, -20, 0))
        #expect(mesh.vertices[1].position == SIMD3<Float>(10, -20, 0))
        #expect(mesh.vertices[2].position == SIMD3<Float>(0, 20, 0))
        #expect(mesh.vertices[0].uv == SIMD2<Float>(0, 1))
        #expect(mesh.vertices[1].uv == SIMD2<Float>(1, 1))
        #expect(mesh.vertices[2].uv == SIMD2<Float>(0.5, 0))
        #expect(mesh.indices == [0, 1, 2])
        #expect(mesh.parts == [
            WPEPuppetMeshPart(id: 7, start: 0, count: 3)
        ])
    }

    @Test("Parses MDLV23 skin blend indices as little-endian Int32, not float bit patterns")
    func parsesMDLV23SkinBlendIndicesAsInt32() throws {
        let model = try WPEMdlParser.parse(data: makeSingleVertexSkinnedMDLV23())
        let mesh = try #require(model.meshes.first)
        let vertex = try #require(mesh.vertices.first)

        #expect(vertex.skinBlendIndices == SIMD4<Int32>(7, 1, 1, 1))
        #expect(vertex.skinBlendWeights == SIMD4<Float>(1, 0, 0, 0))
        #expect(vertex.position == SIMD3<Float>(149.086, -686.59, 0))
        #expect(vertex.uv == SIMD2<Float>(0.65, 0.198))
    }

    @Test("Parses MDLV19 header with the leading meshCount byte (same layout as v23)")
    func parsesMDLV19HeaderWithLeadingByte() throws {
        // MDLV0019 puppets carry the same `u8 + u32 meshCount + u32` header as
        // MDLV0023. Reading them without the leading byte (the old `>= 23` gate)
        // misaligned the cursor, inflated meshCount, and aborted the parse — the
        // root cause of scattered facial features in v19 scenes (e.g. 3220362582).
        let model = try WPEMdlParser.parse(data: makeSingleVertexSkinnedMDLV19())
        let mesh = try #require(model.meshes.first)
        let vertex = try #require(mesh.vertices.first)

        #expect(model.version == 19)
        #expect(model.meshes.count == 1)
        #expect(mesh.materialPath == "materials/test.json")
        #expect(vertex.skinBlendIndices == SIMD4<Int32>(7, 1, 1, 1))
        #expect(vertex.skinBlendWeights == SIMD4<Float>(1, 0, 0, 0))
        #expect(vertex.position == SIMD3<Float>(149.086, -686.59, 0))
        #expect(vertex.uv == SIMD2<Float>(0.65, 0.198))
    }

    @Test("MDLV23 skeleton fixture audit accounts for every byte")
    func auditAccountsForMDLV23SkeletonFixture() throws {
        var audit: WPEMdlParseAudit?
        let model = try WPEMdlParser.parse(data: makeSkinnedMDLV23WithSkeleton(), audit: &audit)
        let parseAudit = try #require(audit)

        #expect(model.version == 23)
        #expect(parseAudit.sections.contains { $0.kind == .mdlvMesh })
        #expect(parseAudit.sections.contains { $0.kind == .mdls })
        #expect(parseAudit.unexplainedGaps.isEmpty)
        #expect(parseAudit.trailingLeftover == nil)
    }

    @Test("MDLV19 fixture audit accounts for every byte")
    func auditAccountsForMDLV19Fixture() throws {
        var audit: WPEMdlParseAudit?
        let model = try WPEMdlParser.parse(data: makeSingleVertexSkinnedMDLV19(), audit: &audit)
        let parseAudit = try #require(audit)

        #expect(model.version == 19)
        #expect(parseAudit.sections.contains { $0.kind == .mdlvMesh })
        #expect(parseAudit.unexplainedGaps.isEmpty)
        #expect(parseAudit.trailingLeftover == nil)
    }

    @Test("Audit surfaces bytes appended after the parsed MDL")
    func auditSurfacesTrailingLeftoverBytes() throws {
        var data = makeSingleVertexSkinnedMDLV19()
        let junkRangeStart = data.count
        data.append(contentsOf: [0xde, 0xad, 0xbe, 0xef])
        var audit: WPEMdlParseAudit?

        _ = try WPEMdlParser.parse(data: data, audit: &audit)
        let parseAudit = try #require(audit)

        #expect(parseAudit.unexplainedGaps.isEmpty)
        #expect(parseAudit.trailingLeftover == junkRangeStart..<data.count)
    }

    @Test("Parses MDLV16 scene model header with the leading meshCount byte")
    func parsesMDLV16SceneModelHeaderWithLeadingByte() throws {
        // Scene 3509243656 ships a static scene model (`models/Hollow Cylinder/...mdl`)
        // as MDLV0016 with the same leading-byte header as modern puppets. Reading
        // it through the legacy v14 layout shifts the material string by one byte
        // and turns the vertex byte count into garbage, aborting the entire scene.
        let model = try WPEMdlParser.parse(data: makeSingleTriangleMDLV16SceneModel())
        let mesh = try #require(model.meshes.first)

        #expect(model.version == 16)
        #expect(model.meshes.count == 1)
        #expect(mesh.materialPath == "materials/models/Hollow Cylinder/diffuse_0.json")
        #expect(mesh.vertices.count == 3)
        #expect(mesh.vertices[0].position == SIMD3<Float>(-1, -1, 0))
        #expect(mesh.vertices[1].position == SIMD3<Float>(1, -1, 0))
        #expect(mesh.vertices[2].position == SIMD3<Float>(0, 1, 0))
        #expect(mesh.indices == [0, 1, 2])
    }

    @Test("Preserves MDLV vertex positions when MDLS skeleton metadata is present")
    func preservesVertexPositionsWithSkeletonMetadata() throws {
        let model = try WPEMdlParser.parse(data: makeSkinnedMDLV23WithSkeleton())
        let mesh = try #require(model.meshes.first)

        #expect(model.bones.count == 1)
        #expect(mesh.vertices[0].position == SIMD3<Float>(10, 20, 0))
    }

    @Test("Parses MDLS skeleton records separated by an optional trailing marker byte")
    func parsesSkeletonRecordsWithTrailingMarkerBytes() throws {
        let model = try WPEMdlParser.parse(data: makeSkinnedMDLV23WithSkeletonTrailingMarker())

        #expect(model.bones.count == 2)
        #expect(model.bones[0].parentIndex == nil)
        #expect(model.bones[0].rawMatrix[12] == 5)
        #expect(model.bones[0].rawMatrix[13] == -7)
        #expect(model.bones[1].parentIndex == 0)
        #expect(model.bones[1].rawMatrix[12] == 12)
        #expect(model.bones[1].rawMatrix[13] == -34)
    }

    @Test("Retains the raw MDLS bone-name string (often a rig-physics JSON blob)")
    func retainsBoneNameString() throws {
        let model = try WPEMdlParser.parse(data: makeSkinnedMDLV23WithBoneNameJSON())

        #expect(model.bones.count == 1)
        // The name field carries a rig-physics JSON blob in the real corpus; it must survive verbatim,
        // unparsed, so a future runtime can consume it.
        #expect(model.bones[0].name == #"{"tm":null,"tp":[1.0,2.0,3.0]}"#)
    }

    @Test("Recovers mesh geometry when the MDLS skeleton section is malformed")
    func recoversMeshGeometryWhenSkeletonSectionMalformed() throws {
        // A corrupt or edge-case skeleton must not discard the already-parsed meshes:
        // the renderer draws the static assembled mesh and treats bones as optional
        // metadata. Regression for MDLV0023 scene 3479521040 "人物", whose MDLS0004
        // skeleton trips the trailing-marker heuristic and previously collapsed the
        // whole puppet to nil -> a flat, scattered atlas.
        let model = try WPEMdlParser.parse(data: makeMDLV23WithCorruptSkeleton())
        let mesh = try #require(model.meshes.first)

        // Recover indexed geometry, not just vertices: encodePuppetMaterialPassIfNeeded
        // filters out meshes with empty indices, so the recovered mesh must be drawable.
        #expect(mesh.vertices.count == 3)
        #expect(mesh.vertices[0].position == SIMD3<Float>(10, 20, 0))
        #expect(mesh.indices == [0, 1, 2])
        #expect(model.bones.isEmpty)
    }

    @Test("Parses MDLA0006 baked TRS animation channels")
    func parsesMDLA0006Animation() throws {
        let model = try WPEMdlParser.parse(data: makeMDLV23WithAnimation())
        let animation = try #require(model.animations.first)

        #expect(model.animations.count == 1)
        #expect(animation.id == 267)
        #expect(animation.name == "动画 1")
        #expect(animation.mode == "loop")
        #expect(animation.fps == 30)
        #expect(animation.frameCount == 1)
        #expect(animation.channels.count == 2)
        // (frameCount + 1) keyframes are stored per channel (frame 0...frameCount).
        #expect(animation.channels[0].boneIndex == 0)
        #expect(animation.channels[0].keyframes.count == 2)
        #expect(animation.channels[0].keyframes[0].translation == SIMD3<Float>(1, 2, 3))
        #expect(animation.channels[0].keyframes[0].scale == SIMD3<Float>(1, 1, 1))
        #expect(animation.channels[0].keyframes[1].translation == SIMD3<Float>(4, 5, 6))
        #expect(animation.channels[1].boneIndex == 1)
        #expect(animation.channels[1].keyframes[0].translation == SIMD3<Float>(7, 8, 9))
        #expect(animation.channels[1].keyframes[1].euler == SIMD3<Float>(0, 0, 0))
    }

    @Test("Recovers mesh and animations when the skeleton is malformed but MDLA is valid")
    func recoversAnimationWhenSkeletonMalformed() throws {
        // Mirrors 3479521040/人物: the MDLS skeleton fails (bones dropped) yet the mesh stays
        // drawable and the MDLA animation parses independently to drive P2b skinning.
        let model = try WPEMdlParser.parse(data: makeMDLV23WithCorruptSkeletonAndAnimation())

        #expect(model.bones.isEmpty)
        #expect(model.meshes.first?.indices == [0, 1, 2])
        #expect(model.animations.count == 1)
        #expect(model.animations.first?.channels.count == 2)
        #expect(
            model.animations.first?.channels[1].keyframes[1].translation == SIMD3<Float>(10, 11, 12)
        )
    }

    @Test("Preserves atlas target geometry when MDLE element matrices are present")
    func preservesAtlasTargetGeometryWithElementMatrices() throws {
        let model = try WPEMdlParser.parse(data: makeMDLV23WithElementMetadata())
        let mesh = try #require(model.meshes.first)

        #expect(mesh.vertices[0].position == SIMD3<Float>(0, 0, 0))
        #expect(mesh.vertices[1].position == SIMD3<Float>(10, 0, 0))
        #expect(mesh.vertices[2].position == SIMD3<Float>(0, 10, 0))
        #expect(mesh.vertices[3].position == SIMD3<Float>(20, 0, 0))
        #expect(mesh.vertices[4].position == SIMD3<Float>(30, 0, 0))
        #expect(mesh.vertices[5].position == SIMD3<Float>(20, 10, 0))
    }

    // MARK: - Hostile-count guards (crafted Workshop files must throw, not OOM-trap)

    @Test("Rejects a header claiming a huge mesh count instead of OOM-allocating")
    func rejectsHugeMeshCount() {
        var data = Data()
        data.append(contentsOf: Array("MDLV0023".utf8))
        data.appendLE(UInt32(0x80000900))
        data.append(UInt8(1))
        data.appendLE(UInt32.max)        // meshCount
        data.appendLE(UInt32(1))

        #expect(throws: WPEMdlParserError.implausibleCount(
            section: "MDLV meshCount", count: .max, limit: 4_096
        )) {
            _ = try WPEMdlParser.parse(data: data)
        }
    }

    @Test("Rejects a vertex buffer byte count larger than the remaining file")
    func rejectsOversizedVertexBuffer() {
        var data = Data()
        data.append(contentsOf: Array("MDLV0023".utf8))
        data.appendLE(UInt32(0x80000900))
        data.append(UInt8(1))
        data.appendLE(UInt32(1))
        data.appendLE(UInt32(1))

        data.appendCString("materials/test.json")
        data.appendLE(UInt32(0))
        for _ in 0..<6 { data.appendLE(Float(0)) }
        data.appendLE(UInt32(0x180000f))
        // Stride-aligned (80-byte vertices) but ~4 GB over a near-empty buffer.
        data.appendLE(UInt32(4_000_000_000))

        #expect(throws: WPEMdlParserError.invalidVertexBuffer(byteCount: 4_000_000_000, stride: 80)) {
            _ = try WPEMdlParser.parse(data: data)
        }
    }

    @Test("Rejects an index buffer byte count larger than the remaining file")
    func rejectsOversizedIndexBuffer() {
        var data = Data()
        data.append(contentsOf: Array("MDLV0023".utf8))
        data.appendLE(UInt32(0x80000900))
        data.append(UInt8(1))
        data.appendLE(UInt32(1))
        data.appendLE(UInt32(1))

        data.appendCString("materials/test.json")
        data.appendLE(UInt32(0))
        for _ in 0..<6 { data.appendLE(Float(0)) }
        data.appendLE(UInt32(0x180000f))
        let vertexData = Data.puppetVertices([
            (SIMD3<Float>(10, 20, 0), SIMD2<Float>(0.5, 0.5))
        ])
        data.appendLE(UInt32(vertexData.count))
        data.append(vertexData)
        // UInt16-aligned but far beyond the remaining bytes.
        data.appendLE(UInt32(4_294_967_294))

        #expect(throws: WPEMdlParserError.invalidIndexBuffer(4_294_967_294)) {
            _ = try WPEMdlParser.parse(data: data)
        }
    }

    @Test("Rejects a part table byte count larger than the remaining file")
    func rejectsOversizedPartTable() {
        var data = Data()
        data.append(contentsOf: Array("MDLV0023".utf8))
        data.appendLE(UInt32(0x80000900))
        data.append(UInt8(1))
        data.appendLE(UInt32(1))
        data.appendLE(UInt32(1))

        data.appendCString("materials/test.json")
        data.appendLE(UInt32(0))
        for _ in 0..<6 { data.appendLE(Float(0)) }
        data.appendLE(UInt32(0x180000f))
        let vertexData = Data.puppetVertices([
            (SIMD3<Float>(10, 20, 0), SIMD2<Float>(0.5, 0.5))
        ])
        data.appendLE(UInt32(vertexData.count))
        data.append(vertexData)
        data.appendLE(UInt32(0))         // index byte count
        data.append(UInt8(0))            // uv2 marker
        data.append(UInt8(1))            // hasParts
        // 16-aligned but ~4 GB over an empty tail.
        data.appendLE(UInt32(4_294_967_040))

        #expect(throws: WPEMdlParserError.invalidPartTable(4_294_967_040)) {
            _ = try WPEMdlParser.parse(data: data)
        }
    }

    @Test("Recovers the mesh when a skeleton claims a huge bone count, without OOM-allocating")
    func recoversFromHugeBoneCount() throws {
        var data = makeSingleVertexSkinnedMDLV23()
        data.append(contentsOf: Array("MDLS0004".utf8))
        data.append(UInt8(0))
        data.appendLE(UInt32(0))         // sectionEnd
        data.appendLE(UInt32.max)        // boneCount

        // Skeleton metadata is optional: the implausible count must abort the MDLS section
        // (previously a multi-GB reserveCapacity trap) while the mesh stays renderable.
        let model = try WPEMdlParser.parse(data: data)
        #expect(model.bones.isEmpty)
        #expect(model.meshes.first?.vertices.count == 1)
    }

    private func makeSingleTriangleMDLV23() -> Data {
        var data = Data()
        data.append(contentsOf: Array("MDLV0023".utf8))
        data.appendLE(UInt32(0x80000900))
        data.append(UInt8(1))
        data.appendLE(UInt32(1))
        data.appendLE(UInt32(1))

        data.appendCString("materials/test.json")
        data.appendLE(UInt32(0))
        data.appendLE(Float(-10))
        data.appendLE(Float(-20))
        data.appendLE(Float(0))
        data.appendLE(Float(10))
        data.appendLE(Float(20))
        data.appendLE(Float(0))
        data.appendLE(UInt32(0x180000f))
        let vertexData = Data.puppetVertices([
            (SIMD3<Float>(-10, -20, 0), SIMD2<Float>(0, 1)),
            (SIMD3<Float>(10, -20, 0), SIMD2<Float>(1, 1)),
            (SIMD3<Float>(0, 20, 0), SIMD2<Float>(0.5, 0))
        ])
        data.appendLE(UInt32(vertexData.count))
        data.append(vertexData)

        data.appendLE(UInt32(3 * MemoryLayout<UInt16>.size))
        data.appendLE(UInt16(0))
        data.appendLE(UInt16(1))
        data.appendLE(UInt16(2))

        data.append(UInt8(0))
        data.append(UInt8(1))
        data.appendLE(UInt32(16))
        data.appendLE(UInt32(7))
        data.appendLE(UInt32(0))
        data.appendLE(UInt32(0))
        data.appendLE(UInt32(3))

        return data
    }

    private func makeSkinnedMDLV23WithSkeleton() -> Data {
        makeSkinnedMDLV23WithSkeleton(boneName: "{}")
    }

    /// Single-bone MDLV0023 skeleton whose bone-name cstring is `boneName`. The MDLS section-end offset
    /// must account for the name length so the parser consumes the whole record.
    private func makeSkinnedMDLV23WithSkeleton(boneName: String) -> Data {
        var data = Data()
        data.append(contentsOf: Array("MDLV0023".utf8))
        data.appendLE(UInt32(0x80000900))
        data.append(UInt8(1))
        data.appendLE(UInt32(1))
        data.appendLE(UInt32(1))

        data.appendCString("materials/test.json")
        data.appendLE(UInt32(0))
        data.appendLE(Float(0))
        data.appendLE(Float(0))
        data.appendLE(Float(0))
        data.appendLE(Float(0))
        data.appendLE(Float(0))
        data.appendLE(Float(0))
        data.appendLE(UInt32(0x180000f))
        let vertexData = Data.puppetVertices([
            (SIMD3<Float>(10, 20, 0), SIMD2<Float>(0.5, 0.5))
        ])
        data.appendLE(UInt32(vertexData.count))
        data.append(vertexData)

        data.appendLE(UInt32(0))
        data.append(UInt8(0))
        data.append(UInt8(0))

        let nameByteCount = Array(boneName.utf8).count + 1
        data.append(contentsOf: Array("MDLS0004".utf8))
        data.append(UInt8(0))
        data.appendLE(UInt32(data.count + 1 + 4 + 4 + 4 + 1 + 4 + 4 + (16 * 4) + nameByteCount))
        data.appendLE(UInt32(1))
        data.appendLE(UInt32(0))
        data.append(UInt8(0))
        data.appendLE(UInt32.max)
        data.appendLE(UInt32(16 * 4))
        Data.appendMatrix(
            to: &data,
            rows: [
                [1, 0, 0, 0],
                [0, 1, 0, 0],
                [0, 0, 1, 0],
                [5, -7, 0, 1]
            ]
        )
        data.appendCString(boneName)

        return data
    }

    private func makeSkinnedMDLV23WithBoneNameJSON() -> Data {
        makeSkinnedMDLV23WithSkeleton(boneName: #"{"tm":null,"tp":[1.0,2.0,3.0]}"#)
    }

    private func makeMDLV23WithAnimation() -> Data {
        var data = Data()
        data.append(contentsOf: Array("MDLV0023".utf8))
        data.appendLE(UInt32(0x80000900))
        data.append(UInt8(1))
        data.appendLE(UInt32(1))
        data.appendLE(UInt32(1))

        data.appendCString("materials/test.json")
        data.appendLE(UInt32(0))
        for _ in 0..<6 { data.appendLE(Float(0)) }
        data.appendLE(UInt32(0x180000f))
        let vertexData = Data.puppetVertices([
            (SIMD3<Float>(10, 20, 0), SIMD2<Float>(0.5, 0.5))
        ])
        data.appendLE(UInt32(vertexData.count))
        data.append(vertexData)

        data.appendLE(UInt32(0))
        data.append(UInt8(0))
        data.append(UInt8(0))

        appendMDLA0006Section(to: &data)
        return data
    }

    private func appendMDLA0006Section(to data: inout Data) {
        func appendKey(_ t: SIMD3<Float>, _ r: SIMD3<Float>, _ s: SIMD3<Float>) {
            for value in [t.x, t.y, t.z, r.x, r.y, r.z, s.x, s.y, s.z] {
                data.appendLE(value)
            }
        }
        let frameCount: UInt32 = 1
        let channelByteCount = (frameCount + 1) * UInt32(9 * MemoryLayout<Float>.size)

        data.append(contentsOf: Array("MDLA0006".utf8))
        data.append(UInt8(0))
        data.appendLE(UInt32.max)        // sectionEnd -> clamps to data count
        data.appendLE(UInt32(1))         // animationCount
        data.appendLE(UInt32(267))       // id
        data.appendLE(UInt32(0))
        data.appendCString("动画 1")
        data.appendCString("loop")
        data.appendLE(Float(30))
        data.appendLE(frameCount)
        data.appendLE(UInt32(0))
        data.appendLE(UInt32(2))         // channelCount
        data.appendLE(UInt32(0))
        data.appendLE(channelByteCount)

        appendKey(SIMD3<Float>(1, 2, 3), SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 1, 1))
        appendKey(SIMD3<Float>(4, 5, 6), SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 1, 1))
        data.appendLE(UInt32(0))
        data.appendLE(channelByteCount)
        appendKey(SIMD3<Float>(7, 8, 9), SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 1, 1))
        appendKey(SIMD3<Float>(10, 11, 12), SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 1, 1))
    }

    private func makeMDLV23WithCorruptSkeletonAndAnimation() -> Data {
        var data = makeMDLV23WithCorruptSkeleton()
        appendMDLA0006Section(to: &data)
        return data
    }

    private func makeMDLV23WithCorruptSkeleton() -> Data {
        var data = Data()
        data.append(contentsOf: Array("MDLV0023".utf8))
        data.appendLE(UInt32(0x80000900))
        data.append(UInt8(1))
        data.appendLE(UInt32(1))
        data.appendLE(UInt32(1))

        data.appendCString("materials/test.json")
        data.appendLE(UInt32(0))
        for _ in 0..<6 { data.appendLE(Float(0)) }
        data.appendLE(UInt32(0x180000f))
        let vertexData = Data.puppetVertices([
            (SIMD3<Float>(10, 20, 0), SIMD2<Float>(0.5, 0.5)),
            (SIMD3<Float>(20, 20, 0), SIMD2<Float>(1, 0.5)),
            (SIMD3<Float>(10, 30, 0), SIMD2<Float>(0.5, 1))
        ])
        data.appendLE(UInt32(vertexData.count))
        data.append(vertexData)

        data.appendLE(UInt32(3 * MemoryLayout<UInt16>.size))
        data.appendLE(UInt16(0))
        data.appendLE(UInt16(1))
        data.appendLE(UInt16(2))
        data.append(UInt8(0))
        data.append(UInt8(0))

        // Malformed skeleton: declares one bone but with an invalid matrix byte
        // count (< 64 and not a multiple of 4) so parseSkeletonIfPresent throws.
        data.append(contentsOf: Array("MDLS0004".utf8))
        data.append(UInt8(0))
        data.appendLE(UInt32(0))
        data.appendLE(UInt32(1))
        data.appendLE(UInt32(0))
        data.append(UInt8(0))
        data.appendLE(UInt32.max)
        data.appendLE(UInt32(10))
        data.append(contentsOf: [UInt8](repeating: 0, count: 10))
        return data
    }

    private func makeSingleVertexSkinnedMDLV23() -> Data {
        var data = Data()
        data.append(contentsOf: Array("MDLV0023".utf8))
        data.appendLE(UInt32(0x80000900))
        data.append(UInt8(1))
        data.appendLE(UInt32(1))
        data.appendLE(UInt32(1))

        data.appendCString("materials/test.json")
        data.appendLE(UInt32(0))
        for _ in 0..<6 { data.appendLE(Float(0)) }
        data.appendLE(UInt32(0x180000f))

        var vertex = Data()
        vertex.appendLE(Float(149.086)); vertex.appendLE(Float(-686.59)); vertex.appendLE(Float(0))
        vertex.appendLE(Float(0)); vertex.appendLE(Float(0)); vertex.appendLE(Float(1))
        vertex.appendLE(Float(1)); vertex.appendLE(Float(0)); vertex.appendLE(Float(0)); vertex.appendLE(Float(1))
        vertex.appendLE(UInt32(7)); vertex.appendLE(UInt32(1)); vertex.appendLE(UInt32(1)); vertex.appendLE(UInt32(1))
        vertex.appendLE(Float(1)); vertex.appendLE(Float(0)); vertex.appendLE(Float(0)); vertex.appendLE(Float(0))
        vertex.appendLE(Float(0.65)); vertex.appendLE(Float(0.198))
        data.appendLE(UInt32(vertex.count))
        data.append(vertex)

        data.appendLE(UInt32(0))
        data.append(UInt8(0))
        data.append(UInt8(0))

        return data
    }

    /// MDLV0019 single skinned vertex. Mirrors `makeSingleVertexSkinnedMDLV23`
    /// byte-for-byte except for the version tag and the absence of the v21+
    /// parts trailer, matching the real corpus layout (mesh data runs straight
    /// into the skeleton section). Used to lock the `version >= 19` header gate.
    private func makeSingleVertexSkinnedMDLV19() -> Data {
        var data = Data()
        data.append(contentsOf: Array("MDLV0019".utf8))
        data.appendLE(UInt32(0x80000900))
        data.append(UInt8(1))
        data.appendLE(UInt32(1))
        data.appendLE(UInt32(1))

        data.appendCString("materials/test.json")
        data.appendLE(UInt32(0))
        for _ in 0..<6 { data.appendLE(Float(0)) }
        data.appendLE(UInt32(0x180000f))

        var vertex = Data()
        vertex.appendLE(Float(149.086)); vertex.appendLE(Float(-686.59)); vertex.appendLE(Float(0))
        vertex.appendLE(Float(0)); vertex.appendLE(Float(0)); vertex.appendLE(Float(1))
        vertex.appendLE(Float(1)); vertex.appendLE(Float(0)); vertex.appendLE(Float(0)); vertex.appendLE(Float(1))
        vertex.appendLE(UInt32(7)); vertex.appendLE(UInt32(1)); vertex.appendLE(UInt32(1)); vertex.appendLE(UInt32(1))
        vertex.appendLE(Float(1)); vertex.appendLE(Float(0)); vertex.appendLE(Float(0)); vertex.appendLE(Float(0))
        vertex.appendLE(Float(0.65)); vertex.appendLE(Float(0.198))
        data.appendLE(UInt32(vertex.count))
        data.append(vertex)

        data.appendLE(UInt32(0))

        return data
    }

    private func makeSingleTriangleMDLV16SceneModel() -> Data {
        var data = Data()
        data.append(contentsOf: Array("MDLV0016".utf8))
        data.appendLE(UInt32(0x00000f00))
        data.append(UInt8(0))
        data.appendLE(UInt32(1))
        data.appendLE(UInt32(1))

        data.appendCString("materials/models/Hollow Cylinder/diffuse_0.json")
        data.appendLE(UInt32(0))
        data.appendLE(UInt32(0x0000000f))

        var vertices = Data()
        vertices.appendSceneModelVertex(position: SIMD3<Float>(-1, -1, 0), uv: SIMD2<Float>(0, 1))
        vertices.appendSceneModelVertex(position: SIMD3<Float>(1, -1, 0), uv: SIMD2<Float>(1, 1))
        vertices.appendSceneModelVertex(position: SIMD3<Float>(0, 1, 0), uv: SIMD2<Float>(0.5, 0))
        data.appendLE(UInt32(vertices.count))
        data.append(vertices)

        data.appendLE(UInt32(3 * MemoryLayout<UInt16>.size))
        data.appendLE(UInt16(0))
        data.appendLE(UInt16(1))
        data.appendLE(UInt16(2))

        return data
    }

    private func makeSkinnedMDLV23WithSkeletonTrailingMarker() -> Data {
        var data = Data()
        data.append(contentsOf: Array("MDLV0023".utf8))
        data.appendLE(UInt32(0x80000900))
        data.append(UInt8(1))
        data.appendLE(UInt32(1))
        data.appendLE(UInt32(1))

        data.appendCString("materials/test.json")
        data.appendLE(UInt32(0))
        for _ in 0..<6 { data.appendLE(Float(0)) }
        data.appendLE(UInt32(0x180000f))
        let vertexData = Data.puppetVertices([
            (SIMD3<Float>(10, 20, 0), SIMD2<Float>(0.5, 0.5))
        ])
        data.appendLE(UInt32(vertexData.count))
        data.append(vertexData)

        data.appendLE(UInt32(0))
        data.append(UInt8(0))
        data.append(UInt8(0))

        data.append(contentsOf: Array("MDLS0004".utf8))
        data.append(UInt8(0))
        let sectionEndPatchOffset = data.count
        data.appendLE(UInt32(0))
        data.appendLE(UInt32(2))

        data.appendSkeletonRecord(parent: nil, translation: SIMD3<Float>(5, -7, 0))
        data.append(UInt8(0x31))
        data.appendSkeletonRecord(parent: 0, translation: SIMD3<Float>(12, -34, 0))

        let sectionEnd = data.count
        data.replaceLE(UInt32(sectionEnd), at: sectionEndPatchOffset)
        data.append(contentsOf: Array("MDLA0006".utf8))

        return data
    }

    private func makeMDLV23WithElementMetadata() -> Data {
        var data = Data()
        data.append(contentsOf: Array("MDLV0023".utf8))
        data.appendLE(UInt32(0x80000900))
        data.append(UInt8(1))
        data.appendLE(UInt32(1))
        data.appendLE(UInt32(1))

        data.appendCString("materials/test.json")
        data.appendLE(UInt32(0))
        data.appendLE(Float(0))
        data.appendLE(Float(0))
        data.appendLE(Float(0))
        data.appendLE(Float(0))
        data.appendLE(Float(0))
        data.appendLE(Float(0))
        data.appendLE(UInt32(0x180000f))
        let vertexData = Data.puppetVertices([
            (SIMD3<Float>(0, 0, 0), SIMD2<Float>(0, 0)),
            (SIMD3<Float>(10, 0, 0), SIMD2<Float>(1, 0)),
            (SIMD3<Float>(0, 10, 0), SIMD2<Float>(0, 1)),
            (SIMD3<Float>(20, 0, 0), SIMD2<Float>(0, 0)),
            (SIMD3<Float>(30, 0, 0), SIMD2<Float>(1, 0)),
            (SIMD3<Float>(20, 10, 0), SIMD2<Float>(0, 1))
        ])
        data.appendLE(UInt32(vertexData.count))
        data.append(vertexData)

        let indices: [UInt16] = [0, 1, 2, 2, 1, 0, 3, 4, 5, 5, 4, 3]
        data.appendLE(UInt32(indices.count * MemoryLayout<UInt16>.size))
        for index in indices {
            data.appendLE(index)
        }

        data.append(UInt8(0))
        data.append(UInt8(1))
        data.appendLE(UInt32(2 * 16))
        data.appendLE(UInt32(1))
        data.appendLE(UInt32(0))
        data.appendLE(UInt32(0))
        data.appendLE(UInt32(6))
        data.appendLE(UInt32(2))
        data.appendLE(UInt32(0))
        data.appendLE(UInt32(6))
        data.appendLE(UInt32(6))

        data.appendSkeleton([
            (parent: nil, translation: SIMD3<Float>(0, 0, 0)),
            (parent: 0, translation: SIMD3<Float>(10, 20, 0)),
            (parent: 0, translation: SIMD3<Float>(30, 40, 0))
        ])
        data.appendElementMatrices([
            SIMD3<Float>(0, 0, 0),
            SIMD3<Float>(12, -30, 0),
            SIMD3<Float>(25, 5, 0)
        ])

        return data
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: Float) {
        appendLE(value.bitPattern)
    }

    mutating func appendCString(_ string: String) {
        append(contentsOf: Array(string.utf8))
        append(UInt8(0))
    }

    mutating func replaceLE(_ value: UInt32, at offset: Int) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) {
            replaceSubrange(offset..<(offset + MemoryLayout<UInt32>.size), with: $0)
        }
    }

    mutating func appendSkeletonRecord(parent: Int?, translation: SIMD3<Float>) {
        appendLE(UInt32(0))
        append(UInt8(0))
        appendLE(parent.map(UInt32.init) ?? UInt32.max)
        appendLE(UInt32(16 * MemoryLayout<Float>.size))
        Data.appendMatrix(
            to: &self,
            rows: [
                [1, 0, 0, 0],
                [0, 1, 0, 0],
                [0, 0, 1, 0],
                [translation.x, translation.y, translation.z, 1]
            ]
        )
        appendCString("{}")
    }

    static func puppetVertices(_ vertices: [(position: SIMD3<Float>, uv: SIMD2<Float>)]) -> Data {
        var data = Data()
        for vertex in vertices {
            data.appendLE(vertex.position.x)
            data.appendLE(vertex.position.y)
            data.appendLE(vertex.position.z)
            data.appendLE(Float(0))
            data.appendLE(Float(0))
            data.appendLE(Float(1))
            data.appendLE(Float(1))
            data.appendLE(Float(0))
            data.appendLE(Float(0))
            data.appendLE(Float(1))
            data.appendLE(Float(0))
            data.appendLE(Float(0))
            data.appendLE(Float(0))
            data.appendLE(Float(0))
            data.appendLE(Float(1))
            data.appendLE(Float(0))
            data.appendLE(Float(0))
            data.appendLE(Float(0))
            data.appendLE(vertex.uv.x)
            data.appendLE(vertex.uv.y)
        }
        return data
    }

    mutating func appendSceneModelVertex(position: SIMD3<Float>, uv: SIMD2<Float>) {
        appendLE(position.x)
        appendLE(position.y)
        appendLE(position.z)
        appendLE(Float(0))
        appendLE(Float(0))
        appendLE(Float(1))
        appendLE(Float(1))
        appendLE(Float(0))
        appendLE(Float(0))
        appendLE(Float(1))
        appendLE(uv.x)
        appendLE(uv.y)
    }

    static func appendMatrix(to data: inout Data, rows: [[Float]]) {
        for row in rows {
            for value in row {
                data.appendLE(value)
            }
        }
    }

    mutating func appendSkeleton(_ bones: [(parent: Int?, translation: SIMD3<Float>)]) {
        append(contentsOf: Array("MDLS0004".utf8))
        append(UInt8(0))
        appendLE(UInt32(0))
        appendLE(UInt32(bones.count))
        for (index, bone) in bones.enumerated() {
            appendLE(UInt32(index))
            append(UInt8(0))
            appendLE(bone.parent.map(UInt32.init) ?? UInt32.max)
            appendLE(UInt32(16 * MemoryLayout<Float>.size))
            Data.appendMatrix(
                to: &self,
                rows: [
                    [1, 0, 0, 0],
                    [0, 1, 0, 0],
                    [0, 0, 1, 0],
                    [bone.translation.x, bone.translation.y, bone.translation.z, 1]
                ]
            )
            appendCString("{}")
        }
    }

    mutating func appendElementMatrices(_ translations: [SIMD3<Float>]) {
        append(contentsOf: Array("MDLE0002".utf8))
        append(UInt8(0))
        appendLE(UInt32(0))
        appendLE(UInt32(translations.count * 16 * MemoryLayout<Float>.size))
        for translation in translations {
            Data.appendMatrix(
                to: &self,
                rows: [
                    [1, 0, 0, 0],
                    [0, 1, 0, 0],
                    [0, 0, 1, 0],
                    [translation.x, translation.y, translation.z, 1]
                ]
            )
        }
    }
}
