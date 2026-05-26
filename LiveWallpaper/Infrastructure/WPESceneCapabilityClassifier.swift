#if !LITE_BUILD
import Foundation

/// Resource-availability gate run at scene import time. Resolves every
/// declared image layer through the same multi-root chain the runtime uses
/// (primary cache → bundled built-ins → engine-assets fallback) and
/// classifies the project as:
///
/// - `.unsupported` — no image objects at all, or every declared layer is
///   unresolvable through any mount. The import service refuses to mount
///   such projects so the user sees the failure at import time.
/// - `.imageOnly` — every declared layer resolves AND no blocking parser
///   diagnostics. The renderer will likely produce a clean frame.
/// - `.degraded` — at least one declared layer resolves, but some are
///   missing or the parser flagged a non-`.tex` blocking diagnostic. The
///   renderer still mounts and degrades gracefully.
///
/// Coexists with `WPEScenePreflight` (the structural gate covering Windows
/// plugins / runtime-system requirements). Both signals persist on `SceneDescriptor`.
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

    /// Coarse existence probe — does this relative path resolve to a file somewhere in the mount chain?
    private func isReachable(
        _ relativePath: String,
        through resolver: WPEMultiRootResourceResolver
    ) -> Bool {
        guard !relativePath.isEmpty else { return false }
        return (try? resolver.resolveExistingFileURL(relativePath: relativePath)) != nil
    }
}
#endif
