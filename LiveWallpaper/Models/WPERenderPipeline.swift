#if !LITE_BUILD
import Foundation

/// Sits between the JSON render graph and the Metal executor: graph passes are
/// preserved exactly, while shader-backed passes carry expanded GLSL sources
/// with combo defines and includes resolved.
struct WPEPreparedRenderPipeline: Equatable, Sendable {
    let layers: [WPEPreparedRenderLayer]
}

struct WPEPreparedRenderLayer: Equatable, Sendable, Identifiable {
    var id: String { graphLayer.id }

    let graphLayer: WPERenderLayer
    let puppetModel: WPEPuppetModel?
    let passes: [WPEPreparedRenderPass]

    init(
        graphLayer: WPERenderLayer,
        puppetModel: WPEPuppetModel? = nil,
        passes: [WPEPreparedRenderPass]
    ) {
        self.graphLayer = graphLayer
        self.puppetModel = puppetModel
        self.passes = passes
    }
}

struct WPEPreparedRenderPass: Equatable, Sendable, Identifiable {
    var id: String { pass.id }

    let pass: WPERenderPass
    let shader: WPEShaderProgram?
    let textureBindings: [Int: WPETextureReference]
    let comboValues: [String: Int]
    let uniformValues: [String: WPESceneShaderConstantValue]
}

struct WPERenderObjectTransform: Equatable, Sendable {
    let origin: SIMD3<Double>
    let scale: SIMD3<Double>
    let angles: SIMD3<Double>

    init(origin: SIMD3<Double>, scale: SIMD3<Double>, angles: SIMD3<Double>) {
        self.origin = origin
        self.scale = scale
        self.angles = angles
    }

    init(_ geometry: WPERenderLayerGeometry) {
        self.init(origin: geometry.origin, scale: geometry.scale, angles: geometry.angles)
    }

    func applying(
        origin: SIMD3<Double>?,
        scale: SIMD3<Double>?,
        angles: SIMD3<Double>?
    ) -> WPERenderObjectTransform {
        WPERenderObjectTransform(
            origin: origin ?? self.origin,
            scale: scale ?? self.scale,
            angles: angles ?? self.angles
        )
    }

    func combining(child: WPERenderObjectTransform) -> WPERenderObjectTransform {
        let scaled = SIMD3<Double>(
            child.origin.x * scale.x,
            child.origin.y * scale.y,
            child.origin.z * scale.z
        )
        let rotated = Self.rotate(scaled, by: angles)

        return WPERenderObjectTransform(
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

struct WPEShaderProgram: Equatable, Sendable {
    let name: String
    let vertexSource: String
    let fragmentSource: String
    let isBuiltin: Bool
}

extension WPEPreparedRenderPipeline {
    /// Applies a live scene-visibility toggle without rebuilding the pipeline;
    /// the executor reads `graphLayer.visible` to gate the scene draw.
    func applyingLayerVisibility(_ visibility: [String: Bool]) -> WPEPreparedRenderPipeline {
        guard !visibility.isEmpty else { return self }
        return WPEPreparedRenderPipeline(
            layers: layers.map { layer in
                let resolved = visibility[layer.graphLayer.objectID] ?? layer.graphLayer.visible
                guard resolved != layer.graphLayer.visible else { return layer }
                return WPEPreparedRenderLayer(
                    graphLayer: layer.graphLayer.applyingVisible(resolved),
                    puppetModel: layer.puppetModel,
                    passes: layer.passes
                )
            }
        )
    }

    /// Overrides each layer's alpha by `alpha[objectID]`, clearing any authored
    /// alpha animation so the override isn't re-collapsed per frame. Drives
    /// script-controlled layer fades (e.g. a video intro fading out).
    func applyingLayerAlpha(_ alpha: [String: Double]) -> WPEPreparedRenderPipeline {
        guard !alpha.isEmpty else { return self }
        return WPEPreparedRenderPipeline(
            layers: layers.map { layer in
                guard let value = alpha[layer.graphLayer.objectID] else { return layer }
                let geometry = layer.graphLayer.geometry
                guard geometry.alpha != value || geometry.alphaAnimation != nil else { return layer }
                return WPEPreparedRenderLayer(
                    graphLayer: layer.graphLayer.applyingAlpha(value),
                    puppetModel: layer.puppetModel,
                    passes: layer.passes
                )
            }
        )
    }

    /// Applies per-frame transform-script overrides before object-scoped uniforms
    /// are derived. The maps are keyed by WPE object id and can be sparse.
    func applyingLayerTransforms(
        origins: [String: SIMD3<Double>],
        scales: [String: SIMD3<Double>],
        angles: [String: SIMD3<Double>],
        parentByID: [String: String] = [:],
        hostTransforms: [String: WPERenderObjectTransform] = [:]
    ) -> WPEPreparedRenderPipeline {
        guard !origins.isEmpty || !scales.isEmpty || !angles.isEmpty else { return self }
        guard !parentByID.isEmpty || !hostTransforms.isEmpty else {
            return WPEPreparedRenderPipeline(
                layers: layers.map { layer in
                    let objectID = layer.graphLayer.objectID
                    let origin = origins[objectID]
                    let scale = scales[objectID]
                    let angle = angles[objectID]
                    guard origin != nil || scale != nil || angle != nil else { return layer }
                    return WPEPreparedRenderLayer(
                        graphLayer: layer.graphLayer.applyingTransform(
                            origin: origin,
                            scale: scale,
                            angles: angle
                        ),
                        puppetModel: layer.puppetModel,
                        passes: layer.passes
                    )
                }
            )
        }

        let layerLocalTransforms = Dictionary(
            layers.compactMap { layer -> (String, WPERenderObjectTransform)? in
                guard let localGeometry = layer.graphLayer.localGeometry else { return nil }
                return (layer.graphLayer.objectID, WPERenderObjectTransform(localGeometry))
            },
            uniquingKeysWith: { first, _ in first }
        )
        var memo: [String: WPERenderObjectTransform] = [:]

        func localTransform(for id: String) -> WPERenderObjectTransform? {
            let base = layerLocalTransforms[id] ?? hostTransforms[id]
            return base?.applying(
                origin: origins[id],
                scale: scales[id],
                angles: angles[id]
            )
        }

        func resolvedTransform(for id: String, stack: Set<String>) -> WPERenderObjectTransform? {
            if let cached = memo[id] { return cached }
            guard let local = localTransform(for: id) else { return nil }
            guard let parentID = parentByID[id],
                  parentID != id,
                  !stack.contains(parentID),
                  stack.count < 100,
                  let parent = resolvedTransform(for: parentID, stack: stack.union([id])) else {
                memo[id] = local
                return local
            }
            let resolved = parent.combining(child: local)
            memo[id] = resolved
            return resolved
        }

        return WPEPreparedRenderPipeline(
            layers: layers.map { layer in
                let objectID = layer.graphLayer.objectID
                guard let resolved = resolvedTransform(for: objectID, stack: []) else { return layer }
                let current = layer.graphLayer.geometry
                guard current.origin != resolved.origin
                    || current.scale != resolved.scale
                    || current.angles != resolved.angles else {
                    return layer
                }
                return WPEPreparedRenderLayer(
                    graphLayer: layer.graphLayer.applyingTransform(
                        origin: resolved.origin,
                        scale: resolved.scale,
                        angles: resolved.angles
                    ),
                    puppetModel: layer.puppetModel,
                    passes: layer.passes
                )
            }
        )
    }

    /// Adds simple image layers created at runtime via `thisScene.createLayer`.
    /// This intentionally supports only single-pass, non-puppet templates: the
    /// trail dots in 3509243656 use that shape, while multi-pass/effect templates
    /// would need per-instance FBO renaming to avoid collisions.
    func addingCreatedLayers(
        _ createdLayers: [String: WPECreatedLayerScriptState],
        templatesByImagePath: [String: WPEPreparedRenderLayer]
    ) -> WPEPreparedRenderPipeline {
        guard !createdLayers.isEmpty, !templatesByImagePath.isEmpty else { return self }

        let dynamicLayers = createdLayers.values
            .sorted { $0.key < $1.key }
            .compactMap { state -> WPEPreparedRenderLayer? in
                guard state.visible,
                      state.alpha > 0.001,
                      let template = templatesByImagePath[state.imagePath],
                      template.puppetModel == nil,
                      template.passes.count == 1 else {
                    return nil
                }
                return template.createdLayerCopy(state: state)
            }
        guard !dynamicLayers.isEmpty else { return self }

        var result = layers
        for layer in dynamicLayers {
            let insertionIndex = result.lastIndex {
                $0.graphLayer.sortIndex <= layer.graphLayer.sortIndex
            }.map { result.index(after: $0) } ?? result.startIndex
            result.insert(layer, at: insertionIndex)
        }
        return WPEPreparedRenderPipeline(layers: result)
    }

    func addingMetalRuntimeUniforms(
        _ runtimeUniforms: WPEMetalRuntimeUniforms,
        camera: WPEMetalCameraUniforms
    ) -> WPEPreparedRenderPipeline {
        // Both are COMPUTED properties — each access rebuilds the dict (the runtime
        // one also slices audio spectra). Resolve once per frame, not per pass.
        let runtimeUniformValues = runtimeUniforms.uniformValues
        let cameraUniformValues = camera.uniformValues
        let frameExtraCount = runtimeUniformValues.count + cameraUniformValues.count
        return WPEPreparedRenderPipeline(
            layers: layers.map { layer in
                let resolvedGraphLayer = layer.graphLayer.resolved(at: runtimeUniforms.time)
                // Per-object 2.8 transform uniforms (g_ModelMatrix /
                // g_NormalModelMatrix): object-scoped (depend only on layer geometry),
                // so derive the matrices ONCE per layer rather than per pass. Identity
                // geometry → identity matrices, and undeclared uniforms are dropped at
                // packing, so 2D scenes are unaffected.
                let geometry = resolvedGraphLayer.geometry
                let objectUniforms = WPEMetalObjectUniforms.uniformValues(
                    origin: geometry.origin,
                    scale: geometry.scale,
                    angles: geometry.angles
                )
                // Frame/object-global entries merged into every pass; reserve once so
                // the per-pass inserts don't trigger incremental dictionary resizes.
                let mergedExtraCount = frameExtraCount + objectUniforms.count
                return WPEPreparedRenderLayer(
                    graphLayer: resolvedGraphLayer,
                    puppetModel: layer.puppetModel,
                    passes: layer.passes.map { pass in
                        var values = pass.uniformValues.mapValues {
                            $0.resolved(at: runtimeUniforms.time)
                        }
                        values.reserveCapacity(values.count + mergedExtraCount)
                        for (key, value) in runtimeUniformValues {
                            values[key] = value
                        }
                        for (key, value) in cameraUniformValues {
                            values[key] = value
                        }
                        for (key, value) in objectUniforms {
                            values[key] = value
                        }
                        return WPEPreparedRenderPass(
                            pass: pass.pass,
                            shader: pass.shader,
                            textureBindings: pass.textureBindings,
                            comboValues: pass.comboValues,
                            uniformValues: values
                        )
                    }
                )
            }
        )
    }
}

private extension WPEPreparedRenderLayer {
    func createdLayerCopy(state: WPECreatedLayerScriptState) -> WPEPreparedRenderLayer? {
        guard let preparedPass = passes.first else { return nil }
        let p = preparedPass.pass
        let renderPass = WPERenderPass(
            id: "\(state.key).0",
            phase: p.phase,
            shader: p.shader,
            source: p.source,
            target: .scene,
            textures: p.textures,
            binds: p.binds,
            constants: p.constants,
            combos: p.combos,
            blending: p.blending,
            cullMode: p.cullMode,
            depthTest: p.depthTest,
            depthWrite: p.depthWrite
        )
        let dynamicPass = WPEPreparedRenderPass(
            pass: renderPass,
            shader: preparedPass.shader,
            textureBindings: preparedPass.textureBindings,
            comboValues: preparedPass.comboValues,
            uniformValues: preparedPass.uniformValues
        )
        return WPEPreparedRenderLayer(
            graphLayer: graphLayer.createdLayerCopy(state: state, pass: renderPass),
            puppetModel: nil,
            passes: [dynamicPass]
        )
    }
}

private extension WPERenderLayer {
    func createdLayerCopy(
        state: WPECreatedLayerScriptState,
        pass: WPERenderPass
    ) -> WPERenderLayer {
        let g = geometry
        let dynamicGeometry = WPERenderLayerGeometry(
            origin: state.origin,
            scale: state.scale,
            angles: g.angles,
            alignment: g.alignment,
            size: g.size,
            puppetMeshCenter: g.puppetMeshCenter,
            alpha: state.alpha,
            alphaAnimation: nil,
            color: state.color,
            brightness: g.brightness
        )
        return WPERenderLayer(
            objectID: state.key,
            objectName: state.key,
            visible: state.visible,
            imagePath: imagePath,
            materialPath: materialPath,
            puppetPath: nil,
            parentObjectID: nil,
            attachment: nil,
            animationLayers: [],
            geometry: dynamicGeometry,
            localGeometry: dynamicGeometry,
            compositeA: "_rt_createdLayerComposite_\(state.key)_a",
            compositeB: "_rt_createdLayerComposite_\(state.key)_b",
            localFBOs: [],
            passes: [pass],
            groupRenderTarget: nil,
            groupLocalGeometry: nil,
            groupCompositeSource: nil,
            parallaxDepth: parallaxDepth,
            sortIndex: sortIndex
        )
    }

    func applyingTransform(
        origin: SIMD3<Double>?,
        scale: SIMD3<Double>?,
        angles: SIMD3<Double>?
    ) -> WPERenderLayer {
        let adjustedGeometry = geometry.applyingTransform(
            origin: origin,
            scale: scale,
            angles: angles
        )
        return WPERenderLayer(
            objectID: objectID,
            objectName: objectName,
            visible: visible,
            imagePath: imagePath,
            materialPath: materialPath,
            puppetPath: puppetPath,
            parentObjectID: parentObjectID,
            attachment: attachment,
            animationLayers: animationLayers,
            geometry: adjustedGeometry,
            localGeometry: localGeometry,
            compositeA: compositeA,
            compositeB: compositeB,
            localFBOs: localFBOs,
            passes: passes,
            groupRenderTarget: groupRenderTarget,
            groupLocalGeometry: groupLocalGeometry,
            groupCompositeSource: groupCompositeSource,
            parallaxDepth: parallaxDepth,
            sortIndex: sortIndex
        )
    }

    func applyingVisible(_ visible: Bool) -> WPERenderLayer {
        WPERenderLayer(
            objectID: objectID,
            objectName: objectName,
            visible: visible,
            imagePath: imagePath,
            materialPath: materialPath,
            puppetPath: puppetPath,
            parentObjectID: parentObjectID,
            attachment: attachment,
            animationLayers: animationLayers,
            geometry: geometry,
            localGeometry: localGeometry,
            compositeA: compositeA,
            compositeB: compositeB,
            localFBOs: localFBOs,
            passes: passes,
            groupRenderTarget: groupRenderTarget,
            groupLocalGeometry: groupLocalGeometry,
            groupCompositeSource: groupCompositeSource,
            parallaxDepth: parallaxDepth,
            sortIndex: sortIndex
        )
    }

    /// Overrides the layer's alpha (clearing the authored alpha animation so a
    /// later `resolved(at:)` keeps the script-driven value).
    func applyingAlpha(_ alpha: Double) -> WPERenderLayer {
        let g = geometry
        let overridden = WPERenderLayerGeometry(
            origin: g.origin,
            scale: g.scale,
            angles: g.angles,
            alignment: g.alignment,
            size: g.size,
            puppetMeshCenter: g.puppetMeshCenter,
            alpha: alpha,
            alphaAnimation: nil,
            color: g.color,
            brightness: g.brightness,
            shapePoints: g.shapePoints
        )
        // The executor draws a composelayer-group child's group-buffer pass from
        // groupLocalGeometry (alpha copied verbatim at bake time), so a live fade
        // must land there too or the child renders at its authored alpha inside
        // the group. Clear the animation for the same reason `overridden` does.
        let overriddenGroupLocal = groupLocalGeometry.map { gl in
            WPERenderLayerGeometry(
                origin: gl.origin,
                scale: gl.scale,
                angles: gl.angles,
                alignment: gl.alignment,
                size: gl.size,
                puppetMeshCenter: gl.puppetMeshCenter,
                alpha: alpha,
                alphaAnimation: nil,
                color: gl.color,
                brightness: gl.brightness,
                shapePoints: gl.shapePoints
            )
        }
        return WPERenderLayer(
            objectID: objectID,
            objectName: objectName,
            visible: visible,
            imagePath: imagePath,
            materialPath: materialPath,
            puppetPath: puppetPath,
            parentObjectID: parentObjectID,
            attachment: attachment,
            animationLayers: animationLayers,
            geometry: overridden,
            localGeometry: localGeometry,
            compositeA: compositeA,
            compositeB: compositeB,
            localFBOs: localFBOs,
            passes: passes,
            groupRenderTarget: groupRenderTarget,
            groupLocalGeometry: overriddenGroupLocal,
            groupCompositeSource: groupCompositeSource,
            parallaxDepth: parallaxDepth,
            sortIndex: sortIndex
        )
    }

    func resolved(at time: Double) -> WPERenderLayer {
        WPERenderLayer(
            objectID: objectID,
            objectName: objectName,
            visible: visible,
            imagePath: imagePath,
            materialPath: materialPath,
            puppetPath: puppetPath,
            parentObjectID: parentObjectID,
            attachment: attachment,
            animationLayers: animationLayers,
            geometry: geometry.resolved(at: time),
            localGeometry: localGeometry?.resolved(at: time),
            compositeA: compositeA,
            compositeB: compositeB,
            localFBOs: localFBOs,
            passes: passes,
            groupRenderTarget: groupRenderTarget,
            groupLocalGeometry: groupLocalGeometry?.resolved(at: time),
            groupCompositeSource: groupCompositeSource,
            parallaxDepth: parallaxDepth,
            sortIndex: sortIndex
        )
    }
}

private extension WPERenderLayerGeometry {
    func applyingTransform(
        origin: SIMD3<Double>?,
        scale: SIMD3<Double>?,
        angles: SIMD3<Double>?
    ) -> WPERenderLayerGeometry {
        WPERenderLayerGeometry(
            origin: origin ?? self.origin,
            scale: scale ?? self.scale,
            angles: angles ?? self.angles,
            alignment: alignment,
            size: size,
            puppetMeshCenter: puppetMeshCenter,
            alpha: alpha,
            alphaAnimation: alphaAnimation,
            color: color,
            brightness: brightness,
            shapePoints: shapePoints
        )
    }
}

enum WPERenderPipelineError: Error, Equatable, LocalizedError, Sendable {
    case shaderMissing(name: String, stage: String, path: String)
    case includeMissing(path: String, requestedBy: String)
    case includeCycle(path: String)
    case invalidSourceEncoding(path: String)

    var errorDescription: String? {
        switch self {
        case .shaderMissing(let name, let stage, let path):
            return String(
                localized: "error.render.pipeline.shader_missing",
                defaultValue: "WPE shader \(name) is missing \(stage) source at \(path)",
                comment: "Error shown when a Wallpaper Engine shader source file is missing."
            )
        case .includeMissing(let path, let requestedBy):
            return String(
                localized: "error.render.pipeline.include_missing",
                defaultValue: "WPE shader include \(path) requested by \(requestedBy) is missing",
                comment: "Error shown when a Wallpaper Engine shader include file is missing."
            )
        case .includeCycle(let path):
            return String(
                localized: "error.render.pipeline.include_cycle",
                defaultValue: "WPE shader include cycle detected at \(path)",
                comment: "Error shown when a Wallpaper Engine shader include cycle is detected."
            )
        case .invalidSourceEncoding(let path):
            return String(
                localized: "error.render.pipeline.invalid_source_encoding",
                defaultValue: "WPE shader source is not UTF-8: \(path)",
                comment: "Error shown when a Wallpaper Engine shader source file is not UTF-8."
            )
        }
    }
}
#endif
