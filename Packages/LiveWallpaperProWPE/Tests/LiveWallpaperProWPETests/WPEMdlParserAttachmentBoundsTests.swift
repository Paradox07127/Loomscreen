import Foundation
import Testing
@testable import LiveWallpaperProWPE

/// A malformed MDAT attachment name whose NUL terminator is missing must fail
/// fast on the section boundary and degrade to the no-attachment recovery path,
/// keeping the already-parsed mesh — never scan the rest of the file for a NUL.
@Suite("WPEMdlParser MDAT bounds")
struct WPEMdlParserAttachmentBoundsTests {

    @Test("Truncated (unterminated) MDAT attachment name recovers with an intact mesh")
    func truncatedAttachmentNameRecoversMesh() throws {
        var data = singleTriangleMDLV23()

        // Append a well-formed MDAT header declaring one anchor whose name is a run
        // of non-zero bytes with no terminator inside the declared section.
        let mdatStart = data.count
        data.append(contentsOf: Array("MDAT0001".utf8))
        data.append(UInt8(0)) // section flag
        // Header (15 bytes) + boneIndex(2) + 4 unterminated name bytes = +21.
        data.appendLE(UInt32(mdatStart + 21)) // declared section end
        data.appendLE(UInt16(1))              // anchor count
        data.appendLE(UInt16(0))              // boneIndex
        data.append(contentsOf: [0x41, 0x41, 0x41, 0x41]) // "AAAA", no NUL

        let model = try WPEMdlParser.parse(data: data)

        #expect(model.meshes.count == 1)
        #expect(model.attachments.isEmpty)
    }

    /// Minimal MDLV0023 single-triangle puppet (no skeleton). Byte-for-byte the
    /// known-good mesh fixture; the parser reaches attachment parsing after it.
    private func singleTriangleMDLV23() -> Data {
        var data = Data()
        data.append(contentsOf: Array("MDLV0023".utf8))
        data.appendLE(UInt32(0x80000900))
        data.append(UInt8(1))
        data.appendLE(UInt32(1))
        data.appendLE(UInt32(1))

        data.appendCString("materials/test.json")
        data.appendLE(UInt32(0))
        for value in [Float(-10), -20, 0, 10, 20, 0] { data.appendLE(value) }
        data.appendLE(UInt32(0x180000f))
        let vertexData = Data.puppetVertices([
            (SIMD3<Float>(-10, -20, 0), SIMD2<Float>(0, 1)),
            (SIMD3<Float>(10, -20, 0), SIMD2<Float>(1, 1)),
            (SIMD3<Float>(0, 20, 0), SIMD2<Float>(0.5, 0)),
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
}
