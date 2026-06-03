#if !LITE_BUILD
import Foundation

/// Why a consumer wants a file URL for an asset that the provider may only
/// hold inside a packed container. Lets a package-backed provider decide how
/// (and whether) to materialize the bytes on disk.
enum WPESceneAssetURLPurpose: Equatable, Sendable {
    /// AVFoundation video — needs a stable on-disk URL it can stream from.
    case avFoundationVideo
    /// Audio playback through AVAudioPlayer / AVAudioFile.
    case audioPlayback
    /// ImageIO / Core Text consumers that read from a URL.
    case fileConsumer
}

enum WPESceneAssetProviderError: Error, Equatable, Sendable {
    case invalidRelativePath(String)
    case fileMissing(String)
    case unreadable(String)
    case stagingUnavailable(String)
}

/// A file URL handed to a consumer that needs one. For a directory-backed
/// provider it is the project file itself (no copy, no release work). For a
/// package-backed provider it is a staged temporary file whose lifetime is
/// reference-counted by the stager; the consumer must `release()` once done.
struct WPEStagedAssetURL: Sendable {
    let url: URL
    private let releaseHandler: (@Sendable () -> Void)?

    init(url: URL, releaseHandler: (@Sendable () -> Void)? = nil) {
        self.url = url
        self.releaseHandler = releaseHandler
    }

    /// Idempotent: a directory-backed URL has no handler and releasing is a no-op.
    func release() {
        releaseHandler?()
    }
}

/// Single boundary through which the scene runtime reads project assets. Two
/// backends implement it: a directory of extracted files, and a packed
/// `scene.pkg` read in place. Reads are data-first so packed scenes never need
/// extraction; only consumers that genuinely require a file URL (video, audio,
/// some ImageIO paths) go through `stagedURL`.
protocol WPESceneAssetProvider: Sendable {
    /// Reads an asset's full bytes. Directory backends map large files via
    /// `.mappedIfSafe` so the RSS profile matches the historical extracted-cache
    /// path; package backends read the entry's slice.
    func data(atRelativePath relativePath: String) throws -> Data
    /// Returns a file URL for the asset, materializing it on disk only when the
    /// backend cannot expose the project file directly.
    func stagedURL(atRelativePath relativePath: String, purpose: WPESceneAssetURLPurpose) throws -> WPEStagedAssetURL
    /// True when the asset exists and is a readable regular file/entry.
    func exists(atRelativePath relativePath: String) -> Bool
    /// All relative asset paths the provider can serve (sorted). Diagnostic /
    /// enumeration use only — not on the hot path.
    var entryNames: [String] { get }
}

/// Wraps a provider whose bytes live under a security-scoped source URL (a
/// Workshop folder or a `scene.pkg` the user granted access to). Holds the
/// scope open for the provider's lifetime and drops it on deinit, so the
/// scene session owning the provider also owns the access window.
final class WPESecurityScopedSceneAssetProvider: WPESceneAssetProvider, @unchecked Sendable {
    private let wrapped: any WPESceneAssetProvider
    private let scopedURL: URL
    private let didStartAccessing: Bool

    init(wrapped: any WPESceneAssetProvider, scopedURL: URL, didStartAccessing: Bool) {
        self.wrapped = wrapped
        self.scopedURL = scopedURL
        self.didStartAccessing = didStartAccessing
    }

    deinit {
        if didStartAccessing {
            scopedURL.stopAccessingSecurityScopedResource()
        }
    }

    func data(atRelativePath relativePath: String) throws -> Data {
        try wrapped.data(atRelativePath: relativePath)
    }

    func stagedURL(atRelativePath relativePath: String, purpose: WPESceneAssetURLPurpose) throws -> WPEStagedAssetURL {
        try wrapped.stagedURL(atRelativePath: relativePath, purpose: purpose)
    }

    func exists(atRelativePath relativePath: String) -> Bool {
        wrapped.exists(atRelativePath: relativePath)
    }

    var entryNames: [String] {
        wrapped.entryNames
    }
}
#endif
