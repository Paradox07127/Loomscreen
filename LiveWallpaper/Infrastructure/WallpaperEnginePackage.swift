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
            // 255 matches the upstream RePKG reader cap. Generous for every
            // UTF-8 path observed in real workshops.
            guard nameLength >= 1 && nameLength <= 255 else {
                throw WPEPackageError.invalidEntryName(index: index)
            }

            let name = try data.wpeReadEntryName(cursor: &cursor, length: Int(nameLength), index: index)
            guard !name.isEmpty else {
                throw WPEPackageError.invalidEntryName(index: index)
            }
            let canonicalName = try Self.canonicalEntryName(name, index: index)
            guard seenNames.insert(canonicalName).inserted else {
                throw WPEPackageError.duplicateEntry(name: canonicalName)
            }

            let offset = UInt64(try data.wpeReadU32(cursor: &cursor))
            let size = UInt64(try data.wpeReadU32(cursor: &cursor))
            entries.append(Entry(name: canonicalName, dataOffset: offset, dataSize: size))
        }

        let dataStart = UInt64(cursor)
        let package = Self(magic: magic, entries: entries, dataStart: dataStart)
        for entry in entries {
            _ = try package.dataRange(for: entry, dataCount: data.count)
        }
        return package
    }

    /// Streaming variant of `parseIndex(of:)`. Reads only the header bytes
    /// from the given handle so multi-hundred-MB packages don't have to be
    /// memory-mapped just to discover their entry table. The handle's offset
    /// is left at the start of the payload (i.e. equal to `dataStart`),
    /// ready for `extractAll(streamingFrom:to:)` to seek per-entry.
    static func parseIndex(streamingFrom handle: FileHandle) throws -> Self {
        let totalLength: UInt64
        do {
            totalLength = try handle.seekToEnd()
            try handle.seek(toOffset: 0)
        } catch {
            throw WPEPackageError.truncatedHeader
        }

        var headerData = Data()
        var cursor = 0

        try Self.streamAppend(into: &headerData, from: handle, count: 4)
        let magicLength = try headerData.wpeReadU32(cursor: &cursor)
        guard magicLength >= 4 && magicLength <= 16 else {
            throw WPEPackageError.invalidMagic("length:\(magicLength)")
        }

        try Self.streamAppend(into: &headerData, from: handle, count: Int(magicLength))
        let magic = try headerData.wpeReadString(cursor: &cursor, length: Int(magicLength))
        guard magic.hasPrefix("PKGV") else {
            throw WPEPackageError.invalidMagic(magic)
        }

        try Self.streamAppend(into: &headerData, from: handle, count: 4)
        let entryCount = try headerData.wpeReadU32(cursor: &cursor)
        guard entryCount <= 65_535 else {
            throw WPEPackageError.invalidMagic("entryCount:\(entryCount)")
        }

        var entries: [Entry] = []
        entries.reserveCapacity(Int(entryCount))
        var seenNames = Set<String>()

        for index in 0..<Int(entryCount) {
            try Self.streamAppend(into: &headerData, from: handle, count: 4)
            let nameLength = try headerData.wpeReadU32(cursor: &cursor)
            guard nameLength >= 1 && nameLength <= 255 else {
                throw WPEPackageError.invalidEntryName(index: index)
            }

            try Self.streamAppend(into: &headerData, from: handle, count: Int(nameLength))
            let name = try headerData.wpeReadEntryName(
                cursor: &cursor,
                length: Int(nameLength),
                index: index
            )
            guard !name.isEmpty else { throw WPEPackageError.invalidEntryName(index: index) }
            let canonicalName = try Self.canonicalEntryName(name, index: index)
            guard seenNames.insert(canonicalName).inserted else {
                throw WPEPackageError.duplicateEntry(name: canonicalName)
            }

            try Self.streamAppend(into: &headerData, from: handle, count: 8)
            let offset = UInt64(try headerData.wpeReadU32(cursor: &cursor))
            let size = UInt64(try headerData.wpeReadU32(cursor: &cursor))
            entries.append(Entry(name: canonicalName, dataOffset: offset, dataSize: size))
        }

        let dataStart = UInt64(cursor)
        // Validate every entry stays within the actual file length without
        // mapping the payload — bounds checks mirror `parseIndex(of:)`.
        for entry in entries {
            let (absoluteStart, startOverflow) = dataStart.addingReportingOverflow(entry.dataOffset)
            let (absoluteEnd, endOverflow) = absoluteStart.addingReportingOverflow(entry.dataSize)
            guard !startOverflow, !endOverflow,
                  absoluteEnd <= totalLength,
                  absoluteStart <= absoluteEnd else {
                throw WPEPackageError.entryOutOfBounds(name: entry.name)
            }
        }
        do {
            try handle.seek(toOffset: dataStart)
        } catch {
            throw WPEPackageError.truncatedHeader
        }
        return Self(magic: magic, entries: entries, dataStart: dataStart)
    }

    /// Streaming companion to `extractAll(from:to:)`. Reads each entry from
    /// the supplied handle in fixed-size chunks and writes it to the
    /// inflight directory without ever holding the full pkg in memory.
    /// Same atomicity + crash-recovery behaviour as the Data-based variant.
    func extractAll(streamingFrom handle: FileHandle, to rootURL: URL) throws {
        let fileManager = FileManager.default
        let parentURL = rootURL.deletingLastPathComponent()
        let rootName = rootURL.lastPathComponent
        let inflightURL = parentURL.appendingPathComponent("\(rootName).inflight", isDirectory: true)
        let backupURL = parentURL.appendingPathComponent("\(rootName).replaced", isDirectory: true)

        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)

        if !fileManager.fileExists(atPath: rootURL.path),
           fileManager.fileExists(atPath: backupURL.path) {
            try fileManager.moveItem(at: backupURL, to: rootURL)
        }

        try? fileManager.removeItem(at: inflightURL)
        try? fileManager.removeItem(at: backupURL)
        try fileManager.createDirectory(at: inflightURL, withIntermediateDirectories: true)

        let inflightPath = inflightURL.standardizedFileURL.path
        var movedExistingRoot = false

        do {
            let chunkSize = 1 << 20  // 1 MiB
            for entry in entries {
                let targetURL = inflightURL.appendingPathComponent(entry.name)
                let standardizedTarget = targetURL.standardizedFileURL
                guard standardizedTarget.path.hasPrefix(inflightPath + "/") else {
                    throw WPEPackageError.pathTraversal(name: entry.name)
                }
                try fileManager.createDirectory(
                    at: standardizedTarget.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )

                let absoluteStart = dataStart + entry.dataOffset
                try handle.seek(toOffset: absoluteStart)

                fileManager.createFile(atPath: standardizedTarget.path, contents: nil)
                let writer = try FileHandle(forWritingTo: standardizedTarget)
                do {
                    var remaining = entry.dataSize
                    while remaining > 0 {
                        let toRead = Int(min(UInt64(chunkSize), remaining))
                        guard let chunk = try handle.read(upToCount: toRead),
                              chunk.count == toRead else {
                            try? writer.close()
                            throw WPEPackageError.entryOutOfBounds(name: entry.name)
                        }
                        try writer.write(contentsOf: chunk)
                        remaining -= UInt64(chunk.count)
                    }
                    try writer.close()
                } catch {
                    try? writer.close()
                    throw error
                }
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

    private static func streamAppend(into buffer: inout Data, from handle: FileHandle, count: Int) throws {
        guard count >= 0 else { throw WPEPackageError.truncatedHeader }
        guard count > 0 else { return }
        guard let chunk = try handle.read(upToCount: count), chunk.count == count else {
            throw WPEPackageError.truncatedHeader
        }
        buffer.append(chunk)
    }

    /// Atomic extraction: writes into `<root>.inflight` first, then swaps via
    /// `<root>.replaced` so a partially extracted directory is never observed
    /// at `rootURL`. Rolls back on failure.
    ///
    /// Crash recovery: if a previous extract crashed AFTER moving the live
    /// `rootURL` into `.replaced` but BEFORE moving `.inflight` into place,
    /// the next launch finds `rootURL` missing while `.replaced` still holds
    /// the last-good cache. We restore it before any cleanup so the
    /// pre-existing wallpaper isn't lost just because we tried to replace it.
    func extractAll(from data: Data, to rootURL: URL) throws {
        let fileManager = FileManager.default
        let parentURL = rootURL.deletingLastPathComponent()
        let rootName = rootURL.lastPathComponent
        let inflightURL = parentURL.appendingPathComponent("\(rootName).inflight", isDirectory: true)
        let backupURL = parentURL.appendingPathComponent("\(rootName).replaced", isDirectory: true)

        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)

        // Restore must succeed before cleanup runs, otherwise the next line
        // would silently delete the only good copy.
        if !fileManager.fileExists(atPath: rootURL.path),
           fileManager.fileExists(atPath: backupURL.path) {
            try fileManager.moveItem(at: backupURL, to: rootURL)
        }

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

    private static func canonicalEntryName(_ name: String, index: Int) throws -> String {
        guard !name.hasPrefix("/") else {
            throw WPEPackageError.pathTraversal(name: name)
        }
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        var canonical: [String] = []
        canonical.reserveCapacity(components.count)

        for component in components {
            if component.isEmpty || component == "." {
                continue
            }
            guard !component.contains("..") else {
                throw WPEPackageError.pathTraversal(name: name)
            }
            canonical.append(String(component))
        }

        guard !canonical.isEmpty else {
            throw WPEPackageError.invalidEntryName(index: index)
        }
        return canonical.joined(separator: "/")
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
