#if !LITE_BUILD
import CoreGraphics
import Foundation

/// Stateless flexible parser for Wallpaper Engine `scene.json`. The shipping
/// format mixes JSON objects, scalar arrays, and space-separated string
/// vectors (`"0 1 0"`); we accept all three to cover the long tail of
/// community projects without forking the spec.
///
/// Phase 2.0 contract:
///   - Required: top-level object with `camera` + `general` blocks.
    ///   - Image objects feed `WPESceneDocument.imageObjects`; object kind is
    ///     inferred from WPE shape keys when `type` is missing.
///   - Material/effect/animation metadata is preserved for renderer fallbacks
///     and future shader passes; unsupported objects and full FBO shader
///     pipelines still emit diagnostics so import can downgrade capability.
enum WPESceneDocumentParser {

    static func parse(data: Data) throws -> WPESceneDocument {
        guard !data.isEmpty else {
            throw WPESceneDocumentError.invalidUTF8
        }
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data, options: [.allowFragments])
        } catch {
            throw WPESceneDocumentError.invalidUTF8
        }
        guard let root = json as? [String: Any] else {
            throw WPESceneDocumentError.rootNotObject
        }

        var diagnostics: [WPESceneDiagnostic] = []

        guard let cameraDict = root["camera"] as? [String: Any] else {
            throw WPESceneDocumentError.missingCamera
        }
        guard let generalDict = root["general"] as? [String: Any] else {
            throw WPESceneDocumentError.missingGeneral
        }

        let camera = parseCamera(cameraDict, diagnostics: &diagnostics)
        let general = parseGeneral(generalDict, diagnostics: &diagnostics)

        let rawObjects: [[String: Any]] = (root["objects"] as? [[String: Any]]) ?? []
        var imageObjects: [WPESceneImageObject] = []
        var particleObjects: [WPESceneParticleObject] = []
        var textObjects: [WPESceneTextObject] = []
        var soundObjects: [WPESceneSoundObject] = []

        for entry in rawObjects {
            let objectName = entry["name"] as? String ?? "?"
            let resolution = objectKindResolution(for: entry)
            if resolution.isAmbiguous {
                let declared = resolution.candidates.map(\.rawValue).joined(separator: ", ")
                diagnostics.append(.init(severity: .warning, message: "Ambiguous object \(objectName) declares \(declared)"))
            }

            if resolution.primary == .image, let object = parseImageObject(entry, diagnostics: &diagnostics) {
                imageObjects.append(object)
            }
            if resolution.primary == .particle, let object = parseParticleObject(entry, diagnostics: &diagnostics) {
                particleObjects.append(object)
            }
            if resolution.primary == .text, let object = parseTextObject(entry, diagnostics: &diagnostics) {
                textObjects.append(object)
            }
            if resolution.primary == .sound, let object = parseSoundObject(entry, diagnostics: &diagnostics) {
                soundObjects.append(object)
            }

            var unsupportedKinds = resolution.candidates.filter {
                $0 != .image && $0 != .unknown && $0 != .particle && $0 != .text && $0 != .sound
            }
            if resolution.primary != .image
                && resolution.primary != .particle
                && resolution.primary != .text
                && resolution.primary != .sound
                && resolution.primary != .unknown
                && !unsupportedKinds.contains(resolution.primary) {
                unsupportedKinds.append(resolution.primary)
            }
            for kind in unsupportedKinds {
                diagnostics.append(.init(severity: .info, message: "\(kind.displayName) object \(objectName) is unsupported in Phase 2.0"))
            }
            if resolution.primary == .particle {
                diagnostics.append(.init(severity: .info, message: "Particle object \(objectName) parsed; runtime emitter not yet implemented"))
            }
            if resolution.primary == .text {
                diagnostics.append(.init(severity: .info, message: "Text object \(objectName) parsed; CoreText rasterizer renders static content"))
            }
            if resolution.primary == .sound {
                diagnostics.append(.init(severity: .info, message: "Sound object \(objectName) parsed; AVAudioEngine playback runs at scene start"))
            }

            if resolution.primary == .unknown {
                let type = resolution.explicitType ?? "missing"
                diagnostics.append(.init(severity: .info, message: "Object type \(type) is unsupported in Phase 2.0"))
            }
        }

        if (root["effects"] as? [Any])?.isEmpty == false {
            diagnostics.append(.init(severity: .info, message: "Top-level effects are not yet rendered"))
        }

        for key in generalDict.keys {
            let lowered = key.lowercased()
            if lowered.hasPrefix("bloom") || lowered.hasPrefix("cameraparallax") || lowered.hasPrefix("camerashake") {
                diagnostics.append(.init(severity: .info, message: "general.\(key) is unsupported in Phase 2.0"))
            }
        }

        return WPESceneDocument(
            camera: camera,
            general: general,
            imageObjects: imageObjects,
            particleObjects: particleObjects,
            textObjects: textObjects,
            soundObjects: soundObjects,
            diagnostics: diagnostics
        )
    }

    private static func parseSoundObject(
        _ dict: [String: Any],
        diagnostics: inout [WPESceneDiagnostic]
    ) -> WPESceneSoundObject? {
        var paths: [String] = []
        if let single = dict["sound"] as? String, !single.isEmpty {
            paths.append(single)
        } else if let array = dict["sound"] as? [Any] {
            for value in array {
                if let s = value as? String, !s.isEmpty {
                    paths.append(s)
                }
            }
        }
        guard !paths.isEmpty else {
            diagnostics.append(.init(severity: .warning, message: "Sound object \(dict["name"] as? String ?? "?") has no sound files"))
            return nil
        }
        let id = (dict["id"] as? String)
            ?? (dict["id"] as? Int).map(String.init)
            ?? (dict["name"] as? String)
            ?? paths[0]
        let name = (dict["name"] as? String) ?? id
        let volume = unwrapDouble(dict["volume"]) ?? 1
        let mode = (dict["playbackmode"] as? String) ?? "loop"
        let startSilent = (dict["startsilent"] as? Bool) ?? false
        return WPESceneSoundObject(
            id: id,
            name: name,
            soundRelativePaths: paths,
            volume: max(0, min(volume, 1)),
            playbackMode: mode.lowercased(),
            startSilent: startSilent
        )
    }

    /// Phase 2D-N: text objects shape per the corpus.
    private static func parseTextObject(
        _ dict: [String: Any],
        diagnostics: inout [WPESceneDiagnostic]
    ) -> WPESceneTextObject? {
        let raw = dict["text"]
        let text: String?
        var textScript: String? = nil
        switch raw {
        case let value as String:
            text = value
        case let nested as [String: Any]:
            text = (nested["value"] as? String) ?? (nested["text"] as? String)
            if let script = nested["script"] as? String, !script.isEmpty {
                textScript = script
            }
        default:
            text = nil
        }
        guard let text, !text.isEmpty else {
            diagnostics.append(.init(severity: .warning, message: "Text object \(dict["name"] as? String ?? "?") has no resolvable text"))
            return nil
        }
        let id = (dict["id"] as? String)
            ?? (dict["id"] as? Int).map(String.init)
            ?? (dict["name"] as? String)
            ?? text
        let name = (dict["name"] as? String) ?? id
        let font = unwrapString(dict["font"])
        let pointSize = unwrapDouble(dict["pointsize"]) ?? unwrapDouble(dict["fontsize"]) ?? 32
        let color = unwrapVector3(dict["color"]) ?? SIMD3<Double>(1, 1, 1)
        let alpha = unwrapDouble(dict["alpha"]) ?? 1
        let origin = unwrapVector3(dict["origin"]) ?? SIMD3<Double>(0, 0, 0)
        let scale = unwrapVector3(dict["scale"]) ?? SIMD3<Double>(1, 1, 1)
        let visible = (dict["visible"] as? Bool) ?? true
        let horiz = unwrapString(dict["horizontalalign"]) ?? "center"
        let vert = unwrapString(dict["verticalalign"]) ?? "middle"
        let maxWidth = unwrapDouble(dict["maxwidth"]) ?? unwrapDouble(dict["limitwidth"])
        let parallaxDepth = unwrapDouble(dict["parallaxDepth"]) ?? unwrapDouble(dict["parallaxdepth"]) ?? 0

        return WPESceneTextObject(
            id: id,
            name: name,
            text: text,
            textScript: textScript,
            fontRelativePath: font,
            pointSize: max(1, pointSize),
            color: color,
            alpha: max(0, min(alpha, 1)),
            origin: origin,
            scale: scale,
            visible: visible,
            horizontalAlignment: horiz.lowercased(),
            verticalAlignment: vert.lowercased(),
            maxWidth: maxWidth.map { max(1, $0) },
            parallaxDepth: parallaxDepth
        )
    }

    /// Unwrap WPE's `{ "user": "...", "value": <X> }` envelope, recursing when the inner `value` is itself a property reference.
    private static func unwrapDouble(_ raw: Any?) -> Double? {
        if let value = WPEValueParser.double(raw) { return value }
        if let dict = raw as? [String: Any] {
            return unwrapDouble(dict["value"])
        }
        return nil
    }

    private static func unwrapVector3(_ raw: Any?) -> SIMD3<Double>? {
        if let value = WPEValueParser.vector3(raw) { return value }
        if let dict = raw as? [String: Any] {
            return unwrapVector3(dict["value"])
        }
        return nil
    }

    private static func unwrapString(_ raw: Any?) -> String? {
        if let s = raw as? String, !s.isEmpty { return s }
        if let dict = raw as? [String: Any] {
            return unwrapString(dict["value"])
        }
        return nil
    }

    private static func parseParticleObject(
        _ dict: [String: Any],
        diagnostics: inout [WPESceneDiagnostic]
    ) -> WPESceneParticleObject? {
        guard let path = dict["particle"] as? String, !path.isEmpty else {
            diagnostics.append(.init(severity: .warning, message: "Particle object \(dict["name"] as? String ?? "?") has no particle file"))
            return nil
        }
        let id = (dict["id"] as? String)
            ?? (dict["id"] as? Int).map(String.init)
            ?? (dict["name"] as? String)
            ?? path
        let name = (dict["name"] as? String) ?? id
        let origin = parseVector3(dict["origin"]) ?? SIMD3<Double>(0, 0, 0)
        let scale = parseVector3(dict["scale"]) ?? SIMD3<Double>(1, 1, 1)
        let angles = parseVector3(dict["angles"]) ?? SIMD3<Double>(0, 0, 0)
        let visible = parseBool(dict["visible"]) ?? true
        let alpha = parseDouble(dict["alpha"]) ?? 1.0
        let color = parseVector3(dict["color"]) ?? SIMD3<Double>(1, 1, 1)
        let parallaxDepth = parseDouble(dict["parallaxDepth"]) ?? parseDouble(dict["parallaxdepth"]) ?? 0
        return WPESceneParticleObject(
            id: id,
            name: name,
            particleRelativePath: path,
            origin: origin,
            scale: scale,
            angles: angles,
            visible: visible,
            alpha: alpha,
            color: color,
            parallaxDepth: parallaxDepth
        )
    }

    private static func objectKindResolution(for entry: [String: Any]) -> WPESceneObjectKindResolution {
        let candidates = shapeCandidates(in: entry)
        if let explicit = (entry["type"] as? String)?.lowercased(), !explicit.isEmpty {
            return WPESceneObjectKindResolution(
                primary: objectKind(explicitType: explicit),
                candidates: candidates,
                explicitType: explicit
            )
        }
        if candidates.contains(.image) {
            return WPESceneObjectKindResolution(primary: .image, candidates: candidates, explicitType: nil)
        }
        return WPESceneObjectKindResolution(primary: candidates.first ?? .unknown, candidates: candidates, explicitType: nil)
    }

    private static func objectKind(explicitType: String) -> WPESceneObjectKind {
        switch explicitType {
        case "image": return .image
        case "sound": return .sound
        case "particle": return .particle
        case "text": return .text
        case "light": return .light
        default: return .unknown
        }
    }

    private static func shapeCandidates(in entry: [String: Any]) -> [WPESceneObjectKind] {
        var kinds: [WPESceneObjectKind] = []
        if entry["image"] != nil { kinds.append(.image) }
        if entry["sound"] != nil { kinds.append(.sound) }
        if entry["particle"] != nil { kinds.append(.particle) }
        if entry["text"] != nil { kinds.append(.text) }
        if entry["light"] != nil { kinds.append(.light) }
        return kinds
    }

    // MARK: - Camera

    private static func parseCamera(_ dict: [String: Any], diagnostics: inout [WPESceneDiagnostic]) -> WPESceneCamera {
        let center = parseVector3(dict["center"]) ?? WPESceneCamera.defaultCamera.center
        let eye = parseVector3(dict["eye"]) ?? WPESceneCamera.defaultCamera.eye
        let up = parseVector3(dict["up"]) ?? WPESceneCamera.defaultCamera.up
        let nearZ = parseDouble(dict["nearz"]) ?? WPESceneCamera.defaultCamera.nearZ
        let farZ = parseDouble(dict["farz"]) ?? WPESceneCamera.defaultCamera.farZ
        let fov = parseDouble(dict["fov"]) ?? WPESceneCamera.defaultCamera.fov
        return WPESceneCamera(center: center, eye: eye, up: up, nearZ: nearZ, farZ: farZ, fov: fov)
    }

    // MARK: - General

    private static func parseGeneral(_ dict: [String: Any], diagnostics: inout [WPESceneDiagnostic]) -> WPESceneGeneral {
        let clearColor = parseVector3(dict["clearcolor"]) ?? WPESceneGeneral.defaultGeneral.clearColor
        let projection: WPESceneOrthogonalProjection
        if let nested = dict["orthogonalprojection"] as? [String: Any] {
            let width = parseDouble(nested["width"]) ?? WPESceneGeneral.defaultGeneral.orthogonalProjection.width
            let height = parseDouble(nested["height"]) ?? WPESceneGeneral.defaultGeneral.orthogonalProjection.height
            let auto = (nested["auto"] as? Bool) ?? WPESceneGeneral.defaultGeneral.orthogonalProjection.auto
            projection = WPESceneOrthogonalProjection(width: width, height: height, auto: auto)
        } else {
            diagnostics.append(.init(severity: .info, message: "general.orthogonalprojection missing — using 1920×1080"))
            projection = WPESceneGeneral.defaultGeneral.orthogonalProjection
        }
        return WPESceneGeneral(clearColor: clearColor, orthogonalProjection: projection)
    }

    // MARK: - Image objects

    private static func parseImageObject(
        _ dict: [String: Any],
        diagnostics: inout [WPESceneDiagnostic]
    ) -> WPESceneImageObject? {
        guard let imagePath = dict["image"] as? String, !imagePath.isEmpty else {
            diagnostics.append(.init(severity: .warning, message: "Image object \(dict["name"] as? String ?? "?") has no image path"))
            return nil
        }

        let id = (dict["id"] as? String)
            ?? (dict["id"] as? Int).map(String.init)
            ?? (dict["name"] as? String)
            ?? imagePath
        let name = (dict["name"] as? String) ?? id
        let origin = parseVector3(dict["origin"]) ?? SIMD3<Double>(0, 0, 0)
        let scale = parseVector3(dict["scale"]) ?? SIMD3<Double>(1, 1, 1)
        let angles = parseVector3(dict["angles"]) ?? SIMD3<Double>(0, 0, 0)
        let visible = parseBool(dict["visible"]) ?? true
        let alpha = parseDouble(dict["alpha"]) ?? 1.0
        let color = parseVector3(dict["color"]) ?? SIMD3<Double>(1, 1, 1)
        let brightness = parseDouble(dict["brightness"]) ?? 1.0
        let blend = WPESceneBlendMode(rawWPEValue: dict["blendmode"] as? String)
        let alignment = WPESceneAlignment(rawWPEValue: dict["alignment"] as? String)
        let size: CGSize?
        if let vec = parseVector3(dict["size"]) {
            size = CGSize(width: vec.x, height: vec.y)
        } else {
            size = nil
        }

        let materialRelativePath = dict["material"] as? String
        let effects = parseImageEffects(dict["effects"], imageName: name, diagnostics: &diagnostics)
        let animationLayers = parseAnimationLayers(dict["animationlayers"], imageName: name, diagnostics: &diagnostics)

        if !effects.isEmpty {
            let names = effects.map(\.name).joined(separator: ", ")
            diagnostics.append(.init(severity: .info, message: "Image \(name) declares effects (\(names)) — shader pipeline partially supported"))
        }
        if materialRelativePath != nil {
            diagnostics.append(.init(severity: .info, message: "Image \(name) declares material — material shader pass not yet rendered"))
        }
        if !animationLayers.isEmpty {
            diagnostics.append(.init(severity: .info, message: "Image \(name) declares animationlayers — puppet warp not yet rendered"))
        }
        if imagePath.lowercased().hasSuffix(".tex") {
            diagnostics.append(.init(severity: .warning, message: "Image \(name) uses .tex texture — falls back to first-frame stub if available"))
        }

        let parallaxDepth = parseDouble(dict["parallaxDepth"]) ?? parseDouble(dict["parallaxdepth"]) ?? 0

        return WPESceneImageObject(
            id: id,
            name: name,
            imageRelativePath: imagePath,
            materialRelativePath: materialRelativePath,
            origin: origin,
            scale: scale,
            angles: angles,
            visible: visible,
            alpha: alpha,
            color: color,
            brightness: brightness,
            blendMode: blend,
            alignment: alignment,
            size: size,
            effects: effects,
            animationLayers: animationLayers,
            parallaxDepth: parallaxDepth
        )
    }

    private static func parseImageEffects(
        _ raw: Any?,
        imageName: String,
        diagnostics: inout [WPESceneDiagnostic]
    ) -> [WPESceneImageEffect] {
        guard let array = raw as? [Any] else { return [] }
        var effects: [WPESceneImageEffect] = []
        for (index, entry) in array.enumerated() {
            guard let dict = entry as? [String: Any] else {
                diagnostics.append(.init(severity: .warning, message: "Image \(imageName) effect \(index) is malformed"))
                continue
            }
            guard let file = dict["file"] as? String, !file.isEmpty else {
                diagnostics.append(.init(severity: .warning, message: "Image \(imageName) effect \(index) has no file"))
                continue
            }
            let id = (dict["id"] as? String)
                ?? parseInt(dict["id"]).map(String.init)
                ?? "\(index)"
            let name = (dict["name"] as? String) ?? effectName(from: file)
            effects.append(WPESceneImageEffect(
                id: id,
                name: name,
                fileRelativePath: file,
                visible: parseBool(dict["visible"]) ?? true,
                passOverrides: parseEffectPassOverrides(dict["passes"])
            ))
        }
        return effects
    }

    private static func parseEffectPassOverrides(_ raw: Any?) -> [WPESceneEffectPassOverride] {
        guard let array = raw as? [Any] else { return [] }
        return array.compactMap { entry in
            guard let dict = entry as? [String: Any] else { return nil }
            return WPESceneEffectPassOverride(
                id: parseInt(dict["id"]),
                combos: parseComboMap(dict["combos"]),
                constants: parseShaderConstants(dict["constantshadervalues"]),
                textures: parseTextureSlots(dict["textures"])
            )
        }
    }

    private static func parseAnimationLayers(
        _ raw: Any?,
        imageName: String,
        diagnostics: inout [WPESceneDiagnostic]
    ) -> [WPESceneAnimationLayer] {
        guard let array = raw as? [Any] else { return [] }
        var layers: [WPESceneAnimationLayer] = []
        for (index, entry) in array.enumerated() {
            guard let dict = entry as? [String: Any],
                  let id = parseInt(dict["id"]),
                  let animation = parseInt(dict["animation"]) else {
                diagnostics.append(.init(severity: .warning, message: "Image \(imageName) animation layer \(index) is malformed"))
                continue
            }
            layers.append(WPESceneAnimationLayer(
                id: id,
                rate: parseDouble(dict["rate"]) ?? 0,
                visible: parseBool(dict["visible"]) ?? true,
                blend: parseDouble(dict["blend"]) ?? 1,
                animation: animation
            ))
        }
        return layers
    }

    private static func parseComboMap(_ raw: Any?) -> [String: Int] {
        WPEValueParser.comboMap(raw)
    }

    private static func parseShaderConstants(_ raw: Any?) -> [String: WPESceneShaderConstantValue] {
        WPEValueParser.shaderConstants(raw)
    }

    private static func parseTextureSlots(_ raw: Any?) -> [Int: String] {
        guard let array = raw as? [Any] else { return [:] }
        var result: [Int: String] = [:]
        for (index, value) in array.enumerated() {
            if let string = value as? String, !string.isEmpty {
                result[index] = string
            }
        }
        return result
    }

    private static func effectName(from file: String) -> String {
        let pieces = file.split(separator: "/")
        if pieces.count >= 2 {
            return String(pieces[pieces.count - 2])
        }
        return file
    }

    // MARK: - Primitive parsing

    /// Accepts JSON arrays of numbers, JSON dictionaries with x/y/z keys, or WPE's space-separated strings ("0.5 0 0").
    static func parseVector3(_ raw: Any?) -> SIMD3<Double>? {
        WPEValueParser.vector3(raw)
    }

    static func parseDouble(_ raw: Any?) -> Double? {
        WPEValueParser.double(raw)
    }

    private static func parseInt(_ raw: Any?) -> Int? {
        WPEValueParser.int(raw)
    }

    private static func parseBool(_ raw: Any?) -> Bool? {
        WPEValueParser.bool(raw)
    }
}
#endif
