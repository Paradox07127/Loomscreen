import Foundation
import Testing
@testable import LiveWallpaper

/// Always-on coverage for `WPECorpusScanner`. Builds a tiny synthetic
/// corpus on disk (one scene project, one video project, one web project)
/// and asserts the report matches what the scanner should compute. Pairs
/// with `WPECorpusCompatibilityTests` which is the env-gated regression
/// suite against a real Workshop sync folder.
struct WPECorpusScannerTests {

    @Test("Counts project types from synthetic corpus")
    func countsProjectTypesFromSyntheticCorpus() async throws {
        let root = try Self.makeSyntheticCorpus()
        defer { try? FileManager.default.removeItem(at: root) }

        let report = try await WPECorpusScanner(rootURL: root).scan()

        #expect(report.projectCounts[.scene] == 1)
        #expect(report.projectCounts[.video] == 1)
        #expect(report.projectCounts[.web] == 1)
    }

    @Test("Walks unpacked scene folder and tallies object kinds")
    func walksUnpackedSceneFolder() async throws {
        let root = try Self.makeSyntheticCorpus()
        defer { try? FileManager.default.removeItem(at: root) }

        let report = try await WPECorpusScanner(rootURL: root).scan()

        #expect((report.objectKindCounts[.image] ?? 0) >= 1)
        #expect((report.objectKindCounts[.particle] ?? 0) >= 1)
    }

    @Test("Detects shader sources and aggregates names from materials")
    func detectsShaderSourcesAndAggregatesNames() async throws {
        let root = try Self.makeSyntheticCorpus()
        defer { try? FileManager.default.removeItem(at: root) }

        let report = try await WPECorpusScanner(rootURL: root).scan()

        #expect(report.topShaderNames.contains { $0.name == "genericimage4" })
        #expect(report.scenesWithShaderSources >= 1)
        #expect(report.sceneFeatureCounts[.customShaderSource] == 1)
    }

    @Test("Empty corpus returns empty report")
    func emptyCorpusReturnsEmptyReport() async throws {
        let temp = try Self.makeEmptyCorpus()
        defer { try? FileManager.default.removeItem(at: temp) }

        let report = try await WPECorpusScanner(rootURL: temp).scan()

        #expect(report.projectCounts.isEmpty)
        #expect(report.scenePackageCount == 0)
    }

    // MARK: - Fixtures

    private static func makeSyntheticCorpus() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("wpe-corpus-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        try writeUnpackedScene(under: root.appendingPathComponent("100000001"))
        try writeVideoProject(under: root.appendingPathComponent("100000002"))
        try writeWebProject(under: root.appendingPathComponent("100000003"))

        return root
    }

    private static func makeEmptyCorpus() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("wpe-empty-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func writeUnpackedScene(under folder: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let projectJSON = #"""
        {
            "title": "Synthetic Scene",
            "type": "scene",
            "file": "scene.json",
            "preview": "preview.gif"
        }
        """#
        try projectJSON.data(using: .utf8)!.write(to: folder.appendingPathComponent("project.json"))

        let sceneJSON = #"""
        {
            "camera": {"center":"0 0 0","eye":"0 0 1","up":"0 1 0"},
            "general": {"orthogonalprojection":{"width":1920,"height":1080,"auto":true}},
            "objects": [
                {"name":"bg","image":"materials/bg.json","origin":"0 0 0"},
                {"name":"stars","particle":"particles/stars.json","origin":"0 0 0"}
            ]
        }
        """#
        try sceneJSON.data(using: .utf8)!.write(to: folder.appendingPathComponent("scene.json"))

        let materialsURL = folder.appendingPathComponent("materials")
        try fm.createDirectory(at: materialsURL, withIntermediateDirectories: true)
        let materialJSON = #"""
        {"passes":[{"shader":"genericimage4","textures":["bg.tex"]}]}
        """#
        try materialJSON.data(using: .utf8)!.write(to: materialsURL.appendingPathComponent("bg.json"))

        let shadersURL = folder.appendingPathComponent("shaders")
        try fm.createDirectory(at: shadersURL, withIntermediateDirectories: true)
        try Data("// fragment\n".utf8).write(to: shadersURL.appendingPathComponent("genericimage4.frag"))
        try Data("// vertex\n".utf8).write(to: shadersURL.appendingPathComponent("genericimage4.vert"))
    }

    private static func writeVideoProject(under folder: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let json = #"""
        {"title":"Vid","type":"video","file":"clip.mp4","preview":"preview.gif"}
        """#
        try json.data(using: .utf8)!.write(to: folder.appendingPathComponent("project.json"))
        try Data().write(to: folder.appendingPathComponent("clip.mp4"))
    }

    private static func writeWebProject(under folder: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let json = #"""
        {"title":"Web","type":"web","file":"index.html","preview":"preview.jpg"}
        """#
        try json.data(using: .utf8)!.write(to: folder.appendingPathComponent("project.json"))
        try Data("<html></html>".utf8).write(to: folder.appendingPathComponent("index.html"))
    }
}
