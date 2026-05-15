import Foundation
import Testing
@testable import LiveWallpaper

@Suite("WPEMultiRootResourceResolver")
struct WPEMultiRootResourceResolverTests {

    @Test("Dependency reference resolves only through declared mount")
    func dependencyReferenceResolvesThroughDeclaredMount() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let depMaterials = fixture.dependencyRoot.appendingPathComponent("materials", isDirectory: true)
        try FileManager.default.createDirectory(at: depMaterials, withIntermediateDirectories: true)
        try Data("dep".utf8).write(to: depMaterials.appendingPathComponent("dep.png"))

        let resolver = WPEMultiRootResourceResolver(
            primaryRootURL: fixture.primaryRoot,
            dependencyMounts: [WPEAssetMount(workshopID: "123", rootURL: fixture.dependencyRoot)]
        )

        let url = try resolver.resolveExistingFileURL(relativePath: "../123/materials/dep.png")

        #expect(url.lastPathComponent == "dep.png")
    }

    @Test("Engine assets fallback resolves only after primary miss")
    func engineAssetsFallbackResolvesOnlyAfterPrimaryMiss() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let primaryMaterials = fixture.primaryRoot.appendingPathComponent("materials/util", isDirectory: true)
        let engineMaterials = fixture.engineRoot.appendingPathComponent("assets/materials/util", isDirectory: true)
        try FileManager.default.createDirectory(at: primaryMaterials, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: engineMaterials, withIntermediateDirectories: true)
        try Data("primary".utf8).write(to: primaryMaterials.appendingPathComponent("composelayer.json"))
        try Data("engine".utf8).write(to: engineMaterials.appendingPathComponent("fallback.json"))

        let resolver = WPEMultiRootResourceResolver(
            primaryRootURL: fixture.primaryRoot,
            dependencyMounts: [],
            engineAssetsRootURL: fixture.engineRoot
        )

        let primaryURL = try resolver.resolveExistingFileURL(relativePath: "materials/util/composelayer.json")
        let fallbackURL = try resolver.resolveExistingFileURL(relativePath: "materials/util/fallback.json")

        #expect(String(data: try Data(contentsOf: primaryURL), encoding: .utf8) == "primary")
        #expect(String(data: try Data(contentsOf: fallbackURL), encoding: .utf8) == "engine")
    }

    @Test("Engine assets fallback does not shadow project's own files")
    func engineAssetsFallbackDoesNotShadowProjectFiles() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let primaryMaterials = fixture.primaryRoot.appendingPathComponent("materials", isDirectory: true)
        let engineMaterials = fixture.engineRoot.appendingPathComponent("assets/materials", isDirectory: true)
        try FileManager.default.createDirectory(at: primaryMaterials, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: engineMaterials, withIntermediateDirectories: true)
        // Project ships its own copy AND the engine ships a different one
        // at the same relative path. The project copy must always win.
        try Data("project-version".utf8).write(to: primaryMaterials.appendingPathComponent("composelayer.json"))
        try Data("engine-version".utf8).write(to: engineMaterials.appendingPathComponent("composelayer.json"))

        let resolver = WPEMultiRootResourceResolver(
            primaryRootURL: fixture.primaryRoot,
            dependencyMounts: [],
            engineAssetsRootURL: fixture.engineRoot
        )

        let url = try resolver.resolveExistingFileURL(relativePath: "materials/composelayer.json")
        #expect(String(data: try Data(contentsOf: url), encoding: .utf8) == "project-version")
    }

    @Test("Engine assets fallback only triggers on .fileMissing")
    func engineAssetsFallbackOnlyTriggersOnFileMissing() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let resolver = WPEMultiRootResourceResolver(
            primaryRootURL: fixture.primaryRoot,
            dependencyMounts: [],
            engineAssetsRootURL: fixture.engineRoot
        )

        // pathEscape from primary must NOT retry against engine root —
        // pathEscape means the user-supplied path was malformed, not that
        // we picked the wrong root. Use the dependency-style escape path:
        // "../" prefix triggers `dependencyReference` short-circuit but
        // since no mounts are declared it throws pathEscape directly.
        #expect(throws: SceneResourceResolver.ResolveError.pathEscape) {
            _ = try resolver.resolveExistingFileURL(relativePath: "../456/materials/x.png")
        }
    }

    @Test("Undeclared dependency reference is rejected")
    func undeclaredDependencyReferenceRejected() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let resolver = WPEMultiRootResourceResolver(
            primaryRootURL: fixture.primaryRoot,
            dependencyMounts: [],
            engineAssetsRootURL: fixture.engineRoot
        )

        #expect(throws: SceneResourceResolver.ResolveError.pathEscape) {
            _ = try resolver.resolveExistingFileURL(relativePath: "../123/materials/dep.png")
        }
    }

    @Test("Nested traversal inside dependency reference is rejected")
    func dependencyTraversalRejected() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let resolver = WPEMultiRootResourceResolver(
            primaryRootURL: fixture.primaryRoot,
            dependencyMounts: [WPEAssetMount(workshopID: "123", rootURL: fixture.dependencyRoot)]
        )

        #expect(throws: SceneResourceResolver.ResolveError.pathEscape) {
            _ = try resolver.resolveExistingFileURL(relativePath: "../123/../secret.png")
        }
    }

    private struct Fixture {
        let root: URL
        let primaryRoot: URL
        let dependencyRoot: URL
        let engineRoot: URL

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEMultiRootResourceResolverTests-\(UUID().uuidString)", isDirectory: true)
        let primary = root.appendingPathComponent("primary", isDirectory: true)
        let dependency = root.appendingPathComponent("dependency", isDirectory: true)
        let engine = root.appendingPathComponent("engine", isDirectory: true)
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dependency, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: engine, withIntermediateDirectories: true)
        return Fixture(root: root, primaryRoot: primary, dependencyRoot: dependency, engineRoot: engine)
    }
}
