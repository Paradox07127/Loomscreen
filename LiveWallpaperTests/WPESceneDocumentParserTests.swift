import Foundation
import LiveWallpaperCore
import Testing
@testable import LiveWallpaper

@Suite("WPESceneDocumentParser")
struct WPESceneDocumentParserTests {

    @Test("User-property envelope on visible resolves from supplied user values")
    func userPropertyVisibleResolvesFromUserValues() throws {
        let payload: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 1920, "height": 1080, "auto": true]],
            "objects": [[
                "id": "64",
                "name": "Himmel",
                "type": "image",
                "image": "models/himmel.json",
                "visible": ["user": "xme", "value": true]
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)

        // Override xme=false → the bound `visible` flips to hidden.
        let hidden = try WPESceneDocumentParser.parse(data: data, userValues: ["xme": .bool(false)])
        #expect(hidden.imageObjects.first?.visible == false)

        // The binding table records xme → image-object visibility (incremental).
        let visibleBinding = try #require(hidden.propertyBindings["xme"]?.first)
        #expect(visibleBinding.target == .imageObject(id: "64"))
        #expect(visibleBinding.kind == .visible)
        #expect(visibleBinding.action == .incremental)

        // A diff that only flips xme is incremental, not a reload.
        let patch = WPEScenePropertyPatch(
            bindingsByProperty: hidden.propertyBindings,
            oldValues: ["xme": .bool(true)],
            newValues: ["xme": .bool(false)]
        )
        #expect(!patch.requiresReload)
        #expect(patch.incrementalBindings == [visibleBinding])

        // No override for xme → envelope's own default value (true) is kept.
        let shownDefault = try WPESceneDocumentParser.parse(data: data, userValues: [:])
        #expect(shownDefault.imageObjects.first?.visible == true)

        // Legacy parse(data:) keeps working (no user values).
        let legacy = try WPESceneDocumentParser.parse(data: data)
        #expect(legacy.imageObjects.first?.visible == true)
    }

    @Test("Combo bindings are classified as reload")
    func comboBindingsRequireReload() throws {
        let payload: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 1920, "height": 1080, "auto": true]],
            "objects": [[
                "id": "22",
                "name": "Frieren",
                "type": "image",
                "image": "models/fll.json",
                "effects": [[
                    "id": "waves",
                    "file": "effects/waterwaves/effect.json",
                    "passes": [[
                        "id": 1,
                        "combos": ["QUALITY": ["user": "quality", "value": 0]]
                    ]]
                ]]
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let document = try WPESceneDocumentParser.parse(data: data, userValues: ["quality": .number(1)])
        let binding = try #require(document.propertyBindings["quality"]?.first)

        #expect(binding.kind == .combo)
        #expect(binding.action == .reload)
        #expect(WPEScenePropertyPatch(
            bindingsByProperty: document.propertyBindings,
            oldValues: ["quality": .number(0)],
            newValues: ["quality": .number(1)]
        ).requiresReload)
    }

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

    @Test("Image and text alpha animations are preserved and resolve single-shot fades")
    func alphaAnimationsPreserved() throws {
        let alphaFade: [String: Any] = [
            "value": 1,
            "animation": [
                "options": ["fps": 30, "length": 90, "mode": "single"],
                "c0": [
                    ["frame": 0, "value": 1],
                    ["frame": 60, "value": 1],
                    ["frame": 90, "value": 0]
                ]
            ]
        ]
        let payload: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 1920, "height": 1080, "auto": true]],
            "objects": [
                [
                    "id": "intro-image",
                    "name": "Intro Image",
                    "type": "image",
                    "image": "materials/intro.png",
                    "alpha": alphaFade
                ],
                [
                    "id": "intro-text",
                    "name": "Intro Text",
                    "type": "text",
                    "text": "By Author",
                    "alpha": alphaFade
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])

        let document = try WPESceneDocumentParser.parse(data: data)

        let image = try #require(document.imageObjects.first)
        #expect(image.alpha == 1)
        #expect(image.alphaAnimation != nil)
        #expect(image.resolvedAlpha(at: 1) == 1)
        #expect(image.resolvedAlpha(at: 4) == 0)

        let text = try #require(document.textObjects.first)
        #expect(text.alpha == 1)
        #expect(text.alphaAnimation != nil)
        #expect(text.resolvedAlpha(at: 1) == 1)
        #expect(text.resolvedAlpha(at: 4) == 0)
    }

    @Test("WPE 2.8 MSDF text effect keys parse into the text object with neutral defaults")
    func textObjectParsesMSDFEffectKeys() throws {
        let payload: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 1920, "height": 1080, "auto": true]],
            "objects": [
                [
                    "id": "effect-text",
                    "name": "Effect Text",
                    "type": "text",
                    "text": "Glow",
                    "outlinesize": 3,
                    "outlinecolor": "1 0 0",
                    "blursize": 2,
                    "shadowsize": 4,
                    "shadowcolor": "0 0 1",
                    "shadowoffset": "5 -6",
                    "letterspacing": 1.5
                ],
                [
                    "id": "plain-text",
                    "name": "Plain Text",
                    "type": "text",
                    "text": "Plain"
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])

        let document = try WPESceneDocumentParser.parse(data: data)

        let effect = try #require(document.textObjects.first { $0.id == "effect-text" })
        #expect(effect.outlineSize == 3)
        #expect(effect.outlineColor == SIMD3<Double>(1, 0, 0))
        #expect(effect.blurSize == 2)
        #expect(effect.shadowSize == 4)
        #expect(effect.shadowColor == SIMD3<Double>(0, 0, 1))
        #expect(effect.shadowOffset == SIMD2<Double>(5, -6))
        #expect(effect.letterSpacing == 1.5)

        // A 2.7-style text object without effect keys stays neutral, so the
        // CoreText fallback and existing scenes are unaffected.
        let plain = try #require(document.textObjects.first { $0.id == "plain-text" })
        #expect(plain.outlineSize == 0)
        #expect(plain.blurSize == 0)
        #expect(plain.shadowSize == 0)
        #expect(plain.shadowOffset == SIMD2<Double>(0, 0))
        #expect(plain.letterSpacing == 0)
    }

    @Test("Image object inherits parent transform from non-renderable group object")
    func imageObjectInheritsParentTransform() throws {
        let payload: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 1920, "height": 1080, "auto": true]],
            "objects": [
                [
                    "id": 10,
                    "name": "Group",
                    "origin": "100 200 3",
                    "scale": "2 3 4",
                    "angles": "0 0 1.5707963267948966"
                ],
                [
                    "id": 11,
                    "name": "Child",
                    "image": "materials/child.png",
                    "parent": 10,
                    "origin": "10 20 5",
                    "scale": "0.5 2 0.25",
                    "angles": "0.1 0.2 0.3"
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])

        let document = try WPESceneDocumentParser.parse(data: data)

        let layer = try #require(document.imageObjects.first)
        #expect(abs(layer.origin.x - 40) < 0.0001)
        #expect(abs(layer.origin.y - 220) < 0.0001)
        #expect(layer.origin.z == 23)
        #expect(layer.scale == SIMD3<Double>(1, 6, 1))
        #expect(abs(layer.angles.z - 1.8707963267948966) < 0.0001)
    }

    @Test("Child image object adds parent-local Y in scene-up coordinates")
    func childImageOriginYAddsInSceneUpCoordinates() throws {
        let payload: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 3840, "height": 2160, "auto": true]],
            "objects": [
                [
                    "id": 86,
                    "name": "Parent",
                    "origin": "1921 938 0"
                ],
                [
                    "id": 106,
                    "name": "Child",
                    "image": "models/child.json",
                    "parent": 86,
                    "origin": "-607.5 222.5 0"
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])

        let document = try WPESceneDocumentParser.parse(data: data)

        let layer = try #require(document.imageObjects.first)
        #expect(layer.origin == SIMD3<Double>(1313.5, 1160.5, 0))
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
                    "additive": true,
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
        #expect(animation.additive == true)
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

    @Test("Particle object preserves instance overrides")
    func particleObjectPreservesInstanceOverrides() throws {
        let json = """
        {
          "camera": { "center": "0 0 0" },
          "general": { "orthogonalprojection": { "width": 100, "height": 50, "auto": true } },
          "objects": [{
            "id": 17,
            "name": "Leaves",
            "type": "particle",
            "particle": "particles/presets/leaves2.json",
            "instanceoverride": {
              "count": 0.2,
              "rate": 0.7,
              "lifetime": 1.77,
              "size": 0.69,
              "speed": 1.32,
              "alpha": 0.03,
              "colorn": "0.75294 0.75294 0.75294"
            }
          }]
        }
        """

        let document = try WPESceneDocumentParser.parse(data: Data(json.utf8))
        let object = try #require(document.particleObjects.first)
        let override = try #require(object.instanceOverride)

        #expect(override.count == 0.2)
        #expect(override.rate == 0.7)
        #expect(override.lifetime == 1.77)
        #expect(override.size == 0.69)
        #expect(override.speed == 1.32)
        #expect(override.alpha == 0.03)
        let color = try #require(override.color)
        #expect(abs(color.x - 192) < 0.001)
        #expect(abs(color.y - 192) < 0.001)
        #expect(abs(color.z - 192) < 0.001)
    }

    @Test("Particle object inherits parent transform from group object")
    func particleObjectInheritsParentTransform() throws {
        let json = """
        {
          "camera": { "center": "0 0 0" },
          "general": { "orthogonalprojection": { "width": 100, "height": 50, "auto": true } },
          "objects": [
            {
              "id": "group",
              "origin": "1920 1080 0",
              "scale": "2 2 1"
            },
            {
              "id": "leaves",
              "type": "particle",
              "particle": "particles/presets/leaves2.json",
              "parent": "group",
              "origin": "-10 15 0",
              "scale": "0.5 0.25 1"
            }
          ]
        }
        """

        let document = try WPESceneDocumentParser.parse(data: Data(json.utf8))
        let object = try #require(document.particleObjects.first)

        #expect(object.origin == SIMD3<Double>(1900, 1110, 0))
        #expect(object.scale == SIMD3<Double>(1, 0.5, 1))
    }
}
