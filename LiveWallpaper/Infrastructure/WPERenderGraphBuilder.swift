#if !LITE_BUILD
import Foundation

struct WPERenderGraphBuilder: Sendable {
    private let resolver: WPEMultiRootResourceResolver

    init(
        cacheRootURL: URL,
        dependencyMounts: [WPEAssetMount] = [],
        engineAssetsRootURL: URL? = nil,
        tracer: WPEResolutionTracer? = nil
    ) {
        self.resolver = WPEMultiRootResourceResolver(
            primaryRootURL: cacheRootURL,
            dependencyMounts: dependencyMounts,
            engineAssetsRootURL: engineAssetsRootURL,
            tracer: tracer
        )
    }

    func build(document: WPESceneDocument) throws -> WPERenderGraph {
        var objectByID: [String: WPESceneImageObject] = [:]
        for object in document.imageObjects where objectByID[object.id] == nil {
            objectByID[object.id] = object
        }

        let visibleLayerIDs = Set(document.imageObjects
            .filter(Self.compositesToScene)
            .map(\.id))
        var layerIDsToBuild = visibleLayerIDs
        var pendingIDs = Array(visibleLayerIDs)

        while let id = pendingIDs.popLast(), let object = objectByID[id] {
            for dependencyID in Self.referencedLayerIDs(in: object) where objectByID[dependencyID] != nil {
                if layerIDsToBuild.insert(dependencyID).inserted {
                    pendingIDs.append(dependencyID)
                }
            }
        }

        let layers = try document.imageObjects
            .filter { layerIDsToBuild.contains($0.id) }
            .map { object in
                try buildLayer(
                    object: object,
                    finalUntargetedPassToScene: visibleLayerIDs.contains(object.id)
                )
            }
        return WPERenderGraph(layers: layers)
    }

    private static func compositesToScene(_ object: WPESceneImageObject) -> Bool {
        object.visible && object.alpha > 0.001
    }

    private static func referencedLayerIDs(in object: WPESceneImageObject) -> Set<String> {
        var ids = Set(object.dependencies)
        for effect in object.effects where effect.visible {
            for passOverride in effect.passOverrides {
                for texture in passOverride.textures.values {
                    if let id = layerID(fromCompositeName: texture) {
                        ids.insert(id)
                    }
                }
            }
        }
        return ids
    }

    private static func layerID(fromCompositeName name: String) -> String? {
        let prefix = "_rt_imageLayerComposite_"
        guard name.hasPrefix(prefix),
              name.hasSuffix("_a") || name.hasSuffix("_b") else {
            return nil
        }
        let start = name.index(name.startIndex, offsetBy: prefix.count)
        let end = name.index(name.endIndex, offsetBy: -2)
        guard start < end else { return nil }
        return String(name[start..<end])
    }

    private func buildLayer(
        object: WPESceneImageObject,
        finalUntargetedPassToScene: Bool
    ) throws -> WPERenderLayer {
        let materialPath = try resolveMaterialPath(for: object)
        let compositeA = "_rt_imageLayerComposite_\(object.id)_a"
        let compositeB = "_rt_imageLayerComposite_\(object.id)_b"

        var context = LayerBuildContext(
            object: object,
            compositeA: compositeA,
            compositeB: compositeB,
            nextComposite: compositeA,
            source: .image(object.imageRelativePath)
        )

        if let materialPath {
            let material = try builtinMaterial(path: materialPath, object: object) ?? loadMaterial(path: materialPath)
            context.source = material.initialTextureSource(fallback: context.source)
            try appendMaterialPasses(
                material.passes,
                phase: .material,
                override: nil,
                binds: [:],
                explicitTarget: nil,
                to: &context
            )
        }

        for effect in object.effects where effect.visible {
            let asset = try loadEffect(path: effect.fileRelativePath)
            context.localFBOs.append(contentsOf: asset.fbos)
            var overrideIndex = 0
            for effectPass in asset.passes {
                let override = overrideIndex < effect.passOverrides.count
                    ? effect.passOverrides[overrideIndex]
                    : nil
                overrideIndex += 1

                switch effectPass.kind {
                case .material(let materialPath):
                    let material = try loadMaterial(path: materialPath)
                    try appendMaterialPasses(
                        material.passes,
                        phase: .effect(file: effect.fileRelativePath),
                        override: override,
                        binds: effectPass.binds,
                        explicitTarget: effectPass.target.map { .fbo(name: $0) },
                        to: &context
                    )
                case .command(let command, let source, let target):
                    let virtualPass = WPEMaterialPass(
                        shader: "commands/\(command)",
                        textures: [0: source ?? .previous],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                    try appendMaterialPasses(
                        [virtualPass],
                        phase: .command(file: effect.fileRelativePath),
                        override: override,
                        binds: effectPass.binds,
                        explicitTarget: target.map { .fbo(name: $0) },
                        to: &context
                    )
                }
            }
        }

        return WPERenderLayer(
            objectID: object.id,
            objectName: object.name,
            imagePath: object.imageRelativePath,
            materialPath: materialPath,
            compositeA: compositeA,
            compositeB: compositeB,
            localFBOs: context.localFBOs,
            passes: context.finalizedPasses(finalUntargetedPassToScene: finalUntargetedPassToScene),
            parallaxDepth: object.parallaxDepth
        )
    }

    private func appendMaterialPasses(
        _ passes: [WPEMaterialPass],
        phase: WPERenderPassPhase,
        override: WPESceneEffectPassOverride?,
        binds: [Int: WPETextureReference],
        explicitTarget: WPERenderTarget?,
        to context: inout LayerBuildContext
    ) throws {
        for materialPass in passes {
            let target = explicitTarget ?? .layerComposite(name: context.nextComposite)
            let merged = materialPass.merging(override: override)
            let passID = "\(context.object.id).\(context.passes.count)"
            context.passes.append(WPERenderPass(
                id: passID,
                phase: phase,
                shader: merged.shader,
                source: context.source,
                target: target,
                textures: merged.textures,
                binds: binds,
                constants: merged.constants,
                combos: merged.combos,
                blending: merged.blending,
                cullMode: merged.cullMode,
                depthTest: merged.depthTest,
                depthWrite: merged.depthWrite
            ))
            context.passTargetsWereExplicit.append(explicitTarget != nil)

            if explicitTarget == nil {
                context.source = .fbo(context.nextComposite)
                context.nextComposite = context.nextComposite == context.compositeA
                    ? context.compositeB
                    : context.compositeA
            }
        }
    }

    private func resolveMaterialPath(for object: WPESceneImageObject) throws -> String? {
        if let material = object.materialRelativePath, !material.isEmpty {
            return material
        }
        if isBuiltinModelPath(object.imageRelativePath) {
            return object.imageRelativePath
        }
        let extensionName = (object.imageRelativePath as NSString).pathExtension.lowercased()
        guard extensionName == "json" else {
            return nil
        }
        let dict = try readJSONObject(path: object.imageRelativePath)
        guard let material = dict["material"] as? String, !material.isEmpty else {
            throw WPERenderGraphError.materialUnresolved(object.imageRelativePath)
        }
        return inheritDependencyPrefix(material, from: object.imageRelativePath)
    }

    private func isBuiltinModelPath(_ path: String) -> Bool {
        path.lowercased() == "models/util/solidlayer.json"
    }

    private func builtinMaterial(path: String, object: WPESceneImageObject) throws -> WPEMaterialAsset? {
        guard path.lowercased() == "models/util/solidlayer.json" else {
            return nil
        }

        let color = object.color * object.brightness
        return WPEMaterialAsset(
            path: path,
            passes: [
                WPEMaterialPass(
                    shader: "solidcolor",
                    textures: [:],
                    constants: [
                        "g_Color": .vector([color.x, color.y, color.z, object.alpha])
                    ],
                    combos: [:],
                    blending: object.blendMode.rawValue,
                    cullMode: "nocull",
                    depthTest: "disabled",
                    depthWrite: "disabled"
                )
            ]
        )
    }

    private func loadMaterial(path: String) throws -> WPEMaterialAsset {
        let dict = try readJSONObject(path: path)
        guard let rawPasses = dict["passes"] as? [Any] else {
            throw WPERenderGraphError.malformedMaterial(path)
        }
        let passes = rawPasses.compactMap { parseMaterialPass($0, ownerPath: path) }
        guard !passes.isEmpty else {
            throw WPERenderGraphError.malformedMaterial(path)
        }
        return WPEMaterialAsset(path: path, passes: passes)
    }

    private func loadEffect(path: String) throws -> WPEEffectAsset {
        let dict = try readJSONObject(path: path)
        let fbos = ((dict["fbos"] as? [Any]) ?? []).compactMap(parseFBO)
        let declaredFBONames = Set(fbos.map(\.name))
        guard let rawPasses = dict["passes"] as? [Any] else {
            throw WPERenderGraphError.malformedEffect(path)
        }
        let passes = rawPasses.compactMap {
            parseEffectPass($0, ownerPath: path, declaredFBONames: declaredFBONames)
        }
        guard !passes.isEmpty else {
            throw WPERenderGraphError.malformedEffect(path)
        }
        return WPEEffectAsset(path: path, passes: passes, fbos: fbos)
    }

    private func readJSONObject(path: String) throws -> [String: Any] {
        let url: URL
        do {
            url = try resolver.resolveExistingFileURL(relativePath: path)
        } catch {
            throw WPERenderGraphError.fileMissing(path)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw WPERenderGraphError.fileMissing(path)
        }
        do {
            guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw WPERenderGraphError.invalidJSON(path)
            }
            return dict
        } catch let error as WPERenderGraphError {
            throw error
        } catch {
            throw WPERenderGraphError.invalidJSON(path)
        }
    }

    private func parseMaterialPass(_ raw: Any, ownerPath: String) -> WPEMaterialPass? {
        guard let dict = raw as? [String: Any],
              let shader = dict["shader"] as? String,
              !shader.isEmpty else {
            return nil
        }
        return WPEMaterialPass(
            shader: shader,
            textures: parseTextureArray(dict["textures"], ownerPath: ownerPath),
            constants: parseShaderConstants(dict["constantshadervalues"]),
            combos: parseComboMap(dict["combos"]),
            blending: (dict["blending"] as? String) ?? "normal",
            cullMode: (dict["cullmode"] as? String) ?? "nocull",
            depthTest: (dict["depthtest"] as? String) ?? "disabled",
            depthWrite: (dict["depthwrite"] as? String) ?? "disabled"
        )
    }

    private func parseEffectPass(
        _ raw: Any,
        ownerPath: String,
        declaredFBONames: Set<String>
    ) -> WPEEffectPass? {
        guard let dict = raw as? [String: Any] else { return nil }
        let binds = parseBinds(
            dict["bind"],
            ownerPath: ownerPath,
            declaredFBONames: declaredFBONames
        )
        let target = dict["target"] as? String
        if let material = dict["material"] as? String, !material.isEmpty {
            return WPEEffectPass(
                kind: .material(inheritDependencyPrefix(material, from: ownerPath)),
                binds: binds,
                target: target
            )
        }
        if let command = dict["command"] as? String, !command.isEmpty {
            return WPEEffectPass(
                kind: .command(
                    command,
                    source: (dict["source"] as? String).map {
                        textureReference($0, ownerPath: ownerPath, declaredFBONames: declaredFBONames)
                    },
                    target: target
                ),
                binds: binds,
                target: target
            )
        }
        return nil
    }

    private func parseFBO(_ raw: Any) -> WPERenderFBO? {
        guard let dict = raw as? [String: Any],
              let name = dict["name"] as? String,
              !name.isEmpty else {
            return nil
        }
        return WPERenderFBO(
            name: name,
            scale: parseDouble(dict["scale"]) ?? 1,
            format: (dict["format"] as? String) ?? "rgba8888",
            unique: parseBool(dict["unique"]) ?? false
        )
    }

    private func parseBinds(
        _ raw: Any?,
        ownerPath: String,
        declaredFBONames: Set<String> = []
    ) -> [Int: WPETextureReference] {
        guard let array = raw as? [Any] else { return [:] }
        var result: [Int: WPETextureReference] = [:]
        for entry in array {
            guard let dict = entry as? [String: Any],
                  let index = parseInt(dict["index"]),
                  let name = dict["name"] as? String,
                  !name.isEmpty else {
                continue
            }
            result[index] = textureReference(name, ownerPath: ownerPath, declaredFBONames: declaredFBONames)
        }
        return result
    }

    private func parseTextureArray(_ raw: Any?, ownerPath: String) -> [Int: WPETextureReference] {
        guard let array = raw as? [Any] else { return [:] }
        var result: [Int: WPETextureReference] = [:]
        for (index, value) in array.enumerated() {
            if let name = value as? String, !name.isEmpty {
                result[index] = textureReference(name, ownerPath: ownerPath)
            }
        }
        return result
    }

    private func textureReference(
        _ name: String,
        ownerPath: String,
        declaredFBONames: Set<String> = []
    ) -> WPETextureReference {
        if name == "previous" {
            return .previous
        }
        if declaredFBONames.contains(name) {
            return .fbo(name)
        }
        if name.hasPrefix("_") {
            return .fbo(name)
        }
        return .asset(inheritDependencyPrefix(name, from: ownerPath))
    }

    private func inheritDependencyPrefix(_ path: String, from ownerPath: String) -> String {
        guard !path.hasPrefix("../"),
              let prefix = dependencyPrefix(in: ownerPath) else {
            return path
        }
        return "\(prefix)/\(path)"
    }

    private func dependencyPrefix(in path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] == ".." else { return nil }
        return "../\(parts[1])"
    }

    private func parseShaderConstants(_ raw: Any?) -> [String: WPESceneShaderConstantValue] {
        WPEValueParser.shaderConstants(raw, boolAsNumber: true)
    }

    private func parseComboMap(_ raw: Any?) -> [String: Int] {
        WPEValueParser.comboMap(raw, boolAsNumber: true)
    }

    private func parseDouble(_ raw: Any?) -> Double? {
        WPEValueParser.double(raw, boolAsNumber: true)
    }

    private func parseBool(_ raw: Any?) -> Bool? {
        WPEValueParser.bool(raw)
    }

    private func parseInt(_ raw: Any?) -> Int? {
        WPEValueParser.int(raw, boolAsNumber: true)
    }
}

private struct LayerBuildContext {
    let object: WPESceneImageObject
    let compositeA: String
    let compositeB: String
    var nextComposite: String
    var source: WPETextureReference
    var localFBOs: [WPERenderFBO] = []
    var passes: [WPERenderPass] = []
    var passTargetsWereExplicit: [Bool] = []

    func finalizedPasses(finalUntargetedPassToScene: Bool) -> [WPERenderPass] {
        guard let lastPass = passes.last,
              finalUntargetedPassToScene,
              passTargetsWereExplicit.indices.contains(passes.count - 1),
              passTargetsWereExplicit[passes.count - 1] == false else {
            return passes.movingFirstBlendModeToFinalPass()
        }

        var finalized = passes
        finalized[finalized.count - 1] = lastPass.replacingTarget(.scene)
        return finalized.movingFirstBlendModeToFinalPass()
    }
}

private extension Array where Element == WPERenderPass {
    func movingFirstBlendModeToFinalPass() -> [WPERenderPass] {
        guard count > 1,
              let first = first,
              let last = last else {
            return self
        }

        var result = self
        result[0] = first.replacingBlending("normal")
        result[result.count - 1] = last.replacingBlending(first.blending)
        return result
    }
}

private struct WPEMaterialAsset {
    let path: String
    let passes: [WPEMaterialPass]

    func initialTextureSource(fallback: WPETextureReference) -> WPETextureReference {
        passes.first?.textures[0] ?? fallback
    }
}

private struct WPEEffectAsset {
    let path: String
    let passes: [WPEEffectPass]
    let fbos: [WPERenderFBO]
}

private struct WPEEffectPass {
    let kind: Kind
    let binds: [Int: WPETextureReference]
    let target: String?

    enum Kind {
        case material(String)
        case command(String, source: WPETextureReference?, target: String?)
    }
}

private struct WPEMaterialPass {
    let shader: String
    let textures: [Int: WPETextureReference]
    let constants: [String: WPESceneShaderConstantValue]
    let combos: [String: Int]
    let blending: String
    let cullMode: String
    let depthTest: String
    let depthWrite: String

    func merging(override: WPESceneEffectPassOverride?) -> WPEMaterialPass {
        guard let override else { return self }
        var mergedTextures = textures
        for (index, path) in override.textures {
            if path.hasPrefix("_") {
                mergedTextures[index] = .fbo(path)
            } else {
                mergedTextures[index] = .asset(path)
            }
        }

        return WPEMaterialPass(
            shader: shader,
            textures: mergedTextures,
            constants: constants.merging(override.constants) { _, new in new },
            combos: combos.merging(override.combos) { _, new in new },
            blending: blending,
            cullMode: cullMode,
            depthTest: depthTest,
            depthWrite: depthWrite
        )
    }
}
#endif
