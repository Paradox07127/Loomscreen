#if !LITE_BUILD
import Foundation

/// A dependency workshop item mounted for in-place asset resolution.
///
/// A dependency can be backed either by a real on-disk directory (an unpacked
/// sibling Steam Workshop folder) or by a `scene.pkg` read in place — the latter
/// lets packaged dependencies resolve without ever extracting them to a cache.
struct WPEAssetMount: Equatable, Sendable {
    enum Backing: Equatable, Sendable {
        case directory(URL)
        case package(URL)
    }

    let workshopID: String
    let backing: Backing

    init(workshopID: String, rootURL: URL) {
        self.workshopID = workshopID
        self.backing = .directory(rootURL.standardizedFileURL.resolvingSymlinksInPath())
    }

    init(workshopID: String, packageURL: URL) {
        self.workshopID = workshopID
        self.backing = .package(packageURL.standardizedFileURL.resolvingSymlinksInPath())
    }

    /// Directory root for a directory-backed mount; `nil` for a package mount.
    var rootURL: URL? {
        if case .directory(let url) = backing { return url }
        return nil
    }
}
#endif
