import AppKit
import CoreGraphics
import Foundation
import SpriteKit

/// Phase 2.0 image-only SpriteKit runtime for Wallpaper Engine `.scene`
/// content. Owns an `SKView` + `SKScene` pair on the main actor — the SK
/// stack is itself main-actor-bound so we lean on the type system to keep
/// callers on the right queue.
///
/// Loading is async because we read `scene.json` from disk and decode the
/// PNG/JPG layers off-main via Task work items. Once `load()` returns the
/// scene is mounted; the caller can then ask for `view` to insert into a
/// wallpaper window.
@MainActor
final class SceneRenderingController: WPESceneRenderer {
    /// Default frame rate target when not throttled. `SKView` clamps this to
    /// the display's refresh rate so 60 means "render every vsync".
    static let defaultPreferredFPS = 60
    static let throttledPreferredFPS = 1

    private let descriptor: SceneDescriptor
    private let cacheRootURL: URL
    private let resolver: SceneResourceResolver
    private let imageResolver: WPEMultiRootResourceResolver
    private let initialFrame: CGRect

    private let skView: SKView
    private var scene: SKScene?
    private var didLoad = false
    private var isThrottled = false
    private var currentProfile: WallpaperPerformanceProfile = .quality
    /// First per-layer failure we observed during `load()`. Surfaced to the
    /// detail view's diagnostic panel so power users can see *why* a layer
    /// was skipped without diving into Console logs.
    private(set) var loadDiagnostics: SceneLoadDiagnostic?
    /// Renderer-neutral WPE pass graph built from scene/material/effect JSON.
    /// SpriteKit currently remains the visible fallback, but this graph is
    /// the single input model for the Metal WPE executor.
    private(set) var renderGraph: WPERenderGraph?
    /// Shader-source prepared form of `renderGraph`. This is the immediate
    /// input for the Metal WPE executor once the backend is enabled.
    private(set) var renderPipeline: WPEPreparedRenderPipeline?
    /// Per-layer progress callback driven by `load()`. The controller
    /// invokes this on the main actor with strings like "3/12" so the
    /// inspector card can surface them in `LiquidGlassSpinner`.
    var onProgress: (@MainActor (String) -> Void)?

    init(
        descriptor: SceneDescriptor,
        cacheRootURL: URL,
        dependencyMounts: [WPEAssetMount] = [],
        frame: CGRect
    ) {
        self.descriptor = descriptor
        self.cacheRootURL = cacheRootURL
        self.resolver = SceneResourceResolver(cacheRootURL: cacheRootURL)
        self.imageResolver = WPEMultiRootResourceResolver(
            primaryRootURL: cacheRootURL,
            dependencyMounts: dependencyMounts
        )
        self.initialFrame = frame
        let view = SKView(frame: frame)
        view.allowsTransparency = true
        view.ignoresSiblingOrder = true
        view.autoresizingMask = [.width, .height]
        view.preferredFramesPerSecond = Self.defaultPreferredFPS
        // Diagnostic overlays are off by default so they never bleed into
        // the wallpaper output for end users; the build flag still allows
        // turning them on for triage.
        view.showsFPS = false
        view.showsNodeCount = false
        view.showsDrawCount = false
        self.skView = view
    }

    var view: SKView { skView }
    var nsView: NSView { skView }
    var hasPresentedFrame: Bool { skView.scene != nil }

    /// SpriteKit snapshot via AppKit's offscreen bitmap cache. Returns `nil`
    /// when the SKView has zero bounds (early load) so consumers can choose a
    /// loading placeholder instead of an opaque blank image.
    var previewSnapshot: NSImage? {
        guard skView.bounds.width > 0, skView.bounds.height > 0 else {
            return nil
        }
        guard let representation = skView.bitmapImageRepForCachingDisplay(in: skView.bounds) else {
            return nil
        }
        skView.cacheDisplay(in: skView.bounds, to: representation)
        let image = NSImage(size: skView.bounds.size)
        image.addRepresentation(representation)
        return image
    }

    /// Materialises the SpriteKit scene from disk. Idempotent — calling it
    /// twice is a no-op on the second pass so the wallpaper session can
    /// safely re-prepare on focus changes.
    func load() async throws {
        guard !didLoad else { return }

        // Defense-in-depth: route `entryFile` through the same path-safety
        // gate as image layers so a tampered descriptor with `..` segments
        // cannot read files outside the cache root.
        let entryURL: URL
        do {
            entryURL = try resolver.resolveExistingFileURL(relativePath: descriptor.entryFile)
        } catch {
            throw SceneRenderingError.entryFileMissing(descriptor.entryFile)
        }

        let document: WPESceneDocument
        do {
            // I/O off-main: parse on a background task so a 100 KiB
            // scene.json doesn't stall the run loop on a slow disk.
            let parsedDocument = try await Task.detached(priority: .userInitiated) {
                let data = try Data(contentsOf: entryURL)
                return try WPESceneDocumentParser.parse(data: data)
            }.value
            document = parsedDocument
        } catch let error as WPESceneDocumentError {
            throw SceneRenderingError.parseFailed(error.errorDescription ?? "scene.json parse failed")
        } catch {
            throw SceneRenderingError.parseFailed(error.localizedDescription)
        }

        let projection = document.general.orthogonalProjection
        let canvasSize = CGSize(
            width: max(projection.width, 1),
            height: max(projection.height, 1)
        )

        do {
            let graph = try await Task.detached(priority: .userInitiated) { [cacheRootURL] in
                try WPERenderGraphBuilder(cacheRootURL: cacheRootURL).build(document: document)
            }.value
            renderGraph = graph
            let passCount = graph.layers.reduce(0) { $0 + $1.passes.count }
            Logger.info(
                "Scene \(descriptor.workshopID): built WPE render graph with \(graph.layers.count) layers / \(passCount) passes",
                category: .screenManager
            )
            do {
                let pipeline = try await Task.detached(priority: .userInitiated) { [cacheRootURL] in
                    try WPERenderPipelineBuilder(cacheRootURL: cacheRootURL).build(graph: graph)
                }.value
                renderPipeline = pipeline
                let preparedPassCount = pipeline.layers.reduce(0) { $0 + $1.passes.count }
                Logger.info(
                    "Scene \(descriptor.workshopID): prepared WPE shader pipeline with \(preparedPassCount) passes",
                    category: .screenManager
                )
            } catch {
                renderPipeline = nil
                Logger.warning(
                    "Scene \(descriptor.workshopID): WPE shader pipeline unavailable — \(error.localizedDescription)",
                    category: .screenManager
                )
            }
        } catch {
            renderGraph = nil
            renderPipeline = nil
            Logger.warning(
                "Scene \(descriptor.workshopID): WPE render graph unavailable — \(error.localizedDescription)",
                category: .screenManager
            )
        }

        let scene = SKScene(size: canvasSize)
        scene.scaleMode = .aspectFill
        scene.backgroundColor = NSColor(
            red: CGFloat(document.general.clearColor.x),
            green: CGFloat(document.general.clearColor.y),
            blue: CGFloat(document.general.clearColor.z),
            alpha: 1
        )

        var renderableLayers = 0
        var firstFailure: SceneLoadDiagnostic?
        let visibleLayers = document.imageObjects.filter { $0.visible && $0.alpha > 0.001 }
        let totalLayers = visibleLayers.count
        var processed = 0

        for object in visibleLayers {
            processed += 1
            onProgress?(
                String(
                    localized: "Decoding \(processed)/\(totalLayers) textures…",
                    comment: "Scene loading progress. Placeholders are decoded layer count and total layer count."
                )
            )
            do {
                let cgImage = try imageResolver.resolveImage(relativePath: object.imageRelativePath)
                let texture = SKTexture(cgImage: cgImage)
                texture.filteringMode = .linear
                let node = makeSpriteNode(texture: texture, object: object, canvas: canvasSize)
                scene.addChild(node)
                renderableLayers += 1
            } catch SceneResourceResolver.ResolveError.texture(let texError) {
                Logger.warning("Scene \(descriptor.workshopID): tex decode failed for \(object.name) — \(texError.errorDescription ?? "?")", category: .screenManager)
                firstFailure = firstFailure ?? .texture(layer: object.name, error: texError)
            } catch SceneResourceResolver.ResolveError.materialUnresolved(let reason) {
                Logger.warning("Scene \(descriptor.workshopID): material chain unresolved for \(object.name) — \(reason)", category: .screenManager)
                firstFailure = firstFailure ?? .materialUnresolved(layer: object.name, reason: reason)
            } catch SceneResourceResolver.ResolveError.unsupportedTexture {
                Logger.warning("Scene \(descriptor.workshopID): skipping .tex layer \(object.name)", category: .screenManager)
                firstFailure = firstFailure ?? .legacyUnsupportedTexture(layer: object.name)
            } catch SceneResourceResolver.ResolveError.fileMissing {
                Logger.warning("Scene \(descriptor.workshopID): missing asset for layer \(object.name)", category: .screenManager)
                firstFailure = firstFailure ?? .fileMissing(layer: object.name, path: object.imageRelativePath)
            } catch SceneResourceResolver.ResolveError.pathEscape {
                // Cross-package reference (e.g. `../<workshopid>/materials/foo.png`).
                // Missing or undeclared mounts stay rejected, while declared
                // dependency roots are resolved by `imageResolver` above.
                Logger.warning("Scene \(descriptor.workshopID): cross-package reference rejected for \(object.name) — \(object.imageRelativePath)", category: .screenManager)
                firstFailure = firstFailure ?? .crossPackageReference(layer: object.name, path: object.imageRelativePath)
            } catch {
                Logger.warning("Scene \(descriptor.workshopID): failed to load \(object.name): \(error.localizedDescription)", category: .screenManager)
                firstFailure = firstFailure ?? .other(layer: object.name, message: error.localizedDescription)
            }
        }

        loadDiagnostics = firstFailure

        guard renderableLayers > 0 else {
            // Surface the most specific failure we saw so the UI can map
            // it to a precise FallbackReason instead of a generic message.
            if let firstFailure {
                throw SceneRenderingError.resourceFailed(firstFailure)
            }
            throw SceneRenderingError.noRenderableObjects
        }

        skView.presentScene(scene)
        scene.isPaused = currentProfile == .suspended
        self.scene = scene
        didLoad = true
    }

    /// Drops the SKView's frame rate target to 1 fps when throttled. Keeps
    /// every node alive so we can flip back to full speed without re-loading.
    func setThrottled(_ throttled: Bool) {
        guard isThrottled != throttled else { return }
        isThrottled = throttled
        // Suspended takes priority: a throttle while suspended must keep the
        // scene paused. Re-applying the profile flushes both flags together.
        applyEffectiveState()
    }

    /// Power policy hook. `.suspended` halts ticks (`SKScene.isPaused`),
    /// `.degradedAnimation` and `.quality` map to the active fps target.
    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        currentProfile = profile
        applyEffectiveState()
    }

    func cleanup() {
        scene?.removeAllChildren()
        scene?.removeAllActions()
        skView.presentScene(nil)
        scene = nil
        didLoad = false
        loadDiagnostics = nil
        renderGraph = nil
        renderPipeline = nil
    }

    /// Tears the current SKScene down and re-runs `load()`. Used by the
    /// inspector's Retry button — keeps the SKView itself alive (and on
    /// the wallpaper window) so the user doesn't see a black flicker
    /// while the new scene materialises.
    func reload() async throws {
        if didLoad {
            scene?.removeAllChildren()
            scene?.removeAllActions()
            skView.presentScene(nil)
            scene = nil
            didLoad = false
            loadDiagnostics = nil
            renderGraph = nil
            renderPipeline = nil
        }
        try await load()
    }

    // MARK: - Private

    private func applyEffectiveState() {
        let suspended = currentProfile == .suspended
        scene?.isPaused = suspended
        if suspended {
            // SKView.isPaused doesn't exist as such; pausing the scene tree
            // already stops ticking. Drop the framerate further so vsync
            // wakeups stop too.
            skView.preferredFramesPerSecond = Self.throttledPreferredFPS
            return
        }
        skView.preferredFramesPerSecond = isThrottled
            ? Self.throttledPreferredFPS
            : Self.defaultPreferredFPS
    }

    private func makeSpriteNode(
        texture: SKTexture,
        object: WPESceneImageObject,
        canvas: CGSize
    ) -> SKSpriteNode {
        let textureSize = texture.size()
        let baseSize: CGSize
        if let explicit = object.size, explicit.width > 0, explicit.height > 0 {
            baseSize = explicit
        } else {
            baseSize = textureSize
        }

        let node = SKSpriteNode(texture: texture)
        node.name = object.name
        node.size = CGSize(
            width: baseSize.width * CGFloat(object.scale.x),
            height: baseSize.height * CGFloat(object.scale.y)
        )
        node.alpha = CGFloat(object.alpha)
        node.color = NSColor(
            red: CGFloat(object.color.x),
            green: CGFloat(object.color.y),
            blue: CGFloat(object.color.z),
            alpha: 1
        )
        node.colorBlendFactor = colorBlendFactor(for: object.color, brightness: object.brightness)
        node.blendMode = blendMode(for: object.blendMode)

        let transform = WPESceneTransformMapper.spriteTransform(
            origin: object.origin,
            angles: object.angles,
            alignment: object.alignment,
            canvas: canvas
        )
        node.zRotation = transform.zRotation
        node.position = transform.position

        return node
    }

    private func colorBlendFactor(for color: SIMD3<Double>, brightness: Double) -> CGFloat {
        let neutralColor = (color.x == 1 && color.y == 1 && color.z == 1)
        let neutralBrightness = brightness == 1
        return (neutralColor && neutralBrightness) ? 0 : 1
    }

    private func blendMode(for mode: WPESceneBlendMode) -> SKBlendMode {
        switch mode {
        case .normal:       return .alpha
        case .translucent:  return .alpha
        case .additive:     return .add
        case .multiply:     return .multiply
        case .screen:       return .screen
        }
    }

}
