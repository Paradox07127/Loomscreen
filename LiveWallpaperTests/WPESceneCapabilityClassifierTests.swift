import Foundation
import Testing
@testable import LiveWallpaper

@Suite("WPESceneCapabilityClassifier")
struct WPESceneCapabilityClassifierTests {

    @Test("Classifier rejects scenes where the declared image reference resolves nowhere")
    func unreachableImageReferenceIsUnsupported() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // No file shipped — the only declared image reference can't be
        // found in the primary cache, in the bundled built-ins, or in any
        // dependency mount. Classifier rejects so the user sees the
        // failure at import time instead of after applying the wallpaper.
        let document = try parseScene(imagePath: "materials/totally-missing.png")

        let tier = WPESceneCapabilityClassifier().capabilityTier(for: document, cacheURL: fixture.cacheRoot)

        #expect(tier == .unsupported)
    }

    @Test("Classifier accepts scenes whose direct image reference resolves even if the deep chain fails")
    func reachableImageReferenceWithBrokenChainIsImageOnly() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // Scene declares a model wrapper that resolves on disk; the inner
        // material references a missing terminal texture. The runtime
        // resolver owns the deep `model.json → material.json → texture`
        // chain walk + graceful degradation when intermediate refs miss
        // (including special runtime tokens like `_rt_FullFrameBuffer`).
        // The import gate just confirms the directly-named entry resolves
        // through *some* mount in the multi-root chain.
        let modelsDir = fixture.cacheRoot.appendingPathComponent("models", isDirectory: true)
        let materialsDir = fixture.cacheRoot.appendingPathComponent("materials", isDirectory: true)
        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: materialsDir, withIntermediateDirectories: true)
        try Data(#"{ "material": "materials/foo.json" }"#.utf8).write(to: modelsDir.appendingPathComponent("foo.json"))
        try Data(#"{ "passes": [{ "textures": ["missing"], "shader": "genericimage4" }] }"#.utf8).write(to: materialsDir.appendingPathComponent("foo.json"))
        let document = try parseScene(imagePath: "models/foo.json")

        let tier = WPESceneCapabilityClassifier().capabilityTier(for: document, cacheURL: fixture.cacheRoot)

        #expect(tier == .imageOnly)
    }

    @Test("Classifier keeps renderable images with unsupported diagnostics degraded")
    func renderableImageWithUnsupportedDiagnosticsIsDegraded() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data("not decoded by probe".utf8).write(to: fixture.cacheRoot.appendingPathComponent("layer.png"))
        let document = try parseScene(
            imagePath: "layer.png",
            extraObject: #"{ "name": "Loop", "sound": { "file": "sounds/loop.ogg" } }"#
        )

        let tier = WPESceneCapabilityClassifier().capabilityTier(for: document, cacheURL: fixture.cacheRoot)

        #expect(tier == .degraded)
    }

    private struct Fixture {
        let root: URL
        let cacheRoot: URL
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPESceneCapabilityClassifierTests-\(UUID().uuidString)", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        return Fixture(root: root, cacheRoot: cacheRoot)
    }

    private func parseScene(imagePath: String, extraObject: String? = nil) throws -> WPESceneDocument {
        let extra = extraObject.map { ",\n\($0)" } ?? ""
        let json = """
        {
            "camera": { "center": "0 0 0" },
            "general": {
                "orthogonalprojection": { "width": 1920, "height": 1080, "auto": true }
            },
            "objects": [
                {
                    "name": "Layer",
                    "image": "\(imagePath)"
                }
                \(extra)
            ]
        }
        """
        return try WPESceneDocumentParser.parse(data: Data(json.utf8))
    }
}
