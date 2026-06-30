import CoreText
import Foundation
import Metal
import Testing
@testable import LiveWallpaper

@MainActor
struct WPETextRendererTests {

    @Test("WPE systemfont_<family> refs map to OS fonts, not packaged files")
    func systemFontReferenceMapsToOSFont() throws {
        #expect(WPESystemFont.isReference("systemfont_arial"))
        #expect(WPESystemFont.isReference("fonts/Monofur.ttf") == false)
        #expect(WPESystemFont.familyName(for: "systemfont_arial") == "Arial")
        #expect(WPESystemFont.familyName(for: "systemfont_comic_sans_ms") == "Comic Sans Ms")
        // CoreText resolves the family by name (Arial ships on macOS) rather than treating it as a
        // missing asset path; an unknown name still yields a usable font, never a crash.
        let font = WPESystemFont.font(for: "systemfont_arial", size: 32)
        #expect(CTFontGetSize(font) == 32)
    }

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
        #expect(text.color.x == 1 && text.color.y == 0 && text.color.z == 0)
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
            fontRelativePath: nil,
            pointSize: 48,
            color: SIMD3<Double>(1, 1, 1),
            alpha: 1,
            origin: SIMD3<Double>(0, 0, 0),
            scale: SIMD3<Double>(1, 1, 1),
            visible: true,
            horizontalAlignment: "center",
            verticalAlignment: "middle",
            maxWidth: nil,
            parallaxDepth: SIMD2<Double>(0, 0)
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
            parallaxDepth: SIMD2<Double>(0, 0)
        )
        let first = try #require(renderer.rasterize(object))
        let second = try #require(renderer.rasterize(object))
        #expect(first.texture === second.texture)
    }

    @Test("Box-fit text memoizes the font-size measurement and stays cache-coherent")
    func boxFitTextMemoizesFontSize() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let resolver = WPEMultiRootResourceResolver(
            primaryRootURL: FileManager.default.temporaryDirectory,
            dependencyMounts: []
        )
        let renderer = WPETextRenderer(device: device, resolver: resolver)
        func object(box: SIMD2<Double>?) -> WPESceneTextObject {
            WPESceneTextObject(
                id: "1", name: "Boxed", text: "Fit me",
                fontRelativePath: nil, pointSize: 32,
                color: SIMD3<Double>(1, 1, 1), alpha: 1,
                origin: SIMD3<Double>(0, 0, 0), scale: SIMD3<Double>(1, 1, 1),
                visible: true, horizontalAlignment: "center", verticalAlignment: "middle",
                maxWidth: nil, parallaxDepth: SIMD2<Double>(0, 0),
                boxSize: box, padding: 8
            )
        }
        let boxed = object(box: SIMD2<Double>(400, 200))
        let first = try #require(renderer.rasterize(boxed))
        let second = try #require(renderer.rasterize(boxed))
        #expect(first.texture === second.texture)
        // Box-fit scaling actually applied: the box-fit render differs in size
        // from the same text at raw pointSize (proves the memoized effectiveFontSize
        // returns the scaled value, not the base).
        let unboxed = try #require(renderer.rasterize(object(box: nil)))
        #expect(first.size != unboxed.size)
    }

    @Test("Rasterized texture is a neutral coverage mask, not baked color")
    func rasterizesNeutralCoverageMask() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let resolver = WPEMultiRootResourceResolver(
            primaryRootURL: FileManager.default.temporaryDirectory,
            dependencyMounts: []
        )
        let renderer = WPETextRenderer(device: device, resolver: resolver)
        // Authored RED: the old baked path would have produced red pixels. The
        // mask must stay neutral (premultiplied white ⇒ rgb == alpha); color is
        // applied only by the overlay shader at draw time.
        let object = WPESceneTextObject(
            id: "1", name: "Mask", text: "W",
            fontRelativePath: nil, pointSize: 64,
            color: SIMD3<Double>(1, 0, 0), alpha: 1,
            origin: SIMD3<Double>(0, 0, 0), scale: SIMD3<Double>(1, 1, 1),
            visible: true, horizontalAlignment: "center", verticalAlignment: "middle",
            maxWidth: nil, parallaxDepth: SIMD2<Double>(0, 0)
        )
        let tex = try #require(renderer.rasterize(object)).texture
        let bytesPerRow = tex.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * tex.height)
        bytes.withUnsafeMutableBytes { ptr in
            tex.getBytes(
                ptr.baseAddress!,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, tex.width, tex.height),
                mipmapLevel: 0
            )
        }
        var maxAlpha = 0
        var maxChannelDelta = 0
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let a = Int(bytes[i + 3])
            maxAlpha = max(maxAlpha, a)
            maxChannelDelta = max(maxChannelDelta, abs(Int(bytes[i]) - a))
            maxChannelDelta = max(maxChannelDelta, abs(Int(bytes[i + 1]) - a))
            maxChannelDelta = max(maxChannelDelta, abs(Int(bytes[i + 2]) - a))
        }
        #expect(maxAlpha > 0)           // glyph actually rasterized
        #expect(maxChannelDelta <= 2)   // neutral premultiplied white, not red
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
