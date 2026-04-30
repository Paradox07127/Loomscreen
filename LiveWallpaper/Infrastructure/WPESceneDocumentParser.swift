import CoreGraphics
import Foundation

/// Stateless flexible parser for Wallpaper Engine `scene.json`. The shipping
/// format mixes JSON objects, scalar arrays, and space-separated string
/// vectors (`"0 1 0"`); we accept all three to cover the long tail of
/// community projects without forking the spec.
///
/// Phase 2.0 contract:
///   - Required: top-level object with `camera` + `general` blocks.
///   - Image objects (`type` either missing or "image") feed
///     `WPESceneDocument.imageObjects`.
///   - Anything else (text / particles / sound / shaders / FBO passes /
///     bloom / parallax) emits a `WPESceneDiagnostic` and the parser keeps
///     going so the import flow can still light up image-only scenes.
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

        for entry in rawObjects {
            let type = (entry["type"] as? String)?.lowercased() ?? "image"
            switch type {
            case "image", "":
                if let object = parseImageObject(entry, diagnostics: &diagnostics) {
                    imageObjects.append(object)
                }
            case "text":
                diagnostics.append(.init(severity: .info, message: "Text object \(entry["name"] as? String ?? "?") is unsupported in Phase 2.0"))
            case "sound":
                diagnostics.append(.init(severity: .info, message: "Sound object \(entry["name"] as? String ?? "?") is unsupported in Phase 2.0"))
            case "particle":
                diagnostics.append(.init(severity: .info, message: "Particle object \(entry["name"] as? String ?? "?") is unsupported in Phase 2.0"))
            default:
                diagnostics.append(.init(severity: .info, message: "Object type \(type) is unsupported in Phase 2.0"))
            }
        }

        if (root["effects"] as? [Any])?.isEmpty == false {
            diagnostics.append(.init(severity: .info, message: "Top-level effects are not yet rendered"))
        }

        // Optional general fields we do not yet consume: bloom*, cameraparallax*,
        // camerashake*. Surfacing them as info-level diagnostics keeps the
        // import service's tier classifier honest.
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
            diagnostics: diagnostics
        )
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
            // No image path means nothing to draw — skip but log so the
            // import service can flag obviously broken scenes.
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

        // Track unsupported features so the import flow can downgrade tier.
        if let effects = dict["effects"] as? [Any], !effects.isEmpty {
            diagnostics.append(.init(severity: .info, message: "Image \(name) declares effects — rendered without effects in Phase 2.0"))
        }
        if dict["material"] != nil {
            diagnostics.append(.init(severity: .info, message: "Image \(name) declares material — Phase 2.0 ignores material/shader"))
        }
        if dict["animationlayers"] != nil {
            diagnostics.append(.init(severity: .info, message: "Image \(name) declares animationlayers — unsupported in Phase 2.0"))
        }
        if imagePath.lowercased().hasSuffix(".tex") {
            diagnostics.append(.init(severity: .warning, message: "Image \(name) uses .tex texture — falls back to first-frame stub if available"))
        }

        return WPESceneImageObject(
            id: id,
            name: name,
            imageRelativePath: imagePath,
            origin: origin,
            scale: scale,
            angles: angles,
            visible: visible,
            alpha: alpha,
            color: color,
            brightness: brightness,
            blendMode: blend,
            alignment: alignment,
            size: size
        )
    }

    // MARK: - Primitive parsing

    /// Accepts JSON arrays of numbers, JSON dictionaries with x/y/z keys,
    /// or WPE's space-separated strings ("0.5 0 0").
    static func parseVector3(_ raw: Any?) -> SIMD3<Double>? {
        if let array = raw as? [Any] {
            let values = array.compactMap(parseDouble)
            guard values.count >= 2 else { return nil }
            let x = values[0]
            let y = values[1]
            let z = values.count >= 3 ? values[2] : 0
            return SIMD3<Double>(x, y, z)
        }
        if let dict = raw as? [String: Any] {
            let x = parseDouble(dict["x"]) ?? 0
            let y = parseDouble(dict["y"]) ?? 0
            let z = parseDouble(dict["z"]) ?? 0
            if x == 0 && y == 0 && z == 0 { return nil }
            return SIMD3<Double>(x, y, z)
        }
        if let string = raw as? String {
            let pieces = string.split(whereSeparator: { $0.isWhitespace || $0 == "," })
            let values = pieces.compactMap { Double($0) }
            guard values.count >= 2 else { return nil }
            let x = values[0]
            let y = values[1]
            let z = values.count >= 3 ? values[2] : 0
            return SIMD3<Double>(x, y, z)
        }
        return nil
    }

    static func parseDouble(_ raw: Any?) -> Double? {
        if let number = raw as? NSNumber {
            return number.doubleValue
        }
        if let double = raw as? Double {
            return double
        }
        if let int = raw as? Int {
            return Double(int)
        }
        if let string = raw as? String {
            return Double(string)
        }
        return nil
    }

    private static func parseBool(_ raw: Any?) -> Bool? {
        if let bool = raw as? Bool { return bool }
        if let int = raw as? Int { return int != 0 }
        if let string = raw as? String {
            switch string.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        return nil
    }
}
