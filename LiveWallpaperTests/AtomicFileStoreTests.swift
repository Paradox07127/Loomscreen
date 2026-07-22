import Foundation
import LiveWallpaperCore
import Testing
@testable import LiveWallpaper

@Suite("AtomicFileStore: atomic write, recovery, rotation")
struct AtomicFileStoreTests {
    @Test("Round-trips a value through write/read")
    func roundTripsValue() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AtomicFileStore<TestValue>(
            fileURL: directory.appendingPathComponent("payload.json")
        )

        let value = TestValue(label: "α", count: 7)
        try store.write(value)

        #expect(store.read() == value)
    }

    @Test("Overwriting a payload rotates the prior file into .bak")
    func overwriteRotatesBackup() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("payload.json")
        let store = AtomicFileStore<TestValue>(fileURL: fileURL)

        try store.write(TestValue(label: "v1", count: 1))
        try store.write(TestValue(label: "v2", count: 2))

        let primary = try JSONDecoder().decode(TestValue.self, from: Data(contentsOf: fileURL))
        let backup = try JSONDecoder().decode(TestValue.self, from: Data(contentsOf: fileURL.appendingPathExtension("bak")))
        #expect(primary == TestValue(label: "v2", count: 2))
        #expect(backup == TestValue(label: "v1", count: 1))
    }

    @Test("Read recovers from a corrupted primary using the backup")
    func recoverFromCorruptPrimary() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("payload.json")
        let store = AtomicFileStore<TestValue>(fileURL: fileURL)

        try store.write(TestValue(label: "good", count: 100))
        try store.write(TestValue(label: "newer", count: 200))

        try Data([0xFF, 0xFE]).write(to: fileURL)

        let recovered = store.read()
        #expect(recovered == TestValue(label: "good", count: 100))
    }

    @Test("Read returns nil when both files are absent")
    func readReturnsNilWhenEmpty() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AtomicFileStore<TestValue>(
            fileURL: directory.appendingPathComponent("missing.json")
        )

        #expect(store.read() == nil)
        #expect(store.hasPersistedValue == false)
    }

    @Test("writeRaw accepts an already-encoded blob")
    func writeRawAcceptsEncodedBlob() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AtomicFileStore<TestValue>(
            fileURL: directory.appendingPathComponent("raw.json")
        )

        let payload = try JSONEncoder().encode(TestValue(label: "raw", count: 9))
        try store.writeRaw(payload)

        #expect(store.read() == TestValue(label: "raw", count: 9))
    }

    @Test("Files are written with 0600 mode, parent directory with 0700")
    func writesUseRestrictivePermissions() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory
            .appendingPathComponent("Configuration", isDirectory: true)
            .appendingPathComponent("payload.json")
        let store = AtomicFileStore<TestValue>(fileURL: fileURL)

        try store.write(TestValue(label: "secret", count: 42))

        let actualFileMode = try posixMode(at: fileURL)
        let actualDirMode = try posixMode(at: fileURL.deletingLastPathComponent())
        #expect(actualFileMode == 0o600, "Config file containing bookmark Data must be 0600, got \(String(format: "%o", actualFileMode))")
        #expect(actualDirMode == 0o700, "Config directory must be 0700, got \(String(format: "%o", actualDirMode))")
    }

    @Test("Write throws StoreError.writeFailed when the parent directory is unwritable")
    func writeFailsOnUnwritableParent() throws {
        let directory = try makeTempDirectory()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: directory.path(percentEncoded: false)
            )
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o500))],
            ofItemAtPath: directory.path(percentEncoded: false)
        )

        let store = AtomicFileStore<TestValue>(
            fileURL: directory
                .appendingPathComponent("Configuration", isDirectory: true)
                .appendingPathComponent("payload.json")
        )

        do {
            try store.write(TestValue(label: "x", count: 1))
            Issue.record("Expected StoreError.writeFailed on read-only parent directory")
        } catch is AtomicFileStore<TestValue>.StoreError {
        }
    }

    @Test("Refuses to decode files larger than maxReasonableFileSize")
    func refusesOversizedPayload() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("oversized.json")

        FileManager.default.createFile(atPath: fileURL.path(percentEncoded: false), contents: nil)
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seek(toOffset: UInt64(AtomicFileStore<TestValue>.maxReasonableFileSize) + 1)
        try handle.write(contentsOf: Data([0x00]))
        try handle.close()

        let store = AtomicFileStore<TestValue>(fileURL: fileURL)
        #expect(store.read() == nil, "Oversized payload must be rejected without throwing on MainActor")
    }

    @Test("delete removes both the primary and backup files")
    func deleteRemovesBothFiles() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("payload.json")
        let store = AtomicFileStore<TestValue>(fileURL: fileURL)

        try store.write(TestValue(label: "first", count: 1))
        try store.write(TestValue(label: "second", count: 2))
        store.delete()

        #expect(FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) == false)
        #expect(FileManager.default.fileExists(atPath: fileURL.appendingPathExtension("bak").path(percentEncoded: false)) == false)
        #expect(store.read() == nil)
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("AtomicFileStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func posixMode(at url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        let number = attrs[.posixPermissions] as? NSNumber
        return number?.intValue ?? 0
    }

    private struct TestValue: Codable, Equatable {
        let label: String
        let count: Int
    }
}
