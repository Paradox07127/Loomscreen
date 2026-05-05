import Foundation

struct WPEAssetMount: Equatable, Sendable {
    let workshopID: String
    let rootURL: URL

    init(workshopID: String, rootURL: URL) {
        self.workshopID = workshopID
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
    }
}
