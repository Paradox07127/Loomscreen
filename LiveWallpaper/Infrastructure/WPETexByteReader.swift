import Foundation

/// Lightweight cursor over an immutable `Data` slice. Used by the `.tex`
/// decoder to read little-endian integers and 8-byte ASCII block magics
/// without allocating intermediate `String` / `NSData` wrappers.
///
/// Block magics in WPE `.tex` files always come as a NUL-terminated 8-byte
/// ASCII run (`TEXV0005\0`, `TEXI0001\0`, …). The reader strips the NUL
/// terminator and returns the canonical 8-character form so the decoder
/// can prefix-match (`hasPrefix("TEXV")`).
struct WPETexByteReader {
    let data: Data
    private(set) var cursor: Int

    init(data: Data, cursor: Int = 0) {
        self.data = data
        self.cursor = cursor
    }

    var remaining: Int { data.count - cursor }
    var isAtEnd: Bool { cursor >= data.count }

    mutating func readUInt32(blockName: String = "?") throws -> UInt32 {
        try ensure(byteCount: 4, blockName: blockName)
        let value = data.withUnsafeBytes { buffer -> UInt32 in
            buffer.loadUnaligned(fromByteOffset: cursor, as: UInt32.self)
        }
        cursor += 4
        return UInt32(littleEndian: value)
    }

    mutating func readInt32(blockName: String = "?") throws -> Int32 {
        try ensure(byteCount: 4, blockName: blockName)
        let value = data.withUnsafeBytes { buffer -> Int32 in
            buffer.loadUnaligned(fromByteOffset: cursor, as: Int32.self)
        }
        cursor += 4
        return Int32(littleEndian: value)
    }

    /// Phase 2E: reads a little-endian IEEE-754 single-precision float used
    /// by `TEXS` blocks for per-frame timing and atlas UVs.
    mutating func readFloat32(blockName: String = "?") throws -> Float {
        let bits = try readUInt32(blockName: blockName)
        return Float(bitPattern: bits)
    }

    /// Reads a NUL-terminated 8-byte ASCII magic. Returns the trimmed
    /// canonical form (e.g. `"TEXV0005"`). Empty / non-printable runs
    /// surface as `truncatedBlock`.
    mutating func readMagic() throws -> String {
        try ensure(byteCount: 9, blockName: "magic")
        let raw = data.subdata(in: cursor..<(cursor + 9))
        cursor += 9
        // Strip the trailing NUL and any padding so the prefix match works.
        let trimmed = raw.prefix { $0 != 0 }
        guard let asciiString = String(data: Data(trimmed), encoding: .ascii),
              !asciiString.isEmpty else {
            throw WPETexDecodeError.truncatedBlock(block: "magic", offset: cursor)
        }
        return asciiString
    }

    mutating func readBytes(count: Int, blockName: String) throws -> Data {
        try ensure(byteCount: count, blockName: blockName)
        let slice = data.subdata(in: cursor..<(cursor + count))
        cursor += count
        return slice
    }

    mutating func skip(_ count: Int, blockName: String = "?") throws {
        try ensure(byteCount: count, blockName: blockName)
        cursor += count
    }

    mutating func skipNullTerminatedString(blockName: String) throws {
        guard cursor <= data.count else {
            throw WPETexDecodeError.truncatedBlock(block: blockName, offset: cursor)
        }
        guard let terminator = data[cursor...].firstIndex(of: 0) else {
            throw WPETexDecodeError.truncatedBlock(block: blockName, offset: cursor)
        }
        cursor = terminator + 1
    }

    private func ensure(byteCount: Int, blockName: String) throws {
        guard byteCount >= 0, cursor + byteCount <= data.count else {
            throw WPETexDecodeError.truncatedBlock(block: blockName, offset: cursor)
        }
    }
}
