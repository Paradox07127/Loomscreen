#if !LITE_BUILD
import CoreGraphics
import Foundation
import ImageIO

/// Resource resolver for `.scene` content. Reads PNG/JPG via ImageIO and
/// `.tex` via the Phase 2.1 `WPETexDecoder`. Path safety mirrors the WPE
/// folder scheme handler — every relative path is standardized + symlink-
/// resolved and rejected if it escapes the cache root.
///
/// Phase 2.1: `.tex` no longer auto-fails. The decoder routes by container
/// version + format enum; unsupported BC formats, RGBA1010102, unknown
/// containers, and animation frames surface as precise errors.
struct SceneResourceResolver: Sendable {
    enum ResolveError: Error, Equatable, Sendable {
        case pathEscape
        case fileMissing
        case decodeFailed
        case unsupportedTexture                          // legacy alias
        case texture(WPETexDecodeError)
        /// scene.json's `image` field pointed at a `.json` model/material
        /// descriptor that we couldn't follow to a real texture file. The
        /// descriptor either references a built-in WPE utility model
        /// (`models/util/*.json`) we don't have a substitute for, or its
        /// shape doesn't expose any `material`/`passes[].textures[]`
        /// fields. Distinct case so the UI can say "scene relies on
        /// engine-built layers" rather than "tex decode failed".
        case materialUnresolved(reason: String)
    }

    let cacheRootURL: URL
    private let decoder: WPETexDecoder

    init(cacheRootURL: URL, decoder: WPETexDecoder = WPETexDecoder()) {
        self.cacheRootURL = cacheRootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.decoder = decoder
    }

    /// Single point where the resolver touches the filesystem. Pulled out as
    /// a computed property so the struct stays `Sendable` (FileManager is
    /// not Sendable, and storing one as a property is a hard error in
    /// strict-concurrency mode).
    private var fileManager: FileManager { .default }

    /// Returns a CGImage decoded from the cache.
    func resolveImage(relativePath: String) throws -> CGImage {
        guard !relativePath.isEmpty else { throw ResolveError.fileMissing }
        let resolvedPath = try resolveImageReference(relativePath: relativePath, depth: 0)
        let target = try resolveURL(for: resolvedPath)

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

    /// Returns the raw texture payload for Metal-backed renderers.
    func resolveTexturePayload(relativePath: String) throws -> WPETexTexturePayload {
        guard !relativePath.isEmpty else { throw ResolveError.fileMissing }
        let resolvedPath = try resolveImageReference(relativePath: relativePath, depth: 0)
        let target = try resolveURL(for: resolvedPath)

        guard fileManager.fileExists(atPath: target.path) else {
            throw ResolveError.fileMissing
        }
        guard target.pathExtension.lowercased() == "tex" else {
            throw ResolveError.unsupportedTexture
        }

        let payload: Data
        do {
            payload = try Data(contentsOf: target)
        } catch {
            throw ResolveError.fileMissing
        }
        switch decoder.extractTexturePayload(data: payload) {
        case .success(let texture):
            return texture
        case .failure(let error):
            throw ResolveError.texture(error)
        }
    }

    /// Walks WPE's image-reference chain until it produces a path to a real asset (`.tex` / `.png` / `.jpg` / `.gif`).
    private func resolveImageReference(relativePath: String, depth: Int) throws -> String {
        let lowered = (relativePath as NSString).pathExtension.lowercased()
        if lowered != "json" {
            return relativePath
        }
        if depth >= 4 {
            throw ResolveError.materialUnresolved(reason: "Reference depth exceeded for \(relativePath)")
        }

        let url = try resolveURL(for: relativePath)
        guard fileManager.fileExists(atPath: url.path) else {
            if relativePath.contains("models/util/") {
                throw ResolveError.materialUnresolved(reason: "Built-in WPE layer \(relativePath) is not available on macOS")
            }
            throw ResolveError.fileMissing
        }

        let payload: Data
        do {
            payload = try Data(contentsOf: url)
        } catch {
            throw ResolveError.fileMissing
        }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: payload, options: [.fragmentsAllowed])
        } catch {
            throw ResolveError.materialUnresolved(reason: "Couldn't parse \(relativePath) as JSON")
        }
        guard let dict = parsed as? [String: Any] else {
            throw ResolveError.materialUnresolved(reason: "\(relativePath) is not a JSON object")
        }

        if let materialPath = dict["material"] as? String, !materialPath.isEmpty {
            return try resolveImageReference(relativePath: materialPath, depth: depth + 1)
        }

        if let textureName = firstTextureName(in: dict) {
            return "materials/\(textureName).tex"
        }

        throw ResolveError.materialUnresolved(reason: "\(relativePath) has no `material` or `passes[].textures[]`")
    }

    /// Drills into a material descriptor's `passes[0].textures[0]` and returns its bare identifier.
    private func firstTextureName(in dict: [String: Any]) -> String? {
        guard let passes = dict["passes"] as? [[String: Any]] else { return nil }
        for pass in passes {
            guard let textures = pass["textures"] as? [Any] else { continue }
            for entry in textures {
                if let name = entry as? String, !name.isEmpty { return name }
                if let nested = entry as? [String: Any],
                   let name = nested["name"] as? String, !name.isEmpty {
                    return name
                }
            }
        }
        return nil
    }

    /// Decode-backed probe used by `WallpaperEngineImportService` during capability tier classification.
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
        let data: Data
        do {
            data = try Data(contentsOf: target, options: [.mappedIfSafe])
        } catch {
            return .failure(.fileMissing)
        }
        switch decoder.probe(data: data) {
        case .success(let info):
            guard info.format?.isPhase21Decodable == true else {
                return .success(info)
            }
            switch decoder.decode(data: data) {
            case .success:
                break
            case .failure(let error):
                return .failure(.texture(error))
            }
            return .success(info)
        case .failure(let error):
            return .failure(.texture(error))
        }
    }

    /// Import-time renderability probe for WPE image references.
    func probeRenderableImage(relativePath: String) -> Result<Void, ResolveError> {
        guard !relativePath.isEmpty else { return .failure(.fileMissing) }
        let resolvedPath: String
        do {
            resolvedPath = try resolveImageReference(relativePath: relativePath, depth: 0)
        } catch let error as ResolveError {
            return .failure(error)
        } catch {
            return .failure(.fileMissing)
        }

        let lowered = (resolvedPath as NSString).pathExtension.lowercased()
        if lowered == "tex" {
            switch probeImage(relativePath: resolvedPath) {
            case .success(let info):
                return info.format?.isPhase21Decodable == true ? .success(()) : .failure(.unsupportedTexture)
            case .failure(let error):
                return .failure(error)
            }
        }

        do {
            _ = try resolveExistingFileURL(relativePath: resolvedPath)
            return .success(())
        } catch let error as ResolveError {
            return .failure(error)
        } catch {
            return .failure(.fileMissing)
        }
    }

    /// File existence probe used by tests + the import service to decide whether a scene's declared image layers are actually shipped.
    func exists(relativePath: String) -> Bool {
        (try? resolveExistingFileURL(relativePath: relativePath)) != nil
    }

    /// Validates `relativePath`, joins it onto the cache root, and confirms the result is a regular file inside the cache.
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
    private func resolveURL(for relativePath: String) throws -> URL {
        guard let resolved = WPEPathSafety.strictResourceURL(root: cacheRootURL, relativePath: relativePath) else {
            throw ResolveError.pathEscape
        }
        return resolved
    }
}
#endif
