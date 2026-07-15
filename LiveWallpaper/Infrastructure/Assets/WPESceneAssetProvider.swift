#if !LITE_BUILD
import Foundation

enum WPESceneAssetProviderError: Error, Equatable, Sendable {
    case invalidRelativePath(String)
    case fileMissing(String)
    case unreadable(String)
    case stagingUnavailable(String)
}

/// Single boundary through which the scene runtime reads project assets. Two
/// backends implement it: a directory of extracted files, and a packed
/// `scene.pkg` read in place. Reads are data-first so packed scenes never need
/// extraction; only consumers that genuinely require a file URL (video, audio,
/// some ImageIO paths) go through `stagedURL`.
protocol WPESceneAssetProvider: Sendable {
    /// Directory backends map large files via `.mappedIfSafe` so the RSS profile
    /// matches the historical extracted-cache path; package backends read the slice.
    func data(atRelativePath relativePath: String) throws -> Data
    /// A directory backend returns the project file itself; a package backend stages
    /// the entry into the provider's session-lifetime temp dir (cleaned on deinit).
    func stagedURL(atRelativePath relativePath: String) throws -> URL
    func exists(atRelativePath relativePath: String) -> Bool
    /// Diagnostic / enumeration use only — not on the hot path.
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

    func stagedURL(atRelativePath relativePath: String) throws -> URL {
        try wrapped.stagedURL(atRelativePath: relativePath)
    }

    func exists(atRelativePath relativePath: String) -> Bool {
        wrapped.exists(atRelativePath: relativePath)
    }

    var entryNames: [String] {
        wrapped.entryNames
    }
}
#endif
