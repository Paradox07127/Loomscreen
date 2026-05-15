import AppKit
import MetalKit

/// Wraps a texture-load failure with the requested asset path AND the WPE
/// object/layer name that referenced it so the H1 diagnostic mapper can
/// blame the exact file and surface the failing layer instead of falling
/// back to the scene entry point.
private struct WPEMetalTextureLoadContextError: Error {
    let layerName: String
    let path: String
    let underlying: any Error
}

@MainActor
final class WPEMetalSceneRenderer: NSObject, WPESceneRenderer, MTKViewDelegate {
    private let descriptor: SceneDescriptor
    private let cacheRootURL: URL
    private let dependencyMounts: [WPEAssetMount]
    private let entryResolver: SceneResourceResolver
    private let resourceResolver: WPEMultiRootResourceResolver
    private let mtkView: MTKView
    private let executor: WPEMetalRenderExecutor
    private let textureLoader: WPEMetalTextureLoader
    private var outputTexture: MTLTexture?
    /// Phase 2D-L: alive particle systems and the per-system sprite
    /// texture. Built on load from the scene's `particleObjects`; ticked
    /// + drawn each frame.
    private var particleSystems: [WPEParticleSystem] = []
    private var particleTextures: [ObjectIdentifier: MTLTexture] = [:]
    /// Phase 2D-N: text overlay draws assembled at load time. Each
    /// frame re-rasterizes via the cached WPETextRenderer (cache hits
    /// the common case) and draws atop the scene output.
    private var textRenderer: WPETextRenderer?
    private var textObjects: [WPESceneTextObject] = []
    private var loadedTextures: [String: MTLTexture] = [:]
    /// Phase 2E: animated and video texture sources keyed by the same path
    /// the executor uses to look up `MTLTexture` for each pass. Populated
    /// during `performLoad()`; refreshed each render via
    /// `texturesForCurrentFrame(time:)` so the executor sees the live frame.
    private var dynamicTextureSources: [String: WPEDynamicTextureSource] = [:]
    private var sceneRenderSize: CGSize = CGSize(width: 1, height: 1)
    private var cameraUniforms: WPEMetalCameraUniforms = .identity
    private var frameClock: WPEMetalFrameClock
    private let pointerSampler: WPEMetalPointerSampler
    private let snapshotter: WPEMetalTextureSnapshotter
    private var cachedSnapshot: NSImage?
    private var didLoad = false
    private var isThrottled = false
    private var currentProfile: WallpaperPerformanceProfile = .quality

    private(set) var hasPresentedFrame = false
    private(set) var loadDiagnostics: SceneLoadDiagnostic?
    private(set) var renderGraph: WPERenderGraph?
    private(set) var renderPipeline: WPEPreparedRenderPipeline?
    private(set) var lastRuntimeUniforms: WPEMetalRuntimeUniforms?
    var renderedTexture: MTLTexture? { outputTexture }
    /// CGImage readback of the most recent rendered frame; populated at the
    /// end of `performLoad()` so `WPESceneDetailView` can show a thumbnail
    /// instead of falling into `.previewUnavailable`. Refreshed by `reload()`
    /// and cleared by `cleanup()`.
    var previewSnapshot: NSImage? { cachedSnapshot }
    var onProgress: (@MainActor (String) -> Void)?

    init(
        descriptor: SceneDescriptor,
        cacheRootURL: URL,
        dependencyMounts: [WPEAssetMount],
        frame: CGRect,
        device: MTLDevice,
        frameClock: WPEMetalFrameClock = WPEMetalFrameClock(),
        pointerSampler: WPEMetalPointerSampler = .live,
        snapshotter: WPEMetalTextureSnapshotter = .shared
    ) throws {
        self.descriptor = descriptor
        self.cacheRootURL = cacheRootURL
        self.dependencyMounts = dependencyMounts
        self.entryResolver = SceneResourceResolver(cacheRootURL: cacheRootURL)
        self.resourceResolver = WPEMultiRootResourceResolver(
            primaryRootURL: cacheRootURL,
            dependencyMounts: dependencyMounts
        )
        self.executor = try WPEMetalRenderExecutor(device: device)
        self.textureLoader = WPEMetalTextureLoader(device: device)
        self.mtkView = MTKView(frame: frame, device: device)
        self.frameClock = frameClock
        self.pointerSampler = pointerSampler
        self.snapshotter = snapshotter
        super.init()

        mtkView.delegate = self
        mtkView.colorPixelFormat = WPEMetalRenderExecutor.outputPixelFormat
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        mtkView.preferredFramesPerSecond = SceneRenderingController.defaultPreferredFPS
        mtkView.autoresizingMask = [.width, .height]
        mtkView.enableSetNeedsDisplay = false
        mtkView.isPaused = true
    }

    var nsView: NSView { mtkView }

    func load() async throws {
        guard !didLoad else { return }
        do {
            try await performLoad()
            loadDiagnostics = nil
        } catch {
            // Surface a precise reason via `loadDiagnostics` so the detail
            // view's honesty pass shows the actual failure (unsupported
            // shader, missing texture, …) instead of "All declared layers
            // decoded cleanly."
            loadDiagnostics = diagnostic(for: error)
            throw error
        }
    }

    private func performLoad() async throws {
        onProgress?("Reading scene")
        let entryURL = try entryResolver.resolveExistingFileURL(relativePath: descriptor.entryFile)
        let document = try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: entryURL)
            return try WPESceneDocumentParser.parse(data: data)
        }.value

        onProgress?("Building render graph")
        let cacheRoot = cacheRootURL
        let mounts = dependencyMounts
        let graph = try await Task.detached(priority: .userInitiated) {
            try WPERenderGraphBuilder(cacheRootURL: cacheRoot, dependencyMounts: mounts).build(document: document)
        }.value

        onProgress?("Preparing render pipeline")
        let pipeline = try await Task.detached(priority: .userInitiated) {
            try WPERenderPipelineBuilder(cacheRootURL: cacheRoot).build(graph: graph)
        }.value

        renderGraph = graph
        renderPipeline = pipeline
        cameraUniforms = WPEMetalCameraUniforms(
            orthogonalProjection: document.general.orthogonalProjection,
            sceneCamera: document.camera
        )
        sceneRenderSize = cameraUniforms.renderSize

        onProgress?("Loading textures")
        try await loadTextures(for: pipeline)

        onProgress?("Loading particle systems")
        await loadParticleSystems(from: document)

        onProgress?("Loading text overlays")
        loadTextOverlays(from: document)

        onProgress?("Rendering scene")
        outputTexture = try renderCurrentFrame()
        if let outputTexture {
            cachedSnapshot = snapshotter.snapshot(from: outputTexture)
        }
        hasPresentedFrame = true
        didLoad = true
        applyPerformanceProfile(currentProfile)
        mtkView.setNeedsDisplay(mtkView.bounds)
    }

    /// Computes one frame's runtime uniforms (clock, daytime, brightness,
    /// pointer) and submits the render pipeline with both runtime and camera
    /// uniforms. Called once during `performLoad()` and then per-frame from
    /// `draw(in:)` so animated scenes refresh without rebuilding the
    /// pipeline. The captured value is re-read by dynamic texture sources
    /// in `draw(in:)` to drive their frame selection.
    private func renderCurrentFrame() throws -> MTLTexture {
        guard let pipeline = renderPipeline else {
            throw WPEMetalRenderExecutorError.noRenderablePasses
        }
        let uniforms = frameClock.runtimeUniforms(
            profile: currentProfile,
            pointerPosition: pointerSampler.sample(mtkView)
        )
        lastRuntimeUniforms = uniforms
        let currentTextures = texturesForCurrentFrame(time: uniforms.time)
        let frame = try executor.render(
            pipeline: pipeline,
            size: sceneRenderSize,
            textures: currentTextures,
            runtimeUniforms: uniforms,
            cameraUniforms: cameraUniforms
        )
        // Phase 2D-L: particles render after the layer/effect pipeline so
        // they composite on top of the scene's background. CPU tick uses
        // the scene clock so animation stays in lockstep with shaders'
        // `g_Time`.
        if !particleSystems.isEmpty {
            for system in particleSystems {
                system.tick(now: uniforms.time)
            }
            try executor.drawParticles(
                systems: particleSystems,
                texturesByMaterial: particleTextures,
                sceneSize: sceneRenderSize,
                output: frame
            )
        }
        // Phase 2D-N: text overlays composite on top of particles. The
        // rasterizer caches by content hash, so static text only walks
        // CoreText once.
        if let textRenderer, !textObjects.isEmpty {
            var draws: [WPETextOverlayDraw] = []
            draws.reserveCapacity(textObjects.count)
            for object in textObjects where object.visible && object.alpha > 0 {
                guard let entry = textRenderer.rasterize(object) else { continue }
                // WPE pixel-space origin is screen-relative; the scene
                // canvas is centered at (width/2, height/2). Subtract
                // half-canvas so origin "1920 1080 0" lands at the
                // center of a 1920×1080 scene. Y is also flipped to
                // match Metal's NDC convention (already y-up).
                let halfWidth = Double(sceneRenderSize.width) * 0.5
                let halfHeight = Double(sceneRenderSize.height) * 0.5
                let center = SIMD2<Float>(
                    Float(object.origin.x - halfWidth),
                    Float(object.origin.y - halfHeight)
                )
                let scale = SIMD2<Float>(
                    Float(max(object.scale.x, 0.0001)),
                    Float(max(object.scale.y, 0.0001))
                )
                let scaledSize = CGSize(
                    width: entry.size.width * CGFloat(scale.x),
                    height: entry.size.height * CGFloat(scale.y)
                )
                draws.append(WPETextOverlayDraw(
                    texture: entry.texture,
                    centerInScenePixels: center,
                    sizeInScenePixels: scaledSize,
                    tint: SIMD3<Float>(
                        Float(object.color.x),
                        Float(object.color.y),
                        Float(object.color.z)
                    ),
                    alpha: Float(object.alpha)
                ))
            }
            if !draws.isEmpty {
                try executor.drawTextOverlays(
                    overlays: draws,
                    sceneSize: sceneRenderSize,
                    output: frame
                )
            }
        }
        return frame
    }

    /// Phase 2D-N: build the WPETextRenderer + cache the parsed text
    /// object list. Rasterization happens lazily during the first frame
    /// so we don't pay the CoreText cost when the scene is preview-only.
    private func loadTextOverlays(from document: WPESceneDocument) {
        textObjects = document.textObjects
        guard !textObjects.isEmpty else {
            textRenderer = nil
            return
        }
        textRenderer = WPETextRenderer(
            device: executor.textureSourceDevice,
            resolver: resourceResolver
        )
    }

    /// Spawn one `WPEParticleSystem` per parsed particle object. Reads
    /// the linked particle JSON, parses it into a definition, and
    /// allocates a GPU instance buffer. Resolves the material → first
    /// texture path so the draw call has a sprite atlas to sample.
    private func loadParticleSystems(from document: WPESceneDocument) async {
        particleSystems.removeAll(keepingCapacity: true)
        particleTextures.removeAll(keepingCapacity: true)
        for object in document.particleObjects where object.visible {
            guard let particleURL = try? entryResolver.resolveExistingFileURL(relativePath: object.particleRelativePath),
                  let data = try? Data(contentsOf: particleURL),
                  let definition = WPEParticleDefinitionParser.parse(data: data) else {
                continue
            }
            guard let system = WPEParticleSystem(
                definition: definition,
                device: executor.textureSourceDevice
            ) else {
                continue
            }
            particleSystems.append(system)
            // Try to resolve the material → first texture so the
            // particle has something to sample. We re-walk the material
            // here rather than route it through the render-graph builder
            // because particle materials live outside the layer pipeline.
            if let materialPath = definition.materialRelativePath,
               let materialURL = try? entryResolver.resolveExistingFileURL(relativePath: materialPath),
               let materialData = try? Data(contentsOf: materialURL),
               let materialJSON = try? JSONSerialization.jsonObject(with: materialData) as? [String: Any],
               let passes = materialJSON["passes"] as? [[String: Any]],
               let firstPass = passes.first,
               let textures = firstPass["textures"] as? [Any],
               let firstTexturePath = textures.first as? String,
               let texturePayload = try? await makeTextureResource(
                    relativePath: firstTexturePath,
                    label: "particle texture \(firstTexturePath)"
               ) {
                switch texturePayload {
                case .staticTexture(let texture):
                    particleTextures[ObjectIdentifier(system)] = texture
                case .dynamicSource(let source):
                    if let texture = source.texture(at: 0) {
                        particleTextures[ObjectIdentifier(system)] = texture
                    }
                }
            }
        }
    }

    func reload() async throws {
        didLoad = false
        hasPresentedFrame = false
        outputTexture = nil
        renderGraph = nil
        renderPipeline = nil
        loadDiagnostics = nil
        releaseDynamicTextureSources()
        particleSystems.removeAll(keepingCapacity: false)
        particleTextures.removeAll(keepingCapacity: false)
        textObjects.removeAll(keepingCapacity: false)
        textRenderer?.releaseAll()
        textRenderer = nil
        sceneRenderSize = CGSize(width: 1, height: 1)
        cameraUniforms = .identity
        lastRuntimeUniforms = nil
        cachedSnapshot = nil
        executor.releaseTransientResources()
        try await load()
    }

    func setThrottled(_ throttled: Bool) {
        isThrottled = throttled
        guard currentProfile != .suspended else { return }
        mtkView.preferredFramesPerSecond = throttled
            ? SceneRenderingController.throttledPreferredFPS
            : SceneRenderingController.defaultPreferredFPS
    }

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        currentProfile = profile
        // Phase 2E: forward profile to dynamic sources so video readers
        // pause cleanly on `.suspended` and resume on `.quality`.
        dynamicTextureSources.values.forEach { $0.applyPerformanceProfile(profile) }
        switch profile {
        case .quality:
            // Phase 2E correction: enable continuous draw whenever the
            // scene holds at least one dynamic texture source (animated
            // TEX or video). Static built-in scenes keep the Phase 2B
            // paused/present-cached behaviour to avoid burning GPU on a
            // multi-display setup.
            let hasDynamic = !dynamicTextureSources.isEmpty
            mtkView.isPaused = !hasDynamic
            mtkView.enableSetNeedsDisplay = !hasDynamic
            mtkView.preferredFramesPerSecond = isThrottled
                ? SceneRenderingController.throttledPreferredFPS
                : SceneRenderingController.defaultPreferredFPS
        case .suspended:
            mtkView.isPaused = true
            mtkView.enableSetNeedsDisplay = true
            mtkView.releaseDrawables()
            // Phase 2C Task 2: pooled FBO/layer-composite textures live
            // across `render(...)` calls; release them when the wallpaper
            // is suspended so a 6-display setup does not retain hundreds
            // of MB of transient render targets while paused.
            executor.releaseTransientResources()
        }
    }

    func cleanup() {
        mtkView.delegate = nil
        outputTexture = nil
        releaseDynamicTextureSources()
        particleSystems.removeAll(keepingCapacity: false)
        particleTextures.removeAll(keepingCapacity: false)
        textObjects.removeAll(keepingCapacity: false)
        textRenderer?.releaseAll()
        textRenderer = nil
        lastRuntimeUniforms = nil
        cachedSnapshot = nil
        executor.releaseTransientResources()
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { [weak self] in
            guard let self, didLoad else { return }
            do {
                // Phase 2E: re-render when there are dynamic texture sources
                // so animated/video frames advance with the runtime clock.
                // Static scenes keep the Phase 2B cheap path (present the
                // cached snapshot) so a 6-display wallpaper does not burn
                // GPU producing identical frames.
                let textureToPresent: MTLTexture?
                if dynamicTextureSources.isEmpty {
                    textureToPresent = outputTexture
                } else {
                    let frame = try renderCurrentFrame()
                    outputTexture = frame
                    textureToPresent = frame
                }
                guard let texture = textureToPresent else { return }
                if try executor.present(texture: texture, in: view) {
                    SystemMonitor.shared.tickFrame()
                }
            } catch {
                Logger.warning("Experimental Metal scene present failed: \(error.localizedDescription)", category: .screenManager)
            }
        }
    }

    /// Phase 2E: differentiates between a one-shot static texture and a
    /// dynamic source (animated TEX or video) so the renderer can either
    /// stuff the result into `loadedTextures` or hold the source for
    /// per-frame refresh via `texturesForCurrentFrame(time:)`.
    private enum WPELoadedTextureResource {
        case staticTexture(MTLTexture)
        case dynamicSource(WPEDynamicTextureSource)
    }

    private func loadTextures(for pipeline: WPEPreparedRenderPipeline) async throws {
        loadedTextures = [:]
        dynamicTextureSources = [:]

        for layer in pipeline.layers {
            if layer.passes.isEmpty {
                try await loadTexture(
                    reference: .image(layer.graphLayer.imagePath),
                    layerName: layer.graphLayer.objectName
                )
                continue
            }
            for preparedPass in layer.passes {
                for reference in requiredTextureReferences(for: preparedPass) {
                    try await loadTexture(
                        reference: reference,
                        layerName: layer.graphLayer.objectName
                    )
                }
            }
        }
    }

    private func loadTexture(
        reference: WPETextureReference,
        layerName: String
    ) async throws {
        guard let path = externalTexturePath(for: reference),
              loadedTextures[path] == nil,
              dynamicTextureSources[path] == nil else {
            return
        }
        do {
            let resource = try await makeTextureResource(relativePath: path, label: "WPE texture \(path)")
            switch resource {
            case .staticTexture(let texture):
                loadedTextures[path] = texture
            case .dynamicSource(let source):
                dynamicTextureSources[path] = source
                // Phase 2E: video sources return nil before the background
                // reader publishes its first frame. Seed `loadedTextures`
                // with a 1×1 transparent placeholder so the executor's
                // texture lookup does not throw `missingTexture` during
                // the initial render pass.
                if let texture = source.texture(at: lastRuntimeUniforms?.time ?? 0) {
                    loadedTextures[path] = texture
                } else {
                    loadedTextures[path] = try makeDynamicPlaceholderTexture(label: "\(path) placeholder")
                }
            }
        } catch {
            // Carry the asset path AND layer name through so `diagnostic(for:)`
            // can attribute the failure to the WPE object that referenced it.
            throw WPEMetalTextureLoadContextError(layerName: layerName, path: path, underlying: error)
        }
    }

    private func externalTexturePath(for reference: WPETextureReference) -> String? {
        switch reference {
        case .image(let path), .asset(let path):
            return path
        case .fbo, .previous:
            return nil
        }
    }

    private func requiredTextureReferences(for pass: WPEPreparedRenderPass) -> [WPETextureReference] {
        switch normalizedBuiltinShaderName(pass.pass.shader) {
        case "solidcolor", "solidlayer":
            return []

        case "compose":
            let first = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
            let second = pass.textureBindings[1] ?? pass.pass.textures[1] ?? first
            return [first, second].filter(\.isExternalTextureReference)

        case "genericimage4":
            // Slot 0 + slot 1 (alpha mask). Slot 1 is optional; only
            // request load if it's actually bound.
            let primary = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
            var refs: [WPETextureReference] = [primary]
            if let mask = pass.textureBindings[1] ?? pass.pass.textures[1] {
                refs.append(mask)
            }
            return refs.filter(\.isExternalTextureReference)

        default:
            // Single-input shaders: copy, genericimage2, genericparticle,
            // and every effect_* variant. The translator-driven custom
            // shader path also goes here — it always reads at least slot 0.
            // Multi-pass effects (lightshafts, blur_precise_gaussian, …)
            // express inter-pass texture references via `pass.binds`,
            // resolving to FBO names that the executor produces during
            // earlier passes — those don't need to be pre-loaded.
            let reference = pass.pass.binds[0]
                ?? pass.textureBindings[0]
                ?? pass.pass.textures[0]
                ?? pass.pass.source
            var refs: [WPETextureReference] = [reference]
            for slot in 1..<4 {
                if let extra = pass.pass.binds[slot] ?? pass.textureBindings[slot] ?? pass.pass.textures[slot] {
                    refs.append(extra)
                }
            }
            return refs.filter(\.isExternalTextureReference)
        }
    }

    private func normalizedBuiltinShaderName(_ shaderName: String) -> String {
        // Mirrors WPEMetalRenderExecutor.normalizedBuiltinShaderName so the
        // loader and dispatcher route on the same canonical names.
        WPEBuiltinShaderName.normalized(shaderName, genericImageAsCopy: false)
    }

    /// Phase 2E rewrite: returns a `WPELoadedTextureResource` instead of a
    /// raw texture so the caller can route MP4 video and multi-frame
    /// animations through dedicated dynamic sources.
    private func makeTextureResource(relativePath: String, label: String) async throws -> WPELoadedTextureResource {
        var lastError: Error?
        for candidate in textureCandidates(for: relativePath) {
            do {
                if shouldTryTexturePayload(candidate) {
                    do {
                        let payload = try resourceResolver.resolveTexturePayload(relativePath: candidate)

                        if payload.videoPayload != nil {
                            let source = try await makeVideoTextureSource(from: payload, label: label)
                            return .dynamicSource(source)
                        }
                        if payload.animationTrack != nil {
                            let source = try await textureLoader.makeAnimatedTextureSource(
                                from: payload,
                                label: label
                            )
                            return .dynamicSource(source)
                        }

                        return .staticTexture(try await textureLoader.makeTexture(from: payload, label: label))
                    } catch {
                        lastError = error
                    }
                }
                let image = try resourceResolver.resolveImage(relativePath: candidate)
                return .staticTexture(try await textureLoader.makeTexture(from: image, label: label))
            } catch {
                lastError = error
            }
        }
        throw lastError ?? WPEMetalRenderExecutorError.missingTexture(.image(relativePath))
    }

    /// Phase 2E: stages MP4 bytes into the per-process video cache and
    /// constructs a `WPEVideoTextureSource` bound to the executor's
    /// MTLDevice.
    private func makeVideoTextureSource(
        from payload: WPETexTexturePayload,
        label: String
    ) async throws -> WPEVideoTextureSource {
        guard let videoPayload = payload.videoPayload else {
            throw WPEMetalTextureLoaderError.malformedPayload("missing video payload")
        }
        let url = try await WPEVideoTextureSource.persistVideoData(
            videoPayload.bytes,
            cacheDirectory: Self.videoCacheDirectory()
        )
        let source = try WPEVideoTextureSource(
            device: executor.textureSourceDevice,
            videoURL: url
        )
        _ = label
        return source
    }

    private static func videoCacheDirectory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("wpe-tex-video", isDirectory: true)
    }

    /// Phase 2E: returns a 1×1 transparent texture used as a temporary
    /// stand-in for dynamic sources whose first frame has not yet decoded.
    /// Replaced by the live texture on the next `texturesForCurrentFrame`
    /// call once the source publishes a frame.
    private func makeDynamicPlaceholderTexture(label: String) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: WPEMetalRenderExecutor.outputPixelFormat,
            width: 1,
            height: 1,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = executor.textureSourceDevice.makeTexture(descriptor: descriptor) else {
            throw WPEMetalTextureLoaderError.textureAllocationFailed
        }
        texture.label = label
        var pixel: UInt32 = 0
        texture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0,
            withBytes: &pixel,
            bytesPerRow: 4
        )
        return texture
    }

    /// Phase 2E: pulls fresh `MTLTexture`s from any dynamic sources before
    /// every render call. `loadedTextures` mirrors the latest texture so a
    /// pass that samples the same path through the executor always sees a
    /// live frame.
    private func texturesForCurrentFrame(time: TimeInterval) -> [String: MTLTexture] {
        var textures = loadedTextures
        for (path, source) in dynamicTextureSources {
            if let texture = source.texture(at: time) {
                textures[path] = texture
                loadedTextures[path] = texture
            }
        }
        return textures
    }

    private func releaseDynamicTextureSources() {
        dynamicTextureSources.values.forEach { $0.invalidate() }
        dynamicTextureSources.removeAll()
        loadedTextures.removeAll()
    }

    private func shouldTryTexturePayload(_ path: String) -> Bool {
        let extensionName = (path as NSString).pathExtension.lowercased()
        return extensionName.isEmpty || extensionName == "json" || extensionName == "tex"
    }

    private func textureCandidates(for path: String) -> [String] {
        let extensionName = (path as NSString).pathExtension
        guard extensionName.isEmpty else {
            return [path]
        }

        if let dependency = dependencyReference(path) {
            let child = dependency.childPath
            if child.contains("/") {
                return [
                    path,
                    "\(path).tex",
                    "\(path).png",
                    "\(path).jpg",
                    "\(path).jpeg"
                ]
            }
            let prefix = "../\(dependency.workshopID)"
            return [
                "\(prefix)/materials/\(child).tex",
                "\(prefix)/materials/\(child).png",
                "\(prefix)/materials/\(child).jpg",
                "\(prefix)/materials/\(child).jpeg",
                path
            ]
        }

        if path.contains("/") {
            return [
                path,
                "\(path).tex",
                "\(path).png",
                "\(path).jpg",
                "\(path).jpeg"
            ]
        }

        return [
            "materials/\(path).tex",
            "materials/\(path).png",
            "materials/\(path).jpg",
            "materials/\(path).jpeg",
            path
        ]
    }

    private func dependencyReference(_ relativePath: String) -> (workshopID: String, childPath: String)? {
        guard relativePath.hasPrefix("../") else { return nil }
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] == ".." else { return nil }
        return (String(parts[1]), parts.dropFirst(2).joined(separator: "/"))
    }

    /// Maps any error raised during `performLoad()` onto the same
    /// `SceneLoadDiagnostic` taxonomy `SceneRenderingController` populates so
    /// SpriteKit and Metal report failures through one UI path. The
    /// `WPEMetalTextureLoadContextError` wrapper carries both the asset path
    /// and the failing WPE object name through the recursion so missing-asset
    /// diagnostics blame the exact layer instead of the generic scene entry.
    private func diagnostic(for error: Error) -> SceneLoadDiagnostic {
        diagnostic(for: error, fallbackPath: nil, layerName: "scene")
    }

    private func diagnostic(
        for error: Error,
        fallbackPath: String?,
        layerName: String
    ) -> SceneLoadDiagnostic {
        switch error {
        case let context as WPEMetalTextureLoadContextError:
            return diagnostic(
                for: context.underlying,
                fallbackPath: context.path,
                layerName: context.layerName
            )
        case let executorError as WPEMetalRenderExecutorError:
            switch executorError {
            case .unsupportedShader(let name):
                return .materialUnresolved(layer: layerName, reason: "Shader \"\(name)\" is not supported by the Metal renderer yet.")
            case .shaderTranslatorUnavailable(let name, let reason):
                return .materialUnresolved(
                    layer: layerName,
                    reason: "Shader \"\(name)\" needs the WPE GLSL translator: \(reason)"
                )
            case .unsupportedTarget:
                return .materialUnresolved(layer: layerName, reason: "This wallpaper uses an unsupported rendering target.")
            case .missingTexture(let reference):
                switch reference {
                case .image(let path), .asset(let path), .fbo(let path):
                    return .fileMissing(layer: layerName, path: path)
                case .previous:
                    return .materialUnresolved(layer: layerName, reason: "Previous-frame effects (motion blur, feedback) are not yet supported.")
                }
            case .noRenderablePasses:
                return .materialUnresolved(layer: layerName, reason: "Scene contains no renderable passes.")
            case .commandQueueUnavailable, .libraryUnavailable, .pipelineUnavailable, .commandBufferFailed:
                return .other(layer: layerName, message: executorError.errorDescription ?? "Metal renderer failed.")
            }
        case let loaderError as WPEMetalTextureLoaderError:
            switch loaderError {
            case .unsupportedFormat, .unsupportedCompressedFormat, .malformedPayload, .textureAllocationFailed:
                return .other(layer: layerName, message: loaderError.errorDescription ?? "Texture upload failed.")
            }
        case let resolveError as SceneResourceResolver.ResolveError:
            switch resolveError {
            case .fileMissing:
                return .fileMissing(layer: layerName, path: fallbackPath ?? descriptor.entryFile)
            case .pathEscape:
                return .crossPackageReference(layer: layerName, path: fallbackPath ?? descriptor.entryFile)
            case .materialUnresolved(let reason):
                return .materialUnresolved(layer: layerName, reason: reason)
            case .texture(let texError):
                return .texture(layer: layerName, error: texError)
            case .unsupportedTexture:
                return .legacyUnsupportedTexture(layer: layerName)
            case .decodeFailed:
                return .other(layer: layerName, message: "A texture or image file is corrupted and cannot be decoded.")
            }
        default:
            return .other(layer: layerName, message: error.localizedDescription)
        }
    }
}

/// Phase 2C: filters out FBO/previous references at the texture-discovery
/// layer so the renderer never tries to load an in-graph FBO from disk.
/// Those references resolve at executor time via the frame state.
private extension WPETextureReference {
    var isExternalTextureReference: Bool {
        switch self {
        case .image, .asset:
            return true
        case .fbo, .previous:
            return false
        }
    }
}
