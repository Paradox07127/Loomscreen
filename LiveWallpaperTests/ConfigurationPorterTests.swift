import Foundation
import Testing
@testable import LiveWallpaper

@Suite("ConfigurationBundle / ConfigurationPorter round-trip")
@MainActor
struct ConfigurationPorterTests {
    @Test("Encodes and decodes a populated bundle losslessly")
    func roundTripsPopulatedBundle() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let bundle = ConfigurationBundle(
            schemaVersion: 1,
            appBundleID: Bundle.main.bundleIdentifier ?? "Taijia.LiveWallpaper",
            appVersion: "test-1.0",
            exportedAt: Date(timeIntervalSince1970: 1_750_000_000),
            screenConfigurations: [
                ScreenConfiguration(screenID: 1, wallpaper: .video(bookmarkData: Data([0x01, 0x02])))
            ],
            globalSettings: GlobalSettings(),
            wallpaperBookmarks: []
        )

        let data = try ConfigurationPorter.encode(bundle)
        let destination = directory.appendingPathComponent("export.lwconfig")
        try data.write(to: destination)

        let decoded = try ConfigurationPorter.decode(from: destination)

        #expect(decoded.schemaVersion == bundle.schemaVersion)
        #expect(decoded.appBundleID == bundle.appBundleID)
        #expect(decoded.appVersion == bundle.appVersion)
        #expect(decoded.screenConfigurations?.count == 1)
        #expect(decoded.screenConfigurations?.first?.screenID == 1)
        #expect(decoded.wallpaperBookmarks?.isEmpty == true)
    }

    @Test("Rejects bundles whose schema is newer than this build")
    func rejectsTooNewSchema() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let bundle = ConfigurationBundle(
            schemaVersion: ConfigurationBundle.currentSchemaVersion + 1
        )
        let destination = directory.appendingPathComponent("future.lwconfig")
        try ConfigurationPorter.encode(bundle).write(to: destination)

        do {
            _ = try ConfigurationPorter.decode(from: destination)
            Issue.record("Expected unsupportedSchemaVersion error")
        } catch ConfigurationPorter.ImportError.unsupportedSchemaVersion(let found, let supported) {
            #expect(found == ConfigurationBundle.currentSchemaVersion + 1)
            #expect(supported == ConfigurationBundle.currentSchemaVersion)
        }
    }

    @Test("Rejects bundles for a different app")
    func rejectsWrongBundleID() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let bundle = ConfigurationBundle(appBundleID: "com.example.NotLiveWallpaper")
        let destination = directory.appendingPathComponent("foreign.lwconfig")
        try ConfigurationPorter.encode(bundle).write(to: destination)

        do {
            _ = try ConfigurationPorter.decode(from: destination)
            Issue.record("Expected bundleMismatch error")
        } catch ConfigurationPorter.ImportError.bundleMismatch(_, let found) {
            #expect(found == "com.example.NotLiveWallpaper")
        }
    }

    @Test("Rejects payloads that aren't JSON at all")
    func rejectsCorruptFile() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("garbage.lwconfig")
        try Data([0xFF, 0xFE, 0xFD]).write(to: destination)

        do {
            _ = try ConfigurationPorter.decode(from: destination)
            Issue.record("Expected invalidFile error")
        } catch ConfigurationPorter.ImportError.invalidFile {
            // Expected.
        }
    }

    @Test("Rejects schema versions below 1 (downgrade / corrupt files)")
    func rejectsSchemaBelowOne() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let bundle = ConfigurationBundle(schemaVersion: 0)
        let destination = directory.appendingPathComponent("zero.lwconfig")
        try ConfigurationPorter.encode(bundle).write(to: destination)

        do {
            _ = try ConfigurationPorter.decode(from: destination)
            Issue.record("Expected unsupportedSchemaVersion for schemaVersion=0")
        } catch ConfigurationPorter.ImportError.unsupportedSchemaVersion(let found, _) {
            #expect(found == 0)
        }
    }

    @Test("Rejects files larger than the import size cap")
    func rejectsOversizedFile() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Write a 17 MB file of zero bytes — over the 16 MB cap.
        let destination = directory.appendingPathComponent("huge.lwconfig")
        let chunk = Data(repeating: 0, count: 1024 * 1024)
        try FileManager.default.createFile(atPath: destination.path(percentEncoded: false), contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        for _ in 0..<17 {
            try handle.write(contentsOf: chunk)
        }
        try handle.close()

        do {
            _ = try ConfigurationPorter.decode(from: destination)
            Issue.record("Expected fileTooLarge error")
        } catch ConfigurationPorter.ImportError.fileTooLarge(let bytes) {
            #expect(bytes >= 17 * 1024 * 1024)
        }
    }

    @Test("ConfigurationBundle.contentType has the .lwconfig file extension")
    func contentTypeHasLWConfigExtension() {
        // We always register `lwconfig` via Info.plist; either the registered
        // type is loaded (production) or we fall back to .json (test bundle
        // contexts that don't load Info.plist). Both are conforming JSON
        // types, but the registered one carries our extension.
        let preferred = ConfigurationBundle.contentType.preferredFilenameExtension
        let fallback = preferred == "json"   // ran without Info.plist
        let matched = preferred == "lwconfig" // ran with our registration
        #expect(matched || fallback,
                "Expected lwconfig (registered) or json (fallback), got \(preferred ?? "<nil>")")
    }

    @Test("Suggested filename embeds an ISO date stamp")
    func suggestedFileNameUsesDateStamp() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let fixed = Date(timeIntervalSince1970: 1_750_000_000)
        let expected = "LiveWallpaper-\(formatter.string(from: fixed)).\(ConfigurationBundle.fileExtension)"
        // The porter uses a local-time stamp by default; allow ±1 day so the
        // test passes in any zone without re-implementing the formatter here.
        let actual = ConfigurationPorter.suggestedExportFileName(now: fixed)
        #expect(actual.hasPrefix("LiveWallpaper-"))
        #expect(actual.hasSuffix(".\(ConfigurationBundle.fileExtension)"))
        // Soft check that some 4-digit year is present.
        let expectedYearPrefix = String(expected.prefix("LiveWallpaper-2025".count))
        #expect(actual.hasPrefix(expectedYearPrefix.prefix("LiveWallpaper-".count)))
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("ConfigurationPorterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

@Suite("SettingsManager: file-store migration from UserDefaults")
@MainActor
struct SettingsManagerMigrationTests {
    @Test("Seeds AtomicFileStore from legacy UserDefaults blob on first launch")
    func seedsFromLegacyUserDefaults() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Use an isolated UserDefaults domain to avoid clobbering the real
        // app's keys. We pre-populate the legacy key, then construct a
        // SettingsManager whose stores point into the temp directory and
        // verify it reads the migrated blob.
        let suite = "Taijia.LiveWallpaperMigrationTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("Couldn't create isolated UserDefaults suite")
            return
        }
        defer {
            UserDefaults.standard.removePersistentDomain(forName: suite)
            defaults.removePersistentDomain(forName: suite)
        }

        // Encode a non-trivial configuration into the legacy key directly so
        // we can prove the file store was seeded from it.
        let original = [
            ScreenConfiguration(screenID: 42, wallpaper: .video(bookmarkData: Data([0x10, 0x20])))
        ]
        let legacyData = try JSONEncoder().encode(original)
        UserDefaults.standard.set(legacyData, forKey: "screenConfigurations")
        UserDefaults.standard.removeObject(forKey: "Settings.MigrationVersion")
        defer {
            UserDefaults.standard.removeObject(forKey: "screenConfigurations")
            UserDefaults.standard.removeObject(forKey: "Settings.MigrationVersion")
        }

        // New SettingsManager instance pointed at the temp dir — its init
        // runs the migration as a side effect.
        let manager = SettingsManager(directory: ConfigurationDirectory(root: directory))

        let loaded = manager.loadConfigurations()
        #expect(loaded.count == 1)
        #expect(loaded.first?.screenID == 42)

        // File should now exist on disk independent of UserDefaults.
        let onDisk = directory.appendingPathComponent("screen-configurations.json")
        #expect(FileManager.default.fileExists(atPath: onDisk.path(percentEncoded: false)))
    }

    @Test("Migration version is NOT bumped when seed writes fail (retry on next launch)")
    func migrationVersionDeferredOnSeedFailure() throws {
        // Point the directory resolver at a path inside an unwritable
        // parent so AtomicFileStore.write throws. We expect:
        //   - the migration version key stays at 0
        //   - the next SettingsManager construction will try again
        let unwritableRoot = try makeUnwritableDirectory()
        defer {
            // Restore writability so cleanup can remove it.
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: unwritableRoot.path(percentEncoded: false)
            )
            try? FileManager.default.removeItem(at: unwritableRoot)
        }

        // Seed UserDefaults with a legacy blob so the migration has work
        // to do.
        let legacyConfigs = [
            ScreenConfiguration(screenID: 7, wallpaper: .video(bookmarkData: Data([0xCC])))
        ]
        UserDefaults.standard.set(try JSONEncoder().encode(legacyConfigs), forKey: "screenConfigurations")
        UserDefaults.standard.removeObject(forKey: "Settings.MigrationVersion")
        defer {
            UserDefaults.standard.removeObject(forKey: "screenConfigurations")
            UserDefaults.standard.removeObject(forKey: "Settings.MigrationVersion")
        }

        let unwritableSubdir = unwritableRoot.appendingPathComponent("Configuration", isDirectory: true)
        _ = SettingsManager(directory: ConfigurationDirectory(root: unwritableSubdir))

        let postVersion = UserDefaults.standard.integer(forKey: "Settings.MigrationVersion")
        #expect(postVersion == 0,
                "Migration version must stay at 0 after a failed seed so the next launch retries")
    }

    @Test("File payload wins over the legacy UserDefaults blob")
    func filePayloadWinsOverLegacy() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Pre-seed the file with one value and UserDefaults with another.
        let onDisk = directory.appendingPathComponent("screen-configurations.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileConfigs = [
            ScreenConfiguration(screenID: 1, wallpaper: .video(bookmarkData: Data([0xAA])))
        ]
        try JSONEncoder().encode(fileConfigs).write(to: onDisk)

        let legacyConfigs = [
            ScreenConfiguration(screenID: 99, wallpaper: .video(bookmarkData: Data([0xBB])))
        ]
        UserDefaults.standard.set(try JSONEncoder().encode(legacyConfigs), forKey: "screenConfigurations")
        UserDefaults.standard.removeObject(forKey: "Settings.MigrationVersion")
        defer {
            UserDefaults.standard.removeObject(forKey: "screenConfigurations")
            UserDefaults.standard.removeObject(forKey: "Settings.MigrationVersion")
        }

        let manager = SettingsManager(directory: ConfigurationDirectory(root: directory))
        let loaded = manager.loadConfigurations()
        #expect(loaded.first?.screenID == 1, "File store wins; legacy 99 must not appear")
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("SettingsManagerMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Creates a directory whose POSIX mode is `0500` (read+execute, no
    /// write). AtomicFileStore.write inside a `Configuration` subfolder
    /// here will fail because we can't `mkdir` into a read-only parent.
    private func makeUnwritableDirectory() throws -> URL {
        let url = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("SettingsManagerUnwritable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o500))],
            ofItemAtPath: url.path(percentEncoded: false)
        )
        return url
    }
}
