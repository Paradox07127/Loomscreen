import Foundation
import Testing
@testable import LiveWallpaper

struct WPEScenePreflightTests {

    @Test("Image-only scene with built-in shaders classifies as native playable")
    func imageOnlyScenePlaysNatively() {
        let project = Self.makeProject(requiresWindowsPlugin: false)
        let document = Self.makeDocument(
            imageObjects: [Self.makeImageObject()],
            diagnostics: []
        )

        let result = WPEScenePreflight.classify(
            document: document,
            project: project,
            scenePackageEntries: ["scene.json", "materials/sky.json"]
        )

        #expect(result.tier == .nativePlayable)
        #expect(result.featureFlags.isEmpty)
    }

    @Test("Custom shader source bumps tier to shader-translation-required")
    func customShaderRequiresTranslator() {
        let project = Self.makeProject()
        let document = Self.makeDocument(imageObjects: [Self.makeImageObject()])

        let result = WPEScenePreflight.classify(
            document: document,
            project: project,
            scenePackageEntries: ["scene.json", "shaders/genericimage4.frag", "shaders/genericimage4.vert"]
        )

        #expect(result.tier == .shaderTranslationRequired)
        #expect(result.featureFlags.contains(.customShaderSource))
    }

    @Test("Particle objects route to runtime-systems-required")
    func particleNeedsRuntimeSystems() {
        let project = Self.makeProject()
        let document = Self.makeDocument(
            imageObjects: [Self.makeImageObject()],
            diagnostics: [WPESceneDiagnostic(severity: .info, message: "Particle object Stars is unsupported in Phase 2.0")]
        )

        let result = WPEScenePreflight.classify(
            document: document,
            project: project,
            scenePackageEntries: []
        )

        #expect(result.tier == .runtimeSystemsRequired)
        #expect(result.featureFlags.contains(.particleObject))
    }

    @Test("Animation layer in image object lifts tier")
    func animationLayerLiftsTier() {
        let project = Self.makeProject()
        let layer = WPESceneAnimationLayer(id: 1, rate: 24, visible: true, blend: 1, animation: 0)
        let image = Self.makeImageObject(animationLayers: [layer])
        let document = Self.makeDocument(imageObjects: [image])

        let result = WPEScenePreflight.classify(
            document: document,
            project: project,
            scenePackageEntries: []
        )

        #expect(result.tier == .runtimeSystemsRequired)
        #expect(result.featureFlags.contains(.animationLayer))
    }

    @Test("Windows plugin always unsupported")
    func windowsPluginUnsupported() {
        let project = Self.makeProject(requiresWindowsPlugin: true)
        let document = Self.makeDocument(imageObjects: [Self.makeImageObject()])

        let result = WPEScenePreflight.classify(
            document: document,
            project: project,
            scenePackageEntries: ["bin/plugin.dll", "scene.json"]
        )

        #expect(result.tier == .unsupported)
        #expect(result.featureFlags.contains(.windowsPlugin))
    }

    @Test("Effect-only scene degrades")
    func effectOnlyDegrades() {
        let project = Self.makeProject()
        let effect = WPESceneImageEffect(
            id: "0",
            name: "vignette",
            fileRelativePath: "effects/vignette/effect.json",
            visible: true,
            passOverrides: []
        )
        let image = Self.makeImageObject(effects: [effect])
        let document = Self.makeDocument(imageObjects: [image])

        let result = WPEScenePreflight.classify(
            document: document,
            project: project,
            scenePackageEntries: ["scene.json"]
        )

        #expect(result.tier == .degradedPlayable)
        #expect(result.featureFlags.contains(.imageEffect))
    }

    // MARK: - Fixtures

    private static func makeProject(requiresWindowsPlugin: Bool = false) -> WallpaperEngineProject {
        WallpaperEngineProject(
            workshopID: "100000001",
            title: "Test Scene",
            entryFile: "scene.json",
            type: .scene,
            previewFileName: nil,
            propertyCount: 0,
            dependencyWorkshopIDs: [],
            requiresWindowsPlugin: requiresWindowsPlugin
        )
    }

    private static func makeDocument(
        imageObjects: [WPESceneImageObject] = [],
        diagnostics: [WPESceneDiagnostic] = []
    ) -> WPESceneDocument {
        WPESceneDocument(
            camera: .defaultCamera,
            general: .defaultGeneral,
            imageObjects: imageObjects,
            diagnostics: diagnostics
        )
    }

    private static func makeImageObject(
        effects: [WPESceneImageEffect] = [],
        animationLayers: [WPESceneAnimationLayer] = []
    ) -> WPESceneImageObject {
        WPESceneImageObject(
            id: "1",
            name: "bg",
            imageRelativePath: "materials/bg.json",
            materialRelativePath: nil,
            origin: SIMD3<Double>(0, 0, 0),
            scale: SIMD3<Double>(1, 1, 1),
            angles: SIMD3<Double>(0, 0, 0),
            visible: true,
            alpha: 1,
            color: SIMD3<Double>(1, 1, 1),
            brightness: 1,
            blendMode: .normal,
            alignment: .center,
            size: nil,
            effects: effects,
            animationLayers: animationLayers,
            parallaxDepth: 0
        )
    }
}
