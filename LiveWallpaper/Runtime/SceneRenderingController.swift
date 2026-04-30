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
final class SceneRenderingController {
    /// Default frame rate target when not throttled. `SKView` clamps this to
    /// the display's refresh rate so 60 means "render every vsync".
    static let defaultPreferredFPS = 60
    static let throttledPreferredFPS = 1

    private let descriptor: SceneDescriptor
    private let cacheRootURL: URL
    private let resolver: SceneResourceResolver
    private let initialFrame: CGRect

    private let skView: SKView
    private var scene: SKScene?
    private var didLoad = false
    private var isThrottled = false
    private var currentProfile: WallpaperPerformanceProfile = .quality

    init(descriptor: SceneDescriptor, cacheRootURL: URL, frame: CGRect) {
        self.descriptor = descriptor
        self.cacheRootURL = cacheRootURL
        self.resolver = SceneResourceResolver(cacheRootURL: cacheRootURL)
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

        let scene = SKScene(size: canvasSize)
        scene.scaleMode = .aspectFill
        scene.backgroundColor = NSColor(
            red: CGFloat(document.general.clearColor.x),
            green: CGFloat(document.general.clearColor.y),
            blue: CGFloat(document.general.clearColor.z),
            alpha: 1
        )

        var renderableLayers = 0
        for object in document.imageObjects where object.visible && object.alpha > 0.001 {
            do {
                let cgImage = try resolver.resolveImage(relativePath: object.imageRelativePath)
                let texture = SKTexture(cgImage: cgImage)
                texture.filteringMode = .linear
                let node = makeSpriteNode(texture: texture, object: object, canvas: canvasSize)
                scene.addChild(node)
                renderableLayers += 1
            } catch SceneResourceResolver.ResolveError.unsupportedTexture {
                Logger.warning("Scene \(descriptor.workshopID): skipping .tex layer \(object.name)", category: .screenManager)
            } catch SceneResourceResolver.ResolveError.fileMissing {
                Logger.warning("Scene \(descriptor.workshopID): missing asset for layer \(object.name)", category: .screenManager)
            } catch {
                Logger.warning("Scene \(descriptor.workshopID): failed to load \(object.name): \(error.localizedDescription)", category: .screenManager)
            }
        }

        guard renderableLayers > 0 else {
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
        node.zRotation = CGFloat(object.angles.z) * .pi / 180

        // WPE origin is the absolute world position in projection-space
        // pixels with the origin at the bottom-left of the canvas. SpriteKit
        // uses the same origin convention so we plug origin in directly,
        // clamped to the canvas size if the value is normalized 0–1.
        node.position = position(
            for: object.origin,
            canvas: canvas,
            alignment: object.alignment
        )

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

    private func position(
        for origin: SIMD3<Double>,
        canvas: CGSize,
        alignment: WPESceneAlignment
    ) -> CGPoint {
        let x = CGFloat(origin.x)
        let y = CGFloat(origin.y)
        // Treat values inside 0..1 as normalized — community wallpapers mix
        // both conventions and the documentation is silent on which is
        // canonical. Outside that range we trust the absolute pixel value.
        let xPx = (x >= 0 && x <= 1) ? x * canvas.width : x
        let yPx = (y >= 0 && y <= 1) ? y * canvas.height : y

        switch alignment {
        case .center:       return CGPoint(x: xPx, y: yPx)
        case .topLeft:      return CGPoint(x: xPx, y: canvas.height - yPx)
        case .topRight:     return CGPoint(x: canvas.width - xPx, y: canvas.height - yPx)
        case .bottomLeft:   return CGPoint(x: xPx, y: yPx)
        case .bottomRight:  return CGPoint(x: canvas.width - xPx, y: yPx)
        case .top:          return CGPoint(x: xPx, y: canvas.height - yPx)
        case .bottom:       return CGPoint(x: xPx, y: yPx)
        case .left:         return CGPoint(x: xPx, y: yPx)
        case .right:        return CGPoint(x: canvas.width - xPx, y: yPx)
        }
    }
}
