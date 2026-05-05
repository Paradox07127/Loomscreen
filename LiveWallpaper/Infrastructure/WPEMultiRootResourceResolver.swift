import CoreGraphics
import Foundation

struct WPEMultiRootResourceResolver: Sendable {
    private let primary: SceneResourceResolver
    private let dependencyMounts: [String: SceneResourceResolver]

    init(primaryRootURL: URL, dependencyMounts: [WPEAssetMount]) {
        self.primary = SceneResourceResolver(cacheRootURL: primaryRootURL)
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
        return try primary.resolveImage(relativePath: relativePath)
    }

    func resolveExistingFileURL(relativePath: String) throws -> URL {
        if let dependency = dependencyReference(relativePath) {
            guard let resolver = dependencyMounts[dependency.workshopID] else {
                throw SceneResourceResolver.ResolveError.pathEscape
            }
            return try resolver.resolveExistingFileURL(relativePath: dependency.childPath)
        }
        return try primary.resolveExistingFileURL(relativePath: relativePath)
    }

    func resolveTexturePayload(relativePath: String) throws -> WPETexTexturePayload {
        if let dependency = dependencyReference(relativePath) {
            guard let resolver = dependencyMounts[dependency.workshopID] else {
                throw SceneResourceResolver.ResolveError.pathEscape
            }
            return try resolver.resolveTexturePayload(relativePath: dependency.childPath)
        }
        return try primary.resolveTexturePayload(relativePath: relativePath)
    }

    private func dependencyReference(_ relativePath: String) -> (workshopID: String, childPath: String)? {
        guard relativePath.hasPrefix("../") else { return nil }
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] == ".." else { return nil }
        return (String(parts[1]), parts.dropFirst(2).joined(separator: "/"))
    }
}
