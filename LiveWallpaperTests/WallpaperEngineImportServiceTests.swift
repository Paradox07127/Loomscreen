import Foundation
import Testing
@testable import LiveWallpaper

@Suite("WallpaperEngineImportService") @MainActor
struct WallpaperEngineImportServiceTests {
    @Test("Imports video type from synthetic folder")
    func importsVideoTypeFromSyntheticFolder() async throws {
        let fixture = try makeFixture(type: .video, entryFile: "video.mp4", pkgEntries: [
            PackageEntrySpec("video.mp4", [0x01, 0x02])
        ])
        defer { fixture.cleanup() }

        let result = try await fixture.service.importProject(folder: fixture.folderURL)

        guard case .ready(let content, let origin) = result else {
            Issue.record("Expected .ready, got \(result)")
            return
        }
        guard case .video = content else {
            Issue.record("Expected .video content, got \(content)")
            return
        }
        #expect(origin.workshopID == fixture.workshopID)
        #expect(origin.originalType == .video)
    }

    @Test("Imports unpacked web folder without scene.pkg")
    func importsWebTypeFromSyntheticFolder() async throws {
        let fixture = try makeFixture(type: .web, entryFile: "index.html", pkgEntries: nil)
        defer { fixture.cleanup() }
        try Data("<html></html>".utf8).write(to: fixture.folderURL.appendingPathComponent("index.html"))

        let result = try await fixture.service.importProject(folder: fixture.folderURL)

        guard case .ready(let content, let origin) = result else {
            Issue.record("Expected .ready, got \(result)")
            return
        }
        guard case .html(let source, let config) = content else {
            Issue.record("Expected .html content, got \(content)")
            return
        }
        guard case .folder(_, let indexFileName) = source else {
            Issue.record("Expected .folder source, got \(source)")
            return
        }
        #expect(indexFileName == "index.html")
        #expect(config.physicalPixelLayout)
        #expect(origin.cacheRelativePath == nil)
    }

    @Test("Unsupported scene returns unsupported result")
    func unsupportedSceneReturnsUnsupportedResult() async throws {
        let fixture = try makeFixture(type: .scene, entryFile: "scene.json", pkgEntries: nil)
        defer { fixture.cleanup() }

        let result = try await fixture.service.importProject(folder: fixture.folderURL)

        guard case .unsupported(let origin) = result else {
            Issue.record("Expected .unsupported, got \(result)")
            return
        }
        #expect(origin.originalType == .scene)
    }

    @Test("Unsupported application returns unsupported result")
    func unsupportedApplicationReturnsUnsupportedResult() async throws {
        let fixture = try makeFixture(type: .application, entryFile: "app.exe", pkgEntries: nil)
        defer { fixture.cleanup() }

        let result = try await fixture.service.importProject(folder: fixture.folderURL)

        guard case .unsupported(let origin) = result else {
            Issue.record("Expected .unsupported, got \(result)")
            return
        }
        #expect(origin.originalType == .application)
    }

    @Test("Cache is idempotent")
    func cacheIsIdempotent() async throws {
        let fixture = try makeFixture(type: .video, entryFile: "video.mp4", pkgEntries: [
            PackageEntrySpec("video.mp4", [0x01])
        ])
        defer { fixture.cleanup() }

        _ = try await fixture.service.importProject(folder: fixture.folderURL)
        let markerURL = fixture.cacheURL
            .appendingPathComponent(fixture.workshopID, isDirectory: true)
            .appendingPathComponent("marker.txt")
        try Data("marker".utf8).write(to: markerURL)

        _ = try await fixture.service.importProject(folder: fixture.folderURL)

        #expect(FileManager.default.fileExists(atPath: markerURL.path))
    }

    @Test("Cache invalidates on pkg change")
    func cacheInvalidatesOnPkgChange() async throws {
        let fixture = try makeFixture(type: .video, entryFile: "video.mp4", pkgEntries: [
            PackageEntrySpec("video.mp4", [0x01])
        ])
        defer { fixture.cleanup() }

        _ = try await fixture.service.importProject(folder: fixture.folderURL)
        let extractedURL = fixture.cacheURL
            .appendingPathComponent(fixture.workshopID, isDirectory: true)
            .appendingPathComponent("video.mp4")
        let markerURL = extractedURL.deletingLastPathComponent().appendingPathComponent("marker.txt")
        try Data("marker".utf8).write(to: markerURL)

        // Bump mtime so the cache fingerprint mismatches and forces re-extract.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let changed = makePackage(entries: [PackageEntrySpec("video.mp4", [0x02, 0x03])])
        try changed.write(to: fixture.folderURL.appendingPathComponent("scene.pkg"), options: .atomic)

        _ = try await fixture.service.importProject(folder: fixture.folderURL)

        #expect(try Data(contentsOf: extractedURL) == Data([0x02, 0x03]))
        #expect(!FileManager.default.fileExists(atPath: markerURL.path))
    }

    @Test("Video import sets WPE origin cache path")
    func videoImportSetsWPEOrigin() async throws {
        let fixture = try makeFixture(type: .video, entryFile: "video.mp4", pkgEntries: [
            PackageEntrySpec("video.mp4", [0x01])
        ])
        defer { fixture.cleanup() }

        let result = try await fixture.service.importProject(folder: fixture.folderURL)

        guard case .ready(_, let origin) = result else {
            Issue.record("Expected .ready, got \(result)")
            return
        }
        #expect(origin.cacheRelativePath == "wpe-cache/\(fixture.workshopID)")
    }

    @Test("Scene import sets origin without cache path")
    func sceneImportSetsOriginButNoCachePath() async throws {
        let fixture = try makeFixture(type: .scene, entryFile: "scene.json", pkgEntries: nil)
        defer { fixture.cleanup() }

        let result = try await fixture.service.importProject(folder: fixture.folderURL)

        guard case .unsupported(let origin) = result else {
            Issue.record("Expected .unsupported, got \(result)")
            return
        }
        #expect(origin.cacheRelativePath == nil)
    }

    private func makeFixture(
        type: WPEType,
        entryFile: String,
        pkgEntries: [PackageEntrySpec]?
    ) throws -> ImportFixture {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folderURL = rootURL.appendingPathComponent("workshop", isDirectory: true)
        let cacheURL = rootURL.appendingPathComponent("cache", isDirectory: true)
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let workshopID = "3351072238"
        let manifest = """
        {
            "workshopid": "\(workshopID)",
            "title": "Synthetic Wallpaper",
            "type": "\(type.rawValue)",
            "file": "\(entryFile)",
            "preview": "preview.gif"
        }
        """
        try Data(manifest.utf8).write(to: folderURL.appendingPathComponent("project.json"))
        try Data([0x47, 0x49, 0x46]).write(to: folderURL.appendingPathComponent("preview.gif"))

        if let pkgEntries {
            try makePackage(entries: pkgEntries).write(to: folderURL.appendingPathComponent("scene.pkg"))
        }

        let service = WallpaperEngineImportService(
            cache: WallpaperEngineCache(rootURL: cacheURL),
            validateVideo: { _ in },
            makeBookmark: { url in Data(url.path.utf8) }
        )
        return ImportFixture(
            rootURL: rootURL,
            folderURL: folderURL,
            cacheURL: cacheURL,
            workshopID: workshopID,
            service: service
        )
    }

    private func makePackage(entries: [PackageEntrySpec]) -> Data {
        var payload = Data()
        var resolvedEntries: [(name: String, offset: UInt32, size: UInt32)] = []

        for entry in entries {
            let offset = UInt32(payload.count)
            let size = UInt32(entry.bytes.count)
            resolvedEntries.append((entry.name, offset, size))
            payload.append(contentsOf: entry.bytes)
        }

        var data = Data()
        let magicBytes = Array("PKGV0022".utf8)
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

private struct ImportFixture {
    let rootURL: URL
    let folderURL: URL
    let cacheURL: URL
    let workshopID: String
    let service: WallpaperEngineImportService

    func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private struct PackageEntrySpec: Sendable {
    let name: String
    let bytes: [UInt8]

    init(_ name: String, _ bytes: [UInt8]) {
        self.name = name
        self.bytes = bytes
    }
}
