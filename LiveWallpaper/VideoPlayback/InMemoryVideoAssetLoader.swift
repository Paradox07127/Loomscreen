import AVFoundation
import Foundation

/// `AVAssetResourceLoaderDelegate` that serves a video's bytes from an
/// in-memory `Data` blob (a `.mappedIfSafe` mapping) instead of letting
/// AVFoundation re-read the file from disk on every loop iteration.
///
/// Why this exists: `AVPlayerItem.preferredForwardBufferDuration` is a hint
/// AVFoundation can — and on 4K HEVC clips does — ignore, leaving the
/// player streaming ~4 MB/s straight off disk forever (verified via
/// `fs_usage`). Wrapping a custom-scheme URL with this delegate forces
/// every byte request to come from RAM, giving a hard 0 physical-read
/// guarantee once the initial load is done.
///
/// It also backs **in-place packaged video**: `loadPackageEntry` maps the
/// whole `scene.pkg` and exposes a *window* `[windowStart, windowStart+
/// windowLength)` into it (the video entry's contiguous, uncompressed byte
/// slice). The player gets a normal-looking byte-range resource without the
/// package ever being extracted. `mappedIfSafe` keeps the RSS profile lazy —
/// only the pages AVFoundation actually reads page in.
///
/// The owner must keep a reference to the loader for the lifetime of the
/// player — `AVAssetResourceLoader.setDelegate(_:queue:)` only holds a
/// weak ref.
final class InMemoryVideoAssetLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    /// Obviously non-network scheme so any logs or fs_usage entries are easy to recognise.
    static let scheme = "lwmem"

    private let data: Data
    private let mimeType: String
    /// Window into `data` that this loader exposes as the resource. For a plain
    /// file the window is the whole blob; for a packaged entry it's the entry's
    /// byte slice within the mapped `scene.pkg`.
    private let windowStart: Int
    private let windowLength: Int

    static func load(from url: URL) throws -> (loader: InMemoryVideoAssetLoader, customURL: URL) {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let mime = mimeType(forPathExtension: url.pathExtension)
        let loader = InMemoryVideoAssetLoader(
            data: data,
            mimeType: mime,
            windowStart: 0,
            windowLength: data.count
        )
        return (loader, customURL(forLastComponent: url.lastPathComponent))
    }

    /// In-place packaged video: maps the whole package lazily and exposes only
    /// the entry's contiguous byte range. No extraction.
    static func loadPackageEntry(
        packageURL: URL,
        entryName: String
    ) throws -> (loader: InMemoryVideoAssetLoader, customURL: URL) {
        let package: WallpaperEnginePackage
        do {
            let handle = try FileHandle(forReadingFrom: packageURL)
            defer { try? handle.close() }
            package = try WallpaperEnginePackage.parseIndex(streamingFrom: handle)
        }
        guard let lookup = WallpaperEnginePackage.canonicalLookupName(entryName),
              let entry = package.entry(named: lookup) else {
            throw NSError(domain: "InMemoryVideoAssetLoader", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "Video entry \(entryName) not found in package"
            ])
        }
        let data = try Data(contentsOf: packageURL, options: .mappedIfSafe)
        let absoluteStart = package.dataStart + entry.dataOffset
        guard let start = Int(exactly: absoluteStart),
              let length = Int(exactly: entry.dataSize),
              start >= 0, length >= 0, start &+ length <= data.count else {
            throw NSError(domain: "InMemoryVideoAssetLoader", code: 422, userInfo: [
                NSLocalizedDescriptionKey: "Video entry \(entryName) is out of package bounds"
            ])
        }
        let loader = InMemoryVideoAssetLoader(
            data: data,
            mimeType: mimeType(forPathExtension: (entryName as NSString).pathExtension),
            windowStart: start,
            windowLength: length
        )
        return (loader, customURL(forLastComponent: (entryName as NSString).lastPathComponent))
    }

    private static func customURL(forLastComponent lastComponent: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "wallpaper"
        components.path = "/" + (lastComponent.isEmpty ? "video" : lastComponent)
        return components.url ?? URL(string: "\(scheme)://wallpaper/video")!
    }

    private static func mimeType(forPathExtension rawExtension: String) -> String {
        switch rawExtension.lowercased() {
        case "mp4", "m4v": return "video/mp4"
        case "mov":        return "video/quicktime"
        case "m4a":        return "audio/mp4"
        default:           return "video/mp4"
        }
    }

    private init(data: Data, mimeType: String, windowStart: Int, windowLength: Int) {
        self.data = data
        self.mimeType = mimeType
        self.windowStart = windowStart
        self.windowLength = windowLength
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = mimeType
            info.contentLength = Int64(windowLength)
            info.isByteRangeAccessSupported = true
        }

        if let dataRequest = loadingRequest.dataRequest {
            // Offsets are relative to the logical resource (0..<windowLength);
            // map them into the underlying blob via `windowStart`.
            let logicalStart = Int(clamping: dataRequest.currentOffset)
            let requested = dataRequest.requestedLength
            let logicalEnd: Int
            if requested == Int.max {
                logicalEnd = windowLength
            } else {
                logicalEnd = min(logicalStart &+ requested, windowLength)
            }
            // Respond in bounded chunks so a large requested range can't
            // trigger a single multi-hundred-MB `Data` copy. AVFoundation
            // accepts repeated `respond(with:)` calls before
            // `finishLoading()` and stitches them into one fulfilled range.
            var offset = logicalStart
            while offset < logicalEnd {
                let next = min(offset &+ Self.chunkSize, logicalEnd)
                let physicalLow = windowStart &+ offset
                let physicalHigh = windowStart &+ next
                dataRequest.respond(with: Data(data[physicalLow..<physicalHigh]))
                offset = next
            }
        }

        loadingRequest.finishLoading()
        return true
    }

    /// 2 MB per chunk strikes a balance between syscall overhead and
    /// peak temporary copy size. AVFoundation typically asks for at most
    /// a few MB at a time, so most requests fulfill in one or two chunks.
    private static let chunkSize: Int = 2 * 1024 * 1024
}
