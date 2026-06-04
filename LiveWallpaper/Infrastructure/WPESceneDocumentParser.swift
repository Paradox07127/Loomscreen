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
        try parse(data: data, userValues: [:])
    }

    static func parse(
        data: Data,
        userValues: [String: WallpaperEngineProjectPropertyValue]
    ) throws -> WPESceneDocument {
        guard !data.isEmpty else {
            throw WPESceneDocumentError.invalidUTF8
        }
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data, options: [.allowFragments])
        } catch {
            throw WPESceneDocumentError.invalidUTF8
        }
        // Record property→target bindings BEFORE resolving envelopes, since
        // resolution replaces `{"user":K}` with the literal value and loses the key.
        let propertyBindings = extractUserPropertyBindings(in: json)
        let resolvedJSON = resolveUserPropertyEnvelopes(in: json, userValues: userValues)
        guard let root = resolvedJSON as? [String: Any] else {
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
        let objectTransforms = resolvedObjectTransforms(rawObjects)
        var imageObjects: [WPESceneImageObject] = []
        var particleObjects: [WPESceneParticleObject] = []
        var textObjects: [WPESceneTextObject] = []
        var soundObjects: [WPESceneSoundObject] = []

        for entry in rawObjects {
            let objectName = entry["name"] as? String ?? "?"
            let resolution = objectKindResolution(for: entry)
            let transform = objectID(in: entry).flatMap { objectTransforms[$0] }
                ?? localTransform(in: entry)
            if resolution.isAmbiguous {
                let declared = resolution.candidates.map(\.rawValue).joined(separator: ", ")
                diagnostics.append(.init(severity: .warning, message: "Ambiguous object \(objectName) declares \(declared)"))
            }

            if resolution.primary == .image,
               let object = parseImageObject(entry, transform: transform, diagnostics: &diagnostics) {
                imageObjects.append(object)
            }
            if resolution.primary == .particle,
               let object = parseParticleObject(entry, transform: transform, diagnostics: &diagnostics) {
                particleObjects.append(object)
            }
            if resolution.primary == .text,
               let object = parseTextObject(entry, transform: transform, diagnostics: &diagnostics) {
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
            diagnostics.append(.init(
                severity: .info,
                message: String(
                    localized: "Top-level effects are not yet rendered",
                    defaultValue: "Top-level effects are not yet rendered",
                    comment: "Wallpaper Engine scene diagnostic when root-level effects are ignored."
                )
            ))
        }

        for key in generalDict.keys {
            let lowered = key.lowercased()
            if lowered.hasPrefix("bloom") || lowered.hasPrefix("camerashake") {
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
            propertyBindings: propertyBindings,
            diagnostics: diagnostics
        )
    }

    /// Scans the raw (pre-resolution) JSON and records, for each user-property
    /// key, the concrete render targets it drives plus whether changing it can
    /// be applied incrementally. Only `image`/`text` visibility is incremental
    /// today; everything else is conservatively classified `.reload`.
    private static func extractUserPropertyBindings(in json: Any) -> [String: [WPEScenePropertyBinding]] {
        guard let root = json as? [String: Any],
              let rawObjects = root["objects"] as? [[String: Any]] else {
            return [:]
        }
        var result: [String: [WPEScenePropertyBinding]] = [:]

        func append(
            raw: Any?,
            target: WPEScenePropertyBindingTarget,
            kind: WPEScenePropertyBindingKind,
            action: WPEScenePropertyBindingAction
        ) {
            for key in userPropertyKeys(in: raw).sorted() {
                result[key, default: []].append(WPEScenePropertyBinding(
                    propertyKey: key,
                    target: target,
                    kind: kind,
                    action: action
                ))
            }
        }

        for object in rawObjects {
            guard let objectID = objectID(in: object) else { continue }
            switch objectKindResolution(for: object).primary {
            case .image:
                append(raw: object["visible"], target: .imageObject(id: objectID), kind: .visible, action: .incremental)
                append(raw: object["color"], target: .imageObject(id: objectID), kind: .color, action: .reload)
                append(raw: object["alpha"], target: .imageObject(id: objectID), kind: .alpha, action: .reload)
                append(raw: object["brightness"], target: .imageObject(id: objectID), kind: .brightness, action: .reload)
                append(raw: object["image"], target: .objectResource(objectID: objectID, field: "image"), kind: .resource, action: .reload)
                append(raw: object["material"], target: .objectResource(objectID: objectID, field: "material"), kind: .resource, action: .reload)
                if let effects = object["effects"] as? [[String: Any]] {
                    for (effectIndex, effect) in effects.enumerated() {
                        let effectIdentifier = effectID(in: effect, fallback: "\(effectIndex)")
                        append(raw: effect["visible"], target: .imageEffect(objectID: objectID, effectID: effectIdentifier), kind: .visible, action: .reload)
                        if let passes = effect["passes"] as? [[String: Any]] {
                            for (passIndex, pass) in passes.enumerated() {
                                let passID = parseInt(pass["id"]) ?? passIndex
                                if let constants = pass["constantshadervalues"] as? [String: Any] {
                                    for (name, raw) in constants {
                                        append(raw: raw, target: .shaderUniform(objectID: objectID, effectID: effectIdentifier, passID: passID, name: name), kind: .uniform, action: .reload)
                                    }
                                }
                                if let combos = pass["combos"] as? [String: Any] {
                                    for (name, raw) in combos {
                                        append(raw: raw, target: .shaderCombo(objectID: objectID, effectID: effectIdentifier, passID: passID, name: name), kind: .combo, action: .reload)
                                    }
                                }
                                if let textures = pass["textures"] as? [Any] {
                                    for (index, raw) in textures.enumerated() {
                                        append(raw: raw, target: .textureSlot(objectID: objectID, effectID: effectIdentifier, passID: passID, index: index), kind: .texture, action: .reload)
                                    }
                                }
                            }
                        }
                    }
                }
            case .text:
                append(raw: object["visible"], target: .textObject(id: objectID), kind: .visible, action: .incremental)
                append(raw: object["color"], target: .textObject(id: objectID), kind: .color, action: .reload)
                append(raw: object["alpha"], target: .textObject(id: objectID), kind: .alpha, action: .reload)
            case .particle:
                append(raw: object["visible"], target: .particleObject(id: objectID), kind: .visible, action: .reload)
                append(raw: object["color"], target: .particleObject(id: objectID), kind: .color, action: .reload)
                append(raw: object["alpha"], target: .particleObject(id: objectID), kind: .alpha, action: .reload)
            default:
                break
            }
        }
        return result
    }

    private static func effectID(in dict: [String: Any], fallback: String) -> String {
        if let id = dict["id"] as? String, !id.isEmpty { return id }
        if let id = parseInt(dict["id"]) { return String(id) }
        if let name = dict["name"] as? String, !name.isEmpty { return name }
        return fallback
    }

    /// Recursively collects every `{"user":K, "value":...}` key reachable from
    /// `raw` (a field value may be a scalar, a `{user}` envelope, or an array of
    /// them — e.g. color components).
    private static func userPropertyKeys(in raw: Any?) -> Set<String> {
        guard let raw else { return [] }
        if let array = raw as? [Any] {
            return array.reduce(into: Set<String>()) { keys, value in
                keys.formUnion(userPropertyKeys(in: value))
            }
        }
        guard let dict = raw as? [String: Any] else { return [] }
        var keys = Set<String>()
        if let key = dict["user"] as? String, dict.keys.contains("value") {
            keys.insert(key)
        }
        for value in dict.values {
            keys.formUnion(userPropertyKeys(in: value))
        }
        return keys
    }

    private static func resolvedObjectTransforms(_ rawObjects: [[String: Any]]) -> [String: SceneObjectTransform] {
        var objectsByID: [String: [String: Any]] = [:]
        for object in rawObjects {
            guard let id = objectID(in: object), objectsByID[id] == nil else { continue }
            objectsByID[id] = object
        }

        var memo: [String: SceneObjectTransform] = [:]

        func resolve(id: String, stack: Set<String>) -> SceneObjectTransform {
            if let cached = memo[id] { return cached }
            guard let object = objectsByID[id] else { return .identity }
            let local = localTransform(in: object)
            guard let parent = parentID(in: object),
                  parent != id,
                  objectsByID[parent] != nil,
                  !stack.contains(parent) else {
                memo[id] = local
                return local
            }
            let inherited = resolve(id: parent, stack: stack.union([id]))
            let resolved = inherited.combining(child: local)
            memo[id] = resolved
            return resolved
        }

        for id in objectsByID.keys {
            _ = resolve(id: id, stack: [])
        }
        return memo
    }

    private static func objectID(in dict: [String: Any], fallback: String? = nil) -> String? {
        if let id = dict["id"] as? String, !id.isEmpty { return id }
        if let id = parseInt(dict["id"]) { return String(id) }
        if let name = dict["name"] as? String, !name.isEmpty { return name }
        return fallback
    }

    private static func parentID(in dict: [String: Any]) -> String? {
        if let id = dict["parent"] as? String, !id.isEmpty { return id }
        if let id = parseInt(dict["parent"]) { return String(id) }
        return nil
    }

    private static func localTransform(in dict: [String: Any]) -> SceneObjectTransform {
        SceneObjectTransform(
            origin: parseVector3(dict["origin"]) ?? SIMD3<Double>(0, 0, 0),
            scale: parseVector3(dict["scale"]) ?? SIMD3<Double>(1, 1, 1),
            angles: parseVector3(dict["angles"]) ?? SIMD3<Double>(0, 0, 0)
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
            let objectName = dict["name"] as? String ?? "?"
            diagnostics.append(.init(
                severity: .warning,
                message: String(
                    localized: "Sound object \(objectName) has no sound files",
                    comment: "Wallpaper Engine scene diagnostic. The placeholder is the sound object name."
                )
            ))
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
        transform: SceneObjectTransform,
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
            let objectName = dict["name"] as? String ?? "?"
            diagnostics.append(.init(
                severity: .warning,
                message: String(
                    localized: "Text object \(objectName) has no resolvable text",
                    comment: "Wallpaper Engine scene diagnostic. The placeholder is the text object name."
                )
            ))
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
        let alphaValue = parseAnimatedScalar(dict["alpha"], fallback: 1)
        let origin = transform.origin
        let scale = transform.scale
        let visible = parseBool(dict["visible"]) ?? true
        let horiz = unwrapString(dict["horizontalalign"]) ?? "center"
        let vert = unwrapString(dict["verticalalign"]) ?? "middle"
        let maxWidth = unwrapDouble(dict["maxwidth"]) ?? unwrapDouble(dict["limitwidth"])
        let parallaxDepth = unwrapDouble(dict["parallaxDepth"]) ?? unwrapDouble(dict["parallaxdepth"]) ?? 0
        // WPE text-box footprint ("size") + transparent margin ("padding"). A
        // text object renders like an image layer whose texture is this box, so
        // the rendered text must fill the box (minus padding) × scale — not the
        // raw rasterized bounds at pointsize, which are far smaller.
        let boxSize = parseVector3(dict["size"]).map { SIMD2<Double>($0.x, $0.y) }
        let padding = parseDouble(dict["padding"]) ?? 0
        // WPE 2.8 MSDF text effects. Keys are case-insensitive in the corpus, so
        // accept both spaced and lowercased variants; all default to disabled.
        let outlineSize = unwrapDouble(dict["outlinesize"]) ?? unwrapDouble(dict["outlineSize"]) ?? 0
        let outlineColor = unwrapVector3(dict["outlinecolor"]) ?? SIMD3<Double>(0, 0, 0)
        let blurSize = unwrapDouble(dict["blursize"]) ?? unwrapDouble(dict["blurSize"]) ?? 0
        let shadowSize = unwrapDouble(dict["shadowsize"]) ?? unwrapDouble(dict["shadowSize"]) ?? 0
        let shadowColor = unwrapVector3(dict["shadowcolor"]) ?? SIMD3<Double>(0, 0, 0)
        let shadowOffsetVec = parseVector3(dict["shadowoffset"]).map { SIMD2<Double>($0.x, $0.y) }
        let shadowOffset = shadowOffsetVec ?? SIMD2<Double>(0, 0)
        let letterSpacing = unwrapDouble(dict["letterspacing"]) ?? unwrapDouble(dict["spacing"]) ?? 0

        return WPESceneTextObject(
            id: id,
            name: name,
            text: text,
            textScript: textScript,
            fontRelativePath: font,
            pointSize: max(1, pointSize),
            color: color,
            alpha: max(0, min(alphaValue.value, 1)),
            alphaAnimation: alphaValue.animation,
            origin: origin,
            scale: scale,
            visible: visible,
            horizontalAlignment: horiz.lowercased(),
            verticalAlignment: vert.lowercased(),
            maxWidth: maxWidth.map { max(1, $0) },
            parallaxDepth: parallaxDepth,
            boxSize: (boxSize.map { $0.x > 0 && $0.y > 0 } ?? false) ? boxSize : nil,
            padding: max(0, padding),
            outlineSize: max(0, outlineSize),
            outlineColor: outlineColor,
            blurSize: max(0, blurSize),
            shadowSize: max(0, shadowSize),
            shadowColor: shadowColor,
            shadowOffset: shadowOffset,
            letterSpacing: letterSpacing
        )
    }

    /// Recursively replace every WPE user-property envelope
    /// `{ "user": K, "value": V }` with `userValues[K] ?? V` BEFORE field
    /// parsing, so scene custom settings (e.g. toggling an object's `visible`
    /// via its bound property) actually drive the parsed document.
    private static func resolveUserPropertyEnvelopes(
        in raw: Any,
        userValues: [String: WallpaperEngineProjectPropertyValue]
    ) -> Any {
        if let array = raw as? [Any] {
            return array.map {
                resolveUserPropertyEnvelopes(in: $0, userValues: userValues)
            }
        }

        guard let dict = raw as? [String: Any] else {
            return raw
        }

        if let key = dict["user"] as? String,
           dict.keys.contains("value") {
            let fallback = resolveUserPropertyEnvelopes(
                in: dict["value"] ?? NSNull(),
                userValues: userValues
            )
            guard let override = userValues[key] else {
                return fallback
            }
            return jsonValue(for: override)
        }

        var resolved: [String: Any] = [:]
        resolved.reserveCapacity(dict.count)
        for (key, value) in dict {
            resolved[key] = resolveUserPropertyEnvelopes(
                in: value,
                userValues: userValues
            )
        }
        return resolved
    }

    private static func jsonValue(for value: WallpaperEngineProjectPropertyValue) -> Any {
        switch value {
        case .bool(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        }
    }

    /// Accept legacy `{ "value": <X> }` wrappers. User-property envelopes are
    /// resolved before field parsing so these helpers only see effective values.
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

    private static func parseAnimatedScalar(
        _ raw: Any?,
        fallback: Double
    ) -> (value: Double, animation: WPESceneAnimatedValue?) {
        guard let constant = WPEValueParser.shaderConstant(raw) else {
            return (parseDouble(raw) ?? fallback, nil)
        }
        switch constant {
        case .number(let value):
            return (value, nil)
        case .vector(let vector):
            return (vector.first ?? fallback, nil)
        case .bool(let value):
            return (value ? 1 : 0, nil)
        case .string(let value):
            return (Double(value) ?? fallback, nil)
        case .animated(let value):
            return (value.scalarFallback ?? value.scalar(at: 0) ?? fallback, value)
        }
    }

    private static func parseParticleObject(
        _ dict: [String: Any],
        transform: SceneObjectTransform,
        diagnostics: inout [WPESceneDiagnostic]
    ) -> WPESceneParticleObject? {
        guard let path = dict["particle"] as? String, !path.isEmpty else {
            let objectName = dict["name"] as? String ?? "?"
            diagnostics.append(.init(
                severity: .warning,
                message: String(
                    localized: "Particle object \(objectName) has no particle file",
                    comment: "Wallpaper Engine scene diagnostic. The placeholder is the particle object name."
                )
            ))
            return nil
        }
        let id = (dict["id"] as? String)
            ?? (dict["id"] as? Int).map(String.init)
            ?? (dict["name"] as? String)
            ?? path
        let name = (dict["name"] as? String) ?? id
        let origin = transform.origin
        let scale = transform.scale
        let angles = transform.angles
        let visible = parseBool(dict["visible"]) ?? true
        let alphaValue = parseAnimatedScalar(dict["alpha"], fallback: 1)
        let color = parseVector3(dict["color"]) ?? SIMD3<Double>(1, 1, 1)
        let parallaxDepth = parseDouble(dict["parallaxDepth"]) ?? parseDouble(dict["parallaxdepth"]) ?? 0
        let instanceOverride = parseParticleInstanceOverride(
            dict["instanceoverride"] ?? dict["instanceOverride"]
        )
        return WPESceneParticleObject(
            id: id,
            name: name,
            particleRelativePath: path,
            origin: origin,
            scale: scale,
            angles: angles,
            visible: visible,
            alpha: alphaValue.value,
            alphaAnimation: alphaValue.animation,
            color: color,
            parallaxDepth: parallaxDepth,
            instanceOverride: instanceOverride
        )
    }

    private static func parseParticleInstanceOverride(_ raw: Any?) -> WPESceneParticleInstanceOverride? {
        guard let dict = raw as? [String: Any] else { return nil }
        let value = WPESceneParticleInstanceOverride(
            count: parseDouble(dict["count"]),
            rate: parseDouble(dict["rate"]),
            lifetime: parseDouble(dict["lifetime"]),
            size: parseDouble(dict["size"]),
            speed: parseDouble(dict["speed"]),
            alpha: parseDouble(dict["alpha"]),
            color: parseNormalizedParticleColor(dict["colorn"]) ?? parseVector3(dict["color"])
        )
        return value.count == nil
            && value.rate == nil
            && value.lifetime == nil
            && value.size == nil
            && value.speed == nil
            && value.alpha == nil
            && value.color == nil
            ? nil
            : value
    }

    private static func parseNormalizedParticleColor(_ raw: Any?) -> SIMD3<Double>? {
        guard let color = parseVector3(raw) else { return nil }
        return SIMD3<Double>(
            color.x * 255,
            color.y * 255,
            color.z * 255
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
            diagnostics.append(.init(
                severity: .info,
                message: String(
                    localized: "general.orthogonalprojection missing — using 1920×1080",
                    defaultValue: "general.orthogonalprojection missing — using 1920×1080",
                    comment: "Wallpaper Engine scene diagnostic when default projection dimensions are used."
                )
            ))
            projection = WPESceneGeneral.defaultGeneral.orthogonalProjection
        }
        let parallaxDefaults = WPESceneCameraParallaxSettings.disabled
        let cameraParallax = WPESceneCameraParallaxSettings(
            enabled: parseBool(dict["cameraparallax"]) ?? parallaxDefaults.enabled,
            amount: parseDouble(dict["cameraparallaxamount"]) ?? parallaxDefaults.amount,
            delay: parseDouble(dict["cameraparallaxdelay"]) ?? parallaxDefaults.delay,
            mouseInfluence: parseDouble(dict["cameraparallaxmouseinfluence"]) ?? parallaxDefaults.mouseInfluence
        )
        let supportsAudioProcessing = parseBool(dict["supportsaudioprocessing"]) ?? false
        return WPESceneGeneral(
            clearColor: clearColor,
            orthogonalProjection: projection,
            cameraParallax: cameraParallax,
            supportsAudioProcessing: supportsAudioProcessing
        )
    }

    // MARK: - Image objects

    private static func parseImageObject(
        _ dict: [String: Any],
        transform: SceneObjectTransform,
        diagnostics: inout [WPESceneDiagnostic]
    ) -> WPESceneImageObject? {
        guard let imagePath = dict["image"] as? String, !imagePath.isEmpty else {
            let objectName = dict["name"] as? String ?? "?"
            diagnostics.append(.init(
                severity: .warning,
                message: String(
                    localized: "Image object \(objectName) has no image path",
                    comment: "Wallpaper Engine scene diagnostic. The placeholder is the image object name."
                )
            ))
            return nil
        }

        let id = (dict["id"] as? String)
            ?? (dict["id"] as? Int).map(String.init)
            ?? (dict["name"] as? String)
            ?? imagePath
        let name = (dict["name"] as? String) ?? id
        let origin = transform.origin
        let scale = transform.scale
        let angles = transform.angles
        let local = localTransform(in: dict)
        let parentObjectID = parentID(in: dict)
        let attachment = nonEmptyString(dict["attachment"]) ?? nonEmptyString(dict["anchor"])
        let visible = parseBool(dict["visible"]) ?? true
        let alphaValue = parseAnimatedScalar(dict["alpha"], fallback: 1)
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
        let dependencies = parseDependencyIDs(dict["dependencies"])
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
            parentObjectID: parentObjectID,
            attachment: attachment,
            origin: origin,
            scale: scale,
            angles: angles,
            localOrigin: local.origin,
            localScale: local.scale,
            localAngles: local.angles,
            visible: visible,
            alpha: alphaValue.value,
            alphaAnimation: alphaValue.animation,
            color: color,
            brightness: brightness,
            blendMode: blend,
            alignment: alignment,
            size: size,
            dependencies: dependencies,
            effects: effects,
            animationLayers: animationLayers,
            parallaxDepth: parallaxDepth
        )
    }

    private static func nonEmptyString(_ raw: Any?) -> String? {
        guard let string = raw as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseDependencyIDs(_ raw: Any?) -> [String] {
        guard let array = raw as? [Any] else { return [] }
        var seen = Set<String>()
        var result: [String] = []
        for value in array {
            let id: String?
            if let string = value as? String, !string.isEmpty {
                id = string
            } else if let int = parseInt(value) {
                id = String(int)
            } else {
                id = nil
            }
            guard let id, seen.insert(id).inserted else { continue }
            result.append(id)
        }
        return result
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
                animation: animation,
                additive: parseBool(dict["additive"]) ?? false
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

private struct SceneObjectTransform {
    let origin: SIMD3<Double>
    let scale: SIMD3<Double>
    let angles: SIMD3<Double>

    static let identity = SceneObjectTransform(
        origin: SIMD3<Double>(0, 0, 0),
        scale: SIMD3<Double>(1, 1, 1),
        angles: SIMD3<Double>(0, 0, 0)
    )

    func combining(child: SceneObjectTransform) -> SceneObjectTransform {
        let scaledX = child.origin.x * scale.x
        let scaledY = child.origin.y * scale.y
        let cosine = cos(angles.z)
        let sine = sin(angles.z)
        let rotatedX = scaledX * cosine - scaledY * sine
        let rotatedY = scaledX * sine + scaledY * cosine

        return SceneObjectTransform(
            origin: SIMD3<Double>(
                origin.x + rotatedX,
                origin.y + rotatedY,
                origin.z + child.origin.z * scale.z
            ),
            scale: SIMD3<Double>(
                scale.x * child.scale.x,
                scale.y * child.scale.y,
                scale.z * child.scale.z
            ),
            angles: angles + child.angles
        )
    }
}
#endif
