import CryptoKit
import Foundation
import LiveWallpaperCore

/// Stable bucket key for Wallpaper Engine web project settings.
///
/// The active HTML source is the source of truth because both the inspector
/// and the WKWebView runtime can see it. Workshop metadata is only a fallback
/// for callers that have origin data but no source yet.
enum WallpaperEngineProjectIdentity {
    static func key(source: HTMLSource?, origin: WPEOrigin? = nil) -> String? {
        if case .folder(let bookmarkData, let indexFileName) = source {
            var payload = Data()
            payload.append(bookmarkData)
            payload.append(0)
            payload.append(Data(indexFileName.utf8))
            return "folder:\(sha256Hex(payload))"
        }

        guard let origin else { return nil }
        var payload = Data()
        payload.append(origin.sourceFolderBookmark)
        payload.append(0)
        payload.append(Data((origin.entryFile ?? "").utf8))
        payload.append(0)
        payload.append(Data(origin.workshopID.utf8))
        return "origin:\(sha256Hex(payload))"
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
