import CoreGraphics
import Foundation
import ImageIO

/// Resource resolver for `.scene` content. Reads PNG/JPG via ImageIO and
/// `.tex` via the Phase 2.1 `WPETexDecoder`. Path safety mirrors the WPE
/// folder scheme handler — every relative path is standardized + symlink-
/// resolved and rejected if it escapes the cache root.
///
/// Phase 2.1: `.tex` no longer auto-fails. The decoder routes by container
/// version + format enum; only genuinely unsupported formats (RGBA1010102,
/// unknown V6+ containers, animation frames) surface as precise errors.
struct SceneResourceResolver: Sendable {
    enum ResolveError: Error, Equatable, Sendable {
        case pathEscape
        case fileMissing
        case decodeFailed
        case unsupportedTexture                          // legacy alias
        case texture(WPETexDecodeError)
    }

    let cacheRootURL: URL
    private let decoder: WPETexDecoder

    init(cacheRootURL: URL, decoder: WPETexDecoder = WPETexDecoder()) {
        // Standardize once so subsequent prefix checks are stable.
        self.cacheRootURL = cacheRootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.decoder = decoder
    }

    /// Single point where the resolver touches the filesystem. Pulled out as
    /// a computed property so the struct stays `Sendable` (FileManager is
    /// not Sendable, and storing one as a property is a hard error in
    /// strict-concurrency mode).
    private var fileManager: FileManager { .default }

    /// Returns a CGImage decoded from the cache. The returned image is
    /// independent of the source file handle so the caller can hold it as
    /// long as needed.
    ///
    /// `.tex` files are routed through `WPETexDecoder`; PNG / JPG / GIF go
    /// through ImageIO. Decode failures for `.tex` surface as
    /// `.texture(WPETexDecodeError)` so the UI can map them to a precise
    /// FallbackReason. Decode failures for other extensions stay on
    /// `.decodeFailed` to match Phase 2.0 contracts.
    func resolveImage(relativePath: String) throws -> CGImage {
        guard !relativePath.isEmpty else { throw ResolveError.fileMissing }
        let target = try resolveURL(for: relativePath)

        guard fileManager.fileExists(atPath: target.path) else {
            throw ResolveError.fileMissing
        }

        let lowered = target.pathExtension.lowercased()
        if lowered == "tex" {
            let payload: Data
            do {
                payload = try Data(contentsOf: target)
            } catch {
                throw ResolveError.fileMissing
            }
            switch decoder.decode(data: payload) {
            case .success(let image):
                return image
            case .failure(let error):
                throw ResolveError.texture(error)
            }
        }

        guard let source = CGImageSourceCreateWithURL(target as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ResolveError.decodeFailed
        }
        return image
    }

    /// Cheap header-only probe used by `WallpaperEngineImportService` during
    /// capability tier classification. We read only the first 64 bytes —
    /// enough to cover TEXV (9) + TEXI magic (9) + every field the V3 info
    /// block exposes (28 bytes) — so import scanning a 100 MB / 50-layer
    /// scene.pkg doesn't churn memory mapping every payload.
    func probeImage(relativePath: String) -> Result<WPETexInfo, ResolveError> {
        guard !relativePath.isEmpty else { return .failure(.fileMissing) }
        let target: URL
        do {
            target = try resolveURL(for: relativePath)
        } catch let error as ResolveError {
            return .failure(error)
        } catch {
            return .failure(.fileMissing)
        }
        guard fileManager.fileExists(atPath: target.path) else {
            return .failure(.fileMissing)
        }
        let lowered = target.pathExtension.lowercased()
        guard lowered == "tex" else {
            return .failure(.unsupportedTexture)
        }
        let header: Data
        do {
            let handle = try FileHandle(forReadingFrom: target)
            defer { try? handle.close() }
            header = (try handle.read(upToCount: Self.texProbeByteLimit)) ?? Data()
        } catch {
            return .failure(.fileMissing)
        }
        switch decoder.probe(data: header) {
        case .success(let info):
            return .success(info)
        case .failure(let error):
            return .failure(.texture(error))
        }
    }

    /// Worst-case header size: 9 (TEXV) + 9 (TEXI) + 7×4 (V3 fields) = 46.
    /// Round up to 64 for safety.
    private static let texProbeByteLimit = 64

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
