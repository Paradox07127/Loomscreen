import Foundation

/// Outcome of a `WallpaperRuntimeFactory.makeSession(...)` call. Lite returns
/// `.unsupported(.productDoesNotSupportType(...))` for `.scene` / `.metalShader`
/// without touching the WPE / Metal stack; Pro returns a fully wired session.
enum WallpaperRuntimeBuildResult {
    case session(any WallpaperRuntimeSession)
    /// Type is allowed by the schema but the running SKU cannot render it.
    /// Distinct from `.invalid` so the UI can show a "Pro feature" hint
    /// rather than a generic error.
    case unsupported(UnsupportedWallpaperReason)
    /// Definition was syntactically valid but the underlying resource is
    /// missing or broken (empty bookmark, malformed scene descriptor, ...).
    case invalid
}

enum UnsupportedWallpaperReason: Sendable, Equatable {
    /// SKU explicitly excludes this wallpaper type (e.g. Lite + `.scene`).
    case productDoesNotSupportType(WallpaperType)
    /// SKU includes the type but the renderer module is absent in this build
    /// (recoverable after install / update).
    case missingRenderer(WallpaperType)
    /// Origin / asset persisted as Pro-only and cannot be opened here.
    case invalidProResource
}

/// Pluggable strategy for materialising a `WallpaperRuntimeSession` from a
/// validated `WallpaperSessionDefinition` (Lite: VideoWeb only; Pro: VideoWeb
/// ∪ ProFeatures ∪ ProWPE).
///
/// The factory does not own the `Screen`'s window or runtime references — it
/// constructs the session value and hands it back to the caller, which stays
/// in charge of lifecycle (`releaseRuntimeSession`, transition tokens, etc.).
@MainActor
protocol WallpaperRuntimeFactory: AnyObject {
    func makeSession(
        for definition: WallpaperSessionDefinition,
        screen: Screen,
        configuration: ScreenConfiguration
    ) -> WallpaperRuntimeBuildResult
}
