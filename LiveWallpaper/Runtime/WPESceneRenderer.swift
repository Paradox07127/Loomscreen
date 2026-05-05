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
    /// Static thumbnail of the most recent rendered frame. `nil` until a
    /// frame has been produced. SpriteKit reads back via
    /// `bitmapImageRepForCachingDisplay`; Metal returns the cached snapshot
    /// produced by Task 5 in Phase 2B.
    var previewSnapshot: NSImage? { get }

    func load() async throws
    func reload() async throws
    func setThrottled(_ throttled: Bool)
    func cleanup()
}
