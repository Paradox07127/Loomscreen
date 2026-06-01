import Foundation
import Testing
@testable import LiveWallpaper

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

        data.append(contentsOf: Array("MDLS0004".utf8))
        data.append(UInt8(0))
        data.appendLE(UInt32(data.count + 1 + 4 + 4 + 4 + 1 + 4 + 4 + (16 * 4) + 3))
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
        data.appendCString("{}")

        return data
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
        data.appendLE(UInt32(0))         // reserved
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
