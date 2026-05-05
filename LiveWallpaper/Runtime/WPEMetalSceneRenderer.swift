import AppKit
import MetalKit

/// Wraps a texture-load failure with the requested asset path so the H1
/// diagnostic mapper can blame the exact file, not the scene entry point.
private struct WPEMetalTextureLoadContextError: Error {
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
    private var didLoad = false
    private var isThrottled = false
    private var currentProfile: WallpaperPerformanceProfile = .quality

    private(set) var hasPresentedFrame = false
    private(set) var loadDiagnostics: SceneLoadDiagnostic?
    private(set) var renderGraph: WPERenderGraph?
    private(set) var renderPipeline: WPEPreparedRenderPipeline?
    var renderedTexture: MTLTexture? { outputTexture }
    var onProgress: (@MainActor (String) -> Void)?

    init(
        descriptor: SceneDescriptor,
        cacheRootURL: URL,
        dependencyMounts: [WPEAssetMount],
        frame: CGRect,
        device: MTLDevice
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
        super.init()

        mtkView.delegate = self
        mtkView.colorPixelFormat = WPEMetalRenderExecutor.outputPixelFormat
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        mtkView.preferredFramesPerSecond = SceneRenderingController.defaultPreferredFPS
        mtkView.autoresizingMask = [.width, .height]
        mtkView.enableSetNeedsDisplay = true
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
        let projection = document.general.orthogonalProjection

        onProgress?("Loading textures")
        let textures = try loadTextures(for: pipeline)

        onProgress?("Rendering scene")
        outputTexture = try executor.render(
            pipeline: pipeline,
            size: CGSize(width: max(projection.width, 1), height: max(projection.height, 1)),
            textures: textures
        )
        hasPresentedFrame = true
        didLoad = true
        applyPerformanceProfile(currentProfile)
        mtkView.setNeedsDisplay(mtkView.bounds)
    }

    func reload() async throws {
        didLoad = false
        hasPresentedFrame = false
        outputTexture = nil
        renderGraph = nil
        renderPipeline = nil
        loadDiagnostics = nil
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
            mtkView.isPaused = false
            mtkView.enableSetNeedsDisplay = true
            mtkView.preferredFramesPerSecond = isThrottled
                ? SceneRenderingController.throttledPreferredFPS
                : SceneRenderingController.defaultPreferredFPS
        case .suspended:
            mtkView.isPaused = true
            mtkView.enableSetNeedsDisplay = false
            mtkView.releaseDrawables()
        }
    }

    func cleanup() {
        mtkView.delegate = nil
        outputTexture = nil
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { [weak self] in
            guard let self, let outputTexture else { return }
            do {
                if try executor.present(texture: outputTexture, in: view) {
                    SystemMonitor.shared.tickFrame()
                }
            } catch {
                Logger.warning("Experimental Metal scene present failed: \(error.localizedDescription)", category: .screenManager)
            }
        }
    }

    private func loadTextures(for pipeline: WPEPreparedRenderPipeline) throws -> [String: MTLTexture] {
        var textures: [String: MTLTexture] = [:]
        for layer in pipeline.layers {
            if layer.passes.isEmpty {
                try loadTexture(reference: .image(layer.graphLayer.imagePath), into: &textures)
                continue
            }
            for preparedPass in layer.passes {
                for reference in requiredTextureReferences(for: preparedPass) {
                    try loadTexture(reference: reference, into: &textures)
                }
            }
        }
        return textures
    }

    private func loadTexture(reference: WPETextureReference, into textures: inout [String: MTLTexture]) throws {
        guard let path = externalTexturePath(for: reference), textures[path] == nil else {
            return
        }
        do {
            textures[path] = try makeTexture(relativePath: path, label: "WPE texture \(path)")
        } catch {
            // Carry the asset path through so `diagnostic(for:)` can blame the
            // exact texture instead of falling back to the scene entry file.
            throw WPEMetalTextureLoadContextError(path: path, underlying: error)
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
        if pass.pass.shader == "solidcolor" {
            return []
        }
        if pass.pass.shader == "commands/copy" || pass.pass.shader.hasPrefix("genericimage") {
            return [pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source]
        }
        return []
    }

    private func makeTexture(relativePath: String, label: String) throws -> MTLTexture {
        var lastError: Error?
        for candidate in textureCandidates(for: relativePath) {
            do {
                if shouldTryTexturePayload(candidate) {
                    do {
                        let payload = try resourceResolver.resolveTexturePayload(relativePath: candidate)
                        return try textureLoader.makeTexture(from: payload, label: label)
                    } catch {
                        lastError = error
                    }
                }
                let image = try resourceResolver.resolveImage(relativePath: candidate)
                return try textureLoader.makeTexture(from: image, label: label)
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
    /// `SceneLoadDiagnostic` taxonomy `SceneRenderingController` populates, so
    /// the SpriteKit and Metal backends report failures through one UI path.
    /// `fallbackPath` carries an asset path through `WPEMetalTextureLoadContextError`
    /// so missing-asset diagnostics blame the exact texture, not the scene
    /// entry file. Layer attribution still uses `"scene"` — per-layer
    /// granularity ships in Phase 2B.
    private func diagnostic(for error: Error) -> SceneLoadDiagnostic {
        diagnostic(for: error, fallbackPath: nil)
    }

    private func diagnostic(for error: Error, fallbackPath: String?) -> SceneLoadDiagnostic {
        let layer = "scene"
        switch error {
        case let context as WPEMetalTextureLoadContextError:
            return diagnostic(for: context.underlying, fallbackPath: context.path)
        case let executorError as WPEMetalRenderExecutorError:
            switch executorError {
            case .unsupportedShader(let name):
                return .materialUnresolved(layer: layer, reason: "Shader \"\(name)\" is not supported by the Metal renderer yet.")
            case .unsupportedTarget:
                return .materialUnresolved(layer: layer, reason: "This wallpaper uses an unsupported rendering target.")
            case .missingTexture(let reference):
                switch reference {
                case .image(let path), .asset(let path), .fbo(let path):
                    return .fileMissing(layer: layer, path: path)
                case .previous:
                    return .materialUnresolved(layer: layer, reason: "Previous-frame effects (motion blur, feedback) are not yet supported.")
                }
            case .noRenderablePasses:
                return .materialUnresolved(layer: layer, reason: "Scene contains no renderable passes.")
            case .commandQueueUnavailable, .libraryUnavailable, .pipelineUnavailable, .commandBufferFailed:
                return .other(layer: layer, message: executorError.errorDescription ?? "Metal renderer failed.")
            }
        case let loaderError as WPEMetalTextureLoaderError:
            switch loaderError {
            case .unsupportedFormat, .unsupportedCompressedFormat, .malformedPayload, .textureAllocationFailed:
                return .other(layer: layer, message: loaderError.errorDescription ?? "Texture upload failed.")
            }
        case let resolveError as SceneResourceResolver.ResolveError:
            switch resolveError {
            case .fileMissing:
                return .fileMissing(layer: layer, path: fallbackPath ?? descriptor.entryFile)
            case .pathEscape:
                return .crossPackageReference(layer: layer, path: fallbackPath ?? descriptor.entryFile)
            case .materialUnresolved(let reason):
                return .materialUnresolved(layer: layer, reason: reason)
            case .texture(let texError):
                return .texture(layer: layer, error: texError)
            case .unsupportedTexture:
                return .legacyUnsupportedTexture(layer: layer)
            case .decodeFailed:
                return .other(layer: layer, message: "A texture or image file is corrupted and cannot be decoded.")
            }
        default:
            return .other(layer: layer, message: error.localizedDescription)
        }
    }
}
