#if !LITE_BUILD
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
        var mounts: [String: SceneResourceResolver] = [:]
        for mount in dependencyMounts {
            mounts[mount.workshopID] = SceneResourceResolver(cacheRootURL: mount.rootURL)
        }
        self.dependencyMounts = mounts
        self.tracer = tracer
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

    /// Tries the primary resolver first; on `.fileMissing` falls through to the app-bundled built-ins, then to the optional engine-assets resolver.
    private func resolveWithFallbacks<T>(
        relativePath: String,
        _ resolve: (SceneResourceResolver, String) throws -> T
    ) throws -> T {
        var attempts: [WPEResolutionAttempt] = []

        do {
            let value = try resolve(primary, relativePath)
            attempts.append(WPEResolutionAttempt(origin: .scene, outcome: .resolved))
            record(relativePath: relativePath, attempts: attempts, finalOutcome: .resolved)
            return value
        } catch SceneResourceResolver.ResolveError.fileMissing {
            attempts.append(WPEResolutionAttempt(origin: .scene, outcome: .fileMissing))
        } catch {
            let outcome = WPEResolutionOutcome.otherError("\(error)")
            attempts.append(WPEResolutionAttempt(origin: .scene, outcome: outcome))
            record(relativePath: relativePath, attempts: attempts, finalOutcome: outcome)
            throw error
        }

        if let builtinResolver {
            do {
                let value = try resolve(builtinResolver, relativePath)
                attempts.append(WPEResolutionAttempt(origin: .builtin, outcome: .resolved))
                record(relativePath: relativePath, attempts: attempts, finalOutcome: .resolved)
                return value
            } catch SceneResourceResolver.ResolveError.fileMissing {
                attempts.append(WPEResolutionAttempt(origin: .builtin, outcome: .fileMissing))
            } catch {
                let outcome = WPEResolutionOutcome.otherError("\(error)")
                attempts.append(WPEResolutionAttempt(origin: .builtin, outcome: outcome))
                record(relativePath: relativePath, attempts: attempts, finalOutcome: outcome)
                throw error
            }
        }

        guard let engineAssetsResolver else {
            record(relativePath: relativePath, attempts: attempts, finalOutcome: .fileMissing)
            throw SceneResourceResolver.ResolveError.fileMissing
        }

        do {
            let value = try resolve(engineAssetsResolver, relativePath)
            attempts.append(WPEResolutionAttempt(origin: .engineAssets, outcome: .resolved))
            record(relativePath: relativePath, attempts: attempts, finalOutcome: .resolved)
            return value
        } catch SceneResourceResolver.ResolveError.fileMissing {
            attempts.append(WPEResolutionAttempt(origin: .engineAssets, outcome: .fileMissing))
            record(relativePath: relativePath, attempts: attempts, finalOutcome: .fileMissing)
            throw SceneResourceResolver.ResolveError.fileMissing
        } catch {
            let outcome = WPEResolutionOutcome.otherError("\(error)")
            attempts.append(WPEResolutionAttempt(origin: .engineAssets, outcome: outcome))
            record(relativePath: relativePath, attempts: attempts, finalOutcome: outcome)
            throw error
        }
    }

    private func resolveDependency<T>(
        relativePath: String,
        dependency: (workshopID: String, childPath: String),
        _ resolve: (SceneResourceResolver, String) throws -> T
    ) throws -> T {
        let origin = WPEResolutionOrigin.dependency(dependency.workshopID)
        guard let resolver = dependencyMounts[dependency.workshopID] else {
            let error = SceneResourceResolver.ResolveError.pathEscape
            let outcome = WPEResolutionOutcome.otherError("\(error)")
            record(
                relativePath: relativePath,
                attempts: [WPEResolutionAttempt(origin: origin, outcome: outcome)],
                finalOutcome: outcome
            )
            throw error
        }

        do {
            let value = try resolve(resolver, dependency.childPath)
            record(
                relativePath: relativePath,
                attempts: [WPEResolutionAttempt(origin: origin, outcome: .resolved)],
                finalOutcome: .resolved
            )
            return value
        } catch SceneResourceResolver.ResolveError.fileMissing {
            record(
                relativePath: relativePath,
                attempts: [WPEResolutionAttempt(origin: origin, outcome: .fileMissing)],
                finalOutcome: .fileMissing
            )
            throw SceneResourceResolver.ResolveError.fileMissing
        } catch {
            let outcome = WPEResolutionOutcome.otherError("\(error)")
            record(
                relativePath: relativePath,
                attempts: [WPEResolutionAttempt(origin: origin, outcome: outcome)],
                finalOutcome: outcome
            )
            throw error
        }
    }

    private func record(
        relativePath: String,
        attempts: [WPEResolutionAttempt],
        finalOutcome: WPEResolutionOutcome
    ) {
        guard let tracer else { return }
        let event = WPEResolutionEvent(ref: relativePath, attempts: attempts, finalOutcome: finalOutcome)
        tracer.record(event)
        emitVerboseLog(event)
    }

    private func emitVerboseLog(_ event: WPEResolutionEvent) {
        guard UserDefaults.standard.bool(forKey: "wpeVerboseResolverLogging") else { return }
        let chain = event.attempts
            .map { "\($0.origin.debugLabel)=\($0.outcome.debugLabel)" }
            .joined(separator: " -> ")
        Logger.debug(
            "resolve '\(event.ref)': \(chain); final=\(event.finalOutcome.debugLabel)",
            category: .wpeResolver
        )
    }

    private func dependencyReference(_ relativePath: String) -> (workshopID: String, childPath: String)? {
        guard relativePath.hasPrefix("../") else { return nil }
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] == ".." else { return nil }
        return (String(parts[1]), parts.dropFirst(2).joined(separator: "/"))
    }
}
#endif
