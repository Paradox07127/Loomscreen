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
    /// Lowercased entry-name → entry, built once at parse so case-insensitive
    /// lookups are O(1) instead of an O(n) lowercased scan per read (matters for
    /// large packages + multi-root fallback cascades). First match wins.
    let nameIndex: [String: Entry]

    init(magic: String, entries: [Entry], dataStart: UInt64) {
        self.magic = magic
        self.entries = entries
        self.dataStart = dataStart
        var index: [String: Entry] = [:]
        index.reserveCapacity(entries.count)
        for entry in entries where index[entry.name.lowercased()] == nil {
            index[entry.name.lowercased()] = entry
        }
        self.nameIndex = index
    }

    /// Max bytes for an entry name (a full relative path in UTF-8). The old cap
    /// of 255 wrongly rejected legitimate packages: a path with multi-byte CJK
    /// components easily exceeds 255 *bytes* (e.g. a `sounds/<long Chinese name>`
    /// path). Allow a generous bound while still rejecting wildly misaligned reads.
    static let maxEntryNameBytes: UInt32 = 1024
    /// Per-component cap when writing to disk. APFS rejects a single path
    /// component over 255 UTF-8 bytes, so over-long components are shortened on
    /// extraction (see `filesystemSafeEntryName`).
    static let maxComponentBytes = 250
    /// Upper bound on the entry count — rejects a corrupt/misaligned header
    /// claiming an absurd count. Generous enough for any real package (even
    /// large frame-sequence scenes); `reserveCapacity` is clamped separately so
    /// a bogus count can't pre-allocate wildly.
    static let maxEntryCount: UInt32 = 262_144

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
        guard entryCount <= Self.maxEntryCount else {
            throw WPEPackageError.invalidMagic("entryCount:\(entryCount)")
        }

        var entries: [Entry] = []
        entries.reserveCapacity(min(Int(entryCount), 65_536))
        var seenNames = Set<String>()

        for index in 0..<Int(entryCount) {
            let nameLength = try data.wpeReadU32(cursor: &cursor)
            guard nameLength >= 1 && nameLength <= Self.maxEntryNameBytes else {
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
        guard entryCount <= Self.maxEntryCount else {
            throw WPEPackageError.invalidMagic("entryCount:\(entryCount)")
        }

        var entries: [Entry] = []
        entries.reserveCapacity(min(Int(entryCount), 65_536))
        var seenNames = Set<String>()

        for index in 0..<Int(entryCount) {
            try Self.streamAppend(into: &headerData, from: handle, count: 4)
            let nameLength = try headerData.wpeReadU32(cursor: &cursor)
            guard nameLength >= 1 && nameLength <= Self.maxEntryNameBytes else {
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
            let chunkSize = 1 << 20
            for entry in entries {
                let targetURL = inflightURL.appendingPathComponent(Self.filesystemSafeEntryName(entry.name))
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

    /// Atomic extraction: writes into `<root>.inflight` first, then swaps via `<root>.replaced` so a partially extracted directory is never observed at `rootURL`.
    func extractAll(from data: Data, to rootURL: URL) throws {
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
            for entry in entries {
                let range = try dataRange(for: entry, dataCount: data.count)
                let targetURL = inflightURL.appendingPathComponent(Self.filesystemSafeEntryName(entry.name))
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

    func readEntry(_ entry: Entry, from handle: FileHandle) throws -> Data {
        let absoluteStart = dataStart + entry.dataOffset
        do {
            try handle.seek(toOffset: absoluteStart)
        } catch {
            throw WPEPackageError.entryOutOfBounds(name: entry.name)
        }
        let toRead = Int(entry.dataSize)
        guard let data = try handle.read(upToCount: toRead),
              data.count == toRead else {
            throw WPEPackageError.entryOutOfBounds(name: entry.name)
        }
        return data
    }

    /// Case-insensitive lookup, O(1) via the prebuilt `nameIndex`.
    func entry(named name: String) -> Entry? {
        nameIndex[name.lowercased()]
    }

    /// Normalizes a requested path into the same canonical form `parseIndex`
    /// stored (drops `.`/empty components; rejects leading `/` or any `..`
    /// traversal component) so a lookup matches. Mirrors `canonicalEntryName`
    /// but returns `nil` instead of throwing — lookups treat invalid as a miss.
    static func canonicalLookupName(_ name: String) -> String? {
        guard !name.hasPrefix("/") else { return nil }
        var canonical: [String] = []
        for component in name.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty || component == "." { continue }
            guard component != ".." else { return nil }
            canonical.append(String(component))
        }
        return canonical.isEmpty ? nil : canonical.joined(separator: "/")
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

    /// Shortens any path component that exceeds the APFS 255-byte limit so the
    /// file extracts instead of failing the whole package. Truncation is
    /// deterministic (char-boundary base + a stable FNV-1a suffix + original
    /// extension), so re-extraction is idempotent. A renamed asset won't match
    /// the scene's reference (e.g. an over-long sound path goes silent), but the
    /// wallpaper still extracts and renders. Components within the limit pass
    /// through untouched.
    static func filesystemSafeEntryName(_ name: String) -> String {
        name.split(separator: "/", omittingEmptySubsequences: false).map { raw -> String in
            let component = String(raw)
            guard component.utf8.count > maxComponentBytes else { return component }

            let nsName = component as NSString
            let ext = nsName.pathExtension
            let tail = ext.isEmpty ? "" : "." + ext

            var hash: UInt32 = 2166136261
            for byte in component.utf8 { hash = (hash ^ UInt32(byte)) &* 16777619 }
            let suffix = "~" + String(format: "%08x", hash)

            let budget = maxComponentBytes - suffix.utf8.count - tail.utf8.count
            var base = ""
            var used = 0
            for character in nsName.deletingPathExtension {
                let bytes = String(character).utf8.count
                if used + bytes > budget { break }
                base.append(character)
                used += bytes
            }
            return base + suffix + tail
        }
        .joined(separator: "/")
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
            // Only a component that *is* ".." navigates up (the traversal vector);
            // a name that merely contains ".." (e.g. "image..png", "走过..mp3") is
            // a valid filename. `contains("..")` wrongly rejected such packages.
            // Extraction still re-checks the resolved path stays inside the root.
            guard component != ".." else {
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
