import Foundation

/// Read-only model of a Wallpaper Engine `scene.pkg` container.
/// Layout: `[magicLen|magic][entryCount]({nameLen|name|offset|size})*N[payload]`
/// All integers are little-endian UInt32.
struct WallpaperEnginePackage: Sendable, Equatable {
    struct Entry: Sendable, Equatable {
        let name: String
        let dataOffset: UInt64
        let dataSize: UInt64
    }

    let magic: String
    let entries: [Entry]
    let dataStart: UInt64

    static func parseIndex(of data: Data) throws -> Self {
        var cursor = 0
        let magicLength = try data.wpeReadU32(cursor: &cursor)
        guard magicLength >= 4 && magicLength <= 16 else {
            throw WPEPackageError.invalidMagic("length:\(magicLength)")
        }

        let magic = try data.wpeReadString(cursor: &cursor, length: Int(magicLength))
        guard magic.hasPrefix("PKGV") else {
            throw WPEPackageError.invalidMagic(magic)
        }

        let entryCount = try data.wpeReadU32(cursor: &cursor)
        guard entryCount <= 65_535 else {
            throw WPEPackageError.invalidMagic("entryCount:\(entryCount)")
        }

        var entries: [Entry] = []
        entries.reserveCapacity(Int(entryCount))
        var seenNames = Set<String>()

        for index in 0..<Int(entryCount) {
            let nameLength = try data.wpeReadU32(cursor: &cursor)
            guard nameLength >= 1 && nameLength <= 1_024 else {
                throw WPEPackageError.invalidEntryName(index: index)
            }

            let name = try data.wpeReadEntryName(cursor: &cursor, length: Int(nameLength), index: index)
            guard !name.isEmpty else {
                throw WPEPackageError.invalidEntryName(index: index)
            }
            guard !Self.isUnsafeEntryName(name) else {
                throw WPEPackageError.pathTraversal(name: name)
            }
            guard seenNames.insert(name).inserted else {
                throw WPEPackageError.duplicateEntry(name: name)
            }

            let offset = UInt64(try data.wpeReadU32(cursor: &cursor))
            let size = UInt64(try data.wpeReadU32(cursor: &cursor))
            entries.append(Entry(name: name, dataOffset: offset, dataSize: size))
        }

        let dataStart = UInt64(cursor)
        let package = Self(magic: magic, entries: entries, dataStart: dataStart)
        for entry in entries {
            _ = try package.dataRange(for: entry, dataCount: data.count)
        }
        return package
    }

    func dataRange(for entry: Entry) throws -> Range<Data.Index> {
        try dataRange(for: entry, dataCount: Int.max)
    }

    /// Atomic extraction: writes into `<root>.inflight` first, then swaps via
    /// `<root>.replaced` so a partially extracted directory is never observed
    /// at `rootURL`. Rolls back on failure.
    func extractAll(from data: Data, to rootURL: URL) throws {
        let fileManager = FileManager.default
        let parentURL = rootURL.deletingLastPathComponent()
        let rootName = rootURL.lastPathComponent
        let inflightURL = parentURL.appendingPathComponent("\(rootName).inflight", isDirectory: true)
        let backupURL = parentURL.appendingPathComponent("\(rootName).replaced", isDirectory: true)

        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        try? fileManager.removeItem(at: inflightURL)
        try? fileManager.removeItem(at: backupURL)
        try fileManager.createDirectory(at: inflightURL, withIntermediateDirectories: true)

        let inflightPath = inflightURL.standardizedFileURL.path
        var movedExistingRoot = false

        do {
            for entry in entries {
                let range = try dataRange(for: entry, dataCount: data.count)
                let targetURL = inflightURL.appendingPathComponent(entry.name)
                let standardizedTarget = targetURL.standardizedFileURL
                guard standardizedTarget.path.hasPrefix(inflightPath + "/") else {
                    throw WPEPackageError.pathTraversal(name: entry.name)
                }

                try fileManager.createDirectory(
                    at: standardizedTarget.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data(data[range]).write(to: standardizedTarget, options: .atomic)
            }

            if fileManager.fileExists(atPath: rootURL.path) {
                try fileManager.moveItem(at: rootURL, to: backupURL)
                movedExistingRoot = true
            }
            try fileManager.moveItem(at: inflightURL, to: rootURL)
            if movedExistingRoot {
                try? fileManager.removeItem(at: backupURL)
            }
        } catch {
            try? fileManager.removeItem(at: inflightURL)
            if movedExistingRoot,
               !fileManager.fileExists(atPath: rootURL.path),
               fileManager.fileExists(atPath: backupURL.path) {
                try? fileManager.moveItem(at: backupURL, to: rootURL)
            }
            throw error
        }
    }

    private func dataRange(for entry: Entry, dataCount: Int) throws -> Range<Data.Index> {
        let (absoluteStart, startOverflow) = dataStart.addingReportingOverflow(entry.dataOffset)
        let (absoluteEnd, endOverflow) = absoluteStart.addingReportingOverflow(entry.dataSize)
        guard !startOverflow,
              !endOverflow,
              absoluteEnd <= UInt64(dataCount),
              absoluteStart <= absoluteEnd,
              let start = Int(exactly: absoluteStart),
              let end = Int(exactly: absoluteEnd) else {
            throw WPEPackageError.entryOutOfBounds(name: entry.name)
        }
        return start..<end
    }

    private static func isUnsafeEntryName(_ name: String) -> Bool {
        name.hasPrefix("/") || name.contains("..")
    }
}

enum WPEPackageError: Error, Equatable, Sendable {
    case truncatedHeader
    case invalidMagic(String)
    case invalidEntryName(index: Int)
    case entryOutOfBounds(name: String)
    case pathTraversal(name: String)
    case duplicateEntry(name: String)
}

fileprivate extension Data {
    func wpeReadU32(cursor: inout Int) throws -> UInt32 {
        guard cursor >= 0, cursor <= count, count - cursor >= 4 else {
            throw WPEPackageError.truncatedHeader
        }
        let value = UInt32(self[cursor])
            | (UInt32(self[cursor + 1]) << 8)
            | (UInt32(self[cursor + 2]) << 16)
            | (UInt32(self[cursor + 3]) << 24)
        cursor += 4
        return value
    }

    func wpeReadString(cursor: inout Int, length: Int) throws -> String {
        let bytes = try wpeReadBytes(cursor: &cursor, length: length)
        guard let string = String(data: bytes, encoding: .utf8) else {
            throw WPEPackageError.invalidMagic("nonUTF8")
        }
        return string
    }

    func wpeReadEntryName(cursor: inout Int, length: Int, index: Int) throws -> String {
        let bytes = try wpeReadBytes(cursor: &cursor, length: length)
        guard let string = String(data: bytes, encoding: .utf8) else {
            throw WPEPackageError.invalidEntryName(index: index)
        }
        return string
    }

    private func wpeReadBytes(cursor: inout Int, length: Int) throws -> Data {
        guard length >= 0, cursor >= 0, cursor <= count, length <= count - cursor else {
            throw WPEPackageError.truncatedHeader
        }
        let range = cursor..<(cursor + length)
        cursor += length
        return Data(self[range])
    }
}
