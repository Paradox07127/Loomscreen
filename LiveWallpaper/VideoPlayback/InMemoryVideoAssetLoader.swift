import AVFoundation
import Foundation

/// `AVAssetResourceLoaderDelegate` that serves a video's bytes from an
/// in-memory `Data` blob instead of letting AVFoundation re-read the file
/// from disk on every loop iteration.
///
/// Why this exists: `AVPlayerItem.preferredForwardBufferDuration` is a hint
/// AVFoundation can — and on 4K HEVC clips does — ignore, leaving the
/// player streaming ~4 MB/s straight off disk forever (verified via
/// `fs_usage`). Wrapping a custom-scheme URL with this delegate forces
/// every byte request to come from RAM, giving a hard 0 physical-read
/// guarantee once the initial load is done.
///
/// The owner must keep a reference to the loader for the lifetime of the
/// player — `AVAssetResourceLoader.setDelegate(_:queue:)` only holds a
/// weak ref.
final class InMemoryVideoAssetLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    /// Custom URL scheme used to route AVFoundation through the delegate.
    /// Picked to be obviously non-network so any logs or fs_usage entries
    /// are easy to recognise.
    static let scheme = "lwmem"

    private let data: Data
    private let mimeType: String

    /// Build a `Data` + MIME pair from a local file URL.
    static func load(from url: URL) throws -> (loader: InMemoryVideoAssetLoader, customURL: URL) {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let mime = mimeType(for: url)
        let loader = InMemoryVideoAssetLoader(data: data, mimeType: mime)
        let customURL = customURL(for: url)
        return (loader, customURL)
    }

    /// Convert a regular file URL into the `lwmem://` form that triggers the resource-loader delegate path.
    static func customURL(for url: URL) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "wallpaper"
        components.path = "/" + url.lastPathComponent
        return components.url ?? URL(string: "\(scheme)://wallpaper/video")!
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mp4", "m4v": return "video/mp4"
        case "mov":        return "video/quicktime"
        case "m4a":        return "audio/mp4"
        default:           return "video/mp4"
        }
    }

    private init(data: Data, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = mimeType
            info.contentLength = Int64(data.count)
            info.isByteRangeAccessSupported = true
        }

        if let dataRequest = loadingRequest.dataRequest {
            let start = Int(clamping: dataRequest.currentOffset)
            let requested = dataRequest.requestedLength
            let end: Int
            if requested == Int.max {
                end = data.count
            } else {
                end = min(start &+ requested, data.count)
            }
            if start < end {
                let slice = data[start..<end]
                dataRequest.respond(with: Data(slice))
            }
        }

        loadingRequest.finishLoading()
        return true
    }
}
