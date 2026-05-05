import AppKit

enum WPESceneRendererBackend: String, Codable, Equatable, Sendable {
    case spriteKit
    case metalExperimental
}

@MainActor
protocol WPESceneRenderer: AnyObject, WallpaperPerformanceConfigurable {
    var nsView: NSView { get }
    var onProgress: (@MainActor (String) -> Void)? { get set }
    var loadDiagnostics: SceneLoadDiagnostic? { get }
    var renderGraph: WPERenderGraph? { get }
    var renderPipeline: WPEPreparedRenderPipeline? { get }
    var hasPresentedFrame: Bool { get }

    func load() async throws
    func reload() async throws
    func setThrottled(_ throttled: Bool)
    func cleanup()
}
