import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import LiveWallpaper

@Suite("SceneResourceResolver")
struct SceneResourceResolverTests {

    @Test("Image inside the cache root decodes successfully")
    func imageInsideCacheRoot() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try writePNG(at: fixture.cacheRoot.appendingPathComponent("layer.png"))

        let resolver = SceneResourceResolver(cacheRootURL: fixture.cacheRoot)
        let image = try resolver.resolveImage(relativePath: "layer.png")

        #expect(image.width > 0)
        #expect(image.height > 0)
    }

    @Test("Path traversal via .. is rejected")
    func pathTraversalRejected() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data("secret".utf8).write(to: fixture.root.appendingPathComponent("secret.png"))

        let resolver = SceneResourceResolver(cacheRootURL: fixture.cacheRoot)

        #expect(throws: SceneResourceResolver.ResolveError.pathEscape) {
            try resolver.resolveImage(relativePath: "../secret.png")
        }
    }

    @Test("Absolute path is rejected")
    func absolutePathRejected() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let resolver = SceneResourceResolver(cacheRootURL: fixture.cacheRoot)

        #expect(throws: SceneResourceResolver.ResolveError.pathEscape) {
            try resolver.resolveImage(relativePath: "/etc/passwd")
        }
    }

    @Test("Symlink that escapes cache root is rejected after resolution")
    func symlinkEscapeRejected() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let secret = fixture.root.appendingPathComponent("secret.png")
        try writePNG(at: secret)
        let symlinkURL = fixture.cacheRoot.appendingPathComponent("escape.png")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: secret)

        let resolver = SceneResourceResolver(cacheRootURL: fixture.cacheRoot)

        #expect(throws: SceneResourceResolver.ResolveError.pathEscape) {
            try resolver.resolveImage(relativePath: "escape.png")
        }
    }

    @Test("Truncated .tex surfaces as a texture-specific resolve error")
    func texTruncatedSurfacesTextureError() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data([0x00, 0x01]).write(to: fixture.cacheRoot.appendingPathComponent("layer.tex"))

        let resolver = SceneResourceResolver(cacheRootURL: fixture.cacheRoot)

        do {
            _ = try resolver.resolveImage(relativePath: "layer.tex")
            Issue.record("Expected resolveImage to throw on truncated .tex")
        } catch SceneResourceResolver.ResolveError.texture(let texError) {
            switch texError {
            case .truncatedBlock, .unsupportedContainer:
                break
            default:
                Issue.record("Expected truncatedBlock/unsupportedContainer, got \(texError)")
            }
        } catch {
            Issue.record("Expected ResolveError.texture, got \(error)")
        }
    }

    @Test("Probe rejects MP4-backed .tex that advertises RGBA8888")
    func texProbeRejectsMP4BackedRGBA() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try writeRGBA8888Tex(
            at: fixture.cacheRoot.appendingPathComponent("video.tex"),
            width: 1,
            height: 1,
            payload: mp4HeaderPayload()
        )

        let resolver = SceneResourceResolver(cacheRootURL: fixture.cacheRoot)
        let result = resolver.probeImage(relativePath: "video.tex")
        guard case .failure(.texture(.unsupportedAnimation)) = result else {
            Issue.record("Expected unsupportedAnimation for MP4-backed .tex probe, got \(result)")
            return
        }
    }

    @Test("Model wrapper JSON resolves to materials/<name>.tex via material chain")
    func materialChainResolves() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let modelsDir = fixture.cacheRoot.appendingPathComponent("models", isDirectory: true)
        let materialsDir = fixture.cacheRoot.appendingPathComponent("materials", isDirectory: true)
        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: materialsDir, withIntermediateDirectories: true)

        try Data("""
        { "autosize": true, "material": "materials/foo.json" }
        """.utf8).write(to: modelsDir.appendingPathComponent("foo.json"))
        try Data("""
        { "passes": [{ "textures": ["foo"], "shader": "genericimage4" }] }
        """.utf8).write(to: materialsDir.appendingPathComponent("foo.json"))
        try writeRGBA8888Tex(at: materialsDir.appendingPathComponent("foo.tex"))

        let resolver = SceneResourceResolver(cacheRootURL: fixture.cacheRoot)
        let image = try resolver.resolveImage(relativePath: "models/foo.json")

        #expect(image.width == 4)
        #expect(image.height == 4)
    }

    @Test("Renderable probe follows model material chain to terminal asset")
    func renderableProbeFollowsMaterialChain() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let modelsDir = fixture.cacheRoot.appendingPathComponent("models", isDirectory: true)
        let materialsDir = fixture.cacheRoot.appendingPathComponent("materials", isDirectory: true)
        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: materialsDir, withIntermediateDirectories: true)
        try Data(#"{ "material": "materials/foo.json" }"#.utf8).write(to: modelsDir.appendingPathComponent("foo.json"))
        try Data(#"{ "passes": [{ "textures": ["missing"], "shader": "genericimage4" }] }"#.utf8).write(to: materialsDir.appendingPathComponent("foo.json"))

        let resolver = SceneResourceResolver(cacheRootURL: fixture.cacheRoot)
        let result = resolver.probeRenderableImage(relativePath: "models/foo.json")

        guard case .failure(.fileMissing) = result else {
            Issue.record("Expected missing terminal texture, got \(result)")
            return
        }
    }

    @Test("Built-in util model surfaces materialUnresolved with a friendly hint")
    func builtinUtilModelSurfacesPrecisely() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let resolver = SceneResourceResolver(cacheRootURL: fixture.cacheRoot)

        do {
            _ = try resolver.resolveImage(relativePath: "models/util/solidlayer.json")
            Issue.record("Expected materialUnresolved")
        } catch SceneResourceResolver.ResolveError.materialUnresolved(let reason) {
            #expect(reason.contains("Built-in"))
        } catch {
            Issue.record("Expected materialUnresolved, got \(error)")
        }
    }

    @Test("JSON wrapper without material/passes fields surfaces materialUnresolved")
    func malformedDescriptorSurfacesUnresolved() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let modelsDir = fixture.cacheRoot.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        try Data("""
        { "autosize": true, "puppet": "models/foo_puppet.mdl" }
        """.utf8).write(to: modelsDir.appendingPathComponent("foo.json"))

        let resolver = SceneResourceResolver(cacheRootURL: fixture.cacheRoot)
        do {
            _ = try resolver.resolveImage(relativePath: "models/foo.json")
            Issue.record("Expected materialUnresolved")
        } catch SceneResourceResolver.ResolveError.materialUnresolved {
        } catch {
            Issue.record("Expected materialUnresolved, got \(error)")
        }
    }

    @Test("Missing file throws fileMissing")
    func missingFileThrows() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let resolver = SceneResourceResolver(cacheRootURL: fixture.cacheRoot)

        #expect(throws: SceneResourceResolver.ResolveError.fileMissing) {
            try resolver.resolveImage(relativePath: "missing.png")
        }
    }

    // MARK: - Fixture helpers

    private struct Fixture {
        let root: URL
        let cacheRoot: URL
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SceneResourceResolverTests-\(UUID().uuidString)", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        return Fixture(root: root, cacheRoot: cacheRoot)
    }

    /// Writes a synthetic 4×4 RGBA8888 `.tex` file matching the RePKG / linux-wallpaperengine layout (TEXV0005 / TEXI0001 / TEXB0003).
    private func writeRGBA8888Tex(
        at url: URL,
        width: Int = 4,
        height: Int = 4,
        payload: Data? = nil
    ) throws {
        var data = Data()
        func appendMagic(_ s: String) {
            data.append(contentsOf: s.utf8)
            data.append(0x00)
        }
        func appendInt32(_ v: Int32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        func appendUInt32(_ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        appendMagic("TEXV0005")
        appendMagic("TEXI0001")
        appendInt32(0)
        appendUInt32(0)
        appendInt32(Int32(width))
        appendInt32(Int32(height))
        appendInt32(Int32(width))
        appendInt32(Int32(height))
        appendInt32(0)
        appendMagic("TEXB0003")
        appendInt32(1)
        appendInt32(-1)
        appendInt32(1)
        appendInt32(Int32(width))
        appendInt32(Int32(height))
        appendUInt32(0)
        let pixels = payload ?? Data(repeating: 0xFF, count: width * height * 4)
        appendUInt32(UInt32(pixels.count))
        appendUInt32(UInt32(pixels.count))
        data.append(pixels)
        try data.write(to: url)
    }

    private func mp4HeaderPayload() -> Data {
        Data([
            0x00, 0x00, 0x00, 0x18,
            0x66, 0x74, 0x79, 0x70,
            0x6d, 0x70, 0x34, 0x32,
            0x00, 0x00, 0x00, 0x00,
            0x6d, 0x70, 0x34, 0x32,
            0x69, 0x73, 0x6f, 0x6d
        ])
    }

    private func writePNG(at url: URL) throws {
        guard let context = CGContext(
            data: nil,
            width: 4,
            height: 4,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            Issue.record("Failed to allocate CGContext for fixture PNG")
            return
        }
        context.setFillColor(CGColor(red: 1, green: 0.5, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        guard let image = context.makeImage() else {
            Issue.record("Failed to render fixture PNG")
            return
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            Issue.record("Failed to open PNG destination for fixture")
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        if !CGImageDestinationFinalize(destination) {
            Issue.record("Failed to finalize fixture PNG")
        }
    }
}
