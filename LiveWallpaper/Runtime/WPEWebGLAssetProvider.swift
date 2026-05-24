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
        if let cached = videoCache[relativePath] {
            return cached
        }

        let resolution: CascadeResolution
        do {
            resolution = try resolveImageCascade(relativePath: relativePath)
        } catch SceneResourceResolver.ResolveError.fileMissing {
            return nil
        } catch SceneResourceResolver.ResolveError.unsupportedTexture {
            Logger.warning("WPEWebGLAssetProvider: legacy unsupported texture format for \(relativePath)", category: .screenManager)
            return nil
        }

        switch resolution {
        case .image(let cgImage):
            guard let pngData = WPEWebGLAssetProvider.encodePNG(cgImage) else {
                throw NSError(
                    domain: "WPEWebGLAssetProvider",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "PNG encoding failed for \(relativePath)"]
                )
            }
            imageCache[relativePath] = pngData
            return WPEAssetResponse(bytes: pngData, mimeType: "image/png", cacheControl: "max-age=3600")
        case .video(let bytes):
            let response = WPEAssetResponse(bytes: bytes, mimeType: "video/mp4", cacheControl: "max-age=3600")
            videoCache[relativePath] = response
            return response
        }
    }

    // WPE material payloads reference textures by bare name
    // ("neco arc ship with grain"). `SceneResourceResolver` only walks
    // the material-include chain when the input path already ends in
    // `.json`; bare names get returned as-is and miss the asset on disk.
    // Mirror the WPE lookup order on this side so the playback path
    // surfaces the actual `.tex` / image file instead of falling through
    // to the magenta placeholder.
    private static let textureSearchSuffixes = ["tex", "png", "jpg", "jpeg", "gif", "webp"]

    private enum CascadeResolution {
        case image(CGImage)
        /// MP4 bytes lifted out of a `.tex` container whose payload is an
        /// animated video. The TS-side TextureManager routes this through
        /// the `<video>` element pipeline.
        case video(Data)
    }

    private func resolveImageCascade(relativePath: String) throws -> CascadeResolution {
        let ext = (relativePath as NSString).pathExtension.lowercased()
        if !ext.isEmpty {
            return .image(try resolver.resolveImage(relativePath: relativePath))
        }

        let candidates: [String] = [
            relativePath,
            "materials/\(relativePath).json"
        ] + Self.textureSearchSuffixes.map { "materials/\(relativePath).\($0)" }

        var lastError: Error = SceneResourceResolver.ResolveError.fileMissing
        for candidate in candidates {
            do {
                let image = try resolver.resolveImage(relativePath: candidate)
                Logger.info("WPEWebGLAssetProvider cascade HIT '\(relativePath)' → '\(candidate)' (image)", category: .screenManager)
                return .image(image)
            } catch SceneResourceResolver.ResolveError.fileMissing {
                resolver.popLastTraceEvent()
                continue
            } catch SceneResourceResolver.ResolveError.texture(.unsupportedAnimation) {
                // .tex container wraps an MP4 (WPE's animated-texture
                // format). Re-decode via the texture-payload path to lift
                // the raw bytes and serve them as video. The previous
                // resolveImage attempt already recorded a probe miss —
                // discard it so the user-visible tracer only shows the
                // final success.
                resolver.popLastTraceEvent()
                if let videoBytes = try? extractAnimatedVideoBytes(relativePath: candidate) {
                    Logger.info("WPEWebGLAssetProvider cascade HIT '\(relativePath)' → '\(candidate)' (video, \(videoBytes.count) bytes)", category: .screenManager)
                    return .video(videoBytes)
                }
                lastError = SceneResourceResolver.ResolveError.texture(.unsupportedAnimation)
            } catch {
                resolver.popLastTraceEvent()
                lastError = error
            }
        }
        Logger.warning("WPEWebGLAssetProvider cascade exhausted for '\(relativePath)', last error: \(lastError)", category: .screenManager)
        // Cascade ran out of candidates — surface a single tracer event
        // under the original (bare) request path so the diagnostic panel
        // names what the renderer was actually looking for.
        resolver.recordTraceEvent(
            relativePath: relativePath,
            attempt: WPEResolutionAttempt(origin: .scene, outcome: outcome(for: lastError)),
            finalOutcome: outcome(for: lastError)
        )
        throw lastError
    }

    private func extractAnimatedVideoBytes(relativePath: String) throws -> Data? {
        let payload = try resolver.resolveTexturePayload(relativePath: relativePath)
        return payload.videoPayload?.bytes
    }

    private nonisolated func outcome(for error: Error) -> WPEResolutionOutcome {
        switch error {
        case SceneResourceResolver.ResolveError.fileMissing:
            return .fileMissing
        default:
            return .otherError("\(error)")
        }
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
