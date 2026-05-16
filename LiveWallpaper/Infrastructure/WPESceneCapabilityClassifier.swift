#if !LITE_BUILD
import Foundation

/// Resource-availability gate run at scene import time. Resolves every
/// declared image layer through the same multi-root chain the runtime uses
/// (primary cache → bundled built-ins → engine-assets fallback) and
/// classifies the project as:
///
/// - `.unsupported` — no image objects at all, or every declared layer is
///   unresolvable through any mount. The import service refuses to mount
///   such projects so the user sees the failure at import time instead of
///   after they try to apply the wallpaper.
/// - `.imageOnly` — every declared layer resolves AND no blocking parser
///   diagnostics. The renderer will likely produce a clean frame.
/// - `.degraded` — at least one declared layer resolves, but some are
///   missing or the parser flagged a non-`.tex` blocking diagnostic. The
///   renderer still mounts and degrades gracefully for the missing layers.
///
/// The name is historical — this classifier predates `WPEScenePreflight`
/// (which mints feature-flag-based capability tiers). It now coexists as
/// the *resource-availability* gate; preflight stays as the *structural*
/// gate (Windows plugin, runtime-system requirements). Both signals are
/// persisted on `SceneDescriptor`.
struct WPESceneCapabilityClassifier: Sendable {
    func capabilityTier(
        for document: WPESceneDocument,
        cacheURL: URL,
        dependencyMounts: [WPEAssetMount] = [],
        engineAssetsRootURL: URL? = nil
    ) -> SceneCapabilityTier {
        guard !document.imageObjects.isEmpty else {
            return .unsupported
        }

        // Match the runtime's multi-root chain so the import gate doesn't
        // false-reject scenes that reference our bundled framework assets
        // (`models/util/*`, `materials/util/*`, water-effect noise PNGs) or
        // dependency-mounted workshop addons.
        let resolver = WPEMultiRootResourceResolver(
            primaryRootURL: cacheURL,
            dependencyMounts: dependencyMounts,
            engineAssetsRootURL: engineAssetsRootURL
        )
        var resolvable = 0
        var unresolvable = 0
        for object in document.imageObjects {
            if isReachable(object.imageRelativePath, through: resolver) {
                resolvable += 1
            } else {
                unresolvable += 1
            }
        }

        if resolvable == 0 { return .unsupported }
        let blockingDiagnostics = document.diagnostics.filter { diagnostic in
            !diagnostic.message.contains(".tex texture")
        }
        if unresolvable == 0 && blockingDiagnostics.isEmpty {
            return .imageOnly
        }
        return .degraded
    }

    /// Coarse existence probe — does this relative path resolve to a file
    /// somewhere in the mount chain? The runtime is responsible for the
    /// `models/util/X.json → materials/util/X.json → terminal.tex` JSON
    /// chain walk and graceful degradation when intermediate refs miss; the
    /// classifier just answers "is there anywhere this object's image
    /// pointer can land?". A `false` here means the scene has zero hope of
    /// even starting that chain — that's the precise condition the gate
    /// rejects on.
    private func isReachable(
        _ relativePath: String,
        through resolver: WPEMultiRootResourceResolver
    ) -> Bool {
        guard !relativePath.isEmpty else { return false }
        return (try? resolver.resolveExistingFileURL(relativePath: relativePath)) != nil
    }
}
#endif
