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

    func addingMetalRuntimeUniforms(
        _ runtimeUniforms: WPEMetalRuntimeUniforms,
        camera: WPEMetalCameraUniforms
    ) -> WPEPreparedRenderPipeline {
        WPEPreparedRenderPipeline(
            layers: layers.map { layer in
                let resolvedGraphLayer = layer.graphLayer.resolved(at: runtimeUniforms.time)
                return WPEPreparedRenderLayer(
                    graphLayer: resolvedGraphLayer,
                    puppetModel: layer.puppetModel,
                    passes: layer.passes.map { pass in
                        var values = pass.uniformValues.mapValues {
                            $0.resolved(at: runtimeUniforms.time)
                        }
                        for (key, value) in runtimeUniforms.uniformValues {
                            values[key] = value
                        }
                        for (key, value) in camera.uniformValues {
                            values[key] = value
                        }
                        // Per-object 2.8 transform uniforms (g_ModelMatrix /
                        // g_NormalModelMatrix): object-scoped, so merged from the
                        // resolved layer geometry here. Identity geometry → identity
                        // matrices, and undeclared uniforms are dropped at packing,
                        // so 2D scenes are unaffected.
                        let geometry = resolvedGraphLayer.geometry
                        for (key, value) in WPEMetalObjectUniforms.uniformValues(
                            origin: geometry.origin,
                            scale: geometry.scale,
                            angles: geometry.angles
                        ) {
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

private extension WPERenderLayer {
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
            brightness: g.brightness
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
            geometry: overridden,
            localGeometry: localGeometry,
            compositeA: compositeA,
            compositeB: compositeB,
            localFBOs: localFBOs,
            passes: passes,
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
            parallaxDepth: parallaxDepth,
            sortIndex: sortIndex
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
