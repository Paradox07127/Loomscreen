import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
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
        #expect(origin.resourceLocation == .sourceFolder)
        #expect(origin.entryFile == "index.html")
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
        #expect(origin.resourceLocation == .cache)
        #expect(origin.entryFile == "video.mp4")
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
        #expect(origin.resourceLocation == .unsupported)
        #expect(origin.entryFile == "scene.json")
    }

    @Test("Scene with scene.pkg + valid scene.json + image asset returns ready scene content")
    func sceneWithPackageAndAssetReturnsReady() async throws {
        // The synthetic scene.json declares one image layer; we ship a real
        // PNG inside the same scene.pkg so the import service classifies it
        // as `.imageOnly`.
        let pngBytes = try makeFixturePNG(width: 4, height: 4)
        let sceneJSON = """
        {
            "camera": { "center": "0 0 0" },
            "general": {
                "orthogonalprojection": { "width": 1920, "height": 1080, "auto": true }
            },
            "objects": [{
                "id": "layer1",
                "name": "Layer 1",
                "type": "image",
                "image": "materials/layer1.png",
                "origin": "0.5 0.5 0",
                "scale": "1 1 1",
                "alpha": 1.0,
                "blendmode": "normal"
            }]
        }
        """
        let fixture = try makeFixture(
            type: .scene,
            entryFile: "scene.json",
            pkgEntries: [
                PackageEntrySpec("scene.json", Array(sceneJSON.utf8)),
                PackageEntrySpec("materials/layer1.png", Array(pngBytes))
            ]
        )
        defer { fixture.cleanup() }

        let result = try await fixture.service.importProject(folder: fixture.folderURL)

        guard case .ready(let content, let origin) = result else {
            Issue.record("Expected .ready, got \(result)")
            return
        }
        guard case .scene(let descriptor) = content else {
            Issue.record("Expected .scene content, got \(content)")
            return
        }
        #expect(descriptor.workshopID == fixture.workshopID)
        #expect(descriptor.cacheRelativePath == "wpe-cache/\(fixture.workshopID)")
        #expect(descriptor.entryFile == "scene.json")
        #expect(descriptor.capabilityTier == .imageOnly)
        #expect(origin.cacheRelativePath == "wpe-cache/\(fixture.workshopID)")
        #expect(origin.resourceLocation == .cache)
    }

    @Test("Scene with image layers AND unsupported objects is classified degraded")
    func sceneWithMixedObjectsIsDegraded() async throws {
        let pngBytes = try makeFixturePNG(width: 4, height: 4)
        let sceneJSON = """
        {
            "camera": { "center": "0 0 0" },
            "general": {
                "orthogonalprojection": { "width": 1920, "height": 1080, "auto": true }
            },
            "objects": [
                {
                    "id": "layer1",
                    "name": "Layer 1",
                    "type": "image",
                    "image": "materials/layer1.png"
                },
                {
                    "id": "particle1",
                    "name": "Sparks",
                    "type": "particle"
                }
            ]
        }
        """
        let fixture = try makeFixture(
            type: .scene,
            entryFile: "scene.json",
            pkgEntries: [
                PackageEntrySpec("scene.json", Array(sceneJSON.utf8)),
                PackageEntrySpec("materials/layer1.png", Array(pngBytes))
            ]
        )
        defer { fixture.cleanup() }

        let result = try await fixture.service.importProject(folder: fixture.folderURL)

        guard case .ready(let content, _) = result else {
            Issue.record("Expected .ready, got \(result)")
            return
        }
        guard case .scene(let descriptor) = content else {
            Issue.record("Expected .scene content, got \(content)")
            return
        }
        // The image layer renders but the particle layer doesn't — this is
        // exactly the case the plan's `.degraded` tier is meant to signal so
        // the UI can warn the user even though the image-only renderer
        // happily mounts the SKScene.
        #expect(descriptor.capabilityTier == .degraded)
    }

    @Test("Scene whose declared layers are all missing assets is classified unsupported")
    func sceneWithMissingAssetsIsUnsupported() async throws {
        let sceneJSON = """
        {
            "camera": { "center": "0 0 0" },
            "general": {
                "orthogonalprojection": { "width": 1920, "height": 1080, "auto": true }
            },
            "objects": [{
                "id": "layer1",
                "name": "Layer 1",
                "type": "image",
                "image": "materials/missing.png"
            }]
        }
        """
        let fixture = try makeFixture(
            type: .scene,
            entryFile: "scene.json",
            pkgEntries: [
                PackageEntrySpec("scene.json", Array(sceneJSON.utf8))
            ]
        )
        defer { fixture.cleanup() }

        let result = try await fixture.service.importProject(folder: fixture.folderURL)

        guard case .unsupported(let origin) = result else {
            Issue.record("Expected .unsupported, got \(result)")
            return
        }
        // Cache extraction still happened for the unsupported scene — the
        // origin records the cache path so a future user-driven re-attempt
        // (e.g. workshop ships a fix) can re-evaluate without re-extracting.
        #expect(origin.cacheRelativePath == "wpe-cache/\(fixture.workshopID)")
        #expect(origin.resourceLocation == .cache)
    }

    @Test("Cached content resolver rebuilds scene descriptor without re-parsing scene.json")
    func cachedContentResolverRebuildsSceneDescriptor() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: rootURL) }
        let appSupportRoot = rootURL.appendingPathComponent("ApplicationSupport/LiveWallpaper", isDirectory: true)
        let cacheURL = appSupportRoot.appendingPathComponent("wpe-cache/resolve-scene", isDirectory: true)
        try fileManager.createDirectory(at: cacheURL, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: cacheURL.appendingPathComponent("scene.json"))

        let origin = WPEOrigin(
            workshopID: "resolve-scene",
            title: "Cached Scene",
            originalType: .scene,
            sourceFolderBookmark: Data("missing-source".utf8),
            cacheRelativePath: "wpe-cache/resolve-scene",
            previewFileName: nil,
            entryFile: "scene.json",
            resourceLocation: .cache
        )
        let resolver = WPECachedContentResolver(
            applicationSupportRootURL: appSupportRoot,
            makeBookmark: { url in Data(url.path.utf8) }
        )

        guard case .scene(let descriptor) = resolver.content(for: origin) else {
            Issue.record("Expected cached scene content")
            return
        }
        #expect(descriptor.workshopID == "resolve-scene")
        #expect(descriptor.cacheRelativePath == "wpe-cache/resolve-scene")
        #expect(descriptor.entryFile == "scene.json")
    }

    @Test("Cached content resolver rebuilds packaged video without source folder access")
    func cachedContentResolverRebuildsPackagedVideoWithoutSourceFolderAccess() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: rootURL) }
        let appSupportRoot = rootURL.appendingPathComponent("ApplicationSupport/LiveWallpaper", isDirectory: true)
        let cacheURL = appSupportRoot.appendingPathComponent("wpe-cache/resolve-video", isDirectory: true)
        try fileManager.createDirectory(at: cacheURL, withIntermediateDirectories: true)
        let videoURL = cacheURL.appendingPathComponent("video.mp4")
        try Data([0x00, 0x01]).write(to: videoURL)

        let origin = WPEOrigin(
            workshopID: "resolve-video",
            title: "Cached Video",
            originalType: .video,
            sourceFolderBookmark: Data("missing-source".utf8),
            cacheRelativePath: "wpe-cache/resolve-video",
            previewFileName: nil,
            entryFile: "video.mp4",
            resourceLocation: .cache
        )
        let resolver = WPECachedContentResolver(
            applicationSupportRootURL: appSupportRoot,
            makeBookmark: { url in Data(url.path.utf8) }
        )

        let content = resolver.content(for: origin)

        guard case .video(let bookmarkData) = content else {
            Issue.record("Expected cached video content, got \(String(describing: content))")
            return
        }
        #expect(bookmarkData == Data(videoURL.path.utf8))
    }

    @Test("Bulk import failure summary reports rejected projects")
    func bulkImportFailureSummaryReportsRejectedProjects() {
        let message = WPEBulkImportFailureSummary.message(for: [
            .init(title: "Broken One", reason: "Missing scene.pkg"),
            .init(title: "Broken Two", reason: "Invalid package")
        ])

        #expect(message?.contains("2 imports failed") == true)
        #expect(message?.contains("Broken One: Missing scene.pkg") == true)
        #expect(message?.contains("Broken Two: Invalid package") == true)
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

    /// Produces a real (decodable) PNG so `SceneResourceResolver.exists`
    /// returns true for image-only capability detection.
    private func makeFixturePNG(width: Int, height: Int) throws -> Data {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "fixture", code: -1)
        }
        context.setFillColor(CGColor(red: 1, green: 0.5, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw NSError(domain: "fixture", code: -2)
        }
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "fixture", code: -3)
        }
        CGImageDestinationAddImage(dest, image, nil)
        if !CGImageDestinationFinalize(dest) {
            throw NSError(domain: "fixture", code: -4)
        }
        return mutableData as Data
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
