import Foundation
import Testing
@testable import LiveWallpaper

@Suite("WPEDependencyMountResolver")
struct WPEDependencyMountResolverTests {

    @Test("Cached dependency root is mounted for declared ID")
    func cachedDependencyRootIsMounted() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let cacheDep = fixture.appSupportRoot.appendingPathComponent("wpe-cache/123", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDep, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: cacheDep.appendingPathComponent("scene.json"))

        let mounts = WPEDependencyMountResolver().mounts(
            dependencyWorkshopIDs: ["123"],
            origin: nil,
            applicationSupportRootURL: fixture.appSupportRoot
        )

        #expect(mounts.map(\.workshopID) == ["123"])
        #expect(mounts.first?.rootURL == cacheDep.standardizedFileURL.resolvingSymlinksInPath())
    }

    @Test("Source sibling dependency root is mounted when cache is absent")
    func sourceSiblingDependencyRootIsMounted() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let workshopRoot = fixture.root.appendingPathComponent("workshop", isDirectory: true)
        let source = workshopRoot.appendingPathComponent("main", isDirectory: true)
        let dependency = workshopRoot.appendingPathComponent("456", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dependency, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dependency.appendingPathComponent("project.json"))
        let origin = WPEOrigin(
            workshopID: "main",
            title: "Main",
            originalType: .scene,
            sourceFolderBookmark: try bookmark(for: source),
            cacheRelativePath: "wpe-cache/main",
            previewFileName: nil,
            entryFile: "scene.json",
            resourceLocation: .cache
        )

        let mounts = WPEDependencyMountResolver().mounts(
            dependencyWorkshopIDs: ["456"],
            origin: origin,
            applicationSupportRootURL: fixture.appSupportRoot
        )

        #expect(mounts.map(\.workshopID) == ["456"])
        #expect(mounts.first?.rootURL == dependency.standardizedFileURL.resolvingSymlinksInPath())
    }

    @Test("Packaged source sibling dependency is mounted in place as a package")
    func packagedSourceSiblingDependencyIsMountedAsPackage() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let workshopRoot = fixture.root.appendingPathComponent("workshop", isDirectory: true)
        let source = workshopRoot.appendingPathComponent("main", isDirectory: true)
        let dependency = workshopRoot.appendingPathComponent("456", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dependency, withIntermediateDirectories: true)
        // Packaged dependency: assets live inside scene.pkg (project.json loose).
        try Data("{}".utf8).write(to: dependency.appendingPathComponent("project.json"))
        let pkgURL = dependency.appendingPathComponent("scene.pkg")
        try Data("PKGV0022".utf8).write(to: pkgURL)
        let origin = WPEOrigin(
            workshopID: "main",
            title: "Main",
            originalType: .scene,
            sourceFolderBookmark: try bookmark(for: source),
            cacheRelativePath: "wpe-cache/main",
            previewFileName: nil,
            entryFile: "scene.json",
            resourceLocation: .cache
        )

        let mounts = WPEDependencyMountResolver().mounts(
            dependencyWorkshopIDs: ["456"],
            origin: origin,
            applicationSupportRootURL: fixture.appSupportRoot
        )

        #expect(mounts.map(\.workshopID) == ["456"])
        #expect(mounts.first?.rootURL == nil)
        #expect(mounts.first?.backing == .package(pkgURL.standardizedFileURL.resolvingSymlinksInPath()))
    }

    @Test("Undeclared sibling folders are not mounted")
    func undeclaredSiblingFoldersAreNotMounted() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let workshopRoot = fixture.root.appendingPathComponent("workshop", isDirectory: true)
        let source = workshopRoot.appendingPathComponent("main", isDirectory: true)
        let dependency = workshopRoot.appendingPathComponent("789", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dependency, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dependency.appendingPathComponent("project.json"))
        let origin = WPEOrigin(
            workshopID: "main",
            title: "Main",
            originalType: .scene,
            sourceFolderBookmark: try bookmark(for: source),
            cacheRelativePath: "wpe-cache/main",
            previewFileName: nil,
            entryFile: "scene.json",
            resourceLocation: .cache
        )

        let mounts = WPEDependencyMountResolver().mounts(
            dependencyWorkshopIDs: ["456"],
            origin: origin,
            applicationSupportRootURL: fixture.appSupportRoot
        )

        #expect(mounts.isEmpty)
    }

    private struct Fixture {
        let root: URL
        let appSupportRoot: URL

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEDependencyMountResolverTests-\(UUID().uuidString)", isDirectory: true)
        let appSupportRoot = root.appendingPathComponent("Application Support/LiveWallpaper", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupportRoot, withIntermediateDirectories: true)
        return Fixture(root: root, appSupportRoot: appSupportRoot)
    }

    private func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }
}
