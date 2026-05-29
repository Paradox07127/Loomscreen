#if !LITE_BUILD
import Foundation

struct WPEPuppetModel: Equatable, Sendable {
    let version: Int
    let meshes: [WPEPuppetMesh]
    let bones: [WPEPuppetBone]

    init(version: Int, meshes: [WPEPuppetMesh], bones: [WPEPuppetBone] = []) {
        self.version = version
        self.meshes = meshes
        self.bones = bones
    }
}

struct WPEPuppetMesh: Equatable, Sendable {
    let materialPath: String
    let vertices: [WPEPuppetVertex]
    let indices: [UInt16]
    let parts: [WPEPuppetMeshPart]
}

struct WPEPuppetVertex: Equatable, Sendable {
    /// Object-local target geometry. Do not derive this from `uv`: puppet textures can be atlases.
    let position: SIMD3<Float>
    /// Source texture sampling coordinate inside the material atlas.
    let uv: SIMD2<Float>
    let skinBlendIndices: SIMD4<Int32>
    let skinBlendWeights: SIMD4<Float>

    init(
        position: SIMD3<Float>,
        uv: SIMD2<Float>,
        skinBlendIndices: SIMD4<Int32> = SIMD4<Int32>(0, 0, 0, 0),
        skinBlendWeights: SIMD4<Float> = SIMD4<Float>(1, 0, 0, 0)
    ) {
        self.position = position
        self.uv = uv
        self.skinBlendIndices = skinBlendIndices
        self.skinBlendWeights = skinBlendWeights
    }
}

struct WPEPuppetBone: Equatable, Sendable {
    let index: Int
    let parentIndex: Int?
    /// Raw MDLS metadata retained for future runtime animation. Parser must not bake it into MDLV vertices.
    let rawMatrix: [Float]
}

struct WPEPuppetMeshPart: Equatable, Sendable {
    let id: UInt32
    let start: Int
    let count: Int
}

enum WPEMdlParser {
    static func parse(data: Data) throws -> WPEPuppetModel {
        var reader = WPEMdlBinaryReader(data: data)
        let versionTag = try reader.readFixedString(byteCount: 8)
        guard versionTag.hasPrefix("MDLV"),
              let version = Int(versionTag.dropFirst(4)) else {
            throw WPEMdlParserError.invalidHeader
        }

        let headerMeshFlags = try reader.readUInt32()
        let meshCount: UInt32
        if version >= 23 {
            _ = try reader.readUInt8()
            meshCount = try reader.readUInt32()
            _ = try reader.readUInt32()
        } else {
            _ = try reader.readUInt32()
            meshCount = try reader.readUInt32()
        }
        var meshes: [WPEPuppetMesh] = []
        meshes.reserveCapacity(Int(meshCount))

        for _ in 0..<meshCount {
            meshes.append(try parseMesh(
                version: version,
                headerMeshFlags: headerMeshFlags,
                reader: &reader
            ))
        }

        // MDLV positions are already the static target geometry. Keep trailing skeleton
        // metadata available without applying MDLS/MDLE transforms in the parser.
        let bones = try parseSkeletonIfPresent(reader: &reader)
        return WPEPuppetModel(version: version, meshes: meshes, bones: bones)
    }

    private static func parseMesh(
        version: Int,
        headerMeshFlags: UInt32,
        reader: inout WPEMdlBinaryReader
    ) throws -> WPEPuppetMesh {
        let materialPath = try reader.readCString()
        let flagA = try reader.readUInt32()
        if flagA == 2 {
            _ = try reader.readUInt32()
        }
        if version >= 17 {
            try reader.skip(byteCount: 6 * MemoryLayout<Float>.size)
        }
        let meshFlags = version > 14 ? try reader.readUInt32() : headerMeshFlags
        let vertexByteCount = try reader.readUInt32()
        let vertexStride = stride(for: meshFlags)
        guard vertexStride > 0, vertexByteCount % UInt32(vertexStride) == 0 else {
            throw WPEMdlParserError.invalidVertexBuffer(byteCount: vertexByteCount, stride: vertexStride)
        }
        let vertexCount = vertexByteCount / UInt32(vertexStride)
        var vertices: [WPEPuppetVertex] = []
        vertices.reserveCapacity(Int(vertexCount))

        for _ in 0..<vertexCount {
            vertices.append(try parseVertex(meshFlags: meshFlags, reader: &reader))
        }

        let indexByteCount = try reader.readUInt32()
        guard indexByteCount % UInt32(MemoryLayout<UInt16>.size) == 0 else {
            throw WPEMdlParserError.invalidIndexBuffer(indexByteCount)
        }
        let indexCount = indexByteCount / UInt32(MemoryLayout<UInt16>.size)
        var indices: [UInt16] = []
        indices.reserveCapacity(Int(indexCount))
        for _ in 0..<indexCount {
            indices.append(try reader.readUInt16())
        }

        let parts = version >= 21
            ? try parseVersion21Parts(vertexCount: Int(vertexCount), reader: &reader)
            : []

        return WPEPuppetMesh(
            materialPath: materialPath,
            vertices: vertices,
            indices: indices,
            parts: parts
        )
    }

    private static func parseVertex(
        meshFlags: UInt32,
        reader: inout WPEMdlBinaryReader
    ) throws -> WPEPuppetVertex {
        let position = SIMD3<Float>(
            try reader.readFloat(),
            try reader.readFloat(),
            try reader.readFloat()
        )

        if meshFlags & WPEMdlMeshFlags.normal != 0 {
            try reader.skip(byteCount: 3 * MemoryLayout<Float>.size)
        }
        if meshFlags & WPEMdlMeshFlags.tangent != 0 {
            try reader.skip(byteCount: 4 * MemoryLayout<Float>.size)
        }
        if meshFlags & WPEMdlMeshFlags.extra4 != 0 {
            try reader.skip(byteCount: 4 * MemoryLayout<Float>.size)
        }
        var skinBlendIndices = SIMD4<Int32>(0, 0, 0, 0)
        var skinBlendWeights = SIMD4<Float>(0, 0, 0, 0)
        if meshFlags & WPEMdlMeshFlags.skinBlendIndices != 0 {
            // Skin-blend indices are 4× little-endian Int32 (not floats, which
            // the old decode misread — collapsing every index to bone 0).
            skinBlendIndices = SIMD4<Int32>(
                try reader.readInt32(),
                try reader.readInt32(),
                try reader.readInt32(),
                try reader.readInt32()
            )
        }
        if meshFlags & WPEMdlMeshFlags.skinBlendWeights != 0 {
            skinBlendWeights = SIMD4<Float>(
                try reader.readFloat(),
                try reader.readFloat(),
                try reader.readFloat(),
                try reader.readFloat()
            )
        }

        let uv: SIMD2<Float>
        if meshFlags & WPEMdlMeshFlags.uv != 0 {
            uv = SIMD2<Float>(try reader.readFloat(), try reader.readFloat())
        } else {
            uv = SIMD2<Float>(0, 0)
        }
        if meshFlags & WPEMdlMeshFlags.uv2 != 0 {
            try reader.skip(byteCount: 2 * MemoryLayout<Float>.size)
        }

        return WPEPuppetVertex(
            position: position,
            uv: uv,
            skinBlendIndices: skinBlendIndices,
            skinBlendWeights: skinBlendWeights
        )
    }

    private static func stride(for meshFlags: UInt32) -> Int {
        var stride = 3 * MemoryLayout<Float>.size
        if meshFlags & WPEMdlMeshFlags.normal != 0 {
            stride += 3 * MemoryLayout<Float>.size
        }
        if meshFlags & WPEMdlMeshFlags.tangent != 0 {
            stride += 4 * MemoryLayout<Float>.size
        }
        if meshFlags & WPEMdlMeshFlags.extra4 != 0 {
            stride += 4 * MemoryLayout<Float>.size
        }
        if meshFlags & WPEMdlMeshFlags.skinBlendIndices != 0 {
            stride += 4 * MemoryLayout<Float>.size
        }
        if meshFlags & WPEMdlMeshFlags.skinBlendWeights != 0 {
            stride += 4 * MemoryLayout<Float>.size
        }
        if meshFlags & WPEMdlMeshFlags.uv != 0 {
            stride += 2 * MemoryLayout<Float>.size
        }
        if meshFlags & WPEMdlMeshFlags.uv2 != 0 {
            stride += 2 * MemoryLayout<Float>.size
        }
        return stride
    }

    private static func parseVersion21Parts(
        vertexCount: Int,
        reader: inout WPEMdlBinaryReader
    ) throws -> [WPEPuppetMeshPart] {
        let uv2Marker = try reader.readUInt8()
        if uv2Marker == 1 {
            let hasUV2Payload = try reader.readUInt8()
            if hasUV2Payload != 0 {
                _ = try reader.readUInt16()
                _ = try reader.readUInt8()
                let payloadSize = try reader.readUInt32()
                let expectedSize = UInt32(vertexCount * 12)
                try reader.skip(byteCount: Int(max(payloadSize, expectedSize)))
            }
        } else if uv2Marker != 0 {
            throw WPEMdlParserError.unsupportedSectionMarker(uv2Marker)
        }

        let hasParts = try reader.readUInt8()
        guard hasParts != 0 else { return [] }

        let byteCount = try reader.readUInt32()
        guard byteCount % 16 == 0 else {
            throw WPEMdlParserError.invalidPartTable(byteCount)
        }
        let partCount = Int(byteCount / 16)
        var parts: [WPEPuppetMeshPart] = []
        parts.reserveCapacity(partCount)
        for _ in 0..<partCount {
            let id = try reader.readUInt32()
            _ = try reader.readUInt32()
            let start = try reader.readUInt32()
            let count = try reader.readUInt32()
            parts.append(WPEPuppetMeshPart(id: id, start: Int(start), count: Int(count)))
        }
        return parts
    }

    private static func parseSkeletonIfPresent(reader: inout WPEMdlBinaryReader) throws -> [WPEPuppetBone] {
        guard let skeletonOffset = reader.findTag("MDLS", from: reader.currentOffset) else {
            return []
        }
        try reader.seek(to: skeletonOffset)

        let skeletonTag = try reader.readFixedString(byteCount: 8)
        guard skeletonTag.hasPrefix("MDLS") else { return [] }
        _ = try reader.readUInt8()
        let declaredSectionEnd = Int(try reader.readUInt32())
        let boneCount = try reader.readUInt32()
        let skeletonSectionEnd = declaredSectionEnd > reader.currentOffset
            ? min(declaredSectionEnd, reader.dataCount)
            : reader.dataCount

        var bones: [WPEPuppetBone] = []
        bones.reserveCapacity(Int(boneCount))
        for index in 0..<boneCount {
            _ = try reader.readUInt32()
            _ = try reader.readUInt8()
            let parent = try reader.readInt32()
            let matrixByteCount = try reader.readUInt32()
            guard matrixByteCount >= 16 * UInt32(MemoryLayout<Float>.size),
                  matrixByteCount % UInt32(MemoryLayout<Float>.size) == 0 else {
                throw WPEMdlParserError.invalidSkeletonMatrix(matrixByteCount)
            }

            var matrix: [Float] = []
            matrix.reserveCapacity(16)
            for componentIndex in 0..<Int(matrixByteCount / UInt32(MemoryLayout<Float>.size)) {
                let value = try reader.readFloat()
                if componentIndex < 16 {
                    matrix.append(value)
                }
            }
            _ = try reader.readCString()
            if index + 1 < boneCount {
                try reader.consumeOptionalSkeletonTrailingMarker(
                    beforeNextBoneIndex: Int(index + 1),
                    sectionEnd: skeletonSectionEnd
                )
            }

            bones.append(WPEPuppetBone(
                index: Int(index),
                parentIndex: parent >= 0 ? Int(parent) : nil,
                rawMatrix: matrix
            ))
        }
        if skeletonSectionEnd <= reader.dataCount {
            try reader.seek(to: skeletonSectionEnd)
        }
        return bones
    }
}

private enum WPEMdlMeshFlags {
    static let normal: UInt32 = 0x2
    static let tangent: UInt32 = 0x4
    static let uv: UInt32 = 0x8
    static let uv2: UInt32 = 0x20
    static let extra4: UInt32 = 0x10000
    static let skinBlendIndices: UInt32 = 0x800000
    static let skinBlendWeights: UInt32 = 0x1000000
}

enum WPEMdlParserError: Error, Equatable, Sendable {
    case invalidHeader
    case truncated(offset: Int, requested: Int, available: Int)
    case unterminatedString(offset: Int)
    case invalidString(offset: Int)
    case unsupportedSectionMarker(UInt8)
    case invalidPartTable(UInt32)
    case invalidVertexBuffer(byteCount: UInt32, stride: Int)
    case invalidIndexBuffer(UInt32)
    case invalidSkeletonMatrix(UInt32)
    case invalidSkeletonTrailingMarker(offset: Int, value: UInt8)
}

private struct WPEMdlBinaryReader {
    private let data: Data
    private var offset: Int = 0

    var currentOffset: Int {
        offset
    }

    var dataCount: Int {
        data.count
    }

    init(data: Data) {
        self.data = data
    }

    mutating func readUInt8() throws -> UInt8 {
        guard offset < data.count else {
            throw WPEMdlParserError.truncated(offset: offset, requested: 1, available: data.count)
        }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readUInt16() throws -> UInt16 {
        let b0 = UInt16(try readUInt8())
        let b1 = UInt16(try readUInt8())
        return b0 | (b1 << 8)
    }

    mutating func readUInt32() throws -> UInt32 {
        let b0 = UInt32(try readUInt8())
        let b1 = UInt32(try readUInt8())
        let b2 = UInt32(try readUInt8())
        let b3 = UInt32(try readUInt8())
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    mutating func readInt32() throws -> Int32 {
        Int32(bitPattern: try readUInt32())
    }

    mutating func readFloat() throws -> Float {
        Float(bitPattern: try readUInt32())
    }

    mutating func readFixedString(byteCount: Int) throws -> String {
        let start = offset
        try ensureAvailable(byteCount: byteCount)
        offset += byteCount
        let bytes = data[start..<offset].prefix { $0 != 0 }
        guard let string = String(bytes: bytes, encoding: .utf8) else {
            throw WPEMdlParserError.invalidString(offset: start)
        }
        return string
    }

    mutating func readCString() throws -> String {
        let start = offset
        while offset < data.count, data[offset] != 0 {
            offset += 1
        }
        guard offset < data.count else {
            throw WPEMdlParserError.unterminatedString(offset: start)
        }
        let bytes = data[start..<offset]
        offset += 1
        guard let string = String(bytes: bytes, encoding: .utf8) else {
            throw WPEMdlParserError.invalidString(offset: start)
        }
        return string
    }

    mutating func skip(byteCount: Int) throws {
        try ensureAvailable(byteCount: byteCount)
        offset += byteCount
    }

    mutating func seek(to newOffset: Int) throws {
        guard newOffset >= 0, newOffset <= data.count else {
            throw WPEMdlParserError.truncated(
                offset: newOffset,
                requested: 0,
                available: data.count
            )
        }
        offset = newOffset
    }

    /// Some MDLS bone records carry a single trailing marker byte before the
    /// next record. Consume it only when the bytes at the cursor do not already
    /// look like the next bone record, and require the byte that follows to look
    /// like a valid record — otherwise fail loud rather than drift into garbage.
    mutating func consumeOptionalSkeletonTrailingMarker(
        beforeNextBoneIndex nextBoneIndex: Int,
        sectionEnd: Int
    ) throws {
        guard currentOffset < sectionEnd else { return }
        if isLikelySkeletonBoneRecord(
            at: currentOffset,
            nextBoneIndex: nextBoneIndex,
            sectionEnd: sectionEnd
        ) {
            return
        }

        let markerOffset = currentOffset
        let marker = try readUInt8()
        guard isLikelySkeletonBoneRecord(
            at: currentOffset,
            nextBoneIndex: nextBoneIndex,
            sectionEnd: sectionEnd
        ) else {
            throw WPEMdlParserError.invalidSkeletonTrailingMarker(
                offset: markerOffset,
                value: marker
            )
        }
    }

    private func isLikelySkeletonBoneRecord(
        at candidateOffset: Int,
        nextBoneIndex: Int,
        sectionEnd: Int
    ) -> Bool {
        guard candidateOffset >= 0,
              candidateOffset + 13 <= sectionEnd,
              let parent = readInt32(at: candidateOffset + 5),
              parent >= -1,
              parent < Int32(nextBoneIndex),
              let matrixByteCount = readUInt32(at: candidateOffset + 9),
              matrixByteCount >= 16 * UInt32(MemoryLayout<Float>.size),
              matrixByteCount % UInt32(MemoryLayout<Float>.size) == 0 else {
            return false
        }
        return candidateOffset + 13 + Int(matrixByteCount) <= sectionEnd
    }

    private func readInt32(at absoluteOffset: Int) -> Int32? {
        readUInt32(at: absoluteOffset).map(Int32.init(bitPattern:))
    }

    private func readUInt32(at absoluteOffset: Int) -> UInt32? {
        guard absoluteOffset >= 0, absoluteOffset + 4 <= data.count else { return nil }
        return UInt32(data[absoluteOffset])
            | (UInt32(data[absoluteOffset + 1]) << 8)
            | (UInt32(data[absoluteOffset + 2]) << 16)
            | (UInt32(data[absoluteOffset + 3]) << 24)
    }

    func findTag(_ tag: String, from start: Int) -> Int? {
        let bytes = Data(tag.utf8)
        return data.range(of: bytes, options: [], in: start..<data.count)?.lowerBound
    }

    private func ensureAvailable(byteCount: Int) throws {
        guard byteCount >= 0, offset + byteCount <= data.count else {
            throw WPEMdlParserError.truncated(
                offset: offset,
                requested: byteCount,
                available: data.count
            )
        }
    }
}
#endif
