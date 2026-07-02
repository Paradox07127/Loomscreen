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
        let resolvedJSON = try resolveUserPropertyEnvelopes(in: json, userValues: userValues)
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

        let camera = parseCamera(cameraDict, general: generalDict, diagnostics: &diagnostics)
        let general = parseGeneral(generalDict, diagnostics: &diagnostics)

        let rawObjects: [[String: Any]] = (root["objects"] as? [[String: Any]]) ?? []
        // Script-driven `origin` resolves to the CURRENT user-property values
        // (the baked `value` is stale once the user tweaks the bound sliders).
        // Computed before transform combination so each object's parent offset
        // still applies to the fresh local origin.
        let scriptResolvedOrigins = resolveScriptOrigins(
            rawObjects,
            canvasWidth: general.orthogonalProjection.width,
            canvasHeight: general.orthogonalProjection.height
        )
        let objectTransforms = resolvedObjectTransforms(
            rawObjects,
            scriptOrigins: scriptResolvedOrigins
        )
        // Effective visibility folds each object's own `visible` with its ancestor
        // groups', so a child of a condition-hidden group is hidden too.
        let objectVisibility = resolvedObjectVisibility(rawObjects)
        let (objectParentByID, ownVisibilityByID) = objectHierarchy(rawObjects)
        var imageObjects: [WPESceneImageObject] = []
        var scriptHostObjects: [WPESceneScriptHostObject] = []
        var transformHostObjects: [WPESceneTransformHostObject] = []
        var particleObjects: [WPESceneParticleObject] = []
        var textObjects: [WPESceneTextObject] = []
        var soundObjects: [WPESceneSoundObject] = []
        var objectPaintOrder: [String: Int] = [:]

        for (index, entry) in rawObjects.enumerated() {
            let objectName = entry["name"] as? String ?? "?"
            let resolution = objectKindResolution(for: entry)
            let entryID = objectID(in: entry)
            if let entryID {
                objectPaintOrder[entryID] = index
            }
            let transform = entryID.flatMap { objectTransforms[$0] }
                ?? localTransform(in: entry, scriptOrigins: scriptResolvedOrigins)
            let effectiveVisible = entryID.flatMap { objectVisibility[$0] }
            if resolution.isAmbiguous {
                let declared = resolution.candidates.map(\.rawValue).joined(separator: ", ")
                diagnostics.append(.init(severity: .warning, message: "Ambiguous object \(objectName) declares \(declared)"))
            }

            if resolution.primary == .image,
               let object = parseImageObject(
                   entry,
                   transform: transform,
                   scriptOrigins: scriptResolvedOrigins,
                   effectiveVisible: effectiveVisible,
                   diagnostics: &diagnostics
            ) {
                imageObjects.append(object)
            } else if entry["image"] == nil,
                      entry["model"] == nil,
                      let object = parseScriptHostObject(entry, diagnostics: &diagnostics) {
                scriptHostObjects.append(object)
            }
            if resolution.primary != .image,
               resolution.primary != .particle,
               resolution.primary != .text,
               resolution.primary != .sound,
               let object = parseTransformHostObject(
                entry,
                transform: transform,
                scriptOrigins: scriptResolvedOrigins
               ) {
                transformHostObjects.append(object)
            }
            if resolution.primary == .particle,
               let object = parseParticleObject(
                   entry,
                   transform: transform,
                   effectiveVisible: effectiveVisible,
                   diagnostics: &diagnostics
               ) {
                particleObjects.append(object)
            }
            if resolution.primary == .text,
               let object = parseTextObject(
                   entry,
                   transform: transform,
                   effectiveVisible: effectiveVisible,
                   diagnostics: &diagnostics
               ) {
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
                diagnostics.append(.init(severity: .info, message: "Particle object \(objectName) parsed; rendered by the Metal particle simulator"))
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
            scriptHostObjects: scriptHostObjects,
            transformHostObjects: transformHostObjects,
            particleObjects: particleObjects,
            textObjects: textObjects,
            soundObjects: soundObjects,
            objectPaintOrder: objectPaintOrder,
            propertyBindings: propertyBindings,
            objectParentByID: objectParentByID,
            ownVisibilityByID: ownVisibilityByID,
            diagnostics: diagnostics
        )
    }

    private static func parseTransformHostObject(
        _ dict: [String: Any],
        transform: SceneObjectTransform,
        scriptOrigins: [String: SIMD3<Double>] = [:]
    ) -> WPESceneTransformHostObject? {
        guard let id = objectID(in: dict) else { return nil }
        let local = localTransform(in: dict, scriptOrigins: scriptOrigins)
        return WPESceneTransformHostObject(
            id: id,
            name: (dict["name"] as? String) ?? id,
            parentObjectID: parentID(in: dict),
            origin: transform.origin,
            scale: transform.scale,
            angles: transform.angles,
            localOrigin: local.origin,
            localScale: local.scale,
            localAngles: local.angles,
            originScript: dynamicTransformScript(in: dict["origin"], preserveStaticallyResolvable: false),
            scaleScript: dynamicTransformScript(in: dict["scale"], preserveStaticallyResolvable: true),
            anglesScript: dynamicTransformScript(in: dict["angles"], preserveStaticallyResolvable: true)
        )
    }

    private static func parseScriptHostObject(
        _ dict: [String: Any],
        diagnostics: inout [WPESceneDiagnostic]
    ) -> WPESceneScriptHostObject? {
        guard let visibleDict = dict["visible"] as? [String: Any],
              let script = visibleDict["script"] as? String, !script.isEmpty else {
            return nil
        }
        let id = objectID(in: dict)
            ?? (dict["name"] as? String)
            ?? "script-host-\(abs(script.hashValue))"
        let name = (dict["name"] as? String) ?? id
        diagnostics.append(.init(
            severity: .info,
            message: "Object \(name) has a visible-script but no renderable image; runs as a SceneScript host"
        ))
        return WPESceneScriptHostObject(
            id: id,
            name: name,
            visibleScript: script,
            scriptProperties: scriptPropertyValues(visibleDict["scriptproperties"])
        )
    }

    /// Parent id and OWN baked `visible` for every object (groups included). The
    /// renderer walks the parent chain live so a layer script can't show a layer
    /// under a currently-hidden ancestor (group toggle, condition, or live image
    /// toggle alike) — its `getParent()` is a neutral always-visible stub.
    private static func objectHierarchy(
        _ rawObjects: [[String: Any]]
    ) -> (parents: [String: String], ownVisibility: [String: Bool]) {
        var parents: [String: String] = [:]
        var ownVisibility: [String: Bool] = [:]
        for object in rawObjects {
            guard let id = objectID(in: object) else { continue }
            ownVisibility[id] = parseBool(object["visible"]) ?? true
            if let parent = parentID(in: object), parent != id {
                parents[id] = parent
            }
        }
        return (parents, ownVisibility)
    }

    /// Records, per user-property key, the render targets it drives and whether
    /// it can be applied incrementally. Only `image`/`text` visibility is
    /// incremental today; everything else is conservatively `.reload`.
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
            let specs = (try? userPropertyBindingSpecs(in: raw))?.sorted { lhs, rhs in
                if lhs.key != rhs.key { return lhs.key < rhs.key }
                return (lhs.condition ?? "") < (rhs.condition ?? "")
            } ?? []
            for spec in specs {
                result[spec.key, default: []].append(WPEScenePropertyBinding(
                    propertyKey: spec.key,
                    target: target,
                    kind: kind,
                    action: action,
                    condition: spec.condition
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
                                forEachShaderConstant(in: pass["constantshadervalues"]) { name, raw in
                                    append(raw: raw, target: .shaderUniform(objectID: objectID, effectID: effectIdentifier, passID: passID, name: name), kind: .uniform, action: .reload)
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

    /// Describes one user-property dependency discovered in a raw scene field:
    /// the property key plus, for condition-form (style-selector) bindings, the
    /// expected literal the property must match for the field's `value` to take
    /// effect (nil for the simple form).
    private struct UserPropertyBindingSpec: Hashable {
        let key: String
        let condition: String?
    }

    /// Recursively collects every user-property envelope reachable from `raw`
    /// (a field value may be a scalar, a `{user}` envelope, or an array of them
    /// — e.g. color components). Handles both the simple form
    /// `{"user":K,"value":...}` and the condition form
    /// `{"user":{"name":K,"condition":"2"},"value":...}` (style selectors).
    private static func userPropertyBindingSpecs(in raw: Any?, depth: Int = 0) throws -> Set<UserPropertyBindingSpec> {
        guard depth < 100 else {
            throw WPESceneDocumentError.malformedField("scene.json is too deeply nested")
        }
        guard let raw else { return [] }
        if let array = raw as? [Any] {
            return try array.reduce(into: Set<UserPropertyBindingSpec>()) { specs, value in
                specs.formUnion(try userPropertyBindingSpecs(in: value, depth: depth + 1))
            }
        }
        guard let dict = raw as? [String: Any] else { return [] }
        var specs = Set<UserPropertyBindingSpec>()
        if dict.keys.contains("value") {
            if let key = dict["user"] as? String {
                specs.insert(UserPropertyBindingSpec(key: key, condition: nil))
            } else if let user = dict["user"] as? [String: Any],
                      let name = user["name"] as? String, !name.isEmpty {
                specs.insert(UserPropertyBindingSpec(
                    key: name,
                    condition: conditionString(from: user["condition"])
                ))
            }
        }
        for value in dict.values {
            specs.formUnion(try userPropertyBindingSpecs(in: value, depth: depth + 1))
        }
        return specs
    }

    /// Normalises a condition literal (`String`/number/`Bool`) to its string
    /// form. Integral numbers render without a trailing `.0` so a combo option
    /// value of `2` matches a condition `"2"`. JSON booleans (which bridge to
    /// `NSNumber`) are kept distinct from numerics.
    private static func conditionString(from raw: Any?) -> String? {
        if let value = raw as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = raw as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            // `NSNumber.stringValue` renders integers without a trailing `.0`
            // and never traps — unlike `Int(double)`, which would crash on a
            // finite but out-of-`Int`-range literal from external scene JSON.
            return number.stringValue
        }
        return nil
    }

    private static func resolvedObjectTransforms(
        _ rawObjects: [[String: Any]],
        scriptOrigins: [String: SIMD3<Double>] = [:]
    ) -> [String: SceneObjectTransform] {
        var objectsByID: [String: [String: Any]] = [:]
        for object in rawObjects {
            guard let id = objectID(in: object), objectsByID[id] == nil else { continue }
            objectsByID[id] = object
        }

        var memo: [String: SceneObjectTransform] = [:]

        func resolve(id: String, stack: Set<String>) -> SceneObjectTransform {
            if let cached = memo[id] { return cached }
            guard let object = objectsByID[id] else { return .identity }
            let local = localTransform(in: object, scriptOrigins: scriptOrigins)
            guard let parent = parentID(in: object),
                  parent != id,
                  objectsByID[parent] != nil,
                  !stack.contains(parent) else {
                memo[id] = local
                return local
            }
            guard stack.count < 100 else {
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

    /// WPE binds a transform component to a user property as
    /// `{"user": "newpropertyN", "value": "0.5 0.5 0.5"}`; the resolved value is
    /// in `value`. Unwrap it in the APP target (not just the package's vector3,
    /// which a stale incremental build may not recompile) so a property-bound
    /// scale/origin resolves instead of defaulting.
    private static func resolveBoundTransformValue(_ raw: Any?) -> Any? {
        if let dict = raw as? [String: Any], let value = dict["value"] {
            return value
        }
        return raw
    }

    private static func localTransform(
        in dict: [String: Any],
        scriptOrigins: [String: SIMD3<Double>] = [:]
    ) -> SceneObjectTransform {
        // A script-resolved origin (computed from current user values) replaces the
        // stale baked `value` at the LOCAL level, so parent combination is unchanged.
        let origin: SIMD3<Double>
        if let id = objectID(in: dict), let scripted = scriptOrigins[id] {
            origin = scripted
        } else {
            origin = parseVector3(resolveBoundTransformValue(dict["origin"])) ?? SIMD3<Double>(0, 0, 0)
        }
        return SceneObjectTransform(
            origin: origin,
            scale: parseScale(dict["scale"]),
            angles: parseVector3(resolveBoundTransformValue(dict["angles"])) ?? SIMD3<Double>(0, 0, 0)
        )
    }

    /// Effective visibility per object id = the object's own `visible` AND every
    /// ancestor's. WPE hides a whole component by toggling a parent GROUP's
    /// `visible` (often a condition bound to a user combo, e.g. week1's
    /// 横/竖/关闭), but groups aren't renderable objects — their children carry
    /// their own `visible`. Without folding the ancestor chain in, a child whose
    /// own `visible` is true still renders even though its group is hidden, so
    /// both the horizontal and vertical variant show at once. Mirrors the image
    /// graph's `hasHiddenAncestor`, but covers group containers and text too.
    private static func resolvedObjectVisibility(
        _ rawObjects: [[String: Any]]
    ) -> [String: Bool] {
        var objectsByID: [String: [String: Any]] = [:]
        for object in rawObjects {
            guard let id = objectID(in: object), objectsByID[id] == nil else { continue }
            objectsByID[id] = object
        }

        var memo: [String: Bool] = [:]

        func resolve(id: String, stack: Set<String>) -> Bool {
            if let cached = memo[id] { return cached }
            guard let object = objectsByID[id] else { return true }
            let own = parseBool(object["visible"]) ?? true
            guard own else { memo[id] = false; return false }
            guard let parent = parentID(in: object),
                  parent != id,
                  objectsByID[parent] != nil,
                  !stack.contains(parent) else {
                memo[id] = own
                return own
            }
            guard stack.count < 100 else {
                memo[id] = own
                return own
            }
            let effective = own && resolve(id: parent, stack: stack.union([id]))
            memo[id] = effective
            return effective
        }

        for id in objectsByID.keys {
            _ = resolve(id: id, stack: [])
        }
        return memo
    }

    /// Evaluates static `origin` scripts once per document, returning the resolved
    /// LOCAL origin keyed by object id. Objects without an origin script — or whose
    /// script is dynamic (audio/time/random) — are absent, keeping their baked value.
    private static func resolveScriptOrigins(
        _ rawObjects: [[String: Any]],
        canvasWidth: Double,
        canvasHeight: Double
    ) -> [String: SIMD3<Double>] {
        var pending: [(id: String, script: String, properties: [String: WPESceneScriptPropertyValue], seed: SIMD3<Double>)] = []
        for object in rawObjects {
            guard let id = objectID(in: object),
                  let origin = object["origin"] as? [String: Any],
                  let script = origin["script"] as? String, !script.isEmpty,
                  WPETransformScriptEvaluator.isStaticallyResolvable(script) else { continue }
            let properties = scriptPropertyValues(origin["scriptproperties"])
            let seed = parseVector3(resolveBoundTransformValue(origin["value"])) ?? SIMD3<Double>(0, 0, 0)
            pending.append((id, script, properties, seed))
        }
        guard !pending.isEmpty else { return [:] }

        let evaluator = WPETransformScriptEvaluator(canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        var resolved: [String: SIMD3<Double>] = [:]
        resolved.reserveCapacity(pending.count)
        for item in pending {
            if let origin = evaluator.resolveVec3(
                script: item.script,
                properties: item.properties,
                seed: item.seed
            ) {
                resolved[item.id] = origin
            }
        }
        return resolved
    }

    /// Reads a resolved `scriptproperties` dict into typed values. User-property
    /// envelopes were already collapsed to literals before parsing; the
    /// `{ "value": X }` fallback covers any un-overridden binding. Numbers, bools
    /// (checkboxes), and strings (combos/text) are all preserved so a layout
    /// script can branch on any of them.
    private static func scriptPropertyValues(_ raw: Any?) -> [String: WPESceneScriptPropertyValue] {
        guard let dict = raw as? [String: Any] else { return [:] }
        var properties: [String: WPESceneScriptPropertyValue] = [:]
        for (key, value) in dict {
            if let resolved = scriptPropertyValue(value) {
                properties[key] = resolved
            }
        }
        return properties
    }

    private static func scriptPropertyValue(_ raw: Any?) -> WPESceneScriptPropertyValue? {
        if let dict = raw as? [String: Any], let inner = dict["value"] {
            return scriptPropertyValue(inner)
        }
        if let number = raw as? NSNumber {
            // CFBoolean is an NSNumber subtype; JSON true/false must stay a bool
            // rather than collapse to 1/0 so checkbox-driven branches still work.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return .number(number.doubleValue)
        }
        if let string = raw as? String {
            // Prefer a numeric reading of a "0.5"-style string; else keep the text.
            if let number = parseDouble(string) { return .number(number) }
            return .string(string)
        }
        return nil
    }

    /// WPE may store scale as a vector ("0.5 0.5 0.5"), a {user,value} property
    /// binding, OR a single uniform scalar (0.5 → applied to all axes — this is
    /// what a resolved "Scale Size" slider writes). `parseVector3` returns nil for
    /// a lone scalar, which silently defaulted scale to 1.0 and doubled the layer
    /// (scene 3460973721's audio-bar composelayer). Coerce the scalar to uniform.
    private static func parseScale(_ raw: Any?) -> SIMD3<Double> {
        let resolved = resolveBoundTransformValue(raw)
        if let vector = parseVector3(resolved) { return vector }
        if let scalar = parseDouble(resolved) { return SIMD3<Double>(scalar, scalar, scalar) }
        return SIMD3<Double>(1, 1, 1)
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

    private static func parseTextObject(
        _ dict: [String: Any],
        transform: SceneObjectTransform,
        effectiveVisible: Bool? = nil,
        diagnostics: inout [WPESceneDiagnostic]
    ) -> WPESceneTextObject? {
        let raw = dict["text"]
        let text: String?
        var textScript: String? = nil
        var textScriptProperties: [String: WPESceneScriptPropertyValue] = [:]
        switch raw {
        case let value as String:
            text = value
        case let nested as [String: Any]:
            text = (nested["value"] as? String) ?? (nested["text"] as? String)
            if let script = nested["script"] as? String, !script.isEmpty {
                textScript = script
                // The scene's per-object scriptProperty overrides (already
                // envelope-resolved to literals) so the script renders with the
                // scene's settings, not just its own declared defaults.
                textScriptProperties = scriptPropertyValues(nested["scriptproperties"])
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
        let visible = effectiveVisible ?? (parseBool(dict["visible"]) ?? true)
        let horiz = unwrapString(dict["horizontalalign"]) ?? "center"
        let vert = unwrapString(dict["verticalalign"]) ?? "middle"
        // `maxwidth` only constrains the text when WPE's "Limit Width" toggle
        // (`limitwidth`) is on. With it off (the default), the text is unbounded;
        // applying `maxwidth` unconditionally made large clock/date text wrap at
        // every glyph (each digit is wider than the authored 500pt maxwidth).
        let limitWidth = parseBool(dict["limitwidth"]) ?? false
        let maxWidth = limitWidth ? unwrapDouble(dict["maxwidth"]) : nil
        let parallaxDepth = parseParallaxDepth(dict["parallaxDepth"] ?? dict["parallaxdepth"])
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
            scriptProperties: textScriptProperties,
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
        userValues: [String: WallpaperEngineProjectPropertyValue],
        depth: Int = 0
    ) throws -> Any {
        guard depth < 100 else {
            throw WPESceneDocumentError.malformedField("scene.json is too deeply nested")
        }
        if let array = raw as? [Any] {
            return try array.map {
                try resolveUserPropertyEnvelopes(in: $0, userValues: userValues, depth: depth + 1)
            }
        }

        guard let dict = raw as? [String: Any] else {
            return raw
        }

        // A field carrying a `script` is script-driven (a SceneScript computes it
        // per frame); its `user`/`value` is the script's own enable binding, not a
        // plain user-property envelope. Collapsing it to `value` would discard the
        // script (e.g. an intro video layer whose `visible` is `{script, user, value}`),
        // so preserve the dict — recursing so nested `scriptproperties` envelopes
        // still resolve to the user's values.
        if let script = dict["script"] as? String, !script.isEmpty {
            var resolved: [String: Any] = [:]
            resolved.reserveCapacity(dict.count)
            for (key, value) in dict {
                resolved[key] = try resolveUserPropertyEnvelopes(in: value, userValues: userValues, depth: depth + 1)
            }
            return resolved
        }

        if let key = dict["user"] as? String,
           dict.keys.contains("value") {
            let fallback = try resolveUserPropertyEnvelopes(
                in: dict["value"] ?? NSNull(),
                userValues: userValues,
                depth: depth + 1
            )
            guard let override = userValues[key] else {
                return fallback
            }
            return jsonValue(for: override)
        }

        // Condition form (WPE style selector):
        // `{"user":{"name":K,"condition":"2"},"value":false}`. The field is
        // visible only while `userValues[K]` matches the condition literal.
        if let user = dict["user"] as? [String: Any],
           let name = user["name"] as? String, !name.isEmpty,
           dict.keys.contains("value") {
            let fallback = try resolveUserPropertyEnvelopes(
                in: dict["value"] ?? NSNull(),
                userValues: userValues,
                depth: depth + 1
            )
            guard let override = userValues[name] else {
                return fallback
            }
            guard let condition = conditionString(from: user["condition"]) else {
                // Nested user with a name but no condition → the property drives
                // the value directly, like the simple form.
                return jsonValue(for: override)
            }
            // Gate to a Bool only when the baked fallback is a genuine JSON
            // boolean (a `visible` field). `strictBool` rejects numeric
            // NSNumbers, so a condition-form envelope wrapping a scalar field
            // (alpha/brightness/scale) — or a vector/color — is returned
            // untouched instead of being coerced into a Bool.
            guard WPEValueParser.strictBool(fallback) != nil else {
                return fallback
            }
            return WallpaperEngineProjectPropertySchema.sceneConditionMatches(
                value: override,
                condition: condition
            )
        }

        var resolved: [String: Any] = [:]
        resolved.reserveCapacity(dict.count)
        for (key, value) in dict {
            resolved[key] = try resolveUserPropertyEnvelopes(
                in: value,
                userValues: userValues,
                depth: depth + 1
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
        effectiveVisible: Bool? = nil,
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
        let visible = effectiveVisible ?? (parseBool(dict["visible"]) ?? true)
        let alphaValue = parseAnimatedScalar(dict["alpha"], fallback: 1)
        let color = parseVector3(dict["color"]) ?? SIMD3<Double>(1, 1, 1)
        let parallaxDepth = parseParallaxDepth(dict["parallaxDepth"] ?? dict["parallaxdepth"])
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
        // WPE stores an override either as a bare value (`"lifetime": 0.66`)
        // or, when bound to a user-editable property, as a wrapper
        // `{ "user": "<prop>", "value": X }`. Unwrap `.value` first or the
        // user-bound overrides get silently dropped — that dropped debris
        // `rate` (→ over-dense) and wildfire `alpha` (→ over-bright) in
        // scene 3460973721.
        func unwrap(_ key: String) -> Any? {
            let v = dict[key]
            if let inner = (v as? [String: Any])?["value"] { return inner }
            return v
        }
        let value = WPESceneParticleInstanceOverride(
            count: parseDouble(unwrap("count")),
            rate: parseDouble(unwrap("rate")),
            lifetime: parseDouble(unwrap("lifetime")),
            size: parseDouble(unwrap("size")),
            speed: parseDouble(unwrap("speed")),
            alpha: parseDouble(unwrap("alpha")),
            color: parseNormalizedParticleColor(unwrap("colorn")) ?? parseVector3(unwrap("color"))
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
        case "image", "model": return .image
        case "sound": return .sound
        case "particle": return .particle
        case "text": return .text
        case "light": return .light
        default: return .unknown
        }
    }

    private static func shapeCandidates(in entry: [String: Any]) -> [WPESceneObjectKind] {
        var kinds: [WPESceneObjectKind] = []
        if entry["image"] != nil || entry["model"] != nil { kinds.append(.image) }
        if entry["sound"] != nil { kinds.append(.sound) }
        if entry["particle"] != nil { kinds.append(.particle) }
        if entry["text"] != nil { kinds.append(.text) }
        if entry["light"] != nil { kinds.append(.light) }
        return kinds
    }

    // MARK: - Camera

    private static func parseCamera(
        _ dict: [String: Any],
        general: [String: Any],
        diagnostics: inout [WPESceneDiagnostic]
    ) -> WPESceneCamera {
        let center = parseVector3(dict["center"]) ?? WPESceneCamera.defaultCamera.center
        let eye = parseVector3(dict["eye"]) ?? WPESceneCamera.defaultCamera.eye
        let up = parseVector3(dict["up"]) ?? WPESceneCamera.defaultCamera.up
        let nearZ = parseDouble(dict["nearz"])
            ?? parseDouble(general["nearz"])
            ?? WPESceneCamera.defaultCamera.nearZ
        let farZ = parseDouble(dict["farz"])
            ?? parseDouble(general["farz"])
            ?? WPESceneCamera.defaultCamera.farZ
        let fov = parseDouble(dict["fov"])
            ?? parseDouble(general["fov"])
            ?? WPESceneCamera.defaultCamera.fov
        return WPESceneCamera(center: center, eye: eye, up: up, nearZ: nearZ, farZ: farZ, fov: fov)
    }

    // MARK: - General

    private static func parseGeneral(_ dict: [String: Any], diagnostics: inout [WPESceneDiagnostic]) -> WPESceneGeneral {
        let clearColor = parseVector3(dict["clearcolor"]) ?? WPESceneGeneral.defaultGeneral.clearColor
        let projection: WPESceneOrthogonalProjection
        let usesPerspectiveProjection: Bool
        if let nested = dict["orthogonalprojection"] as? [String: Any] {
            let width = parseDouble(nested["width"]) ?? WPESceneGeneral.defaultGeneral.orthogonalProjection.width
            let height = parseDouble(nested["height"]) ?? WPESceneGeneral.defaultGeneral.orthogonalProjection.height
            let auto = (nested["auto"] as? Bool) ?? WPESceneGeneral.defaultGeneral.orthogonalProjection.auto
            projection = WPESceneOrthogonalProjection(width: width, height: height, auto: auto)
            usesPerspectiveProjection = false
        } else if dict.keys.contains("orthogonalprojection"),
                  dict["orthogonalprojection"] is NSNull {
            diagnostics.append(.init(
                severity: .info,
                message: String(
                    localized: "general.orthogonalprojection is null — using perspective camera with 1920×1080 render size",
                    defaultValue: "general.orthogonalprojection is null — using perspective camera with 1920×1080 render size",
                    comment: "Wallpaper Engine scene diagnostic when perspective projection is used."
                )
            ))
            projection = WPESceneGeneral.defaultGeneral.orthogonalProjection
            usesPerspectiveProjection = true
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
            usesPerspectiveProjection = false
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
            usesPerspectiveProjection: usesPerspectiveProjection,
            cameraParallax: cameraParallax,
            supportsAudioProcessing: supportsAudioProcessing
        )
    }

    // MARK: - Image objects

    private static func parseImageObject(
        _ dict: [String: Any],
        transform: SceneObjectTransform,
        scriptOrigins: [String: SIMD3<Double>] = [:],
        effectiveVisible: Bool? = nil,
        diagnostics: inout [WPESceneDiagnostic]
    ) -> WPESceneImageObject? {
        guard let imagePath = nonEmptyString(dict["image"]) ?? nonEmptyString(dict["model"]) else {
            let objectName = dict["name"] as? String ?? "?"
            diagnostics.append(.init(
                severity: .warning,
                message: "Image/model object \(objectName) has no renderable resource path"
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
        let local = localTransform(in: dict, scriptOrigins: scriptOrigins)
        let parentObjectID = parentID(in: dict)
        let attachment = nonEmptyString(dict["attachment"]) ?? nonEmptyString(dict["anchor"])
        let visible = effectiveVisible ?? (parseBool(dict["visible"]) ?? true)
        let effects = parseImageEffects(dict["effects"], imageName: name, diagnostics: &diagnostics)
        let alphaFallback = imageAlphaFallback(
            imagePath: imagePath,
            rawAlpha: dict["alpha"],
            effects: effects
        )
        let alphaValue = parseAnimatedScalar(dict["alpha"], fallback: alphaFallback)
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
        let animationLayers = parseAnimationLayers(dict["animationlayers"], imageName: name, diagnostics: &diagnostics)
        let originScript = dynamicTransformScript(in: dict["origin"], preserveStaticallyResolvable: false)
        let scaleScript = dynamicTransformScript(in: dict["scale"], preserveStaticallyResolvable: true)
        let anglesScript = dynamicTransformScript(in: dict["angles"], preserveStaticallyResolvable: true)

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

        let parallaxDepth = parseParallaxDepth(dict["parallaxDepth"] ?? dict["parallaxdepth"])

        // A `visible` field that is a script-dict carries a WPE SceneScript that
        // drives the layer's visibility/alpha (and any video texture) per frame —
        // e.g. an intro video that plays once then hides. Capture it; the layer
        // stays renderable (visible defaults true above) until init()/update() run.
        var visibleScript: String? = nil
        var visibleScriptProperties: [String: WPESceneScriptPropertyValue] = [:]
        if let visibleDict = dict["visible"] as? [String: Any],
           let script = visibleDict["script"] as? String, !script.isEmpty {
            visibleScript = script
            visibleScriptProperties = scriptPropertyValues(visibleDict["scriptproperties"])
            diagnostics.append(.init(severity: .info, message: "Image \(name) has a visible-script; runs as a layer SceneScript"))
        }
        var alphaScript: String? = nil
        var alphaScriptProperties: [String: WPESceneScriptPropertyValue] = [:]
        if let alphaDict = dict["alpha"] as? [String: Any],
           let script = alphaDict["script"] as? String, !script.isEmpty {
            alphaScript = script
            alphaScriptProperties = scriptPropertyValues(alphaDict["scriptproperties"])
            diagnostics.append(.init(severity: .info, message: "Image \(name) has an alpha-script; runs as a layer SceneScript"))
        }

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
            parallaxDepth: parallaxDepth,
            visibleScript: visibleScript,
            alphaScript: alphaScript,
            alphaScriptProperties: alphaScriptProperties,
            originScript: originScript,
            scaleScript: scaleScript,
            anglesScript: anglesScript,
            scriptProperties: visibleScriptProperties
        )
    }

    private static func imageAlphaFallback(
        imagePath: String,
        rawAlpha: Any?,
        effects: [WPESceneImageEffect]
    ) -> Double {
        guard rawAlpha == nil,
              effects.contains(where: \.visible) else {
            return 1
        }

        switch imagePath.lowercased() {
        case "models/util/solidlayer.json", "models/util/solidlayer_depthtest.json":
            // Solid layers are commonly used as transparent effect surfaces. If
            // the scene did not author an alpha, keep the base transparent so the
            // effect draws its own alpha instead of filling the target rectangle.
            return 0
        default:
            return 1
        }
    }

    private static func dynamicTransformScript(
        in raw: Any?,
        preserveStaticallyResolvable: Bool
    ) -> WPESceneTransformScript? {
        guard let transform = raw as? [String: Any],
              let script = transform["script"] as? String, !script.isEmpty,
              preserveStaticallyResolvable || !WPETransformScriptEvaluator.isStaticallyResolvable(script) else {
            return nil
        }
        let seed = parseVector3(resolveBoundTransformValue(transform["value"])) ?? SIMD3<Double>(0, 0, 0)
        return WPESceneTransformScript(
            script: script,
            scriptProperties: scriptPropertyValues(transform["scriptproperties"]),
            seed: seed
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
            if let string = parseTextureSlotPath(value) {
                result[index] = string
            }
        }
        return result
    }

    /// Effect texture arrays mix plain path strings with structured entries
    /// (`{"name": "masks/pulse__mask_…"}` — how per-instance opacity masks are
    /// declared). Resolve both; `NSNull` / empty slots return nil.
    private static func parseTextureSlotPath(_ raw: Any?) -> String? {
        if let string = raw as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let dict = raw as? [String: Any] else { return nil }
        for key in ["value", "name", "texture", "path", "file"] {
            if let parsed = parseTextureSlotPath(dict[key]) {
                return parsed
            }
        }
        return nil
    }

    /// Iterates `constantshadervalues` in either of WPE's two forms (plain
    /// dict, or structured array of `{name:…, value:…|default:…}` entries).
    private static func forEachShaderConstant(
        in raw: Any?,
        _ body: (String, Any) -> Void
    ) {
        if let dict = raw as? [String: Any] {
            for (name, value) in dict {
                body(name, value)
            }
            return
        }
        guard let array = raw as? [Any] else { return }
        for entry in array {
            guard let dict = entry as? [String: Any],
                  let name = WPEValueParser.shaderConstantEntryName(in: dict) else { continue }
            if dict.keys.contains("value") {
                body(name, dict["value"] ?? NSNull())
            } else if dict.keys.contains("default") {
                body(name, dict["default"] ?? NSNull())
            }
        }
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

    /// WPE stores object `parallaxDepth` as a PER-AXIS vector string ("x y"),
    /// not a scalar — e.g. "1.000 1.000". A plain `parseDouble` returns nil for
    /// that (Swift's `Double(_:)` rejects the embedded space), so every object's
    /// depth silently fell back to 0 and the camera-parallax pipeline received
    /// all-zero depths → no layer ever shifted with the cursor. WPE supports
    /// per-axis depth ("1 0" = horizontal-only, "0 1" = vertical-only), so keep
    /// both axes rather than collapsing to one. A bare scalar maps to both axes;
    /// a `{ "user", "value" }` wrapper is unwrapped; absent → `.zero` (pinned).
    static func parseParallaxDepth(_ raw: Any?) -> SIMD2<Double> {
        if let dict = raw as? [String: Any], let value = dict["value"] {
            return parseParallaxDepth(value)
        }
        if let vector = parseVector3(raw) { return SIMD2<Double>(vector.x, vector.y) }
        if let scalar = parseDouble(raw) { return SIMD2<Double>(scalar, scalar) }
        return SIMD2<Double>(0, 0)
    }

    private static func parseInt(_ raw: Any?) -> Int? {
        WPEValueParser.int(raw)
    }

    private static func parseBool(_ raw: Any?) -> Bool? {
        // WPE binds layer/effect visibility (and other toggles) to a user property as
        // {"user": {...}, "value": <bool>}; the resolved value is in `value`. Unwrap
        // it so a property-bound `visible:false` actually hides the layer instead of
        // defaulting to true — e.g. scene 3461168300's "音频条底" is hidden by the
        // "音频条/audio strip" style combo (newproperty14=斜), leaving only the diagonal.
        if let dict = raw as? [String: Any], let value = dict["value"] {
            return parseBool(value)
        }
        return WPEValueParser.bool(raw)
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
        let scaled = SIMD3<Double>(
            child.origin.x * scale.x,
            child.origin.y * scale.y,
            child.origin.z * scale.z
        )
        let rotated = Self.rotate(scaled, by: angles)

        return SceneObjectTransform(
            origin: SIMD3<Double>(
                origin.x + rotated.x,
                origin.y + rotated.y,
                origin.z + rotated.z
            ),
            scale: SIMD3<Double>(
                scale.x * child.scale.x,
                scale.y * child.scale.y,
                scale.z * child.scale.z
            ),
            angles: angles + child.angles
        )
    }

    private static func rotate(_ value: SIMD3<Double>, by angles: SIMD3<Double>) -> SIMD3<Double> {
        var result = value

        if angles.x != 0 {
            let c = cos(angles.x)
            let s = sin(angles.x)
            result = SIMD3<Double>(
                result.x,
                result.y * c - result.z * s,
                result.y * s + result.z * c
            )
        }
        if angles.y != 0 {
            let c = cos(angles.y)
            let s = sin(angles.y)
            result = SIMD3<Double>(
                result.x * c + result.z * s,
                result.y,
                -result.x * s + result.z * c
            )
        }
        if angles.z != 0 {
            let c = cos(angles.z)
            let s = sin(angles.z)
            result = SIMD3<Double>(
                result.x * c - result.y * s,
                result.x * s + result.y * c,
                result.z
            )
        }

        return result
    }
}
#endif
