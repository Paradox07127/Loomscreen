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

    @Test("Undeclared dependency reference is rejected")
    func undeclaredDependencyReferenceRejected() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let resolver = WPEMultiRootResourceResolver(primaryRootURL: fixture.primaryRoot, dependencyMounts: [])

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

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEMultiRootResourceResolverTests-\(UUID().uuidString)", isDirectory: true)
        let primary = root.appendingPathComponent("primary", isDirectory: true)
        let dependency = root.appendingPathComponent("dependency", isDirectory: true)
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dependency, withIntermediateDirectories: true)
        return Fixture(root: root, primaryRoot: primary, dependencyRoot: dependency)
    }
}
