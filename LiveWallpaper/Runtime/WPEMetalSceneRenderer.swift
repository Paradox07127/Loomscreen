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
    private var loadedTextures: [String: MTLTexture] = [:]
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
    /// Test-only forwarder for the executor's pooled FBO/composite texture
    /// count so suspended-release behaviour can be asserted at the renderer
    /// boundary (Phase 2C Task 2).
    var transientTargetTextureCountForTesting: Int {
        executor.transientTargetTextureCountForTesting
    }
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
        loadedTextures = try await loadTextures(for: pipeline)

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
    /// pipeline. `lastRuntimeUniforms` is exposed for tests.
    private func renderCurrentFrame() throws -> MTLTexture {
        guard let pipeline = renderPipeline else {
            throw WPEMetalRenderExecutorError.noRenderablePasses
        }
        let uniforms = frameClock.runtimeUniforms(
            profile: currentProfile,
            pointerPosition: pointerSampler.sample(mtkView)
        )
        lastRuntimeUniforms = uniforms
        return try executor.render(
            pipeline: pipeline,
            size: sceneRenderSize,
            textures: loadedTextures,
            runtimeUniforms: uniforms,
            cameraUniforms: cameraUniforms
        )
    }

    func reload() async throws {
        didLoad = false
        hasPresentedFrame = false
        outputTexture = nil
        renderGraph = nil
        renderPipeline = nil
        loadDiagnostics = nil
        loadedTextures = [:]
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
        switch profile {
        case .quality:
            // Phase 2B presents the cached `outputTexture` once per
            // visibility change rather than re-rendering every display
            // tick. Built-in shaders (solidcolor / genericimage / copy) do
            // not consume `g_Time`, so the per-frame work would just burn
            // GPU on a 6-display setup. Phase 2C/2D will re-enable
            // continuous draw once GLSL translation lands and shaders
            // actually use the runtime uniforms.
            mtkView.isPaused = true
            mtkView.enableSetNeedsDisplay = true
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
        loadedTextures = [:]
        lastRuntimeUniforms = nil
        cachedSnapshot = nil
        executor.releaseTransientResources()
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { [weak self] in
            guard let self, didLoad, let outputTexture else { return }
            do {
                if try executor.present(texture: outputTexture, in: view) {
                    SystemMonitor.shared.tickFrame()
                }
            } catch {
                Logger.warning("Experimental Metal scene present failed: \(error.localizedDescription)", category: .screenManager)
            }
        }
    }

    private func loadTextures(for pipeline: WPEPreparedRenderPipeline) async throws -> [String: MTLTexture] {
        var textures: [String: MTLTexture] = [:]
        for layer in pipeline.layers {
            if layer.passes.isEmpty {
                try await loadTexture(
                    reference: .image(layer.graphLayer.imagePath),
                    layerName: layer.graphLayer.objectName,
                    into: &textures
                )
                continue
            }
            for preparedPass in layer.passes {
                for reference in requiredTextureReferences(for: preparedPass) {
                    try await loadTexture(
                        reference: reference,
                        layerName: layer.graphLayer.objectName,
                        into: &textures
                    )
                }
            }
        }
        return textures
    }

    private func loadTexture(
        reference: WPETextureReference,
        layerName: String,
        into textures: inout [String: MTLTexture]
    ) async throws {
        guard let path = externalTexturePath(for: reference), textures[path] == nil else {
            return
        }
        do {
            textures[path] = try await makeTexture(relativePath: path, label: "WPE texture \(path)")
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

        case "copy":
            let reference = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
            return [reference].filter(\.isExternalTextureReference)

        case "compose":
            let first = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
            let second = pass.textureBindings[1] ?? pass.pass.textures[1] ?? first
            return [first, second].filter(\.isExternalTextureReference)

        default:
            return []
        }
    }

    private func normalizedBuiltinShaderName(_ shaderName: String) -> String {
        let lower = shaderName.lowercased()
        let withoutJSON = lower.hasSuffix(".json") ? String(lower.dropLast(5)) : lower
        switch withoutJSON {
        case "solidcolor":
            return "solidcolor"
        case "solidlayer", "materials/util/solidlayer", "models/util/solidlayer":
            return "solidlayer"
        case "copy", "commands/copy", "materials/util/copy":
            return "copy"
        case "compose", "materials/util/compose":
            return "compose"
        default:
            if withoutJSON.hasPrefix("genericimage") {
                return "copy"
            }
            return withoutJSON
        }
    }

    private func makeTexture(relativePath: String, label: String) async throws -> MTLTexture {
        var lastError: Error?
        for candidate in textureCandidates(for: relativePath) {
            do {
                if shouldTryTexturePayload(candidate) {
                    do {
                        let payload = try resourceResolver.resolveTexturePayload(relativePath: candidate)
                        return try await textureLoader.makeTexture(from: payload, label: label)
                    } catch {
                        lastError = error
                    }
                }
                let image = try resourceResolver.resolveImage(relativePath: candidate)
                return try await textureLoader.makeTexture(from: image, label: label)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? WPEMetalRenderExecutorError.missingTexture(.image(relativePath))
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
