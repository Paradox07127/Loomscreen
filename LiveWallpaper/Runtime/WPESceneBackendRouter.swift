#if !LITE_BUILD
import Foundation

/// Decides between Metal and WebGL2 scene renderers for the `.automatic`
/// user mode. The heuristic favours Metal whenever a scene ships any
/// block-compressed (`DXT1` / `DXT3` / `DXT5` / `BC7`) texture, because
/// WebKit does not expose `WEBGL_compressed_texture_s3tc` — sampling those
/// formats from WebGL requires a CPU/GPU transcode to RGBA8 (4× memory,
/// 50–200ms per scene). Metal samples them natively on Apple Silicon.
///
/// User-pinned selections (`.metal` / `.webGL`) bypass the probe.
enum WPESceneBackendRouter {

    enum Backend: String, Sendable, Equatable, Codable {
        case metal
        case webGL = "webgl"
    }

    enum RoutedBy: String, Sendable, Equatable, Codable {
        case user
        case automatic
    }

    struct Routing: Sendable, Equatable {
        let backend: Backend
        let routedBy: RoutedBy
        let reason: String
    }

    struct SceneProfile: Sendable, Equatable {
        let totalTextures: Int
        let blockCompressedTextures: Int
        let videoTextures: Int

        var hasBlockCompressedTextures: Bool { blockCompressedTextures > 0 }
    }

    static func resolve(
        userSelection: WPERuntimeSelection,
        document: WPESceneDocument,
        cacheURL: URL,
        dependencyMounts: [WPEAssetMount] = [],
        engineAssetsRootURL: URL? = nil
    ) -> Routing {
        switch userSelection {
        case .metal:
            return Routing(backend: .metal, routedBy: .user, reason: "user pinned to Metal")
        case .webGL:
            return Routing(backend: .webGL, routedBy: .user, reason: "user pinned to WebGL")
        case .automatic:
            let profile = makeProfile(
                document: document,
                cacheURL: cacheURL,
                dependencyMounts: dependencyMounts,
                engineAssetsRootURL: engineAssetsRootURL
            )
            return decide(profile: profile)
        }
    }

    static func decide(profile: SceneProfile) -> Routing {
        if profile.hasBlockCompressedTextures {
            return Routing(
                backend: .metal,
                routedBy: .automatic,
                reason: "\(profile.blockCompressedTextures)/\(profile.totalTextures) BC-compressed textures — preferring Metal"
            )
        }
        return Routing(
            backend: .webGL,
            routedBy: .automatic,
            reason: profile.videoTextures > 0
                ? "RGBA + \(profile.videoTextures) video texture(s) — WebGL OK"
                : "RGBA-only textures — WebGL OK"
        )
    }

    static func makeProfile(
        document: WPESceneDocument,
        cacheURL: URL,
        dependencyMounts: [WPEAssetMount],
        engineAssetsRootURL: URL?
    ) -> SceneProfile {
        let resolver = WPEMultiRootResourceResolver(
            primaryRootURL: cacheURL,
            dependencyMounts: dependencyMounts,
            engineAssetsRootURL: engineAssetsRootURL
        )
        let decoder = WPETexDecoder()

        var bc = 0
        var video = 0

        for object in document.imageObjects {
            let path = object.imageRelativePath
            guard !path.isEmpty else { continue }

            if let kind = classifyDirect(path: path, resolver: resolver, decoder: decoder) {
                if kind == .blockCompressed { bc += 1 }
                if kind == .video { video += 1 }
                continue
            }

            if let kind = classifyMaterial(path: path, resolver: resolver, decoder: decoder) {
                if kind == .blockCompressed { bc += 1 }
                if kind == .video { video += 1 }
            }
        }

        return SceneProfile(
            totalTextures: document.imageObjects.count,
            blockCompressedTextures: bc,
            videoTextures: video
        )
    }

    private enum TextureKind { case rgba, blockCompressed, video }

    private static func classifyDirect(
        path: String,
        resolver: WPEMultiRootResourceResolver,
        decoder: WPETexDecoder
    ) -> TextureKind? {
        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        if ["mp4", "mov", "m4v", "webm"].contains(ext) {
            return .video
        }
        guard ext == "tex",
              let url = try? resolver.resolveExistingFileURL(relativePath: path),
              let header = try? readHeaderBytes(at: url, limit: 256) else {
            return nil
        }
        return classify(header: header, decoder: decoder)
    }

    private static func classifyMaterial(
        path: String,
        resolver: WPEMultiRootResourceResolver,
        decoder: WPETexDecoder
    ) -> TextureKind? {
        guard (path as NSString).pathExtension.isEmpty else { return nil }
        let texCandidate = "materials/\(path).tex"
        guard let url = try? resolver.resolveExistingFileURL(relativePath: texCandidate),
              let header = try? readHeaderBytes(at: url, limit: 256) else {
            return nil
        }
        return classify(header: header, decoder: decoder)
    }

    private static func classify(header: Data, decoder: WPETexDecoder) -> TextureKind {
        switch decoder.probe(data: header) {
        case .success(let info):
            if let format = info.format, format.bytesPerBlock != nil {
                return .blockCompressed
            }
            return .rgba
        case .failure(.unsupportedFormat), .failure(.metalUnavailable):
            // Format code parsed but isn't in our Phase-21 decodable set —
            // treat as BC so the router routes to Metal (which can sample
            // any documented WPE format natively).
            return .blockCompressed
        case .failure:
            return .rgba
        }
    }

    private static func readHeaderBytes(at url: URL, limit: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: limit) ?? Data()
    }
}
#endif
