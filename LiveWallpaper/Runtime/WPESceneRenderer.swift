import AppKit

/// Renderer-agnostic boundary the scene wallpaper pipeline talks to.
/// Currently always satisfied by `WPEMetalSceneRenderer`; the protocol stays
/// in place so the runtime + test code can hold a type-erased reference
/// without naming the concrete renderer.
@MainActor
protocol WPESceneRenderer: AnyObject, WallpaperPerformanceConfigurable {
    var nsView: NSView { get }
    var onProgress: (@MainActor (String) -> Void)? { get set }
    var loadDiagnostics: SceneLoadDiagnostic? { get }
    var renderGraph: WPERenderGraph? { get }
    var renderPipeline: WPEPreparedRenderPipeline? { get }
    var hasPresentedFrame: Bool { get }
    /// Static thumbnail of the most recent rendered frame. `nil` until a
    /// frame has been produced. Used by the inspector card to show a
    /// preview without driving a second live render loop.
    var previewSnapshot: NSImage? { get }

    func load() async throws
    func reload() async throws
    func setThrottled(_ throttled: Bool)
    func cleanup()
}
