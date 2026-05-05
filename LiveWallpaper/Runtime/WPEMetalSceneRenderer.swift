import AppKit
import MetalKit

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
        mtkView.colorPixelFormat = .rgba8Unorm
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        mtkView.preferredFramesPerSecond = SceneRenderingController.defaultPreferredFPS
        mtkView.autoresizingMask = [.width, .height]
        mtkView.enableSetNeedsDisplay = true
        mtkView.isPaused = true
    }

    var nsView: NSView { mtkView }

    func load() async throws {
        guard !didLoad else { return }

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
        textures[path] = try makeTexture(relativePath: path, label: "WPE texture \(path)")
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
}
