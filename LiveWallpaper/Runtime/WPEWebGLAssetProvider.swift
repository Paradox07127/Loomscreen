#if !LITE_BUILD
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// `WPEAssetProvider` implementation that serves two asset kinds:
/// - Image (default): decode through `WPEMultiRootResourceResolver` →
///   `CGImage` → PNG bytes for JS `createImageBitmap`.
/// - Video (`.mp4` / `.webm` / `.mov` / `.m4v`): memory-mapped raw file
///   bytes so WebKit's `<video>` element can decode natively via
///   AVFoundation. Range support is handled by the scheme handler.
///
/// Decoded payloads are cached per-session; the renderer drops the
/// provider on scene unload, freeing the cache.
actor WPEWebGLAssetProvider: WPEAssetProvider {
    private static let videoExtensions: Set<String> = ["mp4", "webm", "mov", "m4v"]

    private let resolver: WPEMultiRootResourceResolver
    private var imageCache: [String: Data] = [:]
    private var videoCache: [String: WPEAssetResponse] = [:]

    init(resolver: WPEMultiRootResourceResolver) {
        self.resolver = resolver
    }

    func data(for relativePath: String) async throws -> WPEAssetResponse? {
        let ext = (relativePath as NSString).pathExtension.lowercased()
        if Self.videoExtensions.contains(ext) {
            return try resolveVideo(relativePath: relativePath, extension: ext)
        }
        return try resolveImage(relativePath: relativePath)
    }

    private func resolveImage(relativePath: String) throws -> WPEAssetResponse? {
        if let cached = imageCache[relativePath] {
            return WPEAssetResponse(bytes: cached, mimeType: "image/png", cacheControl: "max-age=3600")
        }

        let cgImage: CGImage
        do {
            cgImage = try resolver.resolveImage(relativePath: relativePath)
        } catch SceneResourceResolver.ResolveError.fileMissing {
            return nil
        } catch SceneResourceResolver.ResolveError.unsupportedTexture {
            Logger.warning("WPEWebGLAssetProvider: legacy unsupported texture format for \(relativePath)", category: .screenManager)
            return nil
        }

        guard let pngData = WPEWebGLAssetProvider.encodePNG(cgImage) else {
            throw NSError(
                domain: "WPEWebGLAssetProvider",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "PNG encoding failed for \(relativePath)"]
            )
        }

        imageCache[relativePath] = pngData
        return WPEAssetResponse(bytes: pngData, mimeType: "image/png", cacheControl: "max-age=3600")
    }

    private func resolveVideo(relativePath: String, extension ext: String) throws -> WPEAssetResponse? {
        if let cached = videoCache[relativePath] {
            return cached
        }
        let fileURL: URL
        do {
            fileURL = try resolver.resolveExistingFileURL(relativePath: relativePath)
        } catch SceneResourceResolver.ResolveError.fileMissing {
            return nil
        }
        // Memory-mapped — pages in as WebKit reads ranges; doesn't pin
        // the whole video in RAM.
        let bytes = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let mime = WPEWebGLAssetProvider.videoMimeType(for: ext)
        let response = WPEAssetResponse(bytes: bytes, mimeType: mime, cacheControl: "max-age=3600")
        videoCache[relativePath] = response
        return response
    }

    nonisolated private static func videoMimeType(for ext: String) -> String {
        switch ext {
        case "mp4", "m4v": return "video/mp4"
        case "webm":       return "video/webm"
        case "mov":        return "video/quicktime"
        default:           return "application/octet-stream"
        }
    }

    nonisolated private static func encodePNG(_ image: CGImage) -> Data? {
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutableData as Data
    }
}
#endif
