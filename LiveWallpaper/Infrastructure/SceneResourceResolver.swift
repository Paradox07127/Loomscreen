#if !LITE_BUILD
import CoreGraphics
import Foundation
import ImageIO

/// Resource resolver for `.scene` content. Reads PNG/JPG via ImageIO and
/// `.tex` via the Phase 2.1 `WPETexDecoder`. All filesystem access goes through
/// a `WPESceneAssetProvider`: a directory-backed provider (extracted cache /
/// folder import) preserves the historical path-safety + `.mappedIfSafe`
/// behavior; a package-backed provider reads entries in place from `scene.pkg`.
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

    /// The extracted-cache root when directory-backed; `nil` for a
    /// package-backed resolver. Retained for diagnostics — all reads go through
    /// `provider`, never this URL.
    let cacheRootURL: URL?
    private let provider: any WPESceneAssetProvider
    private let decoder: WPETexDecoder

    init(cacheRootURL: URL, decoder: WPETexDecoder = WPETexDecoder()) {
        let normalized = cacheRootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.cacheRootURL = normalized
        self.provider = WPEDirectorySceneAssetProvider(rootURL: normalized)
        self.decoder = decoder
    }

    init(provider: any WPESceneAssetProvider, cacheRootURL: URL? = nil, decoder: WPETexDecoder = WPETexDecoder()) {
        self.cacheRootURL = cacheRootURL
        self.provider = provider
        self.decoder = decoder
    }

    /// P3 hook: when scene-debug artifacts are active, parse the `.tex`
    /// header once more (very cheap — TEXI + TEXB headers only) and
    /// write the raw TEXI image dims + TEXB v4 fields into the session
    /// folder. No-op when artifacts are off, so production scene loads
    /// don't pay the cost.
    private func dumpRawTexMetadataIfActive(payload: Data, targetName: String) {
        guard WPESceneDebugArtifacts.shared.activeSessionFolder != nil else { return }
        guard case .success(let metadata) = decoder.extractRawMetadata(data: payload) else { return }
        WPESceneDebugArtifacts.shared.dumpRawTexMetadata(
            name: (targetName as NSString).lastPathComponent,
            info: metadata.info,
            bitmap: metadata.bitmap
        )
    }

    /// Returns a CGImage decoded from the resolved asset.
    func resolveImage(relativePath: String) throws -> CGImage {
        guard !relativePath.isEmpty else { throw ResolveError.fileMissing }
        let resolvedPath = try resolveImageReference(relativePath: relativePath, depth: 0)

        if (resolvedPath as NSString).pathExtension.lowercased() == "tex" {
            let payload = try providerData(resolvedPath)
            dumpRawTexMetadataIfActive(payload: payload, targetName: resolvedPath)
            switch decoder.decode(data: payload) {
            case .success(let image):
                return image
            case .failure(let error):
                throw ResolveError.texture(error)
            }
        }

        let payload = try providerData(resolvedPath)
        guard let source = CGImageSourceCreateWithData(payload as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ResolveError.decodeFailed
        }
        return image
    }

    /// Returns the raw texture payload for Metal-backed renderers.
    func resolveTexturePayload(relativePath: String) throws -> WPETexTexturePayload {
        guard !relativePath.isEmpty else { throw ResolveError.fileMissing }
        let resolvedPath = try resolveImageReference(relativePath: relativePath, depth: 0)
        guard (resolvedPath as NSString).pathExtension.lowercased() == "tex" else {
            throw ResolveError.unsupportedTexture
        }

        let payload = try providerData(resolvedPath)
        dumpRawTexMetadataIfActive(payload: payload, targetName: resolvedPath)
        switch decoder.extractTexturePayload(data: payload) {
        case .success(let texture):
            return texture
        case .failure(let error):
            throw ResolveError.texture(error)
        }
    }

    /// Returns a streaming payload (compressed bytes + TEXS schedule)
    /// for `WPETexLazyAnimatedTextureSource`. Directory-backed reads map the
    /// file via `.mappedIfSafe`, so the 60-image multi-frame `.tex` files
    /// (>700 MB on disk) never fully materialize in resident memory.
    func resolveStreamingTexturePayload(relativePath: String) throws -> WPETexStreamingPayload {
        guard !relativePath.isEmpty else { throw ResolveError.fileMissing }
        let resolvedPath = try resolveImageReference(relativePath: relativePath, depth: 0)
        guard (resolvedPath as NSString).pathExtension.lowercased() == "tex" else {
            throw ResolveError.unsupportedTexture
        }

        let payload = try providerData(resolvedPath)
        dumpRawTexMetadataIfActive(payload: payload, targetName: resolvedPath)
        switch decoder.extractStreamingPayload(data: payload) {
        case .success(let streaming):
            return streaming
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

        guard provider.exists(atRelativePath: relativePath) else {
            if relativePath.contains("models/util/") {
                throw ResolveError.materialUnresolved(reason: "Built-in WPE layer \(relativePath) is not available on macOS")
            }
            throw ResolveError.fileMissing
        }

        let payload: Data
        do {
            payload = try provider.data(atRelativePath: relativePath)
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
        guard provider.exists(atRelativePath: relativePath) else {
            return .failure(.fileMissing)
        }
        guard (relativePath as NSString).pathExtension.lowercased() == "tex" else {
            return .failure(.unsupportedTexture)
        }
        let data: Data
        do {
            data = try provider.data(atRelativePath: relativePath)
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

        return provider.exists(atRelativePath: resolvedPath) ? .success(()) : .failure(.fileMissing)
    }

    /// File existence probe used by tests + the import service to decide whether a scene's declared image layers are actually shipped.
    func exists(relativePath: String) -> Bool {
        provider.exists(atRelativePath: relativePath)
    }

    /// Returns the raw bytes for a concrete asset path (scene.json, material /
    /// model / particle JSON, shader source). Throws `.fileMissing` on a miss
    /// so `WPEMultiRootResourceResolver`'s fallback cascade can continue.
    func data(relativePath: String) throws -> Data {
        try providerData(relativePath)
    }

    /// Validates `relativePath` and returns a file URL for a consumer that
    /// needs one (fonts, audio, video). Directory-backed returns the project
    /// file itself; package-backed materializes a staged temporary.
    func resolveExistingFileURL(relativePath: String) throws -> URL {
        guard provider.exists(atRelativePath: relativePath) else {
            throw ResolveError.fileMissing
        }
        do {
            return try provider.stagedURL(atRelativePath: relativePath, purpose: .fileConsumer).url
        } catch {
            throw ResolveError.fileMissing
        }
    }

    private func providerData(_ relativePath: String) throws -> Data {
        do {
            return try provider.data(atRelativePath: relativePath)
        } catch WPESceneAssetProviderError.invalidRelativePath {
            throw ResolveError.pathEscape
        } catch {
            throw ResolveError.fileMissing
        }
    }
}
#endif
