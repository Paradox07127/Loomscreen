import Foundation
import Testing
@testable import LiveWallpaper

@Suite("WPESceneDocumentParser")
struct WPESceneDocumentParserTests {

    // MARK: - Required structure

    @Test("Empty data throws invalidUTF8")
    func emptyDataThrows() {
        #expect(throws: WPESceneDocumentError.invalidUTF8) {
            try WPESceneDocumentParser.parse(data: Data())
        }
    }

    @Test("Top-level array throws rootNotObject")
    func rootArrayThrows() throws {
        let data = try JSONSerialization.data(withJSONObject: [["camera": [:]]], options: [])
        #expect(throws: WPESceneDocumentError.rootNotObject) {
            try WPESceneDocumentParser.parse(data: data)
        }
    }

    @Test("Missing camera throws missingCamera")
    func missingCameraThrows() throws {
        let payload: [String: Any] = ["general": ["clearcolor": "0 0 0"]]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        #expect(throws: WPESceneDocumentError.missingCamera) {
            try WPESceneDocumentParser.parse(data: data)
        }
    }

    @Test("Missing general throws missingGeneral")
    func missingGeneralThrows() throws {
        let payload: [String: Any] = ["camera": ["center": "0 0 0"]]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        #expect(throws: WPESceneDocumentError.missingGeneral) {
            try WPESceneDocumentParser.parse(data: data)
        }
    }

    // MARK: - Flexible vector formats

    @Test("Parser accepts space-separated vector strings, JSON arrays, and dicts")
    func flexibleVectorFormats() throws {
        let payload: [String: Any] = [
            "camera": [
                "center": "0.5 1 2",
                "eye": [3, 4, 5],
                "up": ["x": 0, "y": 1, "z": 0]
            ],
            "general": [
                "orthogonalprojection": ["width": 1920, "height": 1080, "auto": true]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])

        let document = try WPESceneDocumentParser.parse(data: data)

        #expect(document.camera.center.x == 0.5)
        #expect(document.camera.center.y == 1)
        #expect(document.camera.center.z == 2)
        #expect(document.camera.eye == SIMD3<Double>(3, 4, 5))
        #expect(document.camera.up == SIMD3<Double>(0, 1, 0))
    }

    // MARK: - Image objects

    @Test("Image object with happy-path fields populates imageObjects")
    func imageObjectHappyPath() throws {
        let payload: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 1920, "height": 1080, "auto": true]],
            "objects": [[
                "id": "layer1",
                "name": "Background",
                "type": "image",
                "image": "materials/bg.png",
                "origin": "0.5 0.5 0",
                "scale": "1 1 1",
                "alpha": 0.85,
                "blendmode": "additive",
                "visible": true,
                "alignment": "center",
                "size": [512, 512, 0]
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])

        let document = try WPESceneDocumentParser.parse(data: data)

        #expect(document.imageObjects.count == 1)
        let layer = try #require(document.imageObjects.first)
        #expect(layer.name == "Background")
        #expect(layer.imageRelativePath == "materials/bg.png")
        #expect(layer.alpha == 0.85)
        #expect(layer.blendMode == .additive)
        #expect(layer.alignment == .center)
        #expect(layer.size == CGSize(width: 512, height: 512))
    }

    @Test("Unsupported object types emit info diagnostics and do not abort the parse")
    func unsupportedObjectsEmitDiagnostics() throws {
        let payload: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 1, "height": 1, "auto": true]],
            "objects": [
                ["type": "image", "image": "a.png", "name": "A"],
                ["type": "particle", "name": "Sparks"],
                ["type": "text", "name": "Title"],
                ["type": "sound", "name": "Loop"]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])

        let document = try WPESceneDocumentParser.parse(data: data)

        #expect(document.imageObjects.count == 1)
        #expect(document.diagnostics.contains(where: { $0.message.contains("Particle") }))
        #expect(document.diagnostics.contains(where: { $0.message.contains("Text") }))
        #expect(document.diagnostics.contains(where: { $0.message.contains("Sound") }))
    }

    @Test(".tex texture path emits a warning diagnostic")
    func texTextureEmitsWarning() throws {
        let payload: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 1, "height": 1, "auto": true]],
            "objects": [[
                "type": "image",
                "image": "materials/sky.tex",
                "name": "Sky"
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])

        let document = try WPESceneDocumentParser.parse(data: data)

        #expect(document.imageObjects.first?.imageRelativePath == "materials/sky.tex")
        #expect(document.diagnostics.contains(where: { $0.severity == .warning && $0.message.contains(".tex") }))
    }
}
