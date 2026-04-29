import Foundation
import Testing
@testable import LiveWallpaper

struct WallpaperEnginePackageTests {
    @Test("Parses valid package")
    func parsesValidPackage() throws {
        let data = makePackage(entries: [
            EntrySpec("models/a.json", [0x01, 0x02]),
            EntrySpec("textures/b.bin", [0x03])
        ])

        let package = try WallpaperEnginePackage.parseIndex(of: data)

        #expect(package.magic == "PKGV0022")
        #expect(package.entries.map(\.name) == ["models/a.json", "textures/b.bin"])
        #expect(package.entries.count == 2)
        if package.entries.count == 2 {
            #expect(package.entries[0].dataOffset == 0)
            #expect(package.entries[0].dataSize == 2)
            #expect(package.entries[1].dataOffset == 2)
            #expect(package.entries[1].dataSize == 1)
        }
    }

    @Test("Rejects bad magic")
    func rejectsBadMagic() {
        let data = makePackage(magic: "BAD0", entries: [EntrySpec("a.bin", [0x01])])

        #expect(throws: WPEPackageError.self) {
            try WallpaperEnginePackage.parseIndex(of: data)
        }
    }

    @Test("Rejects truncated header")
    func rejectsTruncatedHeader() {
        let data = Data([0x08, 0x00, 0x00, 0x00])

        #expect(throws: WPEPackageError.self) {
            try WallpaperEnginePackage.parseIndex(of: data)
        }
    }

    @Test("Rejects entry out of bounds")
    func rejectsEntryOutOfBounds() {
        let data = makePackage(entries: [
            EntrySpec("a.bin", [0x01], offset: 10_000, dataSize: 4)
        ])

        #expect(throws: WPEPackageError.self) {
            try WallpaperEnginePackage.parseIndex(of: data)
        }
    }

    @Test("Rejects path traversal")
    func rejectsPathTraversal() {
        let data = makePackage(entries: [EntrySpec("../etc/passwd", [0x01])])

        #expect(throws: WPEPackageError.self) {
            try WallpaperEnginePackage.parseIndex(of: data)
        }
    }

    @Test("Rejects absolute path")
    func rejectsAbsolutePath() {
        let data = makePackage(entries: [EntrySpec("/etc/passwd", [0x01])])

        #expect(throws: WPEPackageError.self) {
            try WallpaperEnginePackage.parseIndex(of: data)
        }
    }

    @Test("Rejects duplicate entries")
    func rejectsDuplicateEntries() {
        let data = makePackage(entries: [
            EntrySpec("same.bin", [0x01]),
            EntrySpec("same.bin", [0x02])
        ])

        #expect(throws: WPEPackageError.self) {
            try WallpaperEnginePackage.parseIndex(of: data)
        }
    }

    @Test("Parses UTF-8 names")
    func parsesUTF8Names() throws {
        let name = "材质/妃咲 60帧 .json"
        let data = makePackage(entries: [EntrySpec(name, [0x2a])])

        let package = try WallpaperEnginePackage.parseIndex(of: data)

        #expect(package.entries.first?.name == name)
    }

    @Test("Extract creates nested dirs")
    func extractCreatesNestedDirs() throws {
        let fileManager = FileManager.default
        let root = temporaryRoot()
        defer { try? fileManager.removeItem(at: root) }
        let data = makePackage(entries: [EntrySpec("models/sub/file.bin", [0xde, 0xad])])
        let package = try WallpaperEnginePackage.parseIndex(of: data)

        try package.extractAll(from: data, to: root)

        let extractedURL = root.appendingPathComponent("models/sub/file.bin")
        let extracted = try Data(contentsOf: extractedURL)
        #expect(extracted == Data([0xde, 0xad]))
    }

    @Test("Extract is atomic")
    func extractIsAtomic() throws {
        let fileManager = FileManager.default
        let root = temporaryRoot()
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let staleURL = root.appendingPathComponent("stale.bin")
        try Data([0x00]).write(to: staleURL)

        let data = makePackage(entries: [EntrySpec("fresh.bin", [0x99])])
        let package = try WallpaperEnginePackage.parseIndex(of: data)
        try package.extractAll(from: data, to: root)

        #expect(!fileManager.fileExists(atPath: staleURL.path))
        let fresh = try Data(contentsOf: root.appendingPathComponent("fresh.bin"))
        #expect(fresh == Data([0x99]))
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func makePackage(magic: String = "PKGV0022", entries: [EntrySpec]) -> Data {
        var payload = Data()
        var resolvedEntries: [(name: String, offset: UInt32, size: UInt32)] = []

        for entry in entries {
            let offset = entry.offset ?? UInt32(payload.count)
            let size = entry.dataSize ?? UInt32(entry.bytes.count)
            resolvedEntries.append((entry.name, offset, size))
            payload.append(contentsOf: entry.bytes)
        }

        var data = Data()
        let magicBytes = Array(magic.utf8)
        appendU32(UInt32(magicBytes.count), to: &data)
        data.append(contentsOf: magicBytes)
        appendU32(UInt32(resolvedEntries.count), to: &data)

        for entry in resolvedEntries {
            let nameBytes = Array(entry.name.utf8)
            appendU32(UInt32(nameBytes.count), to: &data)
            data.append(contentsOf: nameBytes)
            appendU32(entry.offset, to: &data)
            appendU32(entry.size, to: &data)
        }

        data.append(payload)
        return data
    }

    private func appendU32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 24) & 0xff))
    }
}

private struct EntrySpec: Sendable {
    let name: String
    let bytes: [UInt8]
    let offset: UInt32?
    let dataSize: UInt32?

    init(_ name: String, _ bytes: [UInt8], offset: UInt32? = nil, dataSize: UInt32? = nil) {
        self.name = name
        self.bytes = bytes
        self.offset = offset
        self.dataSize = dataSize
    }
}
