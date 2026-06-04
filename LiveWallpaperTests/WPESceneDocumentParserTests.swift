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

    @Test("Property-bound {user,value} scale resolves (not default 1.0) through parent composition")
    func propertyBoundScaleResolvesThroughParentComposition() throws {
        // Mirrors scene 3460973721's audio-bar layer: a child composelayer whose
        // scale is bound to a user property as {"user":…,"value":"0.5 0.5 0.5"}.
        // Before the WPEValueParser.vector3 `value`-unwrap, this parsed as the 1.0
        // default, doubling the rendered box. The parent group has no own scale.
        let payload: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 3840, "height": 2160, "auto": true]],
            "objects": [
                ["id": 20, "name": "Group", "origin": "0 0 0"],
                [
                    "id": 21,
                    "name": "Audio",
                    "image": "models/util/composelayer.json",
                    "parent": 20,
                    "origin": "0 0 0",
                    "scale": ["user": "newproperty11", "value": "0.5 0.5 0.5"]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        let document = try WPESceneDocumentParser.parse(data: data)
        let layer = try #require(document.imageObjects.first)
        #expect(abs(layer.scale.x - 0.5) < 0.0001)
        #expect(abs(layer.scale.y - 0.5) < 0.0001)
    }

    @Test("Uniform scalar scale (a lone number) resolves to all axes, not the 1.0 default")
    func uniformScalarScaleResolvesToAllAxes() throws {
        // The real on-device shape (scene 3460973721): once WPE/the app resolves the
        // "Scale Size" slider, the object's scale is written as a SINGLE scalar (0.5),
        // not a vector. parseVector3 returns nil for a scalar → scale silently fell
        // back to 1.0 and doubled the box. parseScale must coerce it to (0.5,0.5,0.5).
        let payload: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 3840, "height": 2160, "auto": true]],
            "objects": [
                ["id": 30, "name": "Group", "origin": "0 0 0"],
                [
                    "id": 31,
                    "name": "Audio",
                    "image": "models/util/composelayer.json",
                    "parent": 30,
                    "origin": "0 0 0",
                    "scale": 0.5
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        let document = try WPESceneDocumentParser.parse(data: data)
        let layer = try #require(document.imageObjects.first)
        #expect(abs(layer.scale.x - 0.5) < 0.0001)
        #expect(abs(layer.scale.y - 0.5) < 0.0001)
        #expect(abs(layer.scale.z - 0.5) < 0.0001)
    }

    @Test("Property-bound visibility {user,value:false} hides the layer (style-combo selection)")
    func propertyBoundVisibilityHidesLayer() throws {
        // Scene 3461168300: a "style" combo (newproperty14) shows the diagonal OR the
        // bottom audio bar. The hidden one carries visible={user:{...}, value:false}.
        // parseBool must read `value` (false) instead of defaulting to true.
        let payload: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 3840, "height": 2160, "auto": true]],
            "objects": [
                [
                    "id": 269, "name": "斜", "image": "models/util/solidlayer.json",
                    "origin": "100 100 0",
                    "visible": ["user": ["condition": "1", "name": "newproperty14"], "value": true]
                ],
                [
                    "id": 488, "name": "底", "image": "models/util/solidlayer.json",
                    "origin": "100 100 0",
                    "visible": ["user": ["condition": "2", "name": "newproperty14"], "value": false]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        let document = try WPESceneDocumentParser.parse(data: data)
        let byID = Dictionary(uniqueKeysWithValues: document.imageObjects.map { ($0.id, $0) })
        #expect(byID["269"]?.visible == true)   // 斜 shown
        #expect(byID["488"]?.visible == false)  // 底 hidden by the style selection
    }

    /// Builds scene 3461168300's two-layer style selector: `newproperty14`
    /// picks the diagonal (condition "1") or the bottom bar (condition "2").
    private func styleSelectorSceneData() throws -> Data {
        let payload: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 3840, "height": 2160, "auto": true]],
            "objects": [
                [
                    "id": 269, "name": "斜", "image": "models/util/solidlayer.json",
                    "origin": "100 100 0",
                    "visible": ["user": ["condition": "1", "name": "newproperty14"], "value": true]
                ],
                [
                    "id": 488, "name": "底", "image": "models/util/solidlayer.json",
                    "origin": "100 100 0",
                    "visible": ["user": ["condition": "2", "name": "newproperty14"], "value": false]
                ]
            ]
        ]
        return try JSONSerialization.data(withJSONObject: payload, options: [])
    }

    @Test("Style selector resolves the live selection (numeric, string, mismatch)")
    func styleSelectorResolvesLiveSelection() throws {
        let data = try styleSelectorSceneData()

        // newproperty14 = 2 → only the bottom bar (condition "2") shows.
        let pickBottom = try WPESceneDocumentParser.parse(data: data, userValues: ["newproperty14": .number(2)])
        let bottomByID = Dictionary(uniqueKeysWithValues: pickBottom.imageObjects.map { ($0.id, $0) })
        #expect(bottomByID["269"]?.visible == false)
        #expect(bottomByID["488"]?.visible == true)

        // String "2" must match the same way as the numeric value.
        let pickBottomString = try WPESceneDocumentParser.parse(data: data, userValues: ["newproperty14": .string("2")])
        let bottomStringByID = Dictionary(uniqueKeysWithValues: pickBottomString.imageObjects.map { ($0.id, $0) })
        #expect(bottomStringByID["488"]?.visible == true)

        // newproperty14 = 1 → only the diagonal (condition "1") shows.
        let pickDiagonal = try WPESceneDocumentParser.parse(data: data, userValues: ["newproperty14": .number(1)])
        let diagonalByID = Dictionary(uniqueKeysWithValues: pickDiagonal.imageObjects.map { ($0.id, $0) })
        #expect(diagonalByID["269"]?.visible == true)
        #expect(diagonalByID["488"]?.visible == false)
    }

    @Test("Style selector 'off' value hides every conditional layer")
    func styleSelectorOffHidesAll() throws {
        let data = try styleSelectorSceneData()
        // newproperty14 = 3 (off) matches neither condition → both hidden.
        let off = try WPESceneDocumentParser.parse(data: data, userValues: ["newproperty14": .number(3)])
        let byID = Dictionary(uniqueKeysWithValues: off.imageObjects.map { ($0.id, $0) })
        #expect(byID["269"]?.visible == false)
        #expect(byID["488"]?.visible == false)
    }

    @Test("Condition-form visibility records an incremental binding carrying the condition")
    func styleSelectorBindingIsIncrementalWithCondition() throws {
        let data = try styleSelectorSceneData()
        let document = try WPESceneDocumentParser.parse(data: data, userValues: ["newproperty14": .number(1)])

        let bindings = try #require(document.propertyBindings["newproperty14"])
        #expect(bindings.count == 2)
        for binding in bindings {
            #expect(binding.kind == .visible)
            #expect(binding.action == .incremental)
            #expect(binding.condition != nil)
        }
        #expect(bindings.contains { $0.target == .imageObject(id: "269") && $0.condition == "1" })
        #expect(bindings.contains { $0.target == .imageObject(id: "488") && $0.condition == "2" })
    }

    @Test("Switching a style selector is an incremental patch, not a reload")
    func styleSelectorPatchIsIncremental() throws {
        let data = try styleSelectorSceneData()
        let document = try WPESceneDocumentParser.parse(data: data, userValues: ["newproperty14": .number(1)])

        let patch = WPEScenePropertyPatch(
            bindingsByProperty: document.propertyBindings,
            oldValues: ["newproperty14": .number(1)],
            newValues: ["newproperty14": .number(2)]
        )
        #expect(!patch.requiresReload)
        #expect(patch.incrementalBindings.count == 2)
    }

    @Test("Nested user property without a condition behaves like a simple binding")
    func nestedUserWithoutConditionActsAsSimpleBinding() throws {
        let payload: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 1920, "height": 1080, "auto": true]],
            "objects": [[
                "id": 7, "name": "Toggle", "image": "models/util/solidlayer.json",
                "visible": ["user": ["name": "toggle"], "value": true]
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        // No condition → the property drives the bool directly: toggle=false hides it.
        let hidden = try WPESceneDocumentParser.parse(data: data, userValues: ["toggle": .bool(false)])
        #expect(hidden.imageObjects.first?.visible == false)
        #expect(hidden.propertyBindings["toggle"]?.first?.target == .imageObject(id: "7"))
    }

    @Test("sceneConditionMatches maps live combo values to a condition literal")
    func sceneConditionMatchesCoversTypes() {
        // The shared helper used by both the parser (full-reload path) and the
        // renderer's resolvedVisible (incremental path). This is the core
        // live-value → visibility mapping for the style selector.
        typealias Schema = WallpaperEngineProjectPropertySchema
        #expect(Schema.sceneConditionMatches(value: .number(2), condition: "2"))
        #expect(Schema.sceneConditionMatches(value: .string("2"), condition: "2"))
        #expect(!Schema.sceneConditionMatches(value: .number(1), condition: "2"))
        #expect(!Schema.sceneConditionMatches(value: .number(2), condition: "1"))
        #expect(!Schema.sceneConditionMatches(value: nil, condition: "2"))
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
