#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperProWPE

struct WPEMultiRootResourceResolver: Sendable {
    private let primary: SceneResourceResolver
    private let dependencyMounts: [String: SceneResourceResolver]
    /// App-bundled clean-room equivalents of the small WPE framework files
    /// (under `wpe-builtins/`). Tried before the optional engine-assets resolver
    /// so most scenes work zero-config on macOS, where WPE isn't installable.
    /// `nil` only when the bundle subtree is unreachable (some unit-test contexts).
    private let builtinResolver: SceneResourceResolver?
    /// Optional read-only fallback rooted at `<engineRoot>/assets/`. Tried only
    /// after the primary AND built-in resolvers miss, so it never shadows a
    /// project's own files.
    private let engineAssetsResolver: SceneResourceResolver?
    private let tracer: WPEResolutionTracer?

    init(
        primaryRootURL: URL,
        dependencyMounts: [WPEAssetMount],
        engineAssetsRootURL: URL? = nil,
        tracer: WPEResolutionTracer? = nil,
        builtinRootURL: URL? = WPEBuiltinFrameworkAssets.rootURL
    ) {
        self.primary = SceneResourceResolver(cacheRootURL: primaryRootURL)
        self.builtinResolver = builtinRootURL.map { SceneResourceResolver(cacheRootURL: $0) }
        self.engineAssetsResolver = engineAssetsRootURL.map {
            SceneResourceResolver(
                cacheRootURL: $0.appendingPathComponent("assets", isDirectory: true)
            )
        }
        self.dependencyMounts = Self.makeMountResolvers(dependencyMounts)
        self.tracer = tracer
    }

    /// Package-backed primary root. Built-ins, engine assets, and dependency
    /// mounts stay directory-backed (they are real on-disk roots).
    init(
        primaryProvider: any WPESceneAssetProvider,
        dependencyMounts: [WPEAssetMount],
        engineAssetsRootURL: URL? = nil,
        tracer: WPEResolutionTracer? = nil,
        builtinRootURL: URL? = WPEBuiltinFrameworkAssets.rootURL
    ) {
        self.primary = SceneResourceResolver(provider: primaryProvider)
        self.builtinResolver = builtinRootURL.map { SceneResourceResolver(cacheRootURL: $0) }
        self.engineAssetsResolver = engineAssetsRootURL.map {
            SceneResourceResolver(
                cacheRootURL: $0.appendingPathComponent("assets", isDirectory: true)
            )
        }
        self.dependencyMounts = Self.makeMountResolvers(dependencyMounts)
        self.tracer = tracer
    }

    /// A package mount that can't be opened is dropped, so its references
    /// resolve as missing rather than crashing.
    private static func makeMountResolvers(_ dependencyMounts: [WPEAssetMount]) -> [String: SceneResourceResolver] {
        var mounts: [String: SceneResourceResolver] = [:]
        for mount in dependencyMounts {
            switch mount.backing {
            case .directory(let rootURL):
                mounts[mount.workshopID] = SceneResourceResolver(cacheRootURL: rootURL)
            case .package(let packageURL):
                if let provider = try? WPEPackageSceneAssetProvider(packageURL: packageURL) {
                    mounts[mount.workshopID] = SceneResourceResolver(provider: provider)
                }
            }
        }
        return mounts
    }

    /// Existence probe across the cascade, without staging or reading bytes —
    /// used by shader-include resolution to pick the right candidate.
    func exists(relativePath: String) -> Bool {
        if let dependency = dependencyReference(relativePath) {
            return dependencyMounts[dependency.workshopID]?.exists(relativePath: dependency.childPath) ?? false
        }
        if primary.exists(relativePath: relativePath) { return true }
        if let builtinResolver, builtinResolver.exists(relativePath: relativePath) { return true }
        if let engineAssetsResolver, engineAssetsResolver.exists(relativePath: relativePath) { return true }
        return false
    }

    /// `optional: true` = best-effort probe whose absence is expected (e.g. the
    /// `.tex-json` sprite-sheet sidecar). A miss is not traced, so it can't inflate
    /// the diagnostic miss list; resolved hits are still recorded.
    func data(relativePath: String, optional: Bool = false) throws -> Data {
        if let dependency = dependencyReference(relativePath) {
            return try resolveDependency(relativePath: relativePath, dependency: dependency, optional: optional) { resolver, path in
                try resolver.data(relativePath: path)
            }
        }
        return try resolveWithFallbacks(relativePath: relativePath, optional: optional) { resolver, path in
            try resolver.data(relativePath: path)
        }
    }

    func resolveImage(relativePath: String) throws -> CGImage {
        if let dependency = dependencyReference(relativePath) {
            return try resolveDependency(relativePath: relativePath, dependency: dependency) { resolver, path in
                try resolver.resolveImage(relativePath: path)
            }
        }
        return try resolveWithFallbacks(relativePath: relativePath) { resolver, path in
            try resolver.resolveImage(relativePath: path)
        }
    }

    func resolveExistingFileURL(relativePath: String) throws -> URL {
        if let dependency = dependencyReference(relativePath) {
            return try resolveDependency(relativePath: relativePath, dependency: dependency) { resolver, path in
                try resolver.resolveExistingFileURL(relativePath: path)
            }
        }
        return try resolveWithFallbacks(relativePath: relativePath) { resolver, path in
            try resolver.resolveExistingFileURL(relativePath: path)
        }
    }

    func resolveTexturePayload(relativePath: String) throws -> WPETexTexturePayload {
        if let dependency = dependencyReference(relativePath) {
            return try resolveDependency(relativePath: relativePath, dependency: dependency) { resolver, path in
                try resolver.resolveTexturePayload(relativePath: path)
            }
        }
        return try resolveWithFallbacks(relativePath: relativePath) { resolver, path in
            try resolver.resolveTexturePayload(relativePath: path)
        }
    }

    func resolveStreamingTexturePayload(relativePath: String) throws -> WPETexStreamingPayload {
        if let dependency = dependencyReference(relativePath) {
            return try resolveDependency(relativePath: relativePath, dependency: dependency) { resolver, path in
                try resolver.resolveStreamingTexturePayload(relativePath: path)
            }
        }
        return try resolveWithFallbacks(relativePath: relativePath) { resolver, path in
            try resolver.resolveStreamingTexturePayload(relativePath: path)
        }
    }

    /// Tries primary first; on `.fileMissing` falls through to app-bundled
    /// built-ins, then to the optional engine-assets resolver.
    private func resolveWithFallbacks<T>(
        relativePath: String,
        optional: Bool = false,
        _ resolve: (SceneResourceResolver, String) throws -> T
    ) throws -> T {
        var attempts: [WPEResolutionAttempt] = []

        do {
            let value = try resolve(primary, relativePath)
            attempts.append(WPEResolutionAttempt(origin: .scene, outcome: .resolved))
            record(relativePath: relativePath, attempts: attempts, finalOutcome: .resolved, optional: optional)
            return value
        } catch SceneResourceResolver.ResolveError.fileMissing {
            attempts.append(WPEResolutionAttempt(origin: .scene, outcome: .fileMissing))
        } catch {
            let outcome = WPEResolutionOutcome.otherError("\(error)")
            attempts.append(WPEResolutionAttempt(origin: .scene, outcome: outcome))
            record(relativePath: relativePath, attempts: attempts, finalOutcome: outcome, optional: optional)
            throw error
        }

        if let builtinResolver {
            do {
                let value = try resolve(builtinResolver, relativePath)
                attempts.append(WPEResolutionAttempt(origin: .builtin, outcome: .resolved))
                record(relativePath: relativePath, attempts: attempts, finalOutcome: .resolved, optional: optional)
                return value
            } catch SceneResourceResolver.ResolveError.fileMissing {
                attempts.append(WPEResolutionAttempt(origin: .builtin, outcome: .fileMissing))
            } catch {
                let outcome = WPEResolutionOutcome.otherError("\(error)")
                attempts.append(WPEResolutionAttempt(origin: .builtin, outcome: outcome))
                record(relativePath: relativePath, attempts: attempts, finalOutcome: outcome, optional: optional)
                throw error
            }
        }

        guard let engineAssetsResolver else {
            record(relativePath: relativePath, attempts: attempts, finalOutcome: .fileMissing, optional: optional)
            throw SceneResourceResolver.ResolveError.fileMissing
        }

        do {
            let value = try resolve(engineAssetsResolver, relativePath)
            attempts.append(WPEResolutionAttempt(origin: .engineAssets, outcome: .resolved))
            record(relativePath: relativePath, attempts: attempts, finalOutcome: .resolved, optional: optional)
            return value
        } catch SceneResourceResolver.ResolveError.fileMissing {
            attempts.append(WPEResolutionAttempt(origin: .engineAssets, outcome: .fileMissing))
            record(relativePath: relativePath, attempts: attempts, finalOutcome: .fileMissing, optional: optional)
            throw SceneResourceResolver.ResolveError.fileMissing
        } catch {
            let outcome = WPEResolutionOutcome.otherError("\(error)")
            attempts.append(WPEResolutionAttempt(origin: .engineAssets, outcome: outcome))
            record(relativePath: relativePath, attempts: attempts, finalOutcome: outcome, optional: optional)
            throw error
        }
    }

    private func resolveDependency<T>(
        relativePath: String,
        dependency: (workshopID: String, childPath: String),
        optional: Bool = false,
        _ resolve: (SceneResourceResolver, String) throws -> T
    ) throws -> T {
        let origin = WPEResolutionOrigin.dependency(dependency.workshopID)
        guard let resolver = dependencyMounts[dependency.workshopID] else {
            let error = SceneResourceResolver.ResolveError.pathEscape
            let outcome = WPEResolutionOutcome.otherError("\(error)")
            record(
                relativePath: relativePath,
                attempts: [WPEResolutionAttempt(origin: origin, outcome: outcome)],
                finalOutcome: outcome,
                optional: optional
            )
            throw error
        }

        do {
            let value = try resolve(resolver, dependency.childPath)
            record(
                relativePath: relativePath,
                attempts: [WPEResolutionAttempt(origin: origin, outcome: .resolved)],
                finalOutcome: .resolved,
                optional: optional
            )
            return value
        } catch SceneResourceResolver.ResolveError.fileMissing {
            record(
                relativePath: relativePath,
                attempts: [WPEResolutionAttempt(origin: origin, outcome: .fileMissing)],
                finalOutcome: .fileMissing,
                optional: optional
            )
            throw SceneResourceResolver.ResolveError.fileMissing
        } catch {
            let outcome = WPEResolutionOutcome.otherError("\(error)")
            record(
                relativePath: relativePath,
                attempts: [WPEResolutionAttempt(origin: origin, outcome: outcome)],
                finalOutcome: outcome,
                optional: optional
            )
            throw error
        }
    }

    private func record(
        relativePath: String,
        attempts: [WPEResolutionAttempt],
        finalOutcome: WPEResolutionOutcome,
        optional: Bool = false
    ) {
        guard let tracer else { return }
        let event = WPEResolutionEvent(ref: relativePath, attempts: attempts, finalOutcome: finalOutcome)
        // Optional probe miss = expected, not a missing asset — don't trace it.
        if optional, finalOutcome != .resolved {
            return
        }
        tracer.record(event)
    }

    private func dependencyReference(_ relativePath: String) -> (workshopID: String, childPath: String)? {
        guard relativePath.hasPrefix("../") else { return nil }
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] == ".." else { return nil }
        return (String(parts[1]), parts.dropFirst(2).joined(separator: "/"))
    }
}
#endif
