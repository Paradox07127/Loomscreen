#if !LITE_BUILD
import AppKit
import Foundation
@preconcurrency import WebKit

/// `WKWebView`-backed `WPESceneRenderer` for the WebGL2 WPE pipeline.
///
/// Phase 1: host + bridge + scheme handlers wired; loads the embedded
/// runtime HTML, awaits the JS `ready` message, surfaces structured
/// errors. No actual scene rendering yet — Phase 3 attaches the pipeline
/// envelope and Phase 5+ enables real corpus playback.
@MainActor
final class WPEWebGLSceneRenderer: NSObject, WPESceneRenderer, WKNavigationDelegate {
    static let readyTimeoutSeconds: TimeInterval = 12
    static let sceneLoadTimeoutSeconds: TimeInterval = 15

    private let descriptor: SceneDescriptor
    private let cacheRootURL: URL
    private let dependencyMounts: [WPEAssetMount]
    private let engineAssetsRootURL: URL?
    private let entryResolver: SceneResourceResolver
    private let assetSchemeHandler: WPEAssetSchemeHandler
    private let runtimeSchemeHandler: WPERuntimeSchemeHandler
    private let bridge: WPEWebGLBridge
    private let webView: WKWebView
    private let frame: CGRect

    private var sessionNonce: String?
    private var readyContinuation: CheckedContinuation<Void, any Error>?
    private var didReceiveReady = false
    private var sceneLoadContinuation: CheckedContinuation<Void, any Error>?
    private var didReceiveSceneLoaded = false
    private var currentProfile: WallpaperPerformanceProfile = .quality
    private var isThrottledFlag = false
    private var frameCount: Int = 0

    private(set) var hasPresentedFrame: Bool = false
    private(set) var loadDiagnostics: SceneLoadDiagnostic?
    private var loadedRenderGraph: WPERenderGraph?
    private var preparedRenderPipeline: WPEPreparedRenderPipeline?
    private var assetProvider: WPEWebGLAssetProvider?

    let resolutionTracer = WPEResolutionTracer()

    var nsView: NSView { webView }
    var onProgress: (@MainActor (String) -> Void)?
    var renderGraph: WPERenderGraph? { loadedRenderGraph }
    var renderPipeline: WPEPreparedRenderPipeline? { preparedRenderPipeline }
    var previewSnapshot: NSImage? { nil }
    var resolutionDiagnostics: WPEResolutionDiagnosticsSnapshot {
        resolutionTracer.snapshot()
    }

    init(
        descriptor: SceneDescriptor,
        cacheRootURL: URL,
        dependencyMounts: [WPEAssetMount],
        engineAssetsRootURL: URL?,
        frame: CGRect
    ) throws {
        self.descriptor = descriptor
        self.cacheRootURL = cacheRootURL
        self.dependencyMounts = dependencyMounts
        self.engineAssetsRootURL = engineAssetsRootURL
        self.frame = frame
        self.entryResolver = SceneResourceResolver(cacheRootURL: cacheRootURL)
        self.assetSchemeHandler = WPEAssetSchemeHandler()
        self.runtimeSchemeHandler = WPERuntimeSchemeHandler()
        self.bridge = WPEWebGLBridge()

        guard runtimeSchemeHandler.hasBundle else {
            throw SceneRenderingError.parseFailed(
                "wpe-webgl-runtime.bundle missing — run `npm run build` in WPEWebGLRuntime/."
            )
        }

        let configuration = WKWebViewConfiguration()
        let controller = WKUserContentController()
        configuration.userContentController = controller
        configuration.suppressesIncrementalRendering = false
        // Phase 6: video-backed `.tex` textures decode through hidden
        // `<video>` elements. They run muted + looped, so allow autoplay
        // without a user gesture and keep playback inline.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.setURLSchemeHandler(runtimeSchemeHandler, forURLScheme: WPERuntimeSchemeHandler.scheme)
        configuration.setURLSchemeHandler(assetSchemeHandler, forURLScheme: WPEAssetSchemeHandler.scheme)

        let webView = WKWebView(frame: frame, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.autoresizingMask = [.width, .height]
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        #if DEBUG
        webView.isInspectable = true
        #endif
        self.webView = webView

        super.init()

        webView.navigationDelegate = self
        bridge.webView = webView
        controller.add(bridge.receiverAdapter(), name: WPEWebGLBridge.messageHandlerName)

        bridge.onReady = { [weak self] sceneID in
            self?.handleReady(sceneID: sceneID)
        }
        bridge.onSceneLoaded = { [weak self] sceneID in
            self?.handleSceneLoaded(sceneID: sceneID)
        }
        bridge.onLoadFailed = { [weak self] error in
            self?.handleLoadFailed(error)
        }
        bridge.onError = { [weak self] error in
            self?.handleBridgeError(error)
        }
        bridge.onDiagnostic = { [weak self] diagnostic in
            self?.onProgress?("\(diagnostic.kind): \(diagnostic.message)")
            Logger.info("WPE-WebGL [\(diagnostic.kind)]: \(diagnostic.message)", category: .screenManager)
        }
        bridge.onFrame = { [weak self] info in
            self?.frameCount = info.frameIndex
            self?.hasPresentedFrame = true
        }
    }

    func load() async throws {
        try await runLoad(isReload: false)
    }

    func reload() async throws {
        bridge.unloadCurrentScene()
        didReceiveReady = false
        didReceiveSceneLoaded = false
        loadedRenderGraph = nil
        preparedRenderPipeline = nil
        assetProvider = nil
        hasPresentedFrame = false
        try await runLoad(isReload: true)
    }

    private func runLoad(isReload: Bool) async throws {
        do {
            try await loadInternal(isReload: isReload)
            loadDiagnostics = nil
        } catch {
            if loadDiagnostics == nil {
                loadDiagnostics = diagnostic(for: error)
            }
            assetSchemeHandler.setActive(nonce: nil, provider: nil)
            assetProvider = nil
            throw error
        }
    }

    private func loadInternal(isReload: Bool) async throws {
        let nonce = UUID().uuidString
        sessionNonce = nonce
        didReceiveSceneLoaded = false
        assetSchemeHandler.setActive(nonce: nonce, provider: nil)

        resolutionTracer.reset()
        try Task.checkCancellation()
        loadDiagnostics = nil
        onProgress?("Loading WebGL runtime…")

        guard let entryURL = URL(string: "\(WPERuntimeSchemeHandler.scheme)://\(WPERuntimeSchemeHandler.host)/\(WPERuntimeSchemeHandler.indexPath)") else {
            throw SceneRenderingError.parseFailed("Invalid runtime URL")
        }

        let request = URLRequest(url: entryURL)
        webView.load(request)

        try await waitForReady()

        onProgress?("Reading scene")
        try Task.checkCancellation()
        let entryURLResolved = try entryResolver.resolveExistingFileURL(relativePath: descriptor.entryFile)
        let document = try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: entryURLResolved)
            return try WPESceneDocumentParser.parse(data: data)
        }.value
        try Task.checkCancellation()

        onProgress?("Building render graph")
        let cacheRoot = cacheRootURL
        let mounts = dependencyMounts
        let engineRoot = engineAssetsRootURL
        let tracer = resolutionTracer
        let graph = try await Task.detached(priority: .userInitiated) {
            try WPERenderGraphBuilder(
                cacheRootURL: cacheRoot,
                dependencyMounts: mounts,
                engineAssetsRootURL: engineRoot,
                tracer: tracer
            ).build(document: document)
        }.value
        try Task.checkCancellation()

        onProgress?("Preparing render pipeline")
        let pipeline = try await Task.detached(priority: .userInitiated) {
            try WPERenderPipelineBuilder(
                cacheRootURL: cacheRoot,
                engineAssetsRootURL: engineRoot,
                tracer: tracer
            ).build(graph: graph)
        }.value
        try Task.checkCancellation()

        let projection = document.general.orthogonalProjection
        let sceneSize = CGSize(
            width: max(projection.width, 1),
            height: max(projection.height, 1)
        )
        loadedRenderGraph = graph
        preparedRenderPipeline = pipeline

        let assetResolver = WPEMultiRootResourceResolver(
            primaryRootURL: cacheRoot,
            dependencyMounts: mounts,
            engineAssetsRootURL: engineRoot,
            tracer: tracer
        )
        let provider = WPEWebGLAssetProvider(resolver: assetResolver)
        assetProvider = provider
        assetSchemeHandler.setActive(nonce: nonce, provider: provider)

        let envelope = WPEPipelineEnvelope(
            sceneID: descriptor.workshopID,
            sceneTitle: nil,
            assetScheme: WPEAssetSchemeBinding(
                nonce: nonce,
                urlPrefix: "\(WPEAssetSchemeHandler.scheme)://\(WPEAssetSchemeHandler.host)/\(nonce)/"
            ),
            renderGraph: WPERenderGraphPayload(
                prepared: pipeline,
                sceneSize: sceneSize,
                projection: projection
            )
        )
        bridge.loadScene(envelope)

        try await waitForSceneLoaded()

        if isReload {
            onProgress?("Reloaded.")
        }
    }

    private func diagnostic(for error: any Error) -> SceneLoadDiagnostic {
        switch error {
        case let sceneError as SceneRenderingError:
            switch sceneError {
            case .cacheRootMissing:
                return .fileMissing(layer: "scene", path: descriptor.cacheRelativePath)
            case .parseFailed(let detail):
                return .other(layer: "scene", message: detail)
            case .resourceFailed(let diagnostic):
                return diagnostic
            }
        case let resolveError as SceneResourceResolver.ResolveError:
            switch resolveError {
            case .fileMissing:
                return .fileMissing(layer: "scene", path: descriptor.entryFile)
            case .pathEscape:
                return .crossPackageReference(layer: "scene", path: descriptor.entryFile)
            case .materialUnresolved(let reason):
                return .materialUnresolved(layer: "scene", reason: reason)
            case .texture(let texError):
                return .texture(layer: "scene", error: texError)
            case .unsupportedTexture:
                return .legacyUnsupportedTexture(layer: "scene")
            case .decodeFailed:
                return .other(layer: "scene", message: "A texture or image file is corrupted and cannot be decoded.")
            }
        case let graphError as WPERenderGraphError:
            switch graphError {
            case .fileMissing(let path):
                return .fileMissing(layer: "scene", path: path)
            case .materialUnresolved(let path):
                return .materialUnresolved(layer: "scene", reason: path)
            case .invalidJSON, .malformedMaterial, .malformedEffect:
                return .other(layer: "scene", message: graphError.errorDescription ?? graphError.localizedDescription)
            }
        case let pipelineError as WPERenderPipelineError:
            switch pipelineError {
            case .shaderMissing(_, _, let path):
                return .fileMissing(layer: "scene", path: path)
            case .includeMissing(let path, _):
                return .fileMissing(layer: "scene", path: path)
            case .includeCycle, .invalidSourceEncoding:
                return .other(layer: "scene", message: pipelineError.errorDescription ?? pipelineError.localizedDescription)
            }
        default:
            return .other(layer: "scene", message: error.localizedDescription)
        }
    }

    private func waitForReady() async throws {
        if didReceiveReady { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            self.readyContinuation = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.readyTimeoutSeconds * 1_000_000_000))
                guard let self, let pending = self.readyContinuation else { return }
                self.readyContinuation = nil
                pending.resume(throwing: SceneRenderingError.parseFailed(
                    "WebGL runtime did not signal ready within \(Int(Self.readyTimeoutSeconds))s"
                ))
            }
        }
    }

    private func waitForSceneLoaded() async throws {
        if didReceiveSceneLoaded { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            self.sceneLoadContinuation = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.sceneLoadTimeoutSeconds * 1_000_000_000))
                guard let self, let pending = self.sceneLoadContinuation else { return }
                self.sceneLoadContinuation = nil
                pending.resume(throwing: SceneRenderingError.parseFailed(
                    "WebGL runtime did not acknowledge scene load within \(Int(Self.sceneLoadTimeoutSeconds))s"
                ))
            }
        }
    }

    private func handleReady(sceneID: String?) {
        didReceiveReady = true
        readyContinuation?.resume()
        readyContinuation = nil
        onProgress?("Runtime ready.")
    }

    private func handleSceneLoaded(sceneID: String?) {
        didReceiveSceneLoaded = true
        sceneLoadContinuation?.resume()
        sceneLoadContinuation = nil
    }

    private func handleLoadFailed(_ error: WPEWebGLBridgeError) {
        let diagnostic: SceneLoadDiagnostic = .other(
            layer: error.passID ?? error.stage,
            message: "WebGL load failed [\(error.stage)]: \(error.message)"
        )
        loadDiagnostics = diagnostic
        Logger.warning("WPE-WebGL load_failed [\(error.stage)] pass=\(error.passID ?? "nil"): \(error.message)", category: .screenManager)
        if let continuation = sceneLoadContinuation {
            sceneLoadContinuation = nil
            continuation.resume(throwing: SceneRenderingError.resourceFailed(diagnostic))
        }
    }

    private func handleBridgeError(_ error: WPEWebGLBridgeError) {
        let layer = error.passID ?? error.stage
        let diagnostic: SceneLoadDiagnostic = .other(
            layer: layer,
            message: "WebGL runtime [\(error.stage)]: \(error.message)"
        )
        loadDiagnostics = diagnostic
        Logger.warning("WPE-WebGL error [\(error.stage)] pass=\(error.passID ?? "nil"): \(error.message)", category: .screenManager)
        if let continuation = readyContinuation {
            readyContinuation = nil
            continuation.resume(throwing: SceneRenderingError.resourceFailed(diagnostic))
            return
        }
        if let continuation = sceneLoadContinuation {
            sceneLoadContinuation = nil
            continuation.resume(throwing: SceneRenderingError.resourceFailed(diagnostic))
        }
    }

    func setThrottled(_ throttled: Bool) {
        isThrottledFlag = throttled
        let payload = WPERuntimeStatePayload(
            time: 0,
            pointer: nil,
            audioSpectrum: nil,
            visibility: throttled ? .occluded : .active
        )
        bridge.push(payload)
    }

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        currentProfile = profile
        let visibility: WPERuntimeStatePayload.WPEVisibility = profile == .suspended ? .background : .active
        let payload = WPERuntimeStatePayload(
            time: 0,
            pointer: nil,
            audioSpectrum: nil,
            visibility: visibility
        )
        bridge.push(payload)
    }

    func cleanup() {
        bridge.unloadCurrentScene()
        webView.evaluateJavaScript("""
        (function () {
          try {
            var c = document.getElementById('wpe-canvas');
            var g = c && c.getContext && c.getContext('webgl2');
            var ext = g && g.getExtension('WEBGL_lose_context');
            if (ext) ext.loseContext();
          } catch (e) {}
        })();
        """, completionHandler: nil)
        if let continuation = readyContinuation {
            readyContinuation = nil
            continuation.resume(throwing: CancellationError())
        }
        if let continuation = sceneLoadContinuation {
            sceneLoadContinuation = nil
            continuation.resume(throwing: CancellationError())
        }
        assetSchemeHandler.setActive(nonce: nil, provider: nil)
        assetProvider = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: WPEWebGLBridge.messageHandlerName
        )
        bridge.onReady = nil
        bridge.onSceneLoaded = nil
        bridge.onLoadFailed = nil
        bridge.onError = nil
        bridge.onDiagnostic = nil
        bridge.onFrame = nil
        bridge.onReadback = nil
        bridge.webView = nil
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        let scheme = url.scheme?.lowercased()
        let host = url.host?.lowercased()
        if scheme == WPERuntimeSchemeHandler.scheme && host == WPERuntimeSchemeHandler.host {
            decisionHandler(.allow)
        } else {
            Logger.warning("WPE WebGL blocked navigation to \(url.absoluteString)", category: .screenManager)
            decisionHandler(.cancel)
        }
    }
}
#endif
