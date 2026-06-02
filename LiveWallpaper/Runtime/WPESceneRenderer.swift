#if !LITE_BUILD
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
    /// Per-load snapshot of every asset resolution attempt the renderer
    /// made. Phase A.2 control-variable instrumentation: callers use this
    /// to tell apart pipeline failures from "asset missing" cases.
    var resolutionDiagnostics: WPEResolutionDiagnosticsSnapshot { get }
    /// Static thumbnail of the most recent rendered frame. `nil` until a
    /// frame has been produced. Used by the inspector card to show a
    /// preview without driving a second live render loop.
    var previewSnapshot: NSImage? { get }

    func load() async throws
    func reload() async throws
    func setThrottled(_ throttled: Bool)
    /// Enables or disables cursor reactivity (camera parallax + pointer-driven
    /// shaders). Default no-op so renderers that don't sample the pointer (the
    /// WebGL fallback) don't have to implement it.
    func setMouseInteractionEnabled(_ enabled: Bool)
    func cleanup()
}

extension WPESceneRenderer {
    func setMouseInteractionEnabled(_ enabled: Bool) {}
}

/// Optional capability a scene renderer can adopt to apply project-property
/// changes incrementally (without a full reload). `applyScenePropertyPatch`
/// returns `false` when the patch can't be applied in place — the caller then
/// falls back to the full reload path.
@MainActor
protocol WPEScenePropertyRuntime: AnyObject {
    var scenePropertyBindings: [String: [WPEScenePropertyBinding]] { get }
    func applyScenePropertyPatch(_ patch: WPEScenePropertyPatch) -> Bool
}
#endif
