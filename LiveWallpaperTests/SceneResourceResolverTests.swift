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

    @Test(".tex texture returns unsupportedTexture without crashing")
    func texTextureUnsupported() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data([0x00, 0x01]).write(to: fixture.cacheRoot.appendingPathComponent("layer.tex"))

        let resolver = SceneResourceResolver(cacheRootURL: fixture.cacheRoot)

        #expect(throws: SceneResourceResolver.ResolveError.unsupportedTexture) {
            try resolver.resolveImage(relativePath: "layer.tex")
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

    /// Writes a 4×4 opaque PNG. ImageIO needs at least a real PNG header
    /// to produce a CGImage; a hand-rolled empty file would yield nil.
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
