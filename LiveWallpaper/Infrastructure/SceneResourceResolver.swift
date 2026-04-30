import CoreGraphics
import Foundation
import ImageIO

/// Phase 2.0 resource resolver for `.scene` content. Reads images out of the
/// extracted cache root using `ImageIO`. Path safety mirrors the WPE folder
/// scheme handler — every relative path is standardized + symlink-resolved
/// and rejected if it escapes the cache root.
///
/// `.tex` is a Wallpaper Engine binary texture format that Phase 2.0 does
/// not parse yet. `resolveImage(...)` will throw `.unsupportedTexture` so
/// the import service can flag the scene as `degraded`/`unsupported` and the
/// runtime can render the scene minus that layer instead of crashing.
struct SceneResourceResolver: Sendable {
    enum ResolveError: Error, Equatable, Sendable {
        case pathEscape
        case fileMissing
        case decodeFailed
        case unsupportedTexture
    }

    let cacheRootURL: URL

    init(cacheRootURL: URL) {
        // Standardize once so subsequent prefix checks are stable.
        self.cacheRootURL = cacheRootURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Single point where the resolver touches the filesystem. Pulled out as
    /// a computed property so the struct stays `Sendable` (FileManager is
    /// not Sendable, and storing one as a property is a hard error in
    /// strict-concurrency mode).
    private var fileManager: FileManager { .default }

    /// Returns a CGImage decoded from the cache. The returned image is
    /// independent of the source file handle so the caller can hold it as
    /// long as needed.
    func resolveImage(relativePath: String) throws -> CGImage {
        guard !relativePath.isEmpty else { throw ResolveError.fileMissing }
        let target = try resolveURL(for: relativePath)

        let lowered = target.pathExtension.lowercased()
        if lowered == "tex" {
            // Phase 2.0 stub: surface as unsupported so the caller picks a
            // policy (skip layer / show fallback). 2.1 will add a real .tex
            // first-frame extractor.
            throw ResolveError.unsupportedTexture
        }

        guard fileManager.fileExists(atPath: target.path) else {
            throw ResolveError.fileMissing
        }

        guard let source = CGImageSourceCreateWithURL(target as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ResolveError.decodeFailed
        }
        return image
    }

    /// File existence probe used by tests + the import service to decide
    /// whether a scene's declared image layers are actually shipped.
    func exists(relativePath: String) -> Bool {
        (try? resolveExistingFileURL(relativePath: relativePath)) != nil
    }

    /// Validates `relativePath`, joins it onto the cache root, and confirms
    /// the result is a regular file inside the cache. Used by callers that
    /// need a safe URL up-front (e.g. `SceneRenderingController.load()` for
    /// the entry file safety probe). Throws `.fileMissing` for both missing
    /// files and directory hits so callers don't accidentally try to read
    /// a directory as data.
    func resolveExistingFileURL(relativePath: String) throws -> URL {
        let url = try resolveURL(for: relativePath)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw ResolveError.fileMissing
        }
        return url
    }

    /// Standardize the candidate URL and verify it falls under cache root.
    /// Mirrors `FolderURLSchemeHandler` and `WPECachedContentResolver`.
    private func resolveURL(for relativePath: String) throws -> URL {
        // Component-level guard so a tampered relativePath cannot smuggle
        // `..` or absolute segments past the textual check that misses
        // mid-path components.
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        if relativePath.hasPrefix("/")
            || relativePath.contains("\\")
            || components.contains("..")
            || components.contains(".")
            || components.contains("") {
            throw ResolveError.pathEscape
        }

        let resolved = cacheRootURL
            .appendingPathComponent(relativePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        let rootPath = cacheRootURL.path
        let resolvedPath = resolved.path
        guard resolvedPath == rootPath || resolvedPath.hasPrefix(rootPath + "/") else {
            throw ResolveError.pathEscape
        }
        return resolved
    }
}
