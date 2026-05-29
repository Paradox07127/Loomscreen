#if !LITE_BUILD && DIRECT_DISTRIBUTION
import Foundation
import Observation

/// A transient banner the Workshop pane surfaces in the bottom-trailing corner.
/// One channel for every terminal Workshop outcome — SteamCMD downloads and
/// local folder imports both post here, so a single `WorkshopDownloadToastHost`
/// renders them with consistent ordering.
struct WorkshopToastEvent: Equatable, Sendable {
    let token: Int
    /// Bold lead line, e.g. "Downloaded" / "Imported" / "Download failed".
    let headline: String
    /// The item or library name the outcome refers to.
    let title: String
    let message: String
    let isSuccess: Bool
}

/// App-lifetime fan-in for Workshop toasts. The monotonic token lets the host
/// re-fire on every post, including a repeat of an identical outcome.
@MainActor
@Observable
final class WorkshopToastCenter {
    static let shared = WorkshopToastCenter()

    private(set) var lastEvent: WorkshopToastEvent?

    @ObservationIgnored private var token = 0

    private init() {}

    func post(headline: String, title: String, message: String, isSuccess: Bool) {
        token += 1
        lastEvent = WorkshopToastEvent(
            token: token,
            headline: headline,
            title: title,
            message: message,
            isSuccess: isSuccess
        )
    }
}
#endif
