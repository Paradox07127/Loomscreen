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

    @Test("Shape-based object kind detection handles WPE objects without type")
    func shapeBasedObjectKindDetection() throws {
        let payload: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 1, "height": 1, "auto": true]],
            "objects": [
                ["name": "BG", "image": "materials/bg.png"],
                ["name": "Loop", "sound": ["file": "sounds/loop.ogg"]],
                ["name": "Sparks", "particle": ["emitters": []]],
                ["name": "Title", "text": "Hello"],
                ["name": "Lamp", "light": ["color": "1 1 1"]]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])

        let document = try WPESceneDocumentParser.parse(data: data)

        #expect(document.imageObjects.count == 1)
        #expect(document.imageObjects.first?.name == "BG")
        #expect(document.diagnostics.contains(where: { $0.message.contains("Sound object Loop") }))
        #expect(document.diagnostics.contains(where: { $0.message.contains("Particle object Sparks") }))
        #expect(document.diagnostics.contains(where: { $0.message.contains("Text object Title") }))
        #expect(document.diagnostics.contains(where: { $0.message.contains("Light object Lamp") }))
        #expect(!document.diagnostics.contains(where: { $0.message.contains("has no image path") }))
    }

    @Test("Ambiguous WPE object emits warning and preserves renderable image layer")
    func ambiguousObjectEmitsWarningAndPreservesImage() throws {
        let payload: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 1, "height": 1, "auto": true]],
            "objects": [[
                "name": "ImageWithSound",
                "image": "materials/bg.png",
                "sound": ["file": "sounds/loop.ogg"]
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])

        let document = try WPESceneDocumentParser.parse(data: data)

        #expect(document.imageObjects.count == 1)
        #expect(document.diagnostics.contains(where: {
            $0.severity == .warning && $0.message.contains("Ambiguous object ImageWithSound")
        }))
        #expect(document.diagnostics.contains(where: { $0.message.contains("Sound object ImageWithSound") }))
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

    @Test("Image effects preserve file, pass overrides, constants, textures, material, and animation metadata")
    func imageEffectsPreserveRenderMetadata() throws {
        let payload: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 1920, "height": 1080, "auto": true]],
            "objects": [[
                "id": "layer1",
                "name": "Foreground",
                "type": "image",
                "image": "models/foreground.json",
                "material": "materials/foreground.json",
                "effects": [[
                    "id": 7,
                    "name": "Shake",
                    "file": "effects/shake/effect.json",
                    "visible": true,
                    "passes": [[
                        "id": 2,
                        "combos": ["MASK": 1],
                        "constantshadervalues": [
                            "speed": 0.59,
                            "strength": 0.133,
                            "bounds": "0.1 0.2 0.3 0.4"
                        ],
                        "textures": [NSNull(), "masks/shake_mask"]
                    ]]
                ]],
                "animationlayers": [[
                    "id": 3,
                    "rate": 24,
                    "visible": true,
                    "blend": 0.5,
                    "animation": 9
                ]]
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])

        let document = try WPESceneDocumentParser.parse(data: data)

        let layer = try #require(document.imageObjects.first)
        #expect(layer.materialRelativePath == "materials/foreground.json")
        #expect(layer.effects.count == 1)
        let effect = try #require(layer.effects.first)
        #expect(effect.id == "7")
        #expect(effect.name == "Shake")
        #expect(effect.fileRelativePath == "effects/shake/effect.json")
        #expect(effect.visible == true)
        #expect(effect.isShakeEffect)

        let pass = try #require(effect.passOverrides.first)
        #expect(pass.id == 2)
        #expect(pass.combos["MASK"] == 1)
        #expect(pass.constants["speed"]?.numberValue == 0.59)
        #expect(pass.constants["strength"]?.numberValue == 0.133)
        #expect(pass.constants["bounds"]?.vectorValue == [0.1, 0.2, 0.3, 0.4])
        #expect(pass.textures[1] == "masks/shake_mask")

        let animation = try #require(layer.animationLayers.first)
        #expect(animation.id == 3)
        #expect(animation.rate == 24)
        #expect(animation.visible == true)
        #expect(animation.blend == 0.5)
        #expect(animation.animation == 9)
    }

    @Test("Parses image parallax depth from scene object")
    func parsesImageParallaxDepth() throws {
        let json = """
        {
          "camera": { "center": "0 0 0" },
          "general": { "orthogonalprojection": { "width": 100, "height": 50, "auto": true } },
          "objects": [{
            "id": "layer",
            "name": "Layer",
            "type": "image",
            "image": "materials/base.png",
            "parallaxDepth": 0.125
          }]
        }
        """

        let document = try WPESceneDocumentParser.parse(data: Data(json.utf8))
        let object = try #require(document.imageObjects.first)

        #expect(object.parallaxDepth == 0.125)
    }
}
