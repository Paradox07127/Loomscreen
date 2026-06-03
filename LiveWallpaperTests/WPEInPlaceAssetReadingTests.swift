#if !LITE_BUILD
import Foundation
import Testing
@testable import LiveWallpaper

/// Phase 1 of the in-place asset-reading migration: locks the `WPESceneAssetProvider`
/// backends, package canonical-name lookups, and `SceneDescriptor.assetStorage`
/// persistence (including back-compat with descriptors written before the field).
@Suite("WPE in-place asset reading — Phase 1")
struct WPEInPlaceAssetReadingTests {

    // MARK: - Helpers

    private func u32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    /// Builds a minimal valid `scene.pkg` byte stream from `(name, bytes)` pairs.
    private func makePackageData(_ entries: [(name: String, data: Data)]) -> Data {
        var header = Data()
        let magic = "PKGV0001"
        header.append(u32(UInt32(magic.utf8.count)))
        header.append(contentsOf: magic.utf8)
        header.append(u32(UInt32(entries.count)))

        var blob = Data()
        var offset: UInt32 = 0
        for entry in entries {
            let nameBytes = Array(entry.name.utf8)
            header.append(u32(UInt32(nameBytes.count)))
            header.append(contentsOf: nameBytes)
            header.append(u32(offset))
            header.append(u32(UInt32(entry.data.count)))
            blob.append(entry.data)
            offset += UInt32(entry.data.count)
        }
        return header + blob
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("inplace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - canonicalLookupName

    @Test("canonicalLookupName normalizes and rejects traversal")
    func canonicalLookupNameNormalizes() {
        #expect(WallpaperEnginePackage.canonicalLookupName("./materials/a.tex") == "materials/a.tex")
        #expect(WallpaperEnginePackage.canonicalLookupName("a//b/c") == "a/b/c")
        #expect(WallpaperEnginePackage.canonicalLookupName("scene.json") == "scene.json")
        #expect(WallpaperEnginePackage.canonicalLookupName("../escape") == nil)
        #expect(WallpaperEnginePackage.canonicalLookupName("/abs") == nil)
        #expect(WallpaperEnginePackage.canonicalLookupName("") == nil)
        #expect(WallpaperEnginePackage.canonicalLookupName(".") == nil)
        // A name that merely contains ".." (not a traversal component) is valid.
        #expect(WallpaperEnginePackage.canonicalLookupName("image..png") == "image..png")
    }

    // MARK: - Directory provider

    @Test("Directory provider reads, reports existence, rejects escapes")
    func directoryProviderReadsAndContains() throws {
        let root = try makeTempDir()
        try "hello".data(using: .utf8)!.write(to: root.appendingPathComponent("scene.json"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("materials"), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("materials/a.tex"))

        let provider = WPEDirectorySceneAssetProvider(rootURL: root)

        #expect(try provider.data(atRelativePath: "scene.json") == "hello".data(using: .utf8))
        #expect(provider.exists(atRelativePath: "materials/a.tex"))
        #expect(!provider.exists(atRelativePath: "missing.json"))
        // A directory is not a readable regular file.
        #expect(!provider.exists(atRelativePath: "materials"))
        // Escapes are rejected, never resolved against the tree.
        #expect(throws: WPESceneAssetProviderError.self) {
            _ = try provider.data(atRelativePath: "../escape")
        }
        #expect(!provider.exists(atRelativePath: "../escape"))
        #expect(provider.entryNames.contains("scene.json"))
        #expect(provider.entryNames.contains("materials/a.tex"))
    }

    // MARK: - Package provider

    @Test("Package provider reads entries in place and matches canonical lookups")
    func packageProviderReadsInPlace() throws {
        let root = try makeTempDir()
        let sceneJSON = #"{"k":"v"}"#.data(using: .utf8)!
        let texBytes = Data([0xAA, 0xBB, 0xCC, 0xDD])
        let pkg = makePackageData([
            (name: "scene.json", data: sceneJSON),
            (name: "materials/a.tex", data: texBytes)
        ])
        let pkgURL = root.appendingPathComponent("scene.pkg")
        try pkg.write(to: pkgURL)

        let provider = try WPEPackageSceneAssetProvider(packageURL: pkgURL)

        #expect(try provider.data(atRelativePath: "scene.json") == sceneJSON)
        // Case-insensitive + normalized lookup, mirroring the directory scheme.
        #expect(try provider.data(atRelativePath: "./materials/a.tex") == texBytes)
        #expect(provider.exists(atRelativePath: "materials/a.tex"))
        #expect(!provider.exists(atRelativePath: "missing.tex"))
        #expect(!provider.exists(atRelativePath: "../escape"))
        #expect(throws: WPESceneAssetProviderError.self) {
            _ = try provider.data(atRelativePath: "missing.tex")
        }
        #expect(provider.entryNames == ["materials/a.tex", "scene.json"])
    }

    @Test("Package provider stages an entry to a readable file URL")
    func packageProviderStagesURL() throws {
        let root = try makeTempDir()
        let payload = Data((0..<2048).map { UInt8($0 & 0xFF) })
        let pkg = makePackageData([(name: "audio/clip.mp3", data: payload)])
        let pkgURL = root.appendingPathComponent("scene.pkg")
        try pkg.write(to: pkgURL)

        let provider = try WPEPackageSceneAssetProvider(packageURL: pkgURL)
        let staged = try provider.stagedURL(atRelativePath: "audio/clip.mp3", purpose: .audioPlayback)
        defer { staged.release() }

        #expect(FileManager.default.fileExists(atPath: staged.url.path))
        #expect(try Data(contentsOf: staged.url) == payload)
    }

    // MARK: - SceneDescriptor.assetStorage

    @Test("SceneDescriptor without assetStorage decodes as .cache")
    func descriptorDefaultsToCacheStorage() throws {
        let payload: [String: Any] = [
            "workshopID": "abc",
            "cacheRelativePath": "wpe-cache/abc",
            "entryFile": "scene.json",
            "capabilityTier": "imageOnly"
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)
        let decoded = try JSONDecoder().decode(SceneDescriptor.self, from: data)
        #expect(decoded.assetStorage == .cache)
    }

    @Test("SceneDescriptor with .cache storage omits the key on encode")
    func descriptorCacheStorageNotEncoded() throws {
        let descriptor = SceneDescriptor(
            workshopID: "abc",
            cacheRelativePath: "wpe-cache/abc",
            entryFile: "scene.json",
            capabilityTier: .imageOnly
        )
        let data = try JSONEncoder().encode(descriptor)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["assetStorage"] == nil)
    }

    @Test("SceneDescriptor round-trips packageSource and sourceDirectory storage")
    func descriptorStorageRoundTrips() throws {
        for storage in [SceneAssetStorage.packageSource(fileName: "scene.pkg"), .sourceDirectory] {
            let descriptor = SceneDescriptor(
                workshopID: "id",
                cacheRelativePath: "wpe-cache/id",
                entryFile: "scene.json",
                capabilityTier: .degraded,
                assetStorage: storage
            )
            let data = try JSONEncoder().encode(descriptor)
            let decoded = try JSONDecoder().decode(SceneDescriptor.self, from: data)
            #expect(decoded == descriptor)
            #expect(decoded.assetStorage == storage)
        }
    }
}
#endif
