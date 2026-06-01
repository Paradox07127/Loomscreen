#if !LITE_BUILD
import Foundation

struct WPEPuppetModel: Equatable, Sendable {
    let version: Int
    let meshes: [WPEPuppetMesh]
    let bones: [WPEPuppetBone]
    let animations: [WPEPuppetAnimation]

    init(
        version: Int,
        meshes: [WPEPuppetMesh],
        bones: [WPEPuppetBone] = [],
        animations: [WPEPuppetAnimation] = []
    ) {
        self.version = version
        self.meshes = meshes
        self.bones = bones
        self.animations = animations
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

/// Baked skeletal animation from the MDLA section. Channels are stored in MDLS bone
/// order; each keyframe is a per-frame TRS transform (no curve interpolation in the file).
struct WPEPuppetAnimation: Equatable, Sendable {
    let id: Int
    let name: String
    /// Playback mode string from the file (e.g. "loop").
    let mode: String
    let fps: Float
    let frameCount: Int
    let channels: [WPEPuppetAnimChannel]
}

struct WPEPuppetAnimChannel: Equatable, Sendable {
    /// Skin-bone/channel index from MDLA (channels appear in bone order; no explicit id in
    /// the file). Usually matches MDLS bone order, but `WPEPuppetModel.bones` may be empty or
    /// malformed while channels stay usable — channels double as the skin skeleton (channel
    /// index == skin-blend index), with keyframe 0 as the bind pose.
    let boneIndex: Int
    let keyframes: [WPEPuppetAnimKey]
}

struct WPEPuppetAnimKey: Equatable, Sendable {
    let frame: Int
    /// Baked transform in the same (absolute/rest) space as the MDLS bone matrices:
    /// frame 0 matches the bone's raw matrix translation.
    let translation: SIMD3<Float>
    let euler: SIMD3<Float>
    let scale: SIMD3<Float>
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
        // The model header carries a leading byte before `meshCount` for every
        // puppet format observed in the corpus (MDLV0019/0021/0023 all use the
        // `u8 + u32 meshCount + u32` layout). Routing v19/v21 down the
        // no-leading-byte branch misaligns the cursor by one byte, which inflates
        // `meshCount` to garbage and aborts the whole parse — the bug behind the
        // "scattered facial features" puppets (e.g. MDLV0019 scene 3220362582).
        if version >= 19 {
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

        // MDLV positions are already the static target geometry. The MDLS skeleton and
        // MDLA animation sections are OPTIONAL metadata the current static draw path does
        // not consume (reserved for future bone skinning). A malformed or edge-case section
        // must never discard the already-parsed, renderable mesh geometry — otherwise the
        // whole puppet collapses to nil and the object degrades to a flat, scattered atlas
        // (observed on MDLV0023 scene 3479521040 "人物"). Parse each defensively on its own
        // cursor and recover the meshes, dropping only the failed section's metadata.
        var metadataReader = reader
        let bones: [WPEPuppetBone]
        do {
            bones = try parseSkeletonIfPresent(reader: &metadataReader)
        } catch {
            Logger.warning(
                "WPE puppet MDL skeleton parse failed; rendering the static mesh without bones: \(error)",
                category: .wpeRender
            )
            bones = []
            metadataReader = reader
        }

        let animations: [WPEPuppetAnimation]
        do {
            animations = try parseAnimationsIfPresent(reader: &metadataReader)
        } catch {
            Logger.warning(
                "WPE puppet MDL animation parse failed; rendering the static mesh without animations: \(error)",
                category: .wpeRender
            )
            animations = []
        }

        return WPEPuppetModel(
            version: version,
            meshes: meshes,
            bones: bones,
            animations: animations
        )
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
                    boneCount: Int(boneCount),
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

    /// One keyframe = 9 little-endian f32: [Tx,Ty,Tz, Rx,Ry,Rz, Sx,Sy,Sz].
    private static let animationKeyByteCount = 9 * MemoryLayout<Float>.size

    /// MDLA0005 (v19) / MDLA0006 (v21/v23) baked skeletal animation. Layout (read-only
    /// validated against the on-disk corpus: 3479521040/人物 55ch anim 267/777, 3554161528/人物,
    /// 3351072238/伊蕾娜 MDLS0003, 3704273480/身体拆分 89 bones, 2955378002/rennee MDLA0005):
    ///
    /// - Section: tag(8) + flag u8 + sectionEnd u32 + animationCount u32.
    /// - Per animation: id u32, reserved u32(0), name cstring, mode cstring, fps f32,
    ///   frameCount u32, reserved u32(0), channelCount u32, reserved u32(0), channelByteCount u32.
    /// - channelByteCount == (frameCount + 1) * 36. Channel-major; each channel stores frames
    ///   0...frameCount as `animationKeyByteCount` records, then an 8-byte delimiter
    ///   (u32 0 + u32 channelByteCount) before the next channel. Channels map to MDLS bone order.
    /// - A short zero-padding tail separates animations; scan to the next plausible header.
    private static func parseAnimationsIfPresent(
        reader: inout WPEMdlBinaryReader
    ) throws -> [WPEPuppetAnimation] {
        guard let animationOffset = reader.findTag("MDLA", from: reader.currentOffset) else {
            return []
        }
        try reader.seek(to: animationOffset)

        let animationTag = try reader.readFixedString(byteCount: 8)
        guard animationTag == "MDLA0005" || animationTag == "MDLA0006" else { return [] }
        _ = try reader.readUInt8()
        let declaredSectionEnd = Int(try reader.readUInt32())
        let animationCount = try reader.readUInt32()
        let sectionEnd = declaredSectionEnd > reader.currentOffset
            ? min(declaredSectionEnd, reader.dataCount)
            : reader.dataCount
        guard animationCount <= 1_024 else {
            throw WPEMdlParserError.invalidAnimationHeader(offset: animationOffset)
        }

        var animations: [WPEPuppetAnimation] = []
        animations.reserveCapacity(Int(animationCount))
        for animationIndex in 0..<animationCount {
            let animationStart = reader.currentOffset
            let id = try reader.readUInt32()
            let reservedID = try reader.readUInt32()
            let name = try reader.readCString()
            let mode = try reader.readCString()
            let fps = try reader.readFloat()
            let frameCount = try reader.readUInt32()
            let reserved0 = try reader.readUInt32()
            let channelCount = try reader.readUInt32()
            let reserved1 = try reader.readUInt32()
            let channelByteCount = try reader.readUInt32()

            guard reservedID == 0, reserved0 == 0, reserved1 == 0,
                  fps.isFinite, fps > 0,
                  frameCount > 0, frameCount < 10_000,
                  channelCount > 0, channelCount < 10_000 else {
                throw WPEMdlParserError.invalidAnimationHeader(offset: animationStart)
            }

            let expectedChannelByteCount = (UInt64(frameCount) + 1) * UInt64(animationKeyByteCount)
            guard expectedChannelByteCount <= UInt64(UInt32.max),
                  channelByteCount == UInt32(expectedChannelByteCount) else {
                throw WPEMdlParserError.invalidAnimationChannelByteCount(
                    animationID: Int(id),
                    byteCount: channelByteCount,
                    expected: expectedChannelByteCount <= UInt64(UInt32.max)
                        ? UInt32(expectedChannelByteCount) : UInt32.max
                )
            }

            let keyframeCount = Int(channelByteCount) / animationKeyByteCount
            let channelCountInt = Int(channelCount)
            let minimumDataByteCount = UInt64(channelCount) * UInt64(channelByteCount)
                + UInt64(max(channelCountInt - 1, 0) * 2 * MemoryLayout<UInt32>.size)
            guard UInt64(reader.currentOffset) + minimumDataByteCount <= UInt64(sectionEnd) else {
                throw WPEMdlParserError.invalidAnimationHeader(offset: animationStart)
            }

            var channels: [WPEPuppetAnimChannel] = []
            channels.reserveCapacity(channelCountInt)
            for channelIndex in 0..<channelCountInt {
                var keyframes: [WPEPuppetAnimKey] = []
                keyframes.reserveCapacity(keyframeCount)
                for frame in 0..<keyframeCount {
                    let translation = SIMD3<Float>(
                        try reader.readFloat(), try reader.readFloat(), try reader.readFloat()
                    )
                    let euler = SIMD3<Float>(
                        try reader.readFloat(), try reader.readFloat(), try reader.readFloat()
                    )
                    let scale = SIMD3<Float>(
                        try reader.readFloat(), try reader.readFloat(), try reader.readFloat()
                    )
                    keyframes.append(WPEPuppetAnimKey(
                        frame: frame,
                        translation: translation,
                        euler: euler,
                        scale: scale
                    ))
                }
                channels.append(WPEPuppetAnimChannel(boneIndex: channelIndex, keyframes: keyframes))

                if channelIndex + 1 < channelCountInt {
                    let delimiterMarker = try reader.readUInt32()
                    let delimiterByteCount = try reader.readUInt32()
                    guard delimiterMarker == 0, delimiterByteCount == channelByteCount else {
                        throw WPEMdlParserError.invalidAnimationChannelDelimiter(
                            animationID: Int(id),
                            channelIndex: channelIndex,
                            marker: delimiterMarker,
                            byteCount: delimiterByteCount,
                            expected: channelByteCount
                        )
                    }
                }
            }

            animations.append(WPEPuppetAnimation(
                id: Int(id),
                name: name,
                mode: mode,
                fps: fps,
                frameCount: Int(frameCount),
                channels: channels
            ))

            if animationIndex + 1 < animationCount {
                guard let nextOffset = reader.findLikelyAnimationRecord(
                    from: reader.currentOffset,
                    sectionEnd: sectionEnd
                ) else {
                    throw WPEMdlParserError.invalidAnimationHeader(offset: reader.currentOffset)
                }
                try reader.seek(to: nextOffset)
            }
        }

        if sectionEnd <= reader.dataCount {
            try reader.seek(to: sectionEnd)
        }
        return animations
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
    case invalidAnimationHeader(offset: Int)
    case invalidAnimationChannelByteCount(animationID: Int, byteCount: UInt32, expected: UInt32)
    case invalidAnimationChannelDelimiter(
        animationID: Int,
        channelIndex: Int,
        marker: UInt32,
        byteCount: UInt32,
        expected: UInt32
    )
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

    /// Some MDLS records carry a short padding run between the bone's trailing JSON
    /// cstring and the next binary record. In MDLS0004 this is a 1–3 byte UTF-8 label
    /// (e.g. `主`, `右眼`, `左眼`), so the old single-marker-byte heuristic failed on
    /// multi-byte CJK labels and dropped the whole skeleton (observed at offset 79286,
    /// value 0xE4 — a CJK lead byte). Scan a bounded window for the next plausible bone
    /// record instead, and fail loud only if none is found.
    mutating func consumeOptionalSkeletonTrailingMarker(
        boneCount: Int,
        sectionEnd: Int
    ) throws {
        guard currentOffset < sectionEnd else { return }
        if let nextRecordOffset = nextLikelySkeletonBoneRecordOffset(
            from: currentOffset,
            boneCount: boneCount,
            sectionEnd: sectionEnd
        ) {
            try seek(to: nextRecordOffset)
            return
        }

        throw WPEMdlParserError.invalidSkeletonTrailingMarker(
            offset: currentOffset,
            value: data[currentOffset]
        )
    }

    /// First offset in `[from, from + 64]` whose bytes look like a bone record.
    /// Returns `from` immediately when the cursor already sits on a record (no padding).
    private func nextLikelySkeletonBoneRecordOffset(
        from start: Int,
        boneCount: Int,
        sectionEnd: Int
    ) -> Int? {
        guard start >= 0, start < sectionEnd else { return nil }
        let upperBound = min(sectionEnd, start + 64)
        for candidateOffset in start...upperBound where isLikelySkeletonBoneRecord(
            at: candidateOffset,
            boneCount: boneCount,
            sectionEnd: sectionEnd
        ) {
            return candidateOffset
        }
        return nil
    }

    /// A bone record begins with `id u32, u8, parent i32, matrixByteCount u32`. The parent
    /// may be any valid bone index or -1 — MDLS0004 skeletons contain forward parent
    /// references (e.g. 人物 bone 24's parent is bone 39), so the upper bound is the total
    /// bone count, not the next bone index.
    private func isLikelySkeletonBoneRecord(
        at candidateOffset: Int,
        boneCount: Int,
        sectionEnd: Int
    ) -> Bool {
        guard candidateOffset >= 0,
              candidateOffset + 13 <= sectionEnd,
              let recordFlag = readUInt8(at: candidateOffset + 4),
              recordFlag == 0,
              let parent = readInt32(at: candidateOffset + 5),
              parent >= -1,
              parent < Int32(boneCount),
              let matrixByteCount = readUInt32(at: candidateOffset + 9),
              matrixByteCount >= 16 * UInt32(MemoryLayout<Float>.size),
              matrixByteCount % UInt32(MemoryLayout<Float>.size) == 0 else {
            return false
        }
        return candidateOffset + 13 + Int(matrixByteCount) <= sectionEnd
    }

    private func readUInt8(at absoluteOffset: Int) -> UInt8? {
        guard absoluteOffset >= 0, absoluteOffset < data.count else { return nil }
        return data[absoluteOffset]
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

    /// First offset at/after `start` that begins a plausible MDLA animation record.
    /// Used to skip the short zero-padding tail between animations.
    func findLikelyAnimationRecord(from start: Int, sectionEnd: Int) -> Int? {
        guard start >= 0, start < sectionEnd else { return nil }
        for offset in start..<min(sectionEnd, data.count)
        where isLikelyAnimationRecord(at: offset, sectionEnd: sectionEnd) {
            return offset
        }
        return nil
    }

    private func isLikelyAnimationRecord(at absoluteOffset: Int, sectionEnd: Int) -> Bool {
        guard absoluteOffset >= 0,
              absoluteOffset + 8 < sectionEnd,
              let id = readUInt32(at: absoluteOffset), id > 0, id < 1_000_000,
              let reservedID = readUInt32(at: absoluteOffset + 4), reservedID == 0,
              let name = readCString(at: absoluteOffset + 8, sectionEnd: sectionEnd),
              !name.value.isEmpty, name.value.utf8.count <= 128,
              let mode = readCString(at: name.nextOffset, sectionEnd: sectionEnd),
              !mode.value.isEmpty, mode.value.utf8.count <= 32 else {
            return false
        }
        let headerTail = mode.nextOffset + MemoryLayout<Float>.size + 5 * MemoryLayout<UInt32>.size
        guard headerTail <= sectionEnd,
              let fps = readFloat(at: mode.nextOffset), fps.isFinite, fps > 0,
              let frameCount = readUInt32(at: mode.nextOffset + 4), frameCount > 0, frameCount < 10_000,
              let reserved0 = readUInt32(at: mode.nextOffset + 8), reserved0 == 0,
              let channelCount = readUInt32(at: mode.nextOffset + 12), channelCount > 0, channelCount < 10_000,
              let reserved1 = readUInt32(at: mode.nextOffset + 16), reserved1 == 0,
              let channelByteCount = readUInt32(at: mode.nextOffset + 20) else {
            return false
        }
        let expected = (UInt64(frameCount) + 1) * UInt64(9 * MemoryLayout<Float>.size)
        guard expected == UInt64(channelByteCount) else { return false }
        let minimumDataByteCount = UInt64(channelCount) * UInt64(channelByteCount)
            + UInt64(max(Int(channelCount) - 1, 0) * 2 * MemoryLayout<UInt32>.size)
        return UInt64(headerTail) + minimumDataByteCount <= UInt64(sectionEnd)
    }

    private func readCString(at absoluteOffset: Int, sectionEnd: Int) -> (value: String, nextOffset: Int)? {
        guard absoluteOffset >= 0, absoluteOffset < sectionEnd, sectionEnd <= data.count else { return nil }
        var cursor = absoluteOffset
        while cursor < sectionEnd, data[cursor] != 0 {
            cursor += 1
        }
        guard cursor < sectionEnd,
              let string = String(bytes: data[absoluteOffset..<cursor], encoding: .utf8) else {
            return nil
        }
        return (string, cursor + 1)
    }

    private func readFloat(at absoluteOffset: Int) -> Float? {
        readUInt32(at: absoluteOffset).map(Float.init(bitPattern:))
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
