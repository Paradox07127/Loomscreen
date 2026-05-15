import CoreGraphics
import Foundation

struct WPEMultiRootResourceResolver: Sendable {
    private let primary: SceneResourceResolver
    private let dependencyMounts: [String: SceneResourceResolver]
    /// App-bundled clean-room equivalents of the small WPE framework files
    /// (~68 KB across 15 files under `wpe-builtins/`). Tried before the
    /// optional engine-assets resolver so most scenes work zero-config on
    /// macOS, where WPE isn't installable. `nil` only when the bundle
    /// subtree is unreachable (some unit-test contexts).
    private let builtinResolver: SceneResourceResolver?
    /// Optional read-only fallback rooted at `<engineRoot>/assets/`. Tried
    /// only after the primary AND built-in resolvers miss — so it covers
    /// the rare scene that references files outside our built-in inventory
    /// without ever shadowing a project's own files.
    private let engineAssetsResolver: SceneResourceResolver?

    init(
        primaryRootURL: URL,
        dependencyMounts: [WPEAssetMount],
        engineAssetsRootURL: URL? = nil
    ) {
        self.primary = SceneResourceResolver(cacheRootURL: primaryRootURL)
        self.builtinResolver = WPEBuiltinFrameworkAssets.makeResolver()
        self.engineAssetsResolver = engineAssetsRootURL.map {
            SceneResourceResolver(
                cacheRootURL: $0.appendingPathComponent("assets", isDirectory: true)
            )
        }
        var mounts: [String: SceneResourceResolver] = [:]
        for mount in dependencyMounts {
            mounts[mount.workshopID] = SceneResourceResolver(cacheRootURL: mount.rootURL)
        }
        self.dependencyMounts = mounts
    }

    func resolveImage(relativePath: String) throws -> CGImage {
        if let dependency = dependencyReference(relativePath) {
            guard let resolver = dependencyMounts[dependency.workshopID] else {
                throw SceneResourceResolver.ResolveError.pathEscape
            }
            return try resolver.resolveImage(relativePath: dependency.childPath)
        }
        return try resolveWithFallbacks(relativePath: relativePath) { resolver, path in
            try resolver.resolveImage(relativePath: path)
        }
    }

    func resolveExistingFileURL(relativePath: String) throws -> URL {
        if let dependency = dependencyReference(relativePath) {
            guard let resolver = dependencyMounts[dependency.workshopID] else {
                throw SceneResourceResolver.ResolveError.pathEscape
            }
            return try resolver.resolveExistingFileURL(relativePath: dependency.childPath)
        }
        return try resolveWithFallbacks(relativePath: relativePath) { resolver, path in
            try resolver.resolveExistingFileURL(relativePath: path)
        }
    }

    func resolveTexturePayload(relativePath: String) throws -> WPETexTexturePayload {
        if let dependency = dependencyReference(relativePath) {
            guard let resolver = dependencyMounts[dependency.workshopID] else {
                throw SceneResourceResolver.ResolveError.pathEscape
            }
            return try resolver.resolveTexturePayload(relativePath: dependency.childPath)
        }
        return try resolveWithFallbacks(relativePath: relativePath) { resolver, path in
            try resolver.resolveTexturePayload(relativePath: path)
        }
    }

    /// Tries the primary resolver first; on `.fileMissing` falls through to
    /// the app-bundled built-ins, then to the optional engine-assets
    /// resolver. Other `ResolveError` cases (`.pathEscape`,
    /// `.materialUnresolved`, `.texture`, …) propagate without retry —
    /// another root can't fix a malformed path or a project's broken JSON
    /// chain.
    private func resolveWithFallbacks<T>(
        relativePath: String,
        _ resolve: (SceneResourceResolver, String) throws -> T
    ) throws -> T {
        do {
            return try resolve(primary, relativePath)
        } catch SceneResourceResolver.ResolveError.fileMissing {
            // Continue to the built-in resolver below.
        }

        if let builtinResolver {
            do {
                return try resolve(builtinResolver, relativePath)
            } catch SceneResourceResolver.ResolveError.fileMissing {
                // Continue to the optional engine-assets resolver below.
            }
        }

        guard let engineAssetsResolver else {
            throw SceneResourceResolver.ResolveError.fileMissing
        }
        return try resolve(engineAssetsResolver, relativePath)
    }

    private func dependencyReference(_ relativePath: String) -> (workshopID: String, childPath: String)? {
        guard relativePath.hasPrefix("../") else { return nil }
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] == ".." else { return nil }
        return (String(parts[1]), parts.dropFirst(2).joined(separator: "/"))
    }
}
