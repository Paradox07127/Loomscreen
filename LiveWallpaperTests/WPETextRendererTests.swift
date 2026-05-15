import Foundation
import Metal
import Testing
@testable import LiveWallpaper

@MainActor
struct WPETextRendererTests {

    @Test("Parses text object with property-object value wrappers")
    func parsesTextObjectWithWrappedValues() throws {
        let json = #"""
        {
            "camera": {"center":"0 0 0"},
            "general": {"orthogonalprojection":{"width":1920,"height":1080,"auto":true}},
            "objects": [{
                "id": 7,
                "name": "Clock",
                "type": "text",
                "text": "Hello, world",
                "font": "fonts/test.ttf",
                "pointsize": 64,
                "color": {"user":"color","value":"1 0 0"},
                "alpha": {"user":"clockopacity","value": 0.5},
                "origin": "100 200 0",
                "horizontalalign": "left",
                "verticalalign": "top"
            }]
        }
        """#
        let document = try WPESceneDocumentParser.parse(data: Data(json.utf8))
        #expect(document.textObjects.count == 1)
        let text = try #require(document.textObjects.first)
        #expect(text.text == "Hello, world")
        #expect(text.fontRelativePath == "fonts/test.ttf")
        #expect(text.pointSize == 64)
        // Wrapped color → red
        #expect(text.color.x == 1 && text.color.y == 0 && text.color.z == 0)
        // Wrapped alpha → 0.5
        #expect(text.alpha == 0.5)
        #expect(text.origin.x == 100 && text.origin.y == 200)
        #expect(text.horizontalAlignment == "left")
        #expect(text.verticalAlignment == "top")
    }

    @Test("Rasterizes static text into a non-empty MTLTexture")
    func rasterizesStaticText() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let resolver = WPEMultiRootResourceResolver(
            primaryRootURL: FileManager.default.temporaryDirectory,
            dependencyMounts: []
        )
        let renderer = WPETextRenderer(device: device, resolver: resolver)
        let object = WPESceneTextObject(
            id: "1",
            name: "Sample",
            text: "Hi",
            fontRelativePath: nil,  // system fallback
            pointSize: 48,
            color: SIMD3<Double>(1, 1, 1),
            alpha: 1,
            origin: SIMD3<Double>(0, 0, 0),
            scale: SIMD3<Double>(1, 1, 1),
            visible: true,
            horizontalAlignment: "center",
            verticalAlignment: "middle",
            maxWidth: nil,
            parallaxDepth: 0
        )
        let entry = try #require(renderer.rasterize(object))
        #expect(entry.size.width > 0)
        #expect(entry.size.height > 0)
        #expect(entry.texture.width > 0)
        #expect(entry.texture.height > 0)
        #expect(entry.texture.pixelFormat == .rgba8Unorm)
    }

    @Test("Rasterizer caches by content hash — repeated calls return same texture")
    func rasterizerCachesByContentHash() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let resolver = WPEMultiRootResourceResolver(
            primaryRootURL: FileManager.default.temporaryDirectory,
            dependencyMounts: []
        )
        let renderer = WPETextRenderer(device: device, resolver: resolver)
        let object = WPESceneTextObject(
            id: "1",
            name: "Cached",
            text: "Persistent",
            fontRelativePath: nil,
            pointSize: 32,
            color: SIMD3<Double>(0.5, 0.5, 0.5),
            alpha: 1,
            origin: SIMD3<Double>(0, 0, 0),
            scale: SIMD3<Double>(1, 1, 1),
            visible: true,
            horizontalAlignment: "center",
            verticalAlignment: "middle",
            maxWidth: nil,
            parallaxDepth: 0
        )
        let first = try #require(renderer.rasterize(object))
        let second = try #require(renderer.rasterize(object))
        // Identity comparison: both should be the same MTLTexture object
        // because the cache hit returns the previously-allocated entry.
        #expect(first.texture === second.texture)
    }

    @Test("Empty text object is rejected at parse time")
    func emptyTextRejected() throws {
        let json = #"""
        {
            "camera": {"center":"0 0 0"},
            "general": {"orthogonalprojection":{"width":100,"height":100,"auto":true}},
            "objects": [{
                "id": 1,
                "name": "Empty",
                "type": "text",
                "text": "",
                "origin": "0 0 0"
            }]
        }
        """#
        let document = try WPESceneDocumentParser.parse(data: Data(json.utf8))
        #expect(document.textObjects.isEmpty)
    }
}
