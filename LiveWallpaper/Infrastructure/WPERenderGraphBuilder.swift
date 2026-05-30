#if !LITE_BUILD
import CoreGraphics
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
        let sceneSize = CGSize(
            width: CGFloat(document.general.orthogonalProjection.width),
            height: CGFloat(document.general.orthogonalProjection.height)
        )
        var objectByID: [String: WPESceneImageObject] = [:]
        var originalIndexByID: [String: Int] = [:]
        for (index, object) in document.imageObjects.enumerated() where objectByID[object.id] == nil {
            objectByID[object.id] = object
            originalIndexByID[object.id] = index
        }

        // Objects whose visibility a user property can toggle at runtime are
        // kept in the graph (with a scene-target pass) even when authored
        // hidden, so the toggle applies live without a pipeline rebuild. The
        // executor skips the scene draw while `WPERenderLayer.visible` is false.
        let liveVisibilityIDs = Self.userToggleableVisibilityIDs(in: document)
        let visibleLayerIDs = Set(document.imageObjects
            .filter { Self.compositesToScene($0, liveVisibilityIDs: liveVisibilityIDs) }
            .map(\.id))
        var layerIDsToBuild = visibleLayerIDs
        var pendingIDs = Array(visibleLayerIDs)
        var layerIDsRequiredAsComposite = Set<String>()

        while let id = pendingIDs.popLast(), let object = objectByID[id] {
            for dependencyID in Self.referencedLayerIDs(in: object) where objectByID[dependencyID] != nil {
                layerIDsRequiredAsComposite.insert(dependencyID)
                if layerIDsToBuild.insert(dependencyID).inserted {
                    pendingIDs.append(dependencyID)
                }
            }
        }

        let orderedLayerIDs = Self.topologicallyOrderedLayerIDs(
            layerIDsToBuild,
            objectByID: objectByID,
            originalIndexByID: originalIndexByID
        )

        let layers = try orderedLayerIDs
            .compactMap { objectByID[$0] }
            .map { object in
                try buildLayer(
                    object: object,
                    sceneSize: sceneSize,
                    finalUntargetedPassToScene: visibleLayerIDs.contains(object.id),
                    preserveFinalCompositeForScene: layerIDsRequiredAsComposite.contains(object.id)
                )
            }
        return WPERenderGraph(layers: layers)
    }

    private static func compositesToScene(_ object: WPESceneImageObject, liveVisibilityIDs: Set<String>) -> Bool {
        guard object.alpha > 0.001 || object.alphaAnimation != nil else { return false }
        return object.visible || liveVisibilityIDs.contains(object.id)
    }

    /// Image-object IDs that have an incremental (`visible`) property binding —
    /// i.e. their on-screen visibility can be toggled live from project settings.
    private static func userToggleableVisibilityIDs(in document: WPESceneDocument) -> Set<String> {
        var ids = Set<String>()
        for bindings in document.propertyBindings.values {
            for binding in bindings where binding.kind == .visible && binding.action == .incremental {
                if case .imageObject(let id) = binding.target {
                    ids.insert(id)
                }
            }
        }
        return ids
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

    /// Orders the layers to build so every composite producer is emitted
    /// before any consumer that references its `_rt_imageLayerComposite_*`
    /// target. WPE scenes often author a consumer object ahead of the
    /// producer it samples; the executor walks layers in array order and the
    /// first frame has no previous named-texture bootstrap, so a producer
    /// that runs later would surface as a fatal `missingTexture(.fbo)`.
    ///
    /// Stable topological sort (Kahn) keyed on the original scene index as a
    /// tie-breaker, so unrelated layers keep their authored order. A
    /// dependency cycle is non-fatal: the cyclic remainder is appended in
    /// scene order and a diagnostic is emitted rather than dropping layers.
    private static func topologicallyOrderedLayerIDs(
        _ layerIDs: Set<String>,
        objectByID: [String: WPESceneImageObject],
        originalIndexByID: [String: Int]
    ) -> [String] {
        func originalIndex(_ id: String) -> Int {
            originalIndexByID[id] ?? Int.max
        }

        func originalOrder(_ lhs: String, _ rhs: String) -> Bool {
            let left = originalIndex(lhs)
            let right = originalIndex(rhs)
            if left != right { return left < right }
            return lhs < rhs
        }

        let orderedIDs = layerIDs.sorted(by: originalOrder)
        var inDegree = Dictionary(uniqueKeysWithValues: orderedIDs.map { ($0, 0) })
        var dependentsByID: [String: Set<String>] = [:]

        for consumerID in orderedIDs {
            guard let consumer = objectByID[consumerID] else { continue }
            for dependencyID in referencedLayerIDs(in: consumer)
            where dependencyID != consumerID
                && layerIDs.contains(dependencyID)
                && objectByID[dependencyID] != nil {
                if dependentsByID[dependencyID, default: []].insert(consumerID).inserted {
                    inDegree[consumerID, default: 0] += 1
                }
            }
        }

        var ready = orderedIDs.filter { inDegree[$0, default: 0] == 0 }
        var emitted: [String] = []
        var emittedIDs = Set<String>()

        while !ready.isEmpty {
            ready.sort(by: originalOrder)
            let id = ready.removeFirst()
            guard emittedIDs.insert(id).inserted else { continue }
            emitted.append(id)

            let dependents = (dependentsByID[id] ?? []).sorted(by: originalOrder)
            for dependentID in dependents {
                let nextDegree = max((inDegree[dependentID] ?? 0) - 1, 0)
                inDegree[dependentID] = nextDegree
                if nextDegree == 0 {
                    ready.append(dependentID)
                }
            }
        }

        if emitted.count < orderedIDs.count {
            let cyclicRemainder = orderedIDs.filter { !emittedIDs.contains($0) }
            logCompositeDependencyCycle(cyclicRemainder)
            emitted.append(contentsOf: cyclicRemainder)
        }

        return emitted
    }

    private static func logCompositeDependencyCycle(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let detail = ids.joined(separator: ", ")
        let message = "WPE render graph composite dependency cycle; preserving scene order for: \(detail)"
        Logger.warning(message, category: .wpeRender)
        WPESceneDebugArtifacts.shared.appendLog(
            "[graph.cycle] \(message)",
            level: .warning
        )
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
        sceneSize: CGSize,
        finalUntargetedPassToScene: Bool,
        preserveFinalCompositeForScene: Bool
    ) throws -> WPERenderLayer {
        let model = try resolveModelDescriptor(for: object)
        let materialPath = model.materialPath
        let puppetPlacement = model.puppetPlacement(for: object, sceneSize: sceneSize)
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
            visible: object.visible,
            imagePath: object.imageRelativePath,
            materialPath: materialPath,
            puppetPath: model.puppetPath,
            geometry: WPERenderLayerGeometry(
                origin: puppetPlacement?.origin ?? object.origin,
                scale: object.scale,
                angles: object.angles,
                alignment: object.alignment,
                size: puppetPlacement?.size ?? object.size,
                puppetMeshCenter: puppetPlacement?.meshCenter ?? SIMD2<Double>(0, 0),
                alpha: object.alpha,
                alphaAnimation: object.alphaAnimation,
                color: object.color,
                brightness: object.brightness
            ),
            compositeA: compositeA,
            compositeB: compositeB,
            localFBOs: context.localFBOs,
            passes: context.finalizedPasses(
                finalUntargetedPassToScene: finalUntargetedPassToScene,
                preserveFinalCompositeForScene: preserveFinalCompositeForScene || model.puppetPath != nil
            ),
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

    private func resolveModelDescriptor(for object: WPESceneImageObject) throws -> WPEModelDescriptor {
        let explicitMaterial = object.materialRelativePath?.isEmpty == false
            ? object.materialRelativePath
            : nil
        if isBuiltinModelPath(object.imageRelativePath) {
            return WPEModelDescriptor(materialPath: explicitMaterial ?? object.imageRelativePath, puppetPath: nil)
        }
        let extensionName = (object.imageRelativePath as NSString).pathExtension.lowercased()
        guard extensionName == "json" else {
            return WPEModelDescriptor(materialPath: explicitMaterial, puppetPath: nil)
        }

        let dict: [String: Any]
        do {
            dict = try readJSONObject(path: object.imageRelativePath)
        } catch {
            guard let explicitMaterial else { throw error }
            return WPEModelDescriptor(materialPath: explicitMaterial, puppetPath: nil)
        }

        guard let material = explicitMaterial ?? (dict["material"] as? String),
              !material.isEmpty else {
            throw WPERenderGraphError.materialUnresolved(object.imageRelativePath)
        }
        let puppetPath = (dict["puppet"] as? String)
            .flatMap { $0.isEmpty ? nil : inheritDependencyPrefix($0, from: object.imageRelativePath) }
        return WPEModelDescriptor(
            materialPath: inheritDependencyPrefix(material, from: object.imageRelativePath),
            puppetPath: puppetPath,
            puppetBounds: puppetPath.flatMap(loadPuppetBounds(path:))
        )
    }

    private func loadPuppetBounds(path: String) -> WPEPuppetBounds? {
        do {
            let url = try resolver.resolveExistingFileURL(relativePath: path)
            let data = try Data(contentsOf: url)
            let model = try WPEMdlParser.parse(data: data)
            guard model.version >= 21 else { return nil }
            return WPEPuppetBounds(model: model)
        } catch {
            return nil
        }
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

    func finalizedPasses(
        finalUntargetedPassToScene: Bool,
        preserveFinalCompositeForScene: Bool
    ) -> [WPERenderPass] {
        guard let lastPass = passes.last,
              finalUntargetedPassToScene,
              passTargetsWereExplicit.indices.contains(passes.count - 1),
              passTargetsWereExplicit[passes.count - 1] == false else {
            return passes.movingFirstBlendModeToFinalPass()
        }

        if preserveFinalCompositeForScene,
           let sceneSource = lastPass.target.textureReference {
            var finalized = passes
            finalized.append(WPERenderPass(
                id: "\(object.id).\(passes.count)",
                phase: .command(file: "materials/util/copy.json"),
                shader: "materials/util/copy.json",
                source: sceneSource,
                target: .scene,
                textures: [0: sceneSource],
                binds: [:],
                constants: [:],
                combos: [:],
                blending: lastPass.blending,
                cullMode: "nocull",
                depthTest: "disabled",
                depthWrite: "disabled"
            ))
            return finalized.movingFirstBlendModeToFinalPass()
        }

        var finalized = passes
        finalized[finalized.count - 1] = lastPass.replacingTarget(.scene)
        return finalized.movingFirstBlendModeToFinalPass()
    }
}

private struct WPEModelDescriptor {
    let materialPath: String?
    let puppetPath: String?
    let puppetBounds: WPEPuppetBounds?

    init(
        materialPath: String?,
        puppetPath: String?,
        puppetBounds: WPEPuppetBounds? = nil
    ) {
        self.materialPath = materialPath
        self.puppetPath = puppetPath
        self.puppetBounds = puppetBounds
    }

    /// Re-place a puppet whose raw MDLV mesh bbox is cropped by the declared
    /// object.size local composite. Sizes the composite AND the scene quad to
    /// the mesh bbox (native 1:1, no shrink/stretch), centers the mesh, and
    /// recomputes the origin so the mesh-bbox center keeps its old on-screen
    /// position. Returns nil (no-op) for non-puppets and puppets that already
    /// fit — protecting every working puppet/image layer.
    func puppetPlacement(for object: WPESceneImageObject, sceneSize: CGSize) -> WPEPuppetPlacement? {
        guard puppetPath != nil,
              let puppetBounds,
              let objectSize = object.size else {
            return nil
        }

        let objectWidth = Double(objectSize.width)
        let objectHeight = Double(objectSize.height)
        guard objectWidth > 0, objectHeight > 0 else { return nil }

        let localMinX = objectWidth * 0.5 + puppetBounds.min.x
        let localMaxX = objectWidth * 0.5 + puppetBounds.max.x
        let localMinY = objectHeight * 0.5 - puppetBounds.max.y
        let localMaxY = objectHeight * 0.5 - puppetBounds.min.y

        let epsilon = 1.0
        let isCropped = localMinX < -epsilon
            || localMaxX > objectWidth + epsilon
            || localMinY < -epsilon
            || localMaxY > objectHeight + epsilon
        guard isCropped else { return nil }

        let scaleX = finiteMagnitude(object.scale.x, fallback: 1)
        let scaleY = finiteMagnitude(object.scale.y, fallback: 1)
        let oldWidth = objectWidth * scaleX
        let oldHeight = objectHeight * scaleY
        let oldOffset = alignmentCenterOffset(
            alignment: object.alignment,
            width: oldWidth,
            height: oldHeight
        )
        let sceneHeight = Double(sceneSize.height)
        let oldCenterX = object.origin.x + oldOffset.x
        let oldCenterY = sceneHeight - object.origin.y - oldOffset.y
        let oldLeft = oldCenterX - oldWidth * 0.5
        let oldTop = oldCenterY - oldHeight * 0.5

        let meshWidth = max(ceil(localMaxX - localMinX), 1)
        let meshHeight = max(ceil(localMaxY - localMinY), 1)
        let meshScaledWidth = meshWidth * scaleX
        let meshScaledHeight = meshHeight * scaleY

        let meshCenterX = oldLeft + (localMinX + localMaxX) * 0.5 * scaleX
        // Keep the mesh-bbox center at its original on-screen position — no
        // bottom clamp. WPE puppet art is authored already cropped at the
        // boots, so that natural cut edge must sit flush against the screen
        // bottom; lifting it (to avoid the final ~50px clip) would float the
        // whole character upward, which is wrong.
        let meshCenterY = oldTop + (localMinY + localMaxY) * 0.5 * scaleY

        let newOffset = alignmentCenterOffset(
            alignment: object.alignment,
            width: meshScaledWidth,
            height: meshScaledHeight
        )
        let newOrigin = SIMD3<Double>(
            meshCenterX - newOffset.x,
            sceneHeight - meshCenterY - newOffset.y,
            object.origin.z
        )

        return WPEPuppetPlacement(
            origin: newOrigin,
            size: CGSize(width: CGFloat(meshWidth), height: CGFloat(meshHeight)),
            meshCenter: puppetBounds.center
        )
    }

    private func finiteMagnitude(_ value: Double, fallback: Double) -> Double {
        let magnitude = abs(value)
        return magnitude.isFinite && magnitude > 0 ? magnitude : fallback
    }

    private func alignmentCenterOffset(
        alignment: WPESceneAlignment,
        width: Double,
        height: Double
    ) -> SIMD2<Double> {
        switch alignment {
        case .center:
            return SIMD2<Double>(0, 0)
        case .topLeft:
            return SIMD2<Double>(width * 0.5, -height * 0.5)
        case .topRight:
            return SIMD2<Double>(-width * 0.5, -height * 0.5)
        case .bottomLeft:
            return SIMD2<Double>(width * 0.5, height * 0.5)
        case .bottomRight:
            return SIMD2<Double>(-width * 0.5, height * 0.5)
        case .top:
            return SIMD2<Double>(0, -height * 0.5)
        case .bottom:
            return SIMD2<Double>(0, height * 0.5)
        case .left:
            return SIMD2<Double>(width * 0.5, 0)
        case .right:
            return SIMD2<Double>(-width * 0.5, 0)
        }
    }
}

private struct WPEPuppetPlacement {
    let origin: SIMD3<Double>
    let size: CGSize
    let meshCenter: SIMD2<Double>
}

private struct WPEPuppetBounds {
    let min: SIMD2<Double>
    let max: SIMD2<Double>

    var center: SIMD2<Double> {
        SIMD2<Double>(
            (min.x + max.x) * 0.5,
            (min.y + max.y) * 0.5
        )
    }

    init?(model: WPEPuppetModel) {
        let vertices = model.meshes.flatMap(\.vertices)
        guard let first = vertices.first else { return nil }

        var minX = Double(first.position.x)
        var maxX = minX
        var minY = Double(first.position.y)
        var maxY = minY

        for vertex in vertices.dropFirst() {
            let x = Double(vertex.position.x)
            let y = Double(vertex.position.y)
            minX = Swift.min(minX, x)
            maxX = Swift.max(maxX, x)
            minY = Swift.min(minY, y)
            maxY = Swift.max(maxY, y)
        }

        self.min = SIMD2<Double>(minX, minY)
        self.max = SIMD2<Double>(maxX, maxY)
    }
}

private extension WPERenderTarget {
    var textureReference: WPETextureReference? {
        switch self {
        case .layerComposite(let name), .fbo(let name):
            return .fbo(name)
        case .scene:
            return nil
        }
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
