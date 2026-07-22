import Foundation
import LiveWallpaperProWPE
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

    @Test("Custom shader source now degrades (translator ships) instead of blocking")
    func customShaderDegradesAfterTranslator() {
        let project = Self.makeProject()
        let document = Self.makeDocument(imageObjects: [Self.makeImageObject()])

        let result = WPEScenePreflight.classify(
            document: document,
            project: project,
            scenePackageEntries: ["scene.json", "shaders/genericimage4.frag", "shaders/genericimage4.vert"]
        )

        #expect(result.tier == .degradedPlayable)
        #expect(result.featureFlags.contains(.customShaderSource))
    }

    @Test("Particle objects classify as native — runtime ships")
    func particlesPlayNatively() {
        let project = Self.makeProject()
        let document = Self.makeDocument(
            imageObjects: [Self.makeImageObject()],
            diagnostics: [WPESceneDiagnostic(severity: .info, message: "Particle object Stars parsed; rendered by the Metal particle simulator")]
        )

        let result = WPEScenePreflight.classify(
            document: document,
            project: project,
            scenePackageEntries: []
        )

        #expect(result.tier == .nativePlayable)
        #expect(result.featureFlags.contains(.particleObject))
    }

    @Test("Animation layers degrade — base image renders, mesh deformation deferred")
    func animationLayerDegrades() {
        let project = Self.makeProject()
        let layer = WPESceneAnimationLayer(id: 1, rate: 24, visible: true, blend: 1, animation: 0)
        let image = Self.makeImageObject(animationLayers: [layer])
        let document = Self.makeDocument(imageObjects: [image])

        let result = WPEScenePreflight.classify(
            document: document,
            project: project,
            scenePackageEntries: []
        )

        #expect(result.tier == .degradedPlayable)
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
            parallaxDepth: SIMD2<Double>(0, 0)
        )
    }
}
