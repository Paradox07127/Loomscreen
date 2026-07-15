import Foundation

#if canImport(Sparkle)
import Sparkle
#endif

@MainActor
final class SparkleUpdateService {
    static let shared = SparkleUpdateService()

    #if canImport(Sparkle)
    private var updaterController: SPUStandardUpdaterController?
    #endif

    var manualChecksEnabled: Bool {
        SparkleUpdateConfiguration.manualChecksEnabled
    }

    func checkForUpdates() {
        guard manualChecksEnabled else { return }
        #if canImport(Sparkle)
        startUpdaterIfNeeded()
        updaterController?.checkForUpdates(nil)
        #endif
    }

    private init() {}

    #if canImport(Sparkle)
    private func startUpdaterIfNeeded() {
        guard updaterController == nil else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.automaticallyChecksForUpdates = false
        updaterController = controller
    }
    #endif
}
